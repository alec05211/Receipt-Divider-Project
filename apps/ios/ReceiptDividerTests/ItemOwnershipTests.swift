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
}
