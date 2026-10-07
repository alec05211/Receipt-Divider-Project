import Foundation

/// How a receipt was read, uploaded with its text so a misread can be traced and replayed. It records the build and
/// device, every recognized line with its position on the page, the text the model saw, each model attempt with its
/// raw output and timing, which reader produced the result, and what was read compared with what was saved.
struct ReceiptDiagnostics: Codable, Hashable, Sendable {
    struct Line: Codable, Hashable, Sendable {
        var text: String
        /// Normalized position on the page, origin at the bottom left.
        var x, y, width, height: Double
        var confidence: Float
    }

    struct Attempt: Codable, Hashable, Sendable {
        /// "cloud" or "model".
        var reader: String?
        /// The discrepancy the model was told about, for a re-read.
        var note: String?
        var seconds: Double
        /// The model's raw output as JSON.
        var reading: String?
        var error: String?
        var issues: [String] = []
    }

    struct Summary: Codable, Hashable, Sendable {
        struct Item: Codable, Hashable, Sendable {
            var name: String; var cents: Int; var localOffsetCents: Int; var globalOffsetCents: Int; var kind: String; var taxed: Bool
        }
        struct Adjustment: Codable, Hashable, Sendable { var kind: String; var rate: Double; var amountCents: Int }
        var name: String
        var category: String?
        var purchaseDate: String?
        var items: [Item]
        var adjustments: [Adjustment]
        var subtotalCents: Int?
        var totalCents: Int?

        init(name: String, category: ExpenseCategory?, purchaseDate: Date?, items: [ReceiptItem], adjustments: [ReceiptAdjustment], subtotalCents: Int?, totalCents: Int?) {
            self.name = name
            self.category = category?.rawValue
            self.purchaseDate = purchaseDate.map { Summary.dayFormatter.string(from: $0) }
            self.items = items.map { Item(name: $0.name, cents: $0.cents, localOffsetCents: $0.localOffsetCents, globalOffsetCents: $0.globalOffsetCents, kind: $0.kind.rawValue, taxed: $0.taxed) }
            self.adjustments = adjustments.map { Adjustment(kind: $0.kind.rawValue, rate: $0.rate, amountCents: $0.amountCents) }
            self.subtotalCents = subtotalCents
            self.totalCents = totalCents
        }

        /// Calendar days in the member's time zone, as transaction dates are.
        private static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        init(_ extraction: ReceiptExtraction) {
            self.init(name: extraction.name, category: extraction.category, purchaseDate: extraction.purchaseDate, items: extraction.items,
                      adjustments: extraction.adjustments, subtotalCents: extraction.subtotalCents, totalCents: extraction.printedTotalCents)
        }
    }

    static let lastScanKey = "last-receipt-scan"

    var build = ReceiptDiagnostics.buildCommit ?? "local"
    var system = ProcessInfo.processInfo.operatingSystemVersionString
    var device = ReceiptDiagnostics.deviceModel
    /// "cloud", "model" or "parser".
    var reader = "parser"
    /// Why an earlier reader wasn't used.
    var fallbackReason: String?
    var recognitionSeconds: Double
    /// Recognized lines; those after the first `documentLineCount` came from the accurate pass.
    var lines: [Line]
    var documentLineCount: Int
    /// The rows the chosen reading labeled: the device's rows for the model or parser, the transcribed rows for cloud.
    var modelText: String
    var attempts: [Attempt] = []
    var read: Summary?
    var saved: Summary?

    init(_ receipt: RecognizedReceipt, modelText: String) {
        recognitionSeconds = receipt.recognitionSeconds
        documentLineCount = receipt.documentLineCount
        lines = receipt.lines.map {
            Line(text: $0.text, x: $0.box.minX, y: $0.box.minY, width: $0.box.width, height: $0.box.height, confidence: $0.confidence)
        }
        self.modelText = modelText
    }

    /// Time spent reading: text recognition plus every model attempt.
    var totalSeconds: Double { recognitionSeconds + attempts.reduce(0) { $0 + $1.seconds } }

    /// The commit the app was built from, set by the deploy script; nil for a local build.
    static var buildCommit: String? {
        (Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
