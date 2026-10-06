import FoundationModels
import UIKit
import XCTest
@testable import ReceiptDivider

/// Real receipts replayed from their saved diagnostics: the lines document recognition found on the phone, and the lines
/// the accurate OCR pass finds in the same image. Card and authorization lines are left out of the fixtures.
final class ReceiptReplayTests: XCTestCase {
    /// On the phone, document recognition merged the stacked "32.00" and "22.50" into one line and dropped "15.50".
    func testAccuratePassRestoresPricesDocumentRecognitionLost() throws {
        let document = try lines("smokehouse-lines"), merged = ReceiptTextRecognizer.merge(document: document, accurate: try lines("smokehouse-accurate-lines"))
        XCTAssertFalse(document.contains { $0.text == "15.50" || $0.text == "32.00" })
        XCTAssertTrue(merged.contains { $0.text == "15.50" })
        XCTAssertTrue(merged.contains { $0.text == "32.00" })
    }

    func testSmokehouseRowsPairEveryNameWithItsPrice() throws {
        let rows = try layout("smokehouse")
        for row in ["Hot Tea  2 x $3.25  6.50", "Pulled Pork Sandwich  19.00", "# 1 - House Special  32.00", "Brisket Sandwich  22.50",
                    "Ultimate Fries  15.50", "Cheeseburger  17.00", "Subtotal  320.85", "Tax  25.67", "Gratuity  64.17", "Total (Non-Cash)  427.12"] {
            XCTAssertTrue(rows.contains(row), "Missing row \(row)")
        }
    }

    func testFiveGuysReadsTaxAndDate() async throws {
        let extraction = try await read("fiveguys")
        XCTAssertEqual(extraction.items.filter { $0.kind == .item }.map(\.cents), [1_169, 619])
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax])
        XCTAssertEqual(extraction.adjustments.first?.amountCents, 158)
        XCTAssertEqual(extraction.printedTotalCents, 1_946)
        XCTAssertEqual(extraction.purchaseDate.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2026, month: 10, day: 4))
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    func testSmokehouseReadsItemsTipAndCardSurcharge() async throws {
        let extraction = try await read("smokehouse")
        let items = extraction.items.filter { $0.kind == .item }
        XCTAssertEqual(items.reduce(0) { $0 + $1.cents }, 32_085)
        XCTAssertEqual(items.first { $0.name.localizedCaseInsensitiveContains("house special") }?.cents, 3_200)
        XCTAssertEqual(extraction.items.first { $0.kind == .tip }?.cents, 6_417)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertEqual(extraction.printedTotalCents, 42_712)
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    private func layout(_ name: String) throws -> [String] {
        let merged = ReceiptTextRecognizer.merge(document: try lines("\(name)-lines"), accurate: try lines("\(name)-accurate-lines"))
        return ReceiptTextRecognizer.layoutText(merged).components(separatedBy: "\n")
    }

    private func read(_ name: String) async throws -> ReceiptExtraction {
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable, "Apple Intelligence isn't available here.")
        let merged = ReceiptTextRecognizer.merge(document: try lines("\(name)-lines"), accurate: try lines("\(name)-accurate-lines"))
        let extraction = await ReceiptReader.extract(RecognizedReceipt(image: UIImage(), lines: merged))
        print("Replay \(name):", extraction.diagnostics?.reader ?? "?", extraction.items.map { "\($0.name) \($0.cents)" },
              extraction.adjustments.map { "\($0.kind) \($0.amountCents)" }, extraction.issues)
        return extraction
    }

    private func lines(_ name: String) throws -> [ReceiptTextRecognizer.Fragment] {
        struct Line: Decodable { let text: String; let x, y, width, height: Double }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode([Line].self, from: Data(contentsOf: url)).map {
            ReceiptTextRecognizer.Fragment(text: $0.text, box: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
        }
    }
}
