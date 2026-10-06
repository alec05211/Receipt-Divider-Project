import CoreGraphics
import XCTest
@testable import ReceiptDivider

final class ReceiptTextRecognizerTests: XCTestCase {
    func testExplicitTotalIsNotAnItem() {
        let scan = parse([
            "COFFEE 4.50",
            "SANDWICH 8.00",
            "SUBTOTAL 12.50",
            "TAX 1.00",
            "TOTAL 13.50",
        ])

        XCTAssertEqual(scan.items.map(\.name), ["COFFEE", "SANDWICH"])
        XCTAssertEqual(scan.printedTotalCents, 1_350)
        XCTAssertEqual(scan.taxCents, 100)
        XCTAssertEqual(scan.reconciledCents, 1_350)
    }

    func testCommonOCRTotalSubstitutionsAreSummaryRows() {
        for label in ["T0TA1", "T0TAI", "GRAND T0TAL"] {
            let scan = parse(["ITEM 12.34", "\(label) 12.34"])
            XCTAssertEqual(scan.items.map(\.name), ["ITEM"], label)
            XCTAssertEqual(scan.printedTotalCents, 1_234, label)
        }
    }

    func testAlternativeCandidateCanRecoverTotalLabel() {
        let fragments = [
            fragment("ITEM 12.34", row: 0),
            ReceiptTextRecognizer.Fragment(
                text: "TQTAI 12.34",
                box: Self.box(row: 1),
                alternatives: ["TOTAL 12.34"],
                confidence: 0.72
            ),
        ]
        let scan = ReceiptTextRecognizer.parse(fragments)

        XCTAssertEqual(scan.items.map(\.name), ["ITEM"])
        XCTAssertEqual(scan.printedTotalCents, 1_234)
    }

    func testDetachedTotalPriceStaysWithItsSummaryLabel() {
        let scan = ReceiptTextRecognizer.parse([
            ReceiptTextRecognizer.Fragment(text: "ITEM", box: CGRect(x: 0.1, y: 0.88, width: 0.4, height: 0.03)),
            ReceiptTextRecognizer.Fragment(text: "10.00", box: CGRect(x: 0.8, y: 0.88, width: 0.1, height: 0.03)),
            ReceiptTextRecognizer.Fragment(text: "TOTAL", box: CGRect(x: 0.1, y: 0.80, width: 0.4, height: 0.03)),
            ReceiptTextRecognizer.Fragment(text: "10.00", box: CGRect(x: 0.8, y: 0.815, width: 0.1, height: 0.03)),
        ])

        XCTAssertEqual(scan.items.map(\.name), ["ITEM"])
        XCTAssertEqual(scan.printedTotalCents, 1_000)
    }

    func testUnknownAmountsAfterSubtotalAreNotItems() {
        let scan = parse([
            "ITEM 10.00",
            "SUBTOTAL 10.00",
            "REFERENCE 10.00",
            "AMOUNT DUE 10.00",
        ])

        XCTAssertEqual(scan.items.map(\.name), ["ITEM"])
        XCTAssertEqual(scan.printedTotalCents, 1_000)
    }

    func testUnknownSummaryLabelCanRecoverAReconciledTotal() {
        let scan = parse([
            "ITEM 10.00",
            "SUBTOTAL 10.00",
            "TAX 0.70",
            "ZXQAI 10.70",
        ])

        XCTAssertEqual(scan.items.map(\.name), ["ITEM"])
        XCTAssertEqual(scan.printedTotalCents, 1_070)
        XCTAssertNil(scan.mismatchWarning)
    }

    func testReceiptWideDiscountReconcilesWithoutBecomingAnItem() {
        let scan = parse([
            "ITEM 10.00",
            "SUBTOTAL 10.00",
            "DISCOUNT -1.00",
            "TOTAL 9.00",
        ])

        XCTAssertEqual(scan.items.count, 1)
        XCTAssertEqual(scan.items[0].cents, 1_000)
        XCTAssertEqual(scan.discountCents, 100)
        XCTAssertEqual(scan.reconciledCents, 900)
        XCTAssertNil(scan.mismatchWarning)
    }

    private func parse(_ lines: [String]) -> ReceiptScan {
        ReceiptTextRecognizer.parse(lines.enumerated().map { fragment($0.element, row: $0.offset) })
    }

    private func fragment(_ text: String, row: Int) -> ReceiptTextRecognizer.Fragment {
        ReceiptTextRecognizer.Fragment(text: text, box: Self.box(row: row))
    }

    private static func box(row: Int) -> CGRect {
        CGRect(x: 0.1, y: 0.9 - CGFloat(row) * 0.08, width: 0.8, height: 0.03)
    }
}
