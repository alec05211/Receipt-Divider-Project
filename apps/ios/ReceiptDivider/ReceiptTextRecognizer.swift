import UIKit
import Vision
import ImageIO

enum ReceiptTextRecognizer {
    static func items(in image: UIImage) throws -> [ReceiptItem] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgImageOrientation)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.compactMap(parseLine).filter { item in
            let excluded = ["total", "subtotal", "tax", "change", "balance", "visa", "mastercard"]
            return item.cents > 0 && !excluded.contains { item.name.lowercased().contains($0) }
        }
    }

    private static func parseLine(_ line: String) -> ReceiptItem? {
        let pattern = "(?:\\$)?(\\d+[.,]\\d{2})\\s*$"
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let value = String(line[range]).replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: value) else { return nil }
        let name = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ReceiptItem(name: name.isEmpty ? "Receipt item" : name, cents: NSDecimalNumber(decimal: decimal * 100).intValue)
    }
}

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
