import XCTest
@testable import ReceiptDivider

final class ReceiptAdjustmentsTests: XCTestCase {
    func testQuantityBecomesOneRowPerUnit() {
        let rows = ReceiptItem.rows(name: "Soda", quantity: 3, lineCents: 1_000, discountCents: 100)
        XCTAssertEqual(rows.map(\.cents), [334, 333, 333])
        XCTAssertEqual(rows.map(\.localOffsetCents), [-34, -33, -33])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        // A line too cheap to give every unit a cent stays one row.
        XCTAssertEqual(ReceiptItem.rows(name: "Gum", quantity: 3, lineCents: 2).map(\.cents), [2])
    }

    /// A $10 burger with a $1 coupon and an untaxed $5 salad: 6% tax on the burger, a $4 tip, then a 3% card surcharge
    /// on everything including the tip.
    func testAdjustmentsApplyInReceiptOrder() {
        var rows = [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100),
            ReceiptItem(name: "Salad", cents: 500, taxed: false),
            ReceiptItem(name: "Tip", cents: 400, kind: .tip),
        ]
        let adjustments = rows.resolveAdjustments([
            ReceiptAdjustment(kind: .tax, amountCents: 54),
            ReceiptAdjustment(kind: .tip),
            ReceiptAdjustment(kind: .surcharge, amountCents: 56),
        ])

        XCTAssertEqual(adjustments.map(\.amountCents), [54, 400, 56])
        XCTAssertEqual(adjustments[0].rate, 0.06, accuracy: 1e-9)
        XCTAssertEqual(adjustments[2].rate, 56.0 / 1_854, accuracy: 1e-9)
        // Only the burger is taxed; the surcharge reaches every row, the tip included.
        XCTAssertEqual(rows[0].globalOffsetCents, 54 + 29)
        XCTAssertEqual(rows[1].globalOffsetCents, 15)
        XCTAssertEqual(rows[2].globalOffsetCents, 12)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalCents }, 1_910)
    }

    func testSurchargePrintedBeforeTheTipIsNotChargedOnIt() {
        var rows = [ReceiptItem(name: "Pasta", cents: 2_000), ReceiptItem(name: "Tip", cents: 400, kind: .tip)]
        rows.resolveAdjustments([ReceiptAdjustment(kind: .surcharge, amountCents: 60), ReceiptAdjustment(kind: .tip)])
        XCTAssertEqual(rows.map(\.globalOffsetCents), [60, 0])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalCents }, 2_460)
    }

    func testDiscountAndTaxReproduceTheirPrintedAmountsInEitherOrder() {
        var discountFirst = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 1_000)]
        let first = discountFirst.resolveAdjustments([ReceiptAdjustment(kind: .discount, amountCents: 200), ReceiptAdjustment(kind: .tax, amountCents: 108)])
        XCTAssertEqual(first.map(\.rate), [0.1, 0.06])
        XCTAssertEqual(discountFirst.reduce(0) { $0 + $1.totalCents }, 1_908)

        var taxFirst = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 1_000)]
        let second = taxFirst.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 120), ReceiptAdjustment(kind: .discount, amountCents: 212)])
        XCTAssertEqual(second.map(\.rate), [0.06, 0.1])
        XCTAssertEqual(taxFirst.reduce(0) { $0 + $1.totalCents }, 1_908)
    }

    func testRoundedSharesAddUpToThePrintedAmount() {
        var rows = [333, 333, 334, 1].map { ReceiptItem(name: "Item", cents: $0) }
        rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 70)])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.globalOffsetCents }, 70)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalCents }, 1_071)
    }

    func testRatesApplyToTheRowsThatRemain() {
        var rows = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 500)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 120)])
        rows.removeLast()
        let applied = rows.applyAdjustments(adjustments)
        XCTAssertEqual(applied[0].amountCents, 80)
        XCTAssertEqual(rows[0].totalCents, 1_080)
    }

    func testPercentOnlyAdjustmentUsesThePrintedRate() {
        var rows = [ReceiptItem(name: "A", cents: 2_500)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, rate: 0.08)])
        XCTAssertEqual(adjustments[0].amountCents, 200)
        XCTAssertEqual(rows[0].totalCents, 2_700)
    }

    func testTipIsSplitEvenlyWhateverEachPersonOrdered() {
        let (ben, alec) = (UUID(), UUID())
        var rows = [
            ReceiptItem(name: "Steak", cents: 3_000, ownerIDs: [ben]),
            ReceiptItem(name: "Soup", cents: 1_000, ownerIDs: [alec]),
            ReceiptItem(name: "Tip", cents: 800, kind: .tip, ownerIDs: [ben, alec]),
        ]
        rows.resolveAdjustments([ReceiptAdjustment(kind: .tip)])
        XCTAssertEqual(rows.ownerShares(for: [ben, alec]), [ben: 3_400, alec: 1_400])
    }

    func testMismatchesAreReportedNotFixed() {
        var extraction = ReceiptExtraction(items: [ReceiptItem(name: "A", cents: 1_000)], subtotalCents: 1_100, printedTotalCents: 1_100)
        XCTAssertEqual(extraction.issues.count, 2)
        XCTAssertNotNil(extraction.mismatchWarning)
        extraction.items[0].cents = 1_100
        XCTAssertTrue(extraction.issues.isEmpty)
    }

    func testMissingTotalIsAWarningAndAnIssue() {
        let extraction = ReceiptExtraction(items: [ReceiptItem(name: "A", cents: 1_000)])
        XCTAssertNil(extraction.mismatchWarning)
        XCTAssertNotNil(extraction.warning)
        XCTAssertEqual(extraction.issues, ["No total was found."])
    }

    /// Text recognition returned the names and the prices as two columns; rows are rebuilt from their positions.
    func testColumnsAreRebuiltIntoPrintedRows() {
        let names = ["Brisket", "Coke Cherry", "Subtotal", "Total"], prices = ["36.00", "3.85", "39.85", "39.85"]
        let fragments = names.enumerated().map { ReceiptTextRecognizer.Fragment(text: $0.element, box: CGRect(x: 0.05, y: 0.9 - Double($0.offset) * 0.05, width: 0.3, height: 0.02)) }
            + prices.enumerated().map { ReceiptTextRecognizer.Fragment(text: $0.element, box: CGRect(x: 0.75, y: 0.9 - Double($0.offset) * 0.05, width: 0.15, height: 0.02)) }
        XCTAssertEqual(ReceiptTextRecognizer.layoutText(fragments).components(separatedBy: "\n"),
                       ["Brisket  36.00", "Coke Cherry  3.85", "Subtotal  39.85", "Total  39.85"])
    }

    /// Separate cash and card totals make the difference a final surcharge; an automatic gratuity is the tip.
    func testCardTotalAddsTheDifferenceAsASurcharge() {
        let reading = ReceiptReading(
            merchant: "Smokehouse", category: .restaurant, purchaseDate: "2026-10-05",
            lines: [.init(name: "Brisket", price: "18.00", unitPrice: "18.00", quantity: 2, discount: "", taxed: true),
                    .init(name: "Coke", price: "4.00", unitPrice: "", quantity: 1, discount: "", taxed: true)],
            subtotal: "40.00",
            adjustments: [.init(kind: .tax, amount: "3.20", percent: "8"), .init(kind: .tip, amount: "8.00", percent: "20")],
            cashTotal: "51.20", total: "53.25", expenseName: "")
        let extraction = ReceiptExtraction(reading, text: "")
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertEqual(extraction.adjustments.last?.amountCents, 205)
        XCTAssertEqual(extraction.items.map(\.cents), [1_800, 1_800, 400, 800])
        XCTAssertEqual(extraction.printedTotalCents, 5_325)
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    /// A unit price given as the price, or the price repeated as a discount, is corrected by matching the subtotal.
    func testMisplacedLineFieldsAreSettledByTheSubtotal() {
        let reading = ReceiptReading(
            merchant: "", category: .restaurant, purchaseDate: "",
            lines: [.init(name: "Hot Tea", price: "3.25", unitPrice: "3.25", quantity: 2, discount: "6.50", taxed: true),
                    .init(name: "Coke", price: "3.85", unitPrice: "", quantity: 1, discount: "3.85", taxed: true)],
            subtotal: "10.35", adjustments: [], cashTotal: "", total: "10.35", expenseName: "")
        let extraction = ReceiptExtraction(reading, text: "")
        XCTAssertEqual(extraction.items.map(\.cents), [325, 325, 385])
        XCTAssertEqual(extraction.items.map(\.localOffsetCents), [0, 0, 0])
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    func testParserReadingBecomesAdjustments() {
        var scan = ReceiptScan(items: [ReceiptItem(name: "Item", cents: 1_000, localOffsetCents: -100)], taxCents: 54, discountCents: 0)
        scan.printedTotalCents = 954
        let extraction = ReceiptExtraction(scan)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax])
        XCTAssertEqual(extraction.adjustments[0].rate, 0.06, accuracy: 1e-9)
        XCTAssertNil(extraction.mismatchWarning)
    }
}
