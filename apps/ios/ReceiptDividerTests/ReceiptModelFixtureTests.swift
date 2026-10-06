import FoundationModels
import UIKit
import XCTest
@testable import ReceiptDivider

/// Runs the on-device model on recognized receipt text, to see where its readings go wrong before adding rules for them.
/// Skipped where Apple Intelligence isn't available. Each reading is printed to the test log.
final class ReceiptModelFixtureTests: XCTestCase {
    func testGroceryWithQuantitiesSavingsAndUntaxedFood() async throws {
        let extraction = try await read("""
            FRESH MARKET
            123 MAIN ST
            09/28/2026 18:42
            BANANAS 1.29 F
            GREEK YOGURT 6.98 F
            2 @ 3.49
            PAPER TOWELS 8.99 T
            SALE -1.00
            DISH SOAP 3.49 T
            SUBTOTAL 19.75
            TAX 7.000% 0.80
            TOTAL 20.55
            VISA 20.55
            YOU SAVED 1.00
            """)
        XCTAssertEqual(extraction.items.first { $0.name.localizedCaseInsensitiveContains("towel") }?.localOffsetCents, -100)
        // Known gaps in the model's reading, logged without failing the run until they're addressed.
        XCTExpectFailure("The quantity line isn't applied to its item", strict: false) {
            XCTAssertEqual(extraction.items.filter { $0.name.localizedCaseInsensitiveContains("yogurt") }.map(\.cents), [349, 349])
        }
        XCTExpectFailure("Tax letters aren't read as untaxed items", strict: false) {
            XCTAssertEqual(extraction.items.filter { !$0.taxed }.count, 3)
        }
        XCTExpectFailure("The \"you saved\" summary is read as an order discount", strict: false) {
            XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax])
            XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
        }
    }

    func testRestaurantWithTipSuggestedTipsAndSurcharge() async throws {
        let extraction = try await read("""
            THE CORNER BISTRO
            Server: Dana  Table 12
            Oct 3, 2026 8:15 PM
            1 Burger 16.00
            1 Caesar Salad 12.00
            2 Iced Tea 7.00
            Subtotal 35.00
            Sales Tax 6% 2.10
            Tip 7.00
            Card Surcharge 3% 1.32
            Total 45.42
            Suggested tip: 18% 6.30  20% 7.00  22% 7.70
            """)
        XCTAssertEqual(extraction.items.filter { $0.kind == .item }.count, 4)
        XCTAssertEqual(extraction.items.first { $0.kind == .tip }?.cents, 700)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    private func read(_ text: String) async throws -> ReceiptExtraction {
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable, "Apple Intelligence isn't available here.")
        let lines = text.split(separator: "\n").map { ReceiptTextRecognizer.Fragment(text: String($0), box: .zero) }
        let extraction = await ReceiptReader.extract(RecognizedReceipt(image: UIImage(), lines: lines))
        print("Reading:", extraction.name, extraction.items.map { "\($0.name) \($0.cents) \($0.localOffsetCents) \($0.taxed)" }, extraction.adjustments.map { "\($0.kind) \($0.amountCents)" }, extraction.issues)
        return extraction
    }
}
