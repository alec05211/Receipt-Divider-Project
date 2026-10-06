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
        // A known gap in the model's reading, logged without failing the run until it's addressed.
        XCTAssertEqual(extraction.items.filter { $0.name.localizedCaseInsensitiveContains("yogurt") }.map(\.cents), [349, 349])
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax])
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
        XCTExpectFailure("Tax letters aren't read as untaxed items", strict: false) {
            XCTAssertEqual(extraction.items.filter { !$0.taxed }.count, 3)
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

    /// A barbecue receipt with quantity lines, an automatic gratuity, and separate cash and card totals.
    func testRestaurantWithGratuityAndCashAndCardTotals() async throws {
        let extraction = try await read("""
            CENTER STREET SMOKEHOUSE
            Oct 5, 2026 at 7:12 PM
            Order #22038
            Hot Tea  2 x $3.25  6.50
            Brisket  2 x $18.00  36.00
            Coke Cherry  3.85
            Pulled Pork Sandwich  19.00
            Subtotal  65.35
            Tax  5.23
            Gratuity  13.07
            Total (Cash)  83.65
            Total (Non-Cash)  87.00
            Suggested tip amounts are provided for your convenience.
            18%: $11.76  20%: $13.07  25%: $16.34
            """)
        XCTAssertEqual(extraction.items.filter { $0.name.localizedCaseInsensitiveContains("brisket") }.map(\.cents), [1_800, 1_800])
        XCTAssertEqual(extraction.items.first { $0.kind == .tip }?.cents, 1_307)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertEqual(extraction.printedTotalCents, 8_700)
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    private func read(_ text: String) async throws -> ReceiptExtraction {
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable, "Apple Intelligence isn't available here.")
        // One printed row per line, top to bottom.
        let lines = text.split(separator: "\n").enumerated().map { index, line in
            ReceiptTextRecognizer.Fragment(text: String(line), box: CGRect(x: 0.05, y: 0.95 - Double(index) * 0.03, width: 0.9, height: 0.02))
        }
        let extraction = await ReceiptReader.extract(RecognizedReceipt(image: UIImage(), lines: lines))
        print("Reader:", extraction.diagnostics?.reader ?? "?", extraction.diagnostics?.attempts.map(\.seconds) ?? [])
        print("Reading:", extraction.name, extraction.items.map { "\($0.name) \($0.cents) \($0.localOffsetCents) \($0.taxed)" }, extraction.adjustments.map { "\($0.kind) \($0.amountCents)" }, extraction.issues)
        return extraction
    }
}
