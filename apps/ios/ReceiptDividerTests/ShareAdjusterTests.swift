import XCTest
@testable import ReceiptDivider

final class ShareAdjusterTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private var people: [UUID] { [a, b, c] }

    private func sum(_ shares: [UUID: Int]) -> Int { shares.values.reduce(0, +) }

    func testAddsTheChangeToHandAdjustedShares() {
        // Hand-adjusted from an even $30 split; a $3 tip split evenly keeps the adjustment.
        let shares = [a: 1_500, b: 1_000, c: 500]
        let result = ShareAdjuster.adding(300, weightedBy: ShareAdjuster.ownerWeights([], people: people), to: shares, people: people, total: 3_300)
        XCTAssertEqual(result, [a: 1_600, b: 1_100, c: 600])
    }

    func testRemainderCentsAreDeterministic() {
        let result = ShareAdjuster.adding(100, weightedBy: [a: 1, b: 1, c: 1], to: [a: 0, b: 0, c: 0], people: people, total: 100)
        XCTAssertEqual(result, [a: 34, b: 33, c: 33])
        XCTAssertEqual(ShareAdjuster.adding(100, weightedBy: [a: 1, b: 1, c: 1], to: [a: 0, b: 0, c: 0], people: people, total: 100), result)
    }

    func testProportionalWeights() {
        let result = ShareAdjuster.adding(400, weightedBy: [a: 3_000, b: 1_000, c: 0], to: [a: 3_000, b: 1_000, c: 1_000], people: people, total: 5_400)
        XCTAssertEqual(result, [a: 3_300, b: 1_100, c: 1_000])
    }

    func testNoShareGoesBelowZero() {
        // Taking $6 evenly would take c below zero; the rest comes from the others by what they have.
        let result = ShareAdjuster.adding(-600, weightedBy: [a: 1, b: 1, c: 1], to: [a: 2_000, b: 1_000, c: 100], people: people, total: 2_500)
        XCTAssertEqual(result[c], 0)
        XCTAssertEqual(sum(result), 2_500)
        XCTAssertTrue(result.values.allSatisfy { $0 >= 0 })
        XCTAssertEqual(result, [a: 1_731, b: 769, c: 0])
    }

    func testAlwaysAddsUpToTheTotal() {
        // Shares that didn't add up (an empty draft) still end at the total.
        let result = ShareAdjuster.adding(5_000, weightedBy: [:], to: [:], people: people, total: 5_000)
        XCTAssertEqual(result, [a: 1_667, b: 1_667, c: 1_666])
        let fixed = ShareAdjuster.adding(0, weightedBy: [:], to: [a: 1_000, b: 1_000, c: 1_000], people: people, total: 2_999)
        XCTAssertEqual(sum(fixed), 2_999)
    }

    func testTaxWeightsUseTaxedItemsOnly() {
        let items = [
            ReceiptItem(name: "Wine", cents: 3_000, isSelected: true, ownerIDs: [a]),
            ReceiptItem(name: "Bread", cents: 1_000, taxed: false, isSelected: true, ownerIDs: [b]),
        ]
        let amounts = ExpenseAmounts(items: items, adjustments: [ReceiptAdjustment(kind: .tax, amountCents: 240)])
        let weights = ShareAdjuster.weights(for: .adjustment(amounts.taxes[0].id), in: amounts, owners: \.ownerIDs, people: people, tipSplit: .even)
        XCTAssertEqual(weights, [a: 3_000, b: 0, c: 0])
        let discountWeights = ShareAdjuster.itemWeights(items, owners: \.ownerIDs, people: people)
        XCTAssertEqual(discountWeights, [a: 3_000, b: 1_000, c: 0])
    }

    func testTipWeightsFollowTheSetting() {
        let items = [ReceiptItem(name: "Steak", cents: 3_000, isSelected: true, ownerIDs: [a, b])]
        let amounts = ExpenseAmounts(items: items, adjustments: [])
        XCTAssertEqual(ShareAdjuster.weights(for: .tip, in: amounts, owners: \.ownerIDs, people: people, tipSplit: .even), [a: 1, b: 1, c: 1])
        XCTAssertEqual(ShareAdjuster.weights(for: .tip, in: amounts, owners: \.ownerIDs, people: people, tipSplit: .proportional), [a: 1_500, b: 1_500, c: 0])
    }

    func testSingleItemSubtotalGoesToItsOwnersOrEveryone() {
        let owned = ExpenseAmounts(items: [ReceiptItem(name: "", cents: 1_000, isSelected: true, ownerIDs: [b])], adjustments: [])
        XCTAssertEqual(ShareAdjuster.weights(for: .subtotal, in: owned, owners: \.ownerIDs, people: people, tipSplit: .even), [a: 0, b: 1, c: 0])
        let unowned = ExpenseAmounts(items: [ReceiptItem(name: "", cents: 1_000, isSelected: true)], adjustments: [])
        XCTAssertEqual(ShareAdjuster.weights(for: .total, in: unowned, owners: \.ownerIDs, people: people, tipSplit: .even), [a: 1, b: 1, c: 1])
    }

    func testItemPriceEditMovesOnlyItsOwners() {
        let old = [
            ReceiptItem(name: "Wine", cents: 3_000, isSelected: true, ownerIDs: [a]),
            ReceiptItem(name: "Bread", cents: 1_000, isSelected: true, ownerIDs: [b, c]),
        ]
        var new = old
        new[1].cents = 1_600
        let shares = [a: 2_800, b: 700, c: 500] // c's share was tweaked down by hand
        let result = ShareAdjuster.applyingItemChanges(from: old, to: new, shares: shares, owners: \.ownerIDs, people: people, total: 4_600)
        XCTAssertEqual(result, [a: 2_800, b: 1_000, c: 800])
    }

    func testAddedAndDeletedItems() {
        let old = [ReceiptItem(name: "Wine", cents: 3_000, isSelected: true, ownerIDs: [a]),
                   ReceiptItem(name: "Bread", cents: 900, isSelected: true, ownerIDs: [b])]
        let new = [old[0], ReceiptItem(name: "Cheese", cents: 600, isSelected: true)]
        let result = ShareAdjuster.applyingItemChanges(from: old, to: new, shares: [a: 3_000, b: 900, c: 0], owners: \.ownerIDs, people: people, total: 3_600)
        // Bread's $9 comes off b; the unowned cheese is everyone's.
        XCTAssertEqual(result, [a: 3_200, b: 200, c: 200])
    }
}

final class ExpensePermissionTests: XCTestCase {
    func testCreatorAndPayerMayEditOthersMayNot() {
        let creator = UUID(), payer = UUID(), other = UUID()
        let expense = Expense(description: "Dinner", transactionDate: .now, payer: payer, items: [], shares: [payer: 500, other: 500], creator: creator)
        XCTAssertTrue(expense.canEdit(as: creator))
        XCTAssertTrue(expense.canEdit(as: payer))
        XCTAssertFalse(expense.canEdit(as: other))
        XCTAssertFalse(expense.canEdit(as: nil))
    }

    func testPayerMayEditAnExpenseWithNoKnownCreator() {
        let payer = UUID()
        let expense = Expense(description: "Dinner", transactionDate: .now, payer: payer, items: [], shares: [payer: 500])
        XCTAssertTrue(expense.canEdit(as: payer))
        XCTAssertFalse(expense.canEdit(as: UUID()))
    }
}

final class AmountsAuditTests: XCTestCase {
    func testDecodesAndDescribesAnAmountsEdit() throws {
        let user = UUID().uuidString
        let json = """
        {"from": {"totalCents": 5400, "adjustments": [{"kind": "tax", "amountCents": 400}, {"kind": "tip", "amountCents": 1000}],
                  "allocations": [{"userId": "\(user)", "amountCents": 5400}]},
         "to":   {"totalCents": 5900, "adjustments": [{"kind": "tax", "amountCents": 400}, {"kind": "tip", "amountCents": 1500}],
                  "allocations": [{"userId": "\(user)", "amountCents": 5900}]}}
        """
        let audit = try JSONDecoder().decode(APIExpenseAmountsAudit.self, from: Data(json.utf8))
        XCTAssertEqual(audit.changes, ["Tip $10.00 → $15.00", "Total $54.00 → $59.00"])
    }

    func testExpenseDecodesWithAndWithoutUpdatedAt() throws {
        func expense(_ extra: String) -> String {
            """
            {"id": "\(UUID())", "creatorId": "\(UUID())", "clientRequestId": "\(UUID())", "description": "D", "category": null,
             "transactionDate": "2026-10-19", "payerId": "\(UUID())", "totalCents": 100, "items": [], "allocations": [],
             "evidenceIds": [], "createdAt": "2026-10-19T00:00:00Z"\(extra)}
            """
        }
        XCTAssertNil(try JSONDecoder().decode(APIExpense.self, from: Data(expense("").utf8)).updatedAt)
        let stamped = try JSONDecoder().decode(APIExpense.self, from: Data(expense(#", "updatedAt": "2026-10-19T12:34:56.789Z""#).utf8))
        XCTAssertEqual(stamped.updatedAt, "2026-10-19T12:34:56.789Z")
    }
}

final class UpdateExpenseEncodingTests: XCTestCase {
    private func json(_ changes: UpdateAPIExpense) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(changes), as: UTF8.self)
    }

    func testCategoryIsLeftOutSetOrClearedWithNull() throws {
        XCTAssertEqual(try json(UpdateAPIExpense(description: "Dinner")), #"{"description":"Dinner"}"#)
        XCTAssertEqual(try json(UpdateAPIExpense(category: "movie")), #"{"category":"movie"}"#)
        XCTAssertEqual(try json(UpdateAPIExpense(category: .some(nil))), #"{"category":null}"#)
    }
}
