import XCTest
@testable import ReceiptDivider

final class ExpenseAmountsTests: XCTestCase {
    private func manual(_ cents: Int, _ adjustments: [ReceiptAdjustment] = []) -> ExpenseAmounts {
        ExpenseAmounts(items: [ReceiptItem(name: "", cents: cents, isSelected: true)], adjustments: adjustments)
    }

    /// Every line adds up to the total, whatever was edited.
    private func assertLinesAddUp(_ amounts: ExpenseAmounts, file: StaticString = #filePath, line: UInt = #line) {
        let others = amounts.otherAdjustments.reduce(0) { $0 + ($1.kind == .discount ? -$1.amountCents : $1.amountCents) }
        let lines = amounts.subtotalCents + amounts.itemOffsetCents + amounts.taxCents + others + amounts.tipCents + amounts.unlistedOffsetCents
        XCTAssertEqual(lines, amounts.totalCents, "lines don't add up to the total", file: file, line: line)
    }

    func testEditingTheTaxKeepsTheTypedAmount() {
        var amounts = manual(5_000)
        let id = amounts.addTax()
        amounts.setTax(400, id: id)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.taxes.first?.rate ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.totalCents, 5_400)
        assertLinesAddUp(amounts)
    }

    func testClearingTheTaxKeepsItsPlaceAtZero() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, rate: 0.08)])
        let id = amounts.taxes[0].id
        amounts.setTax(0, id: id)
        XCTAssertEqual(amounts.taxCents, 0)
        XCTAssertEqual(amounts.taxes.map(\.id), [id])
        XCTAssertEqual(amounts.totalCents, 5_000)
        // Typing again after clearing works from the same tax.
        amounts.setTax(250, id: id)
        XCTAssertEqual(amounts.totalCents, 5_250)
    }

    func testEditingTheSubtotalKeepsTheTaxRate() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, rate: 0.08)])
        XCTAssertEqual(amounts.taxCents, 400)
        amounts.setSubtotal(10_000)
        XCTAssertEqual(amounts.taxCents, 800)
        XCTAssertEqual(amounts.totalCents, 10_800)
        assertLinesAddUp(amounts)
    }

    func testEditingTheTipKeepsTheSubtotalAndTax() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, rate: 0.08)])
        amounts.setTip(1_000)
        XCTAssertEqual(amounts.tipCents, 1_000)
        XCTAssertEqual(amounts.totalCents, 6_400)
        // Each keystroke sets the tip; it doesn't grow on itself.
        amounts.setTip(1_200)
        XCTAssertEqual(amounts.tipCents, 1_200)
        XCTAssertEqual(amounts.totalCents, 6_600)
        assertLinesAddUp(amounts)
    }

    func testClearingTheTipKeepsItBeforeALaterSurcharge() {
        var amounts = manual(2_000, [ReceiptAdjustment(kind: .tip, amountCents: 400), ReceiptAdjustment(kind: .surcharge, rate: 0.03)])
        XCTAssertEqual(amounts.totalCents, 2_472)
        amounts.setTip(0)
        amounts.setTip(500)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tip, .surcharge])
        XCTAssertEqual(amounts.totalCents, 2_575)
        assertLinesAddUp(amounts)
    }

    func testTipLineIsTheTipNotItsSurcharge() {
        var rows = [ReceiptItem(name: "Pasta", cents: 2_000, isSelected: true)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .tip, amountCents: 400), ReceiptAdjustment(kind: .surcharge, amountCents: 72)])
        let amounts = ExpenseAmounts(items: rows, adjustments: adjustments)
        XCTAssertEqual(amounts.tipCents, 400)
        XCTAssertEqual(amounts.otherAdjustments.map(\.amountCents), [72])
        XCTAssertEqual(amounts.totalCents, 2_472)
        assertLinesAddUp(amounts)
    }

    func testEditingTheTotalFindsTheSubtotal() {
        var amounts = manual(0, [ReceiptAdjustment(kind: .tax, rate: 0.08), ReceiptAdjustment(kind: .tip, amountCents: 500)])
        amounts.setTotal(5_900)
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.tipCents, 500)
        XCTAssertEqual(amounts.totalCents, 5_900)
        assertLinesAddUp(amounts)
    }

    /// Typing a total one digit at a time doesn't lose the tax on the way.
    func testTypingTheTotalKeepsTheRates() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, rate: 0.08)])
        for typed in [5, 54, 540, 5_400] { amounts.setTotal(typed) }
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.totalCents, 5_400)
    }

    /// With 8.875% tax no subtotal comes to $10.00 ($9.18 makes $9.99, $9.19 makes $10.01), so the tax gives a cent.
    func testATotalRoundingSkipsIsReachedExactly() {
        var amounts = manual(0, [ReceiptAdjustment(kind: .tax, rate: 0.08875)])
        amounts.setTotal(1_000)
        XCTAssertEqual(amounts.totalCents, 1_000)
        XCTAssertEqual(amounts.subtotalCents, 919)
        XCTAssertEqual(amounts.taxCents, 81)
        assertLinesAddUp(amounts)
    }

    func testATotalBelowTheTipLeavesTheSubtotalAtZero() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .tip, amountCents: 300)])
        amounts.setTotal(200)
        XCTAssertEqual(amounts.subtotalCents, 0)
        XCTAssertEqual(amounts.totalCents, 300)
    }

    func testEditingTheTotalWithNoRowsAddsOne() {
        var amounts = ExpenseAmounts(items: [], adjustments: [])
        amounts.setTotal(1_234)
        XCTAssertEqual(amounts.items.count, 1)
        XCTAssertTrue(amounts.items[0].isSelected)
        XCTAssertEqual(amounts.totalCents, 1_234)
    }

    func testDiscountedRowKeepsItsDiscount() {
        var amounts = ExpenseAmounts(items: [ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100, isSelected: true)], adjustments: [])
        XCTAssertEqual(amounts.subtotalCents, 1_000)
        XCTAssertEqual(amounts.itemOffsetCents, -100)
        XCTAssertEqual(amounts.totalCents, 900)
        amounts.setTotal(1_900)
        XCTAssertEqual(amounts.subtotalCents, 2_000)
        XCTAssertEqual(amounts.totalCents, 1_900)
        assertLinesAddUp(amounts)
    }

    func testItemizedReceiptDerivesSubtotalAndTotal() {
        var rows = [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100, isSelected: true),
            ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true),
        ]
        let adjustments = rows.resolveAdjustments([
            ReceiptAdjustment(kind: .tax, amountCents: 54),
            ReceiptAdjustment(kind: .tip, amountCents: 400),
            ReceiptAdjustment(kind: .surcharge, amountCents: 56),
        ])
        var amounts = ExpenseAmounts(items: rows, adjustments: adjustments)
        XCTAssertFalse(amounts.isSubtotalEditable)
        XCTAssertEqual(amounts.subtotalCents, 1_500)
        XCTAssertEqual(amounts.totalCents, 1_910)
        assertLinesAddUp(amounts)

        // Neither the subtotal nor the total rewrites printed prices.
        amounts.setSubtotal(9_999)
        amounts.setTotal(9_999)
        XCTAssertEqual(amounts.items.map(\.cents), [1_000, 500])
        XCTAssertEqual(amounts.totalCents, 1_910)

        // Tax applies to the taxed burger alone, and its rate comes from that.
        amounts.setTax(90, id: amounts.taxes[0].id)
        XCTAssertEqual(amounts.taxes[0].rate, 0.1, accuracy: 1e-9)
        XCTAssertEqual(amounts.taxCents, 90)
        assertLinesAddUp(amounts)
    }

    func testTaxWithNothingTaxedComesToZero() {
        var amounts = ExpenseAmounts(items: [ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true)], adjustments: [])
        let id = amounts.addTax()
        amounts.setTax(100, id: id)
        XCTAssertEqual(amounts.taxCents, 0)
        XCTAssertEqual(amounts.totalCents, 500)
    }

    func testAddedTaxGoesBeforeTheTip() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .tip, amountCents: 200), ReceiptAdjustment(kind: .surcharge, rate: 0.03)])
        amounts.addTax()
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tax, .tip, .surcharge])
    }

    func testRowsLeftOutDontCount() {
        let amounts = ExpenseAmounts(items: [
            ReceiptItem(name: "Kept", cents: 1_000, isSelected: true),
            ReceiptItem(name: "Left out", cents: 700),
        ], adjustments: [])
        XCTAssertEqual(amounts.subtotalCents, 1_000)
        XCTAssertEqual(amounts.totalCents, 1_000)
        XCTAssertTrue(amounts.isSubtotalEditable)
    }

    /// Expenses saved before adjustments were recorded keep their receipt-wide offsets on the rows only.
    func testOffsetsWithoutAdjustmentsAreListed() {
        let amounts = ExpenseAmounts(items: [ReceiptItem(name: "Dinner", cents: 2_000, globalOffsetCents: 160, isSelected: true)], adjustments: [])
        XCTAssertEqual(amounts.unlistedOffsetCents, 160)
        XCTAssertEqual(amounts.totalCents, 2_160)
        assertLinesAddUp(amounts)
    }

    func testLegacyTipRowsCountAsTheTip() {
        let amounts = ExpenseAmounts(items: [
            ReceiptItem(name: "Dinner", cents: 2_000, isSelected: true),
            ReceiptItem(name: "Tip", cents: 400, kind: .tip, isSelected: true),
        ], adjustments: [])
        XCTAssertEqual(amounts.tipCents, 400)
        XCTAssertEqual(amounts.totalCents, 2_400)
        XCTAssertFalse(amounts.isSubtotalEditable)
        assertLinesAddUp(amounts)
    }
}
