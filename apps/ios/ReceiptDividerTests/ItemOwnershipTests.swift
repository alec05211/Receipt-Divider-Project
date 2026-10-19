import XCTest
@testable import ReceiptDivider

final class ItemOwnershipTests: XCTestCase {
    private let ben = UUID(), willem = UUID(), alec = UUID()

    func testSharedItemIsDividedAmongItsOwners() {
        let items = [
            ReceiptItem(name: "Orange juice", cents: 300, ownerIDs: [ben, willem, alec]),
            ReceiptItem(name: "Bread", cents: 500, ownerIDs: [ben, willem]),
        ]
        XCTAssertEqual(items.ownerShares(for: [ben, willem, alec]), [ben: 350, willem: 350, alec: 100])
    }

    func testUnownedItemsCountTowardNoOne() {
        let items = [ReceiptItem(name: "Milk", cents: 400, ownerIDs: [alec]), ReceiptItem(name: "Eggs", cents: 600)]
        XCTAssertEqual(items.ownerShares(for: [ben, alec]), [ben: 0, alec: 400])
    }

    func testEveryoneOwningEverythingIsAnEvenSplitWithLeftoverCentsFirst() {
        let items = [ReceiptItem(name: "Ticket", cents: 1_000, ownerIDs: [ben, willem, alec])]
        XCTAssertEqual(items.ownerShares(for: [ben, willem, alec]), [ben: 334, willem: 333, alec: 333])
    }

    /// Leftover cents are settled once across all items, not per item, so one person doesn't collect every extra cent.
    func testLeftoverCentsDoNotPileUpAcrossItems() {
        let items = (0..<3).map { ReceiptItem(name: "Item \($0)", cents: 100, ownerIDs: [ben, willem, alec]) }
        XCTAssertEqual(items.ownerShares(for: [ben, willem, alec]), [ben: 100, willem: 100, alec: 100])
    }

    func testTaxAndDiscountsFollowTheItem() {
        let items = [ReceiptItem(name: "Wine", cents: 2_000, globalOffsetCents: 160, ownerIDs: [ben, willem])]
        XCTAssertEqual(items.ownerShares(for: [ben, willem]), [ben: 1_080, willem: 1_080])
    }

    func testTipSplitsEvenlyOrByWhatEachPersonHad() {
        let items = [ReceiptItem(name: "Steak", cents: 4_000, ownerIDs: [ben]), ReceiptItem(name: "Salad", cents: 2_000, ownerIDs: [willem])]
        let people: Set = [ben, willem]
        let even = items + items.tipRows(1_200, among: people, split: .even)
        XCTAssertEqual(even.ownerShares(for: [ben, willem]), [ben: 4_600, willem: 2_600])
        let proportional = items + items.tipRows(1_200, among: people, split: .proportional)
        XCTAssertEqual(proportional.ownerShares(for: [ben, willem]), [ben: 4_800, willem: 2_400])
    }

    /// A shared item's part of the tip is shared by its owners, and someone who had nothing pays no tip.
    func testProportionalTipFollowsSharedItems() {
        let items = [ReceiptItem(name: "Pizza", cents: 3_000, ownerIDs: [ben, willem]), ReceiptItem(name: "Wine", cents: 1_000, ownerIDs: [ben])]
        let shares = (items + items.tipRows(800, among: [ben, willem, alec], split: .proportional)).ownerShares(for: [ben, willem, alec])
        XCTAssertEqual(shares, [ben: 3_000, willem: 1_800, alec: 0])
    }

    func testProportionalTipWithNoOwnedItemsIsEven() {
        let tip = [ReceiptItem]().tipRows(900, among: [ben, willem, alec], split: .proportional)
        XCTAssertEqual(tip.ownerShares(for: [ben, willem, alec]), [ben: 300, willem: 300, alec: 300])
    }

    /// What each item costs a person, as shown in Settle Up and on an expense, includes its tax, surcharge and tip and
    /// adds up to their share.
    func testItemChargesIncludeTaxTipAndSurcharge() {
        var items = [
            ReceiptItem(name: "Steak", cents: 4_000, isSelected: true, ownerIDs: [ben]),
            ReceiptItem(name: "Salad", cents: 2_000, isSelected: true, ownerIDs: [willem]),
            ReceiptItem(name: "Fries", cents: 1_000, isSelected: true, ownerIDs: [ben, willem]),
        ]
        let adjustments = items.applyAdjustments([
            ReceiptAdjustment(kind: .tax, rate: 0.10),
            ReceiptAdjustment(kind: .tip, amountCents: 1_200),
            ReceiptAdjustment(kind: .surcharge, rate: 0.03),
        ])
        let shares = (items + items.tipRows(adjustments.tipCents, among: [ben, willem], split: .even)).ownerShares(for: [ben, willem])
        XCTAssertEqual(shares, [ben: 5_717, willem: 3_450])
        let expense = Expense(description: "Dinner", transactionDate: .now, payer: ben, items: items, shares: shares, recordedTotalCents: 9_167, adjustments: adjustments)

        let bens = expense.itemCharges(for: ben)
        XCTAssertEqual(bens.map(\.item.name), ["Steak", "Fries"])
        XCTAssertEqual(bens.map(\.cents), [5_082, 635])
        let willems = expense.itemCharges(for: willem)
        XCTAssertEqual(willems.map(\.item.name), ["Salad", "Fries"])
        XCTAssertEqual(willems.map(\.cents), [2_760, 690])
    }

    /// A contribution changed by hand is still fully accounted for by the person's items.
    func testItemChargesFollowAnAdjustedShare() {
        let items = [
            ReceiptItem(name: "Pizza", cents: 3_000, globalOffsetCents: 270, isSelected: true, ownerIDs: [ben, willem]),
            ReceiptItem(name: "Soda", cents: 300, globalOffsetCents: 27, isSelected: true, ownerIDs: [willem]),
        ]
        let expense = Expense(description: "Lunch", transactionDate: .now, payer: ben, items: items, shares: [ben: 1_000, willem: 2_597])
        XCTAssertEqual(expense.itemCharges(for: willem).map(\.cents).reduce(0, +), 2_597)
        XCTAssertEqual(expense.itemCharges(for: ben).map(\.cents), [1_000])
    }
}
