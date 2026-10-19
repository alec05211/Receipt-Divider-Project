import XCTest
@testable import ReceiptDivider

final class ExpenseAmountsTests: XCTestCase {
    private func manual(_ cents: Int, _ adjustments: [ReceiptAdjustment] = []) -> ExpenseAmounts {
        ExpenseAmounts(items: [ReceiptItem(name: "", cents: cents, isSelected: true)], adjustments: adjustments)
    }

    private func itemized(_ adjustments: [ReceiptAdjustment] = []) -> ExpenseAmounts {
        ExpenseAmounts(items: [
            ReceiptItem(name: "Burger", cents: 1_000, isSelected: true),
            ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true),
        ], adjustments: adjustments)
    }

    /// subtotal + taxes + surcharges − discounts + tip = total, whatever was edited.
    private func assertLinesAddUp(_ amounts: ExpenseAmounts, file: StaticString = #filePath, line: UInt = #line) {
        let others = amounts.otherAdjustments.reduce(0) { $0 + ($1.kind == .discount ? -$1.amountCents : $1.amountCents) }
        let lines = amounts.subtotalCents + amounts.taxCents + others + amounts.tipCents + amounts.unlistedOffsetCents
        XCTAssertEqual(lines, amounts.totalCents, "lines don't add up to the total", file: file, line: line)
    }

    // MARK: Editing a line changes the total

    func testEditingTheTaxKeepsTheTypedAmount() {
        var amounts = manual(5_000)
        let id = amounts.addTax()
        amounts.setAdjustment(400, id: id)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.totalCents, 5_400)
        assertLinesAddUp(amounts)
    }

    func testTaxAmountStaysWhenTheSubtotalChanges() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400)])
        amounts.setSubtotal(10_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.totalCents, 10_400)
        assertLinesAddUp(amounts)
    }

    func testEditingTheTipChangesTheTotal() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400)])
        amounts.setTip(1_000)
        XCTAssertEqual(amounts.totalCents, 6_400)
        // Each keystroke sets the tip; it doesn't grow on itself.
        amounts.setTip(1_200)
        XCTAssertEqual(amounts.tipCents, 1_200)
        XCTAssertEqual(amounts.totalCents, 6_600)
        assertLinesAddUp(amounts)
    }

    func testEditingSurchargesAndDiscountsChangesTheTotal() {
        var amounts = manual(2_000, [ReceiptAdjustment(kind: .discount, amountCents: 200), ReceiptAdjustment(kind: .surcharge, amountCents: 60)])
        XCTAssertEqual(amounts.totalCents, 1_860)
        amounts.setAdjustment(300, id: amounts.otherAdjustments[0].id)
        XCTAssertEqual(amounts.totalCents, 1_760)
        amounts.setAdjustment(100, id: amounts.otherAdjustments[1].id)
        XCTAssertEqual(amounts.totalCents, 1_800)
        assertLinesAddUp(amounts)
    }

    func testADiscountCantExceedWhatItAppliesTo() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .discount)])
        amounts.setAdjustment(5_000, id: amounts.otherAdjustments[0].id)
        XCTAssertEqual(amounts.otherAdjustments[0].amountCents, 1_000)
        XCTAssertEqual(amounts.totalCents, 0)
    }

    func testClearingTheTaxKeepsItsPlaceAtZero() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400), ReceiptAdjustment(kind: .tip, amountCents: 500)])
        let id = amounts.taxes[0].id
        amounts.setAdjustment(0, id: id)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tax, .tip])
        XCTAssertEqual(amounts.totalCents, 5_500)
        amounts.setAdjustment(250, id: id)
        XCTAssertEqual(amounts.totalCents, 5_750)
    }

    func testClearingTheTipKeepsItBeforeALaterSurcharge() {
        var amounts = manual(2_000, [ReceiptAdjustment(kind: .tip, amountCents: 400), ReceiptAdjustment(kind: .surcharge, amountCents: 72)])
        XCTAssertEqual(amounts.totalCents, 2_472)
        amounts.setTip(0)
        amounts.setTip(500)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tip, .surcharge])
        // The surcharge keeps its amount; part of it is now charged on the tip.
        XCTAssertEqual(amounts.otherAdjustments[0].amountCents, 72)
        XCTAssertEqual(amounts.totalCents, 2_572)
        XCTAssertEqual(amounts.tipCents, 500)
        assertLinesAddUp(amounts)
    }

    func testAllTaxLinesAreListed() {
        let amounts = manual(10_000, [ReceiptAdjustment(kind: .tax, amountCents: 625), ReceiptAdjustment(kind: .tax, amountCents: 225)])
        XCTAssertEqual(amounts.taxes.map(\.amountCents), [625, 225])
        XCTAssertEqual(amounts.totalCents, 10_850)
        assertLinesAddUp(amounts)
    }

    // MARK: Editing the total changes the tip

    func testEditingTheTotalChangesTheTip() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400)])
        amounts.setTotal(6_400)
        XCTAssertEqual(amounts.tipCents, 1_000)
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.totalCents, 6_400)
        assertLinesAddUp(amounts)
    }

    func testEditingTheTipAfterTheTotalChangesTheTotal() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400)])
        amounts.setTotal(6_400)
        amounts.setTip(500)
        XCTAssertEqual(amounts.totalCents, 5_900)
        amounts.setSubtotal(6_000)
        XCTAssertEqual(amounts.tipCents, 500)
        XCTAssertEqual(amounts.totalCents, 6_900)
    }

    func testTotalWithASurchargeOnTheTipIsReachedExactly() {
        var amounts = manual(2_000, [ReceiptAdjustment(kind: .tip, amountCents: 0), ReceiptAdjustment(kind: .surcharge, amountCents: 60)])
        amounts.setTotal(2_500)
        XCTAssertEqual(amounts.tipCents, 440)
        XCTAssertEqual(amounts.totalCents, 2_500)
        assertLinesAddUp(amounts)
    }

    func testTotalBelowTheMinimumLowersASingleAmount() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400), ReceiptAdjustment(kind: .tip, amountCents: 700)])
        amounts.setTotal(4_400)
        XCTAssertEqual(amounts.tipCents, 0)
        XCTAssertEqual(amounts.subtotalCents, 4_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.totalCents, 4_400)
        assertLinesAddUp(amounts)
    }

    func testSingleAmountSubtotalStopsAtZero() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .tip, amountCents: 300)])
        amounts.setTotal(0)
        XCTAssertEqual(amounts.subtotalCents, 0)
        XCTAssertEqual(amounts.tipCents, 0)
        XCTAssertEqual(amounts.totalCents, 0)
    }

    func testItemizedTotalBelowTheMinimumStaysAtTheMinimum() {
        var amounts = itemized([ReceiptAdjustment(kind: .tax, amountCents: 80), ReceiptAdjustment(kind: .tip, amountCents: 300)])
        XCTAssertEqual(amounts.totalCents, 1_880)
        XCTAssertEqual(amounts.minimumTotalCents, 1_580)
        amounts.setTotal(1_000)
        XCTAssertEqual(amounts.tipCents, 0)
        XCTAssertEqual(amounts.totalCents, 1_580)
        XCTAssertEqual(amounts.items.map(\.cents), [1_000, 500])
    }

    func testItemizedTotalAboveTheMinimumGoesToTheTip() {
        var amounts = itemized([ReceiptAdjustment(kind: .tax, amountCents: 80)])
        amounts.setTotal(2_000)
        XCTAssertEqual(amounts.tipCents, 420)
        XCTAssertEqual(amounts.totalCents, 2_000)
        XCTAssertEqual(amounts.items.map(\.cents), [1_000, 500])
        assertLinesAddUp(amounts)
    }

    func testSubtotalOnAnEmptyExpenseAddsARow() {
        var amounts = ExpenseAmounts(items: [], adjustments: [])
        amounts.setSubtotal(1_234)
        XCTAssertEqual(amounts.items.count, 1)
        XCTAssertTrue(amounts.items[0].isSelected)
        XCTAssertEqual(amounts.totalCents, 1_234)
    }

    // MARK: Itemized receipts

    func testItemizedSubtotalIsTheItemsAndNeverRewritesThem() {
        var amounts = itemized([ReceiptAdjustment(kind: .tax, amountCents: 80)])
        XCTAssertFalse(amounts.isSubtotalEditable)
        XCTAssertEqual(amounts.subtotalCents, 1_500)
        amounts.setSubtotal(9_999)
        XCTAssertEqual(amounts.items.map(\.cents), [1_000, 500])
        XCTAssertEqual(amounts.totalCents, 1_580)
        // Tax applies to the taxed burger alone.
        amounts.setAdjustment(100, id: amounts.taxes[0].id)
        XCTAssertEqual(amounts.items.map(\.globalOffsetCents), [100, 0])
        XCTAssertEqual(amounts.totalCents, 1_600)
        assertLinesAddUp(amounts)
    }

    func testSubtotalIncludesItemDiscounts() {
        let amounts = ExpenseAmounts(items: [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100, isSelected: true),
            ReceiptItem(name: "Fries", cents: 400, isSelected: true),
        ], adjustments: [])
        XCTAssertEqual(amounts.subtotalCents, 1_300)
        XCTAssertEqual(amounts.totalCents, 1_300)
        assertLinesAddUp(amounts)
    }

    func testPrintedReceiptKeepsItsAmounts() {
        var rows = [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100, isSelected: true),
            ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true),
        ]
        let adjustments = rows.resolveAdjustments([
            ReceiptAdjustment(kind: .tax, amountCents: 54),
            ReceiptAdjustment(kind: .tip, amountCents: 400),
            ReceiptAdjustment(kind: .surcharge, amountCents: 56),
        ])
        let amounts = ExpenseAmounts(items: rows, adjustments: adjustments)
        XCTAssertEqual(amounts.adjustments.map(\.amountCents), [54, 400, 56])
        XCTAssertEqual(amounts.tipCents, 400)
        XCTAssertEqual(amounts.totalCents, 1_910)
        assertLinesAddUp(amounts)
    }

    // MARK: Other

    func testTaxWithNothingTaxedComesToZero() {
        var amounts = ExpenseAmounts(items: [ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true)], adjustments: [])
        let id = amounts.addTax()
        amounts.setAdjustment(100, id: id)
        XCTAssertEqual(amounts.taxCents, 0)
        XCTAssertEqual(amounts.totalCents, 500)
    }

    func testAddedTaxGoesBeforeTheTip() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .tip, amountCents: 200), ReceiptAdjustment(kind: .surcharge, amountCents: 36)])
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
