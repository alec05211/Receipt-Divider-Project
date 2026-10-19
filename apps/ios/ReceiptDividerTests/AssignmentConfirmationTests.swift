import XCTest
@testable import ReceiptDivider

final class AssignmentConfirmationTests: XCTestCase {
    private let ben = UUID(), willem = UUID(), alec = UUID()
    private let pizza = ReceiptItem(name: "Pizza", cents: 2_000, isSelected: true)
    private let soda = ReceiptItem(name: "Soda", cents: 300, isSelected: true)
    private let added = ReceiptItem(name: "", cents: 500, isSelected: true)

    /// A saved expense's rows keep their owners; only the row nobody has goes to the payer, and contributions from
    /// ownership then match what the ledger saves.
    func testConfirmingFillsOnlyUnassignedRowsWithThePayer() {
        var confirmation = AssignmentConfirmation()
        var assignments: [UUID: Set<UUID>] = [pizza.id: [ben, willem], soda.id: [willem]]
        let items = [pizza, soda, added]
        XCTAssertTrue(confirmation.confirm(items, assignments: &assignments, payer: alec))
        XCTAssertTrue(confirmation.isLocked)
        XCTAssertEqual(assignments, [pizza.id: [ben, willem], soda.id: [willem], added.id: [alec]])
        let owned = items.map { item in
            var item = item
            item.ownerIDs = assignments[item.id, default: []]
            return item
        }
        XCTAssertEqual(owned.ownerShares(for: [ben, willem, alec]), [ben: 1_000, willem: 1_300, alec: 500])
    }

    func testConfirmingWithEveryRowAssignedChangesNothing() {
        var confirmation = AssignmentConfirmation()
        let before: [UUID: Set<UUID>] = [pizza.id: [ben], soda.id: [willem]]
        var assignments = before
        XCTAssertFalse(confirmation.confirm([pizza, soda], assignments: &assignments, payer: ben))
        XCTAssertEqual(assignments, before)
        XCTAssertTrue(confirmation.isLocked)
    }

    func testBackRestoresOwnershipFromBeforeConfirming() {
        var confirmation = AssignmentConfirmation()
        let before: [UUID: Set<UUID>] = [pizza.id: [ben]]
        var assignments = before
        confirmation.confirm([pizza, soda, added], assignments: &assignments, payer: ben)
        confirmation.undo(&assignments)
        XCTAssertEqual(assignments, before)
        XCTAssertFalse(confirmation.isLocked)
    }

    func testANewPayerTakesOnlyTheFilledRows() {
        var confirmation = AssignmentConfirmation()
        var assignments: [UUID: Set<UUID>] = [pizza.id: [ben]]
        let items = [pizza, soda]
        confirmation.confirm(items, assignments: &assignments, payer: ben)
        confirmation.reassignFilledRows(items, assignments: &assignments, to: willem)
        XCTAssertEqual(assignments, [pizza.id: [ben], soda.id: [willem]])
    }
}
