import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
#if canImport(UIKit)
import UIKit
#endif

struct ReceiptScan {
    /// Items at their printed prices, with tax and discounts folded into each item's offset.
    var items: [ReceiptItem] = []
    var taxCents = 0
    /// Discounts printed after the subtotal, which apply to the whole receipt.
    var discountCents = 0
    /// Set only when the receipt shows exactly one distinct date, so an ambiguous receipt still asks the member.
    var purchaseDate: Date?
    /// The printed balance or total, used to flag misread prices.
    var printedTotalCents: Int?
    /// Every line Vision read, saved with the receipt so a misread can be traced later.
    var recognizedText = ""

    /// Nil when the items, tax and discounts add up to the printed total, or when no total was found.
    var mismatchWarning: String? {
        guard let printed = printedTotalCents else { return nil }
        let found = items.reduce(0) { $0 + $1.totalCents }
        guard found != printed else { return nil }
        return "Items, tax and discounts add up to \(found.usd), but the receipt total is \(printed.usd). Check the item prices."
    }
}

struct ExpenseSuggestion {
    var category: ExpenseCategory?
    var name: String
}

/// Fast, deterministic on-device suggestions from Vision's recognized text. This remains the fallback when the
/// Apple Intelligence model is unavailable and keeps a model suggestion from becoming accounting truth.
enum ExpenseSuggester {
    static func suggest(from scan: ReceiptScan) -> ExpenseSuggestion {
        let evidence = ([scan.recognizedText] + scan.items.map(\.name)).joined(separator: "\n")
        let text = evidence.lowercased()
        let category: ExpenseCategory?
        if containsAny(text, ["ticketmaster", "live nation", "concert", "music venue", "eventbrite"]) {
            category = .concert
        } else if containsAny(text, ["amc theatres", "amc theaters", "regal cinemas", "cinemark", "showtime", "auditorium", "movie", "cinema", "theatre", "theater", "matinee", "screen "]) {
            category = .movie
        } else if containsAny(text, ["restaurant", "server", "table", "gratuity", "suggested tip", "dine in", "diner", "bistro", "cafe", "pizzeria", "taqueria", "sushi", "bar & grill", "starbucks", "chipotle", "chick-fil-a", "mcdonald"]) {
            category = .restaurant
        } else if containsAny(text, ["trader joe", "whole foods", "costco", "kroger", "publix", "wegmans", "safeway", "supermarket", "grocery", "produce", "aldi", "food lion", "sprouts", "shoprite", "harris teeter", "fresh market"]) {
            category = .groceries
        } else {
            category = nil
        }
        let identifyingName = merchant(in: scan.recognizedText) ?? scan.items.first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).map { displayName($0.name) }
        let name = identifyingName.map { identifier in
            switch category {
            case .groceries: "\(identifier) Groceries"
            case .restaurant: "\(identifier) Meal"
            case .movie: "\(identifier) Movie Tickets"
            case .concert: "\(identifier) Tickets"
            case nil: "\(identifier) Expense"
            }
        } ?? category?.suggestedName ?? "Shared Expense"
        return ExpenseSuggestion(category: category, name: name)
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool { terms.contains(where: text.contains) }
    private static func merchant(in text: String) -> String? {
        let lowercased = text.lowercased()
        let known: [(String, String)] = [
            ("trader joe", "Trader Joe's"), ("whole foods", "Whole Foods"), ("ticketmaster", "Ticketmaster"),
            ("live nation", "Live Nation"), ("amc", "AMC"), ("regal", "Regal"), ("cinemark", "Cinemark"),
            ("starbucks", "Starbucks"), ("chipotle", "Chipotle"), ("chick-fil-a", "Chick-fil-A"),
            ("mcdonald", "McDonald's"), ("costco", "Costco"), ("walmart", "Walmart"), ("target", "Target"),
            ("kroger", "Kroger"), ("publix", "Publix"), ("wegmans", "Wegmans"), ("safeway", "Safeway"),
            ("aldi", "ALDI"), ("food lion", "Food Lion"), ("sprouts", "Sprouts"), ("shoprite", "ShopRite")
        ]
        if let knownName = known.first(where: { lowercased.contains($0.0) })?.1 { return knownName }
        let boilerplate = ["full photo", "enhanced crop", "receipt", "welcome", "thank you", "subtotal", "total", "balance", "cashier", "register", "order", "transaction", "approved", "customer copy", "merchant copy", "sale"]
        return text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let lower = line.lowercased()
            guard (2...36).contains(line.count), line.contains(where: \.isLetter), line.split(whereSeparator: \.isWhitespace).count <= 5 else { return nil }
            guard !boilerplate.contains(where: lower.contains), !lower.contains("www."), !lower.contains("http"), !lower.contains("@") else { return nil }
            guard line.range(of: #"\$?\d+[.,]\d{2}|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b\d{3}[-.) ]\d{3}"#, options: .regularExpression) == nil else { return nil }
            return displayName(line)
        }.first
    }

    private static func displayName(_ value: String) -> String {
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact == compact.uppercased() ? compact.localizedCapitalized : compact
    }
}

enum ReceiptTextRecognizer {
    /// One piece of recognized text with its Vision bounding box (normalized, origin bottom-left).
    struct Fragment {
        var text: String
        var box: CGRect
        var alternatives: [String] = []
        var confidence: Float = 1
    }

    #if canImport(UIKit)
    static func scan(_ image: UIImage) async throws -> ReceiptScan {
        guard let cgImage = image.cgImage else { return ReceiptScan() }
        let orientation = image.cgImageOrientation
        if #available(iOS 26.0, *) {
            if let structured = try? await documentScan(cgImage, orientation: orientation) {
                if !needsRetry(structured) { return structured }
                let fallback = try legacyScan(cgImage, orientation: orientation)
                return score(structured) >= score(fallback) ? structured : fallback
            }
        }
        return try legacyScan(cgImage, orientation: orientation)
    }
    #endif

    /// iOS 26 document recognition preserves line structure before the receipt-specific parser classifies rows.
    @available(iOS 26.0, *)
    private static func documentScan(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> ReceiptScan {
        let observations = try await RecognizeDocumentsRequest().perform(on: cgImage, orientation: orientation)
        guard let document = observations.first?.document else { return ReceiptScan() }
        let fragments = document.text.lines.compactMap { line -> Fragment? in
            let candidates = line.topCandidates(3)
            guard let first = candidates.first else { return nil }
            return Fragment(
                text: first.string,
                box: line.boundingBox.cgRect,
                alternatives: candidates.dropFirst().map(\.string),
                confidence: first.confidence
            )
        }
        return parse(fragments)
    }

    /// The already-cropped receipt gets one accurate pass. A second enhanced pass runs only when the
    /// first result has no credible total, no items, or does not reconcile.
    private static func legacyScan(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> ReceiptScan {
        let image = CIImage(cgImage: cgImage).oriented(orientation)
        let firstFragments = try fragments(in: image)
        let first = parse(firstFragments)
        guard needsRetry(first), let area = textArea(of: firstFragments) else { return first }
        let extent = image.extent
        let crop = CGRect(x: extent.minX + area.minX * extent.width, y: extent.minY + area.minY * extent.height,
                          width: area.width * extent.width, height: area.height * extent.height)
        let enhanced = image.cropped(to: crop)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6])
        let second = parse(try fragments(in: enhanced, languageCorrection: true))
        // The crop can cut off a date printed outside the item area, so either pass may supply it.
        var best = score(second) >= score(first) ? second : first
        best.purchaseDate = best.purchaseDate ?? first.purchaseDate ?? second.purchaseDate
        best.recognizedText = "[Full photo]\n\(first.recognizedText)\n\n[Enhanced crop]\n\(second.recognizedText)"
        return best
    }

    private static func fragments(in image: CIImage, languageCorrection: Bool = false) throws -> [Fragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        request.customWords = ["SUBTOTAL", "TOTAL", "GRAND TOTAL", "AMOUNT DUE", "BALANCE DUE", "TAX"]
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(ciImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(3)
            return candidates.first.map {
                Fragment(text: $0.string, box: observation.boundingBox,
                         alternatives: candidates.dropFirst().map(\.string), confidence: $0.confidence)
            }
        }
    }

    /// The normalized area covered by line-sized text, padded slightly. Oversized fragments,
    /// such as a logo or a misread column, are ignored.
    private static func textArea(of fragments: [Fragment]) -> CGRect? {
        let lines = fragments.filter { $0.box.height < 0.04 }
        guard lines.count >= 5, let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
        let padded = bounds.insetBy(dx: -0.03, dy: -0.02).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return padded.width * padded.height < 0.9 ? padded : nil
    }

    /// Prefers a scan that matches the printed total, then one with more items.
    private static func score(_ scan: ReceiptScan) -> Int {
        (scan.printedTotalCents != nil && scan.mismatchWarning == nil ? 1_000 : 0) + scan.items.count
    }

    private static func needsRetry(_ scan: ReceiptScan) -> Bool {
        scan.printedTotalCents == nil || scan.items.isEmpty || scan.mismatchWarning != nil
    }

    /// Vision returns the name and price columns of a receipt as separate fragments,
    /// so fragments are first regrouped into printed rows by vertical position.
    static func parse(_ fragments: [Fragment]) -> ReceiptScan {
        var scan = ReceiptScan()
        var printedTotal: (cents: Int, priority: Int, confidence: Float)?
        var pendingName: String?
        var pendingRole: SummaryRole?
        var lastItem: Int?
        var inSummary = false
        var summaryAmounts: [Int] = []
        for row in rows(from: fragments) {
            let text = row.map(\.text).joined(separator: " ")
            let roleEvidence = ([text] + row.flatMap(\.alternatives)).joined(separator: " ")
            let rowConfidence = row.map(\.confidence).min() ?? 0
            let lower = text.lowercased()
            let rowRole = summaryRole(in: roleEvidence)
            // Quantity and weight detail lines ("2 @ 6.49", "1.04 lb @ 1.99 /lb") precede the priced line.
            if lower.contains("@") || lower.contains("/lb") { continue }
            guard let (rawName, cents) = priced(text) else {
                pendingRole = rowRole
                pendingName = rowRole == nil && lower.contains(where: \.isLetter) && !isExcluded(lower) ? clean(text) : nil
                if rowRole?.beginsSummary == true { inSummary = true }
                continue
            }
            // A price printed on its own row belongs to the name on the row above. That name goes through the
            // same checks, so a "TAX" label whose amount landed on the next row isn't read as an item.
            let cleaned = clean(rawName)
            let name = cleaned.contains(where: \.isLetter) ? cleaned : pendingName
            let role = rowRole ?? pendingRole
            pendingName = nil
            pendingRole = nil
            let lowerName = name?.lowercased() ?? lower
            if cents < 0 {
                if role?.rejectsNegativeAmount == true { continue }
                if !inSummary, let lastItem {
                    scan.items[lastItem].offsetCents += cents
                } else {
                    scan.discountCents -= cents
                }
                continue
            }
            switch role {
            case .subtotal:
                inSummary = true
            case .tax:
                inSummary = true
                scan.taxCents += cents
            case let .total(priority):
                inSummary = true
                let currentPriority = printedTotal?.priority ?? -1
                if priority > currentPriority
                    || (priority == currentPriority && rowConfidence >= (printedTotal?.confidence ?? 0)) {
                    printedTotal = (cents, priority, rowConfidence)
                }
            case .payment:
                inSummary = true
                summaryAmounts.append(cents)
            case .savings:
                inSummary = true
            case nil where !inSummary && !isExcluded(lowerName) && cents > 0:
                if let name {
                    scan.items.append(ReceiptItem(name: name, cents: cents))
                    lastItem = scan.items.count - 1
                }
            case nil where inSummary && cents > 0:
                summaryAmounts.append(cents)
            default:
                // Once summary rows begin, an unknown amount is never promoted to a purchased item.
                break
            }
        }
        scan.items.spread(scan.taxCents - scan.discountCents)
        let reconciled = scan.items.reduce(0) { $0 + $1.totalCents }
        scan.printedTotalCents = printedTotal?.cents ?? summaryAmounts.last(where: { $0 == reconciled })
        scan.purchaseDate = purchaseDate(in: fragments.map(\.text))
        scan.recognizedText = fragments.map(\.text).joined(separator: "\n")
        return scan
    }

    private enum SummaryRole: Equatable {
        case subtotal, tax, total(priority: Int), payment, savings
        var beginsSummary: Bool {
            switch self { case .subtotal, .tax, .total(_), .payment: true; case .savings: false }
        }
        var rejectsNegativeAmount: Bool {
            switch self { case .total(_), .subtotal, .payment: true; case .tax, .savings: false }
        }
    }

    /// Normalizes common OCR substitutions before deciding whether a monetary row is receipt summary data.
    private static func summaryRole(in text: String) -> SummaryRole? {
        let folded = String(text.lowercased().map { character in
            switch character {
            default: character.isLetter || character.isNumber ? character : " "
            }
        })
        let words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        let compact = words.joined()
        let fuzzy = String(compact.map { character in
            switch character { case "0", "q": "o"; case "1", "|": "l"; case "5": "s"; default: character }
        }).replacingOccurrences(of: "totai", with: "total")
        if fuzzy.contains("subtotal") { return .subtotal }
        if words.contains(where: { word in
            word == "tax" || word == "taxes" || (word.hasPrefix("tax") && word.dropFirst(3).allSatisfy(\.isNumber))
        }) { return .tax }
        if ["saving", "savings", "discount", "coupon"].contains(where: words.contains) { return .savings }
        if fuzzy.contains("grandtotal") || fuzzy.contains("amountdue") || fuzzy.contains("amtdue") { return .total(priority: 4) }
        if fuzzy.contains("balancedue") || words.contains("balance") { return .total(priority: 3) }
        if fuzzy.contains("total") { return .total(priority: 2) }
        if ["cash", "credit", "debit", "card", "visa", "mastercard", "discover", "amex", "payment", "tend", "tendered", "change", "approved", "auth"].contains(where: words.contains) { return .payment }
        if words.contains("due") { return .total(priority: 1) }
        return nil
    }

    /// Whole words only, so an item like "PRK TENDERLOIN" isn't mistaken for a "TEND" payment line.
    private static let excludedWords = try! NSRegularExpression(pattern: #"\b(sub ?total|total|balance|change|cash|credit|debit|card|visa|mastercard|discover|amex|saved|savings|tend|tendered|due|payment|approved|auth)\b"#)

    private static func isExcluded(_ lowercased: String) -> Bool {
        excludedWords.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)) != nil
    }

    private static func rows(from fragments: [Fragment]) -> [[Fragment]] {
        // Where item names usually start, so margin flags can be told apart from brand prefixes like "WB",
        // and price-column pieces can be told apart from names.
        let nameStarts = group(fragments.filter { $0.text.count > 2 && $0.text.contains(where: \.isLetter) })
            .compactMap { $0.min(by: { $0.box.minX < $1.box.minX })?.box.minX }.sorted()
        let nameColumn = nameStarts.isEmpty ? 0 : nameStarts[nameStarts.count / 2]
        let isPricePiece = { (fragment: Fragment) in
            fragment.box.minX > nameColumn && fragment.text.range(of: #"^-?\$?-?[\d.,\s]*-?\s*[A-Z]{0,2}$"#, options: .regularExpression) != nil
        }
        var rows = group(fragments.filter { !isPricePiece($0) })
        // A photographed receipt is rarely flat, so the price column drifts up or down relative to the
        // names. Walking down the receipt, each price is matched to the nearest name row after
        // allowing for the drift measured on the row above it.
        var drift: CGFloat = 0
        for pieces in group(fragments.filter(isPricePiece)) {
            let cluster = [Fragment(text: priceText(pieces), box: pieces[0].box, confidence: pieces.map(\.confidence).min() ?? 0)]
            let midY = cluster[0].box.midY
            let summaryRows = rows.indices.filter { index in
                let evidence = rows[index].flatMap { [$0.text] + $0.alternatives }.joined(separator: " ")
                return summaryRole(in: evidence) != nil
                    && abs(rows[index][0].box.midY + drift - midY) < rows[index][0].box.height * 1.5
            }
            let candidates = summaryRows.isEmpty ? Array(rows.indices) : summaryRows
            let nearest = candidates.min { abs(rows[$0][0].box.midY + drift - midY) < abs(rows[$1][0].box.midY + drift - midY) }
            let tolerance: CGFloat = summaryRows.isEmpty ? 0.75 : 1.5
            if let index = nearest, abs(rows[index][0].box.midY + drift - midY) < rows[index][0].box.height * tolerance {
                drift = midY - rows[index][0].box.midY
                rows[index] += cluster
            } else {
                rows.append(cluster)
            }
        }
        return rows.sorted { $0[0].box.midY > $1[0].box.midY }.map { row in
            var row = row.sorted { $0.box.minX < $1.box.minX }
            // Drop a standalone register flag in the left margin, like "WT" (weighed) or "SC".
            if row.count > 1, row[0].box.maxX < nameColumn, row[0].text.range(of: #"^[A-Z]{1,2}$"#, options: .regularExpression) != nil { row.removeFirst() }
            return row
        }
    }

    /// Rejoins a price that Vision split into pieces ("8" and ",39", or "4 99") and restores a
    /// dropped decimal point, since receipt prices always print two decimal places. A minus sign on
    /// either side marks a discount. A price that lost digits stays visible so the member can correct
    /// it; the total check flags it.
    private static func priceText(_ pieces: [Fragment]) -> String {
        let text = pieces.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        let flag = text.range(of: #"\s[A-Z]{1,2}$"#, options: .regularExpression).map { String(text[$0]) } ?? ""
        let sign = text.contains("-") ? "-" : ""
        let number = text.filter { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        guard number.contains(where: \.isNumber) else { return text }
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].count == 2 { return "\(sign)\(parts[0].isEmpty ? "0" : String(parts[0])).\(parts[1])\(flag)" }
        let digits = number.filter(\.isNumber)
        guard parts.count == 1, digits.count >= 2 else { return text }
        return "\(sign)\(digits.count == 2 ? "0" : String(digits.dropLast(2))).\(digits.suffix(2))\(flag)"
    }

    /// Groups fragments that sit on the same printed line, top to bottom.
    private static func group(_ fragments: [Fragment]) -> [[Fragment]] {
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = rows.firstIndex(where: { row in
                let anchor = row[0].box
                return abs(anchor.midY - fragment.box.midY) < min(anchor.height, fragment.box.height) * 0.5
            }) {
                rows[index].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows
    }

    /// Splits a row ending in a price, ignoring a trailing tax flag such as "F" or "T". A discount prints
    /// with a minus sign before or after the amount ("-1.00", "1.00-") and comes back negative.
    private static func priced(_ text: String) -> (String, Int)? {
        let pattern = #"^(.*?)\s*(-?)\s*\$?(-?)(\d{1,5}[.,]\d{2})(-?)\s*[A-Z]{0,2}\s*$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let priceRange = Range(match.range(at: 4), in: text),
              let decimal = Decimal(string: text[priceRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let isNegative = [2, 3, 5].contains { match.range(at: $0).length > 0 }
        let cents = NSDecimalNumber(decimal: decimal * 100).intValue
        return (String(text[nameRange]), isNegative ? -cents : cents)
    }

    private static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    /// Receipts can print several dates, such as a return-by date or a survey deadline. Future dates are
    /// ignored, a date printed beside a time (the checkout timestamp) wins, and otherwise the latest date is used.
    static func purchaseDate(in lines: [String], now: Date = Date()) -> Date? {
        var dates: [Date] = [], timed: [Date] = []
        for line in lines {
            let found = self.dates(in: line).filter { $0 <= now }
            dates += found
            if line.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil { timed += found }
        }
        return timed.max() ?? dates.max()
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    /// Numeric dates are read US style (month first). Each pattern captures year, month, and day in the given order.
    private static let datePatterns: [(NSRegularExpression, order: [Character])] = [
        (#"\b(\d{4})[/.-](\d{1,2})[/.-](\d{1,2})\b"#, ["y", "m", "d"]),
        (#"\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\b"#, ["m", "d", "y"]),
        (#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*(\d{1,2}),?\s+(\d{4}|\d{2})\b"#, ["m", "d", "y"]),
        (#"\b(\d{1,2})\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(\d{4}|\d{2})\b"#, ["d", "m", "y"]),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    private static func dates(in line: String) -> [Date] {
        datePatterns.flatMap { regex, order in
            regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match -> Date? in
                var parts: [Character: Int] = [:]
                for (index, key) in order.enumerated() {
                    guard let range = Range(match.range(at: index + 1), in: line) else { return nil }
                    let text = line[range].lowercased()
                    guard let value = Int(text) ?? months.firstIndex(where: text.hasPrefix).map({ $0 + 1 }) else { return nil }
                    parts[key] = value
                }
                guard let year = parts["y"], let month = parts["m"], let day = parts["d"] else { return nil }
                let components = DateComponents(year: year < 100 ? 2000 + year : year, month: month, day: day)
                return components.isValidDate(in: .current) ? Calendar.current.date(from: components) : nil
            }
        }
    }
}

#if canImport(UIKit)
extension UIImage {
    var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
#endif
