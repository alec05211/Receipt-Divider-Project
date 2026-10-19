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

    /// total = subtotal + taxes + surcharges + tip − discounts, and the rows carry exactly that much.
    private func assertAddsUp(_ amounts: ExpenseAmounts, file: StaticString = #filePath, line: UInt = #line) {
        let sum = { (kind: ReceiptAdjustment.Kind) in amounts.adjustments.filter { $0.kind == kind }.reduce(0) { $0 + $1.amountCents } }
        let lines = amounts.subtotalCents + sum(.tax) + sum(.surcharge) + amounts.tipCents - sum(.discount) + amounts.unlistedOffsetCents
        XCTAssertEqual(lines, amounts.totalCents, "lines don't add up to the total", file: file, line: line)
        let rows = amounts.items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents } + amounts.adjustments.tipCents
        XCTAssertEqual(rows, amounts.totalCents, "rows don't carry the total", file: file, line: line)
    }

    private func field(_ amounts: ExpenseAmounts, _ kind: ReceiptAdjustment.Kind, _ index: Int = 0) -> ExpenseAmounts.Field {
        .adjustment(amounts.adjustments.filter { $0.kind == kind }[index].id)
    }

    // MARK: Rule 6: every component holds what was typed and changes nothing else

    func testEditingAComponentChangesOnlyItAndTheTotal() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .discount, amountCents: 300), ReceiptAdjustment(kind: .tax, amountCents: 400),
                                     ReceiptAdjustment(kind: .surcharge, amountCents: 100), ReceiptAdjustment(kind: .tip, amountCents: 1_000)])
        XCTAssertEqual(amounts.totalCents, 6_200)
        amounts.set(.tip, to: 1_500)
        XCTAssertEqual(amounts.adjustments.map(\.amountCents), [300, 400, 100, 1_500])
        XCTAssertEqual(amounts.totalCents, 6_700)
        amounts.set(field(amounts, .tax), to: 450)
        XCTAssertEqual(amounts.adjustments.map(\.amountCents), [300, 450, 100, 1_500])
        XCTAssertEqual(amounts.totalCents, 6_750)
        amounts.set(field(amounts, .discount), to: 500)
        amounts.set(field(amounts, .surcharge), to: 0)
        XCTAssertEqual(amounts.adjustments.map(\.amountCents), [500, 450, 0, 1_500])
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.totalCents, 6_450)
        assertAddsUp(amounts)
    }

    func testTaxesDontFollowTheSubtotal() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400), ReceiptAdjustment(kind: .surcharge, amountCents: 150)])
        amounts.set(.subtotal, to: 10_000)
        XCTAssertEqual(amounts.taxCents, 400)
        XCTAssertEqual(amounts.surcharges[0].amountCents, 150)
        XCTAssertEqual(amounts.totalCents, 10_550)
        assertAddsUp(amounts)
    }

    func testEachKeystrokeSetsTheValue() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tip, amountCents: 0)])
        amounts.set(.tip, to: 1_000)
        amounts.set(.tip, to: 1_200)
        XCTAssertEqual(amounts.tipCents, 1_200)
        XCTAssertEqual(amounts.totalCents, 6_200)
    }

    func testAllTaxLinesCount() {
        let amounts = manual(10_000, [ReceiptAdjustment(kind: .tax, amountCents: 625), ReceiptAdjustment(kind: .tax, amountCents: 225)])
        XCTAssertEqual(amounts.lines().filter { $0.kind == .tax }.map(\.cents), [625, 225])
        XCTAssertEqual(amounts.totalCents, 10_850)
        assertAddsUp(amounts)
    }

    func testTaxWithNothingTaxedKeepsItsAmount() {
        var amounts = ExpenseAmounts(items: [ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true)], adjustments: [])
        let tax = amounts.add(.tax)
        amounts.set(tax, to: 100)
        XCTAssertEqual(amounts.taxCents, 100)
        XCTAssertEqual(amounts.totalCents, 600)
        assertAddsUp(amounts)
    }

    func testADiscountCantExceedWhatItAppliesTo() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .discount)])
        amounts.set(field(amounts, .discount), to: 5_000)
        XCTAssertEqual(amounts.discounts[0].amountCents, 1_000)
        XCTAssertEqual(amounts.totalCents, 0)
    }

    func testNoDoubleCountingOfItemDiscountsOrTheTipSurcharge() {
        var rows = [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100, isSelected: true),
            ReceiptItem(name: "Salad", cents: 500, taxed: false, isSelected: true),
        ]
        let printed = rows.resolveAdjustments([
            ReceiptAdjustment(kind: .tax, amountCents: 54),
            ReceiptAdjustment(kind: .tip, amountCents: 400),
            ReceiptAdjustment(kind: .surcharge, amountCents: 56),
        ])
        let amounts = ExpenseAmounts(items: rows, adjustments: printed)
        XCTAssertEqual(amounts.subtotalCents, 1_400)
        XCTAssertEqual(amounts.adjustments.map(\.amountCents), [54, 400, 56])
        XCTAssertEqual(amounts.tipCents, 400)
        XCTAssertEqual(amounts.totalCents, 1_910)
        assertAddsUp(amounts)
    }

    func testRowsLeftOutDontCount() {
        var amounts = ExpenseAmounts(items: [
            ReceiptItem(name: "Kept", cents: 1_000, isSelected: true),
            ReceiptItem(name: "Left out", cents: 700),
        ], adjustments: [ReceiptAdjustment(kind: .tax, amountCents: 80)])
        XCTAssertEqual(amounts.totalCents, 1_080)
        XCTAssertTrue(amounts.isSubtotalEditable)
        amounts.set(.subtotal, to: 2_000)
        XCTAssertEqual(amounts.items.map(\.cents), [2_000, 700])
        XCTAssertEqual(amounts.items[1].globalOffsetCents, 0)
        assertAddsUp(amounts)
    }

    // MARK: Rule 7: the total is editable only when it's the only amount

    func testTotalOnlyOffersEditTotal() {
        var amounts = manual(5_000)
        XCTAssertTrue(amounts.isTotalOnly())
        XCTAssertEqual(amounts.menu().first, .edit(.total, title: "Edit total"))
        amounts.set(.total, to: 6_000)
        XCTAssertEqual(amounts.totalCents, 6_000)
        XCTAssertEqual(amounts.subtotalCents, 6_000)
    }

    func testTotalCantBeTypedOnceAnythingElseIsShown() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400)])
        XCTAssertFalse(amounts.isTotalOnly())
        XCTAssertFalse(amounts.menu().contains { if case .edit(.total, _) = $0 { true } else { false } })
        amounts.set(.total, to: 9_999)
        XCTAssertEqual(amounts.totalCents, 5_400)
    }

    // MARK: Rule 8: adding to a total-only expense makes the total the subtotal

    func testAddingTaxToATotalMakesItTheSubtotal() {
        var amounts = manual(5_000)
        let tax = amounts.add(.tax)
        XCTAssertEqual(amounts.lines(editing: tax).map(\.title), ["Subtotal", "Tax"])
        amounts.set(tax, to: 400)
        XCTAssertEqual(amounts.subtotalCents, 5_000)
        XCTAssertEqual(amounts.totalCents, 5_400)
        assertAddsUp(amounts)
    }

    func testAddingToAnEmptyExpenseAddsARow() {
        var amounts = ExpenseAmounts(items: [], adjustments: [])
        let tip = amounts.add(.tip)
        amounts.set(tip, to: 500)
        XCTAssertEqual(amounts.items.count, 1)
        XCTAssertEqual(amounts.totalCents, 500)
        assertAddsUp(amounts)
    }

    // MARK: Rule 9: the subtotal is editable only with one item row

    func testSingleItemSubtotalSetsItsPrice() {
        var amounts = ExpenseAmounts(items: [ReceiptItem(name: "Dinner", cents: 2_000, localOffsetCents: -200, isSelected: true)],
                                     adjustments: [ReceiptAdjustment(kind: .tax, amountCents: 160)])
        XCTAssertEqual(amounts.menu().first, .edit(.subtotal, title: "Edit subtotal"))
        amounts.set(.subtotal, to: 2_500)
        XCTAssertEqual(amounts.items[0].cents, 2_500)
        XCTAssertEqual(amounts.items[0].localOffsetCents, 0)
        XCTAssertEqual(amounts.totalCents, 2_660)
        assertAddsUp(amounts)
    }

    func testItemizedSubtotalIsTheItemsAndOffersEditItems() {
        var amounts = itemized([ReceiptAdjustment(kind: .tax, amountCents: 80)])
        XCTAssertFalse(amounts.isSubtotalEditable)
        XCTAssertEqual(amounts.subtotalCents, 1_500)
        XCTAssertEqual(amounts.menu().first, .editItems)
        amounts.set(.subtotal, to: 9_999)
        XCTAssertEqual(amounts.items.map(\.cents), [1_000, 500])
        // Tax applies to the taxed burger alone.
        XCTAssertEqual(amounts.items.map(\.globalOffsetCents), [80, 0])
        assertAddsUp(amounts)
    }

    func testItemizedTotalOnlyOffersEditItemsNotTotal() {
        let amounts = itemized()
        XCTAssertTrue(amounts.isTotalOnly())
        XCTAssertEqual(amounts.menu().first, .editItems)
    }

    // MARK: Rule 10: item edits flow into the subtotal; components stay

    func testItemPriceChangesMoveOnlyTheSubtotalAndTotal() {
        let before = itemized([ReceiptAdjustment(kind: .tax, amountCents: 80), ReceiptAdjustment(kind: .tip, amountCents: 300)])
        var items = before.items
        items[1].cents = 900
        items.append(ReceiptItem(name: "Fries", cents: 400, isSelected: true))
        let after = ExpenseAmounts(items: items, adjustments: before.adjustments)
        XCTAssertEqual(after.subtotalCents, 2_300)
        XCTAssertEqual(after.taxCents, 80)
        XCTAssertEqual(after.tipCents, 300)
        XCTAssertEqual(after.totalCents, 2_680)
        assertAddsUp(after)
    }

    // MARK: Rules 2, 3, 5: the menu, adding, and lines at $0

    func testMenuListsShownLinesInOrderThenAdditions() {
        let amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400), ReceiptAdjustment(kind: .discount, amountCents: 200),
                                     ReceiptAdjustment(kind: .tip, amountCents: 500)])
        XCTAssertEqual(amounts.lines().map(\.title), ["Subtotal", "Discount", "Tax", "Tip"])
        XCTAssertEqual(amounts.menu().map(\.title), ["Edit subtotal", "Edit discount", "Edit tax", "Edit tip", "Add surcharge"])
    }

    func testTwoTaxesAreToldApart() {
        let amounts = manual(10_000, [ReceiptAdjustment(kind: .tax, amountCents: 625), ReceiptAdjustment(kind: .tax, amountCents: 225)])
        XCTAssertEqual(amounts.menu().map(\.title), ["Edit subtotal", "Edit tax ($6.25)", "Edit tax ($2.25)", "Add tip", "Add discount", "Add surcharge"])
    }

    func testTotalOnlyMenu() {
        XCTAssertEqual(manual(5_000).menu().map(\.title), ["Edit total", "Add tax", "Add tip", "Add discount", "Add surcharge"])
    }

    func testALineAtZeroShowsOnlyWhileEdited() {
        var amounts = manual(5_000, [ReceiptAdjustment(kind: .tax, amountCents: 400), ReceiptAdjustment(kind: .tip, amountCents: 500)])
        let tax = field(amounts, .tax)
        amounts.set(tax, to: 0)
        XCTAssertEqual(amounts.lines(editing: tax).map(\.title), ["Subtotal", "Tax", "Tip"])
        XCTAssertEqual(amounts.lines().map(\.title), ["Subtotal", "Tip"])
        // It keeps its place and comes back from the menu.
        XCTAssertTrue(amounts.menu().contains(.add(.tax)))
        XCTAssertEqual(amounts.add(.tax), tax)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tax, .tip])
    }

    func testAddedLinesGoInPlace() {
        var amounts = manual(1_000, [ReceiptAdjustment(kind: .tip, amountCents: 200), ReceiptAdjustment(kind: .surcharge, amountCents: 36)])
        amounts.add(.tax)
        amounts.add(.discount)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.discount, .tax, .tip, .surcharge])
        XCTAssertEqual(amounts.totalCents, 1_236)
    }

    func testClearingTheTipKeepsItBeforeALaterSurcharge() {
        var amounts = manual(2_000, [ReceiptAdjustment(kind: .tip, amountCents: 400), ReceiptAdjustment(kind: .surcharge, amountCents: 72)])
        amounts.set(.tip, to: 0)
        amounts.set(.tip, to: 500)
        XCTAssertEqual(amounts.adjustments.map(\.kind), [.tip, .surcharge])
        XCTAssertEqual(amounts.surcharges[0].amountCents, 72)
        XCTAssertEqual(amounts.totalCents, 2_572)
        assertAddsUp(amounts)
    }

    // MARK: Older expenses

    /// Expenses saved before adjustments were recorded keep their receipt-wide offsets on the rows only.
    func testOffsetsWithoutAdjustmentsAreListed() {
        let amounts = ExpenseAmounts(items: [ReceiptItem(name: "Dinner", cents: 2_000, globalOffsetCents: 160, isSelected: true)], adjustments: [])
        XCTAssertEqual(amounts.unlistedOffsetCents, 160)
        XCTAssertEqual(amounts.totalCents, 2_160)
        XCTAssertEqual(amounts.lines().map(\.title), ["Subtotal", "Adjustments"])
        assertAddsUp(amounts)
    }

    func testLegacyTipRowsCountAsTheTip() {
        var amounts = ExpenseAmounts(items: [
            ReceiptItem(name: "Dinner", cents: 2_000, isSelected: true),
            ReceiptItem(name: "Tip", cents: 400, kind: .tip, isSelected: true),
        ], adjustments: [])
        XCTAssertEqual(amounts.tipCents, 400)
        XCTAssertEqual(amounts.totalCents, 2_400)
        XCTAssertFalse(amounts.isSubtotalEditable)
        amounts.set(.tip, to: 600)
        XCTAssertEqual(amounts.tipCents, 600)
        XCTAssertEqual(amounts.totalCents, 2_600)
        XCTAssertTrue(amounts.isSubtotalEditable)
        assertAddsUp(amounts)
    }

    func testClearingTheSubtotalUnderADiscountKeepsTheLinesWhileEditing() {
        let base = manual(2_000, [ReceiptAdjustment(kind: .discount, amountCents: 500)])
        let kept = Set(base.lines(editing: .subtotal).map(\.id))
        var edited = base
        edited.set(.subtotal, to: 0)
        // The discount can't exceed a $0 subtotal, but the lines shown when editing began stay.
        XCTAssertEqual(edited.lines(editing: .subtotal, keeping: kept).map(\.title), ["Subtotal", "Discount"])
        // Without keeping them, the $0 discount would hide and take the subtotal with it.
        XCTAssertTrue(edited.lines(editing: .subtotal).isEmpty)
        // Typing again from the state before the edit brings the discount back.
        var retyped = base
        retyped.set(.subtotal, to: 1_500)
        XCTAssertEqual(retyped.totalCents, 1_000)
    }
}
