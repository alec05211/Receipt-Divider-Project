import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
#if canImport(UIKit)
import UIKit
#endif

struct ReceiptScan {
    var items: [ReceiptItem] = []
    var taxCents = 0
    /// Set only when the receipt shows exactly one distinct date, so an ambiguous receipt still asks the member.
    var purchaseDate: Date?
    /// The printed balance or total, used to flag misread prices.
    var printedTotalCents: Int?

    /// Nil when the items and tax add up to the printed total, or when no total was found.
    var mismatchWarning: String? {
        guard let printed = printedTotalCents else { return nil }
        let found = items.reduce(0) { $0 + $1.cents } + taxCents
        guard found != printed else { return nil }
        return "Items and tax add up to \(found.usd), but the receipt total is \(printed.usd). Check the prices below."
    }
}

enum ReceiptTextRecognizer {
    /// One piece of recognized text with its Vision bounding box (normalized, origin bottom-left).
    struct Fragment { var text: String; var box: CGRect }

    #if canImport(UIKit)
    static func scan(_ image: UIImage) throws -> ReceiptScan {
        guard let cgImage = image.cgImage else { return ReceiptScan() }
        return try scan(cgImage, orientation: image.cgImageOrientation)
    }
    #endif

    /// Vision works at a limited resolution, so a receipt that fills only part of the photo loses
    /// small printed digits. A first pass locates the receipt text; a second pass reads a
    /// high-contrast crop of just that area, and whichever pass accounts for more of the receipt wins.
    static func scan(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> ReceiptScan {
        let image = CIImage(cgImage: cgImage).oriented(orientation)
        let firstFragments = try fragments(in: image)
        let first = parse(firstFragments)
        guard let area = textArea(of: firstFragments) else { return first }
        let extent = image.extent
        let crop = CGRect(x: extent.minX + area.minX * extent.width, y: extent.minY + area.minY * extent.height,
                          width: area.width * extent.width, height: area.height * extent.height)
        let enhanced = image.cropped(to: crop)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6])
        let second = parse(try fragments(in: enhanced))
        return score(second) >= score(first) ? second : first
    }

    private static func fragments(in image: CIImage) throws -> [Fragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(ciImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Fragment(text: $0.string, box: observation.boundingBox) }
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

    /// Vision returns the name and price columns of a receipt as separate fragments,
    /// so fragments are first regrouped into printed rows by vertical position.
    static func parse(_ fragments: [Fragment]) -> ReceiptScan {
        var scan = ReceiptScan()
        var pendingName: String?
        for row in rows(from: fragments) {
            let text = row.joined(separator: " ")
            let lower = text.lowercased()
            // Quantity and weight detail lines ("2 @ 6.49", "1.04 lb @ 1.99 /lb") precede the priced line.
            if lower.contains("@") || lower.contains("/lb") { continue }
            guard let (rawName, cents) = priced(text) else {
                pendingName = lower.contains(where: \.isLetter) && !isExcluded(lower) ? clean(text) : nil
                continue
            }
            let name = clean(rawName)
            let lowerName = name.lowercased()
            if lowerName.range(of: #"\btax\b"#, options: .regularExpression) != nil && !lowerName.contains("total") {
                scan.taxCents += cents
            } else if scan.printedTotalCents == nil, lowerName.contains("balance") || (lowerName.contains("total") && !lowerName.contains("sub")) {
                scan.printedTotalCents = cents
            } else if isExcluded(lowerName) || cents <= 0 {
                // Totals, payment, and savings lines are not purchased items.
            } else if name.contains(where: \.isLetter) {
                scan.items.append(ReceiptItem(name: name, cents: cents))
            } else if let pending = pendingName {
                scan.items.append(ReceiptItem(name: pending, cents: cents))
            }
            pendingName = nil
        }
        scan.purchaseDate = purchaseDate(in: fragments.map(\.text))
        return scan
    }

    /// Whole words only, so an item like "PRK TENDERLOIN" isn't mistaken for a "TEND" payment line.
    private static let excludedWords = try! NSRegularExpression(pattern: #"\b(sub ?total|total|balance|change|cash|credit|debit|card|visa|mastercard|discover|amex|saved|savings|tend|tendered|due|payment|approved|auth)\b"#)

    private static func isExcluded(_ lowercased: String) -> Bool {
        excludedWords.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)) != nil
    }

    private static func rows(from fragments: [Fragment]) -> [[String]] {
        // Where item names usually start, so margin flags can be told apart from brand prefixes like "WB",
        // and price-column pieces can be told apart from names.
        let nameStarts = group(fragments.filter { $0.text.count > 2 && $0.text.contains(where: \.isLetter) })
            .compactMap { $0.min(by: { $0.box.minX < $1.box.minX })?.box.minX }.sorted()
        let nameColumn = nameStarts.isEmpty ? 0 : nameStarts[nameStarts.count / 2]
        let isPricePiece = { (fragment: Fragment) in
            fragment.box.minX > nameColumn && fragment.text.range(of: #"^\$?[\d.,\s]*[A-Z]{0,2}$"#, options: .regularExpression) != nil
        }
        var rows = group(fragments.filter { !isPricePiece($0) })
        // A photographed receipt is rarely flat, so the price column drifts up or down relative to the
        // names. Walking down the receipt, each price is matched to the nearest name row after
        // allowing for the drift measured on the row above it.
        var drift: CGFloat = 0
        for pieces in group(fragments.filter(isPricePiece)) {
            let cluster = [Fragment(text: priceText(pieces), box: pieces[0].box)]
            let midY = cluster[0].box.midY
            let nearest = rows.indices.min { abs(rows[$0][0].box.midY + drift - midY) < abs(rows[$1][0].box.midY + drift - midY) }
            if let index = nearest, abs(rows[index][0].box.midY + drift - midY) < rows[index][0].box.height * 0.75 {
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
            return row.map(\.text)
        }
    }

    /// Rejoins a price that Vision split into pieces ("8" and ",39", or "4 99") and restores a
    /// dropped decimal point, since receipt prices always print two decimal places. A price that
    /// lost digits stays visible so the member can correct it; the total check flags it.
    private static func priceText(_ pieces: [Fragment]) -> String {
        let text = pieces.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        let flag = text.range(of: #"\s[A-Z]{1,2}$"#, options: .regularExpression).map { String(text[$0]) } ?? ""
        let number = text.filter { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        guard number.contains(where: \.isNumber) else { return text }
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].count == 2 { return "\(parts[0].isEmpty ? "0" : String(parts[0])).\(parts[1])\(flag)" }
        let digits = number.filter(\.isNumber)
        guard parts.count == 1, digits.count >= 2 else { return text }
        return "\(digits.count == 2 ? "0" : String(digits.dropLast(2))).\(digits.suffix(2))\(flag)"
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

    /// Splits a row ending in a price, ignoring a trailing tax flag such as "F" or "T".
    private static func priced(_ text: String) -> (String, Int)? {
        let pattern = #"^(.*?)\s*\$?(\d{1,5}[.,]\d{2})\s*[A-Z]{0,2}\s*$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let priceRange = Range(match.range(at: 2), in: text),
              let decimal = Decimal(string: text[priceRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (String(text[nameRange]), NSDecimalNumber(decimal: decimal * 100).intValue)
    }

    private static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    private static func purchaseDate(in lines: [String]) -> Date? {
        let regex = try! NSRegularExpression(pattern: #"\b(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})\b"#)
        var dates = Set<Date>()
        for line in lines {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let parts = (1...3).compactMap { Range(match.range(at: $0), in: line).flatMap { Int(line[$0]) } }
                guard parts.count == 3 else { continue }
                let components = DateComponents(year: parts[2] < 100 ? 2000 + parts[2] : parts[2], month: parts[0], day: parts[1])
                if components.isValidDate(in: .current), let date = Calendar.current.date(from: components) { dates.insert(date) }
            }
        }
        return dates.count == 1 ? dates.first : nil
    }
}

#if canImport(UIKit)
private extension UIImage {
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
