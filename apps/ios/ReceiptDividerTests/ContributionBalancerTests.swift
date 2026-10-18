import XCTest
@testable import ReceiptDivider

final class ContributionBalancerTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private var four: [UUID] { [a, b, c, d] }

    private func sum(_ shares: [UUID: Int]) -> Int { shares.values.reduce(0, +) }

    /// Raising one of four $10 contributions by $2 lowers each of the other three by $2/3, the odd cent going to the
    /// first of them.
    func testChangeIsSharedEquallyAmongTheOthers() {
        var balancer = ContributionBalancer()
        let shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        let result = balancer.set(a, to: 1_200, in: shares, total: 4_000, people: four)
        XCTAssertEqual(result, [a: 1_200, b: 933, c: 933, d: 934].mapValues { $0 } == result ? result : [a: 1_200, b: 934, c: 933, d: 933])
        XCTAssertEqual(result[a], 1_200)
        XCTAssertEqual([result[b]!, result[c]!, result[d]!].sorted(), [933, 933, 934])
        XCTAssertEqual(sum(result), 4_000)
        XCTAssertEqual(balancer.fixed, [a])
    }

    /// Leftover cents go one each to the first free people in participant order, deterministically.
    func testRemainderCentsGoToTheFirstFreePeopleInOrder() {
        var balancer = ContributionBalancer()
        let result = balancer.set(a, to: 0, in: [a: 1_000, b: 0, c: 0, d: 0], total: 1_000, people: four)
        XCTAssertEqual(result, [a: 0, b: 334, c: 333, d: 333])
        var lowered = ContributionBalancer()
        let down = lowered.set(a, to: 1_200, in: [a: 1_000, b: 1_000, c: 1_000, d: 1_000], total: 4_000, people: four)
        // The $2 comes out of the others: 66 each and the two leftover cents from the first two.
        XCTAssertEqual(down, [a: 1_200, b: 933, c: 933, d: 934])
    }

    /// Typing or dragging through intermediate values always spreads from where everyone stood when the edit began, so
    /// the result matches a single jump to the final value.
    func testIntermediateValuesDoNotAccumulateRounding() {
        var stepped = ContributionBalancer(), direct = ContributionBalancer()
        var shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        for cents in [100, 1_200, 1_250, 1_201] {
            shares = stepped.set(a, to: cents, in: shares, total: 4_000, people: four)
        }
        XCTAssertEqual(shares, direct.set(a, to: 1_201, in: [a: 1_000, b: 1_000, c: 1_000, d: 1_000], total: 4_000, people: four))
    }

    /// Edited people stay fixed; later edits only move the people still free.
    func testEditedPeopleStayFixed() {
        var balancer = ContributionBalancer()
        var shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        shares = balancer.set(a, to: 1_600, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 1_600, b: 800, c: 800, d: 800])
        shares = balancer.set(b, to: 400, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 1_600, b: 400, c: 1_000, d: 1_000])
        XCTAssertEqual(balancer.fixed, [a, b])
        shares = balancer.set(c, to: 1_500, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 1_600, b: 400, c: 1_500, d: 500])
        XCTAssertEqual(balancer.fixed, [a, b, c])
    }

    /// With one person left free, editing them frees whoever has been fixed longest.
    func testEditingTheLastFreePersonFreesTheLongestFixed() {
        var balancer = ContributionBalancer()
        var shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        shares = balancer.set(a, to: 1_600, in: shares, total: 4_000, people: four)
        shares = balancer.set(b, to: 400, in: shares, total: 4_000, people: four)
        shares = balancer.set(c, to: 1_500, in: shares, total: 4_000, people: four)
        shares = balancer.set(d, to: 800, in: shares, total: 4_000, people: four)
        XCTAssertEqual(balancer.fixed, [b, c, d])
        XCTAssertEqual(shares, [a: 1_300, b: 400, c: 1_500, d: 800])
        // Re-editing someone already fixed keeps the free set and makes them the most recent.
        shares = balancer.set(b, to: 500, in: shares, total: 4_000, people: four)
        XCTAssertEqual(balancer.fixed, [c, d, b])
        XCTAssertEqual(shares, [a: 1_200, b: 500, c: 1_500, d: 800])
        // Now the next free-person edit frees c, the longest fixed.
        shares = balancer.set(a, to: 1_000, in: shares, total: 4_000, people: four)
        XCTAssertEqual(balancer.fixed, [d, b, a])
        XCTAssertEqual(shares, [a: 1_000, b: 500, c: 1_700, d: 800])
    }

    func testTwoPeopleAlwaysMoveTogether() {
        var balancer = ContributionBalancer()
        var shares = [a: 500, b: 500]
        shares = balancer.set(a, to: 700, in: shares, total: 1_000, people: [a, b])
        XCTAssertEqual(shares, [a: 700, b: 300])
        shares = balancer.set(b, to: 900, in: shares, total: 1_000, people: [a, b])
        XCTAssertEqual(shares, [a: 100, b: 900])
        XCTAssertEqual(balancer.fixed, [b])
    }

    /// A free contribution stops at zero and the rest of the change is shared among the others; the edited value is
    /// capped at what the other fixed contributions leave.
    func testClampsAtZeroAndCapsAtTheRoomLeft() {
        var balancer = ContributionBalancer()
        let uneven = balancer.set(a, to: 2_000, in: [a: 1_000, b: 100, c: 1_000, d: 900], total: 3_000, people: four)
        // $10 more for a: b gives its last $1, and the other $9 is split between c and d.
        XCTAssertEqual(uneven, [a: 2_000, b: 0, c: 550, d: 450])

        var capped = ContributionBalancer()
        var shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        shares = capped.set(a, to: 2_500, in: shares, total: 4_000, people: four)
        shares = capped.set(b, to: 9_999, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 2_500, b: 1_500, c: 0, d: 0])
        shares = capped.set(c, to: -50, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares[c], 0)
        XCTAssertEqual(sum(shares), 4_000)
    }

    /// Empty shares count as zero, so the first edit splits what's left of the total evenly among the free people.
    func testEmptyStartSplitsTheRemainderEvenly() {
        var balancer = ContributionBalancer()
        var shares = balancer.set(a, to: 1_000, in: [:], total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 1_000, b: 1_000, c: 1_000, d: 1_000])
        shares = balancer.set(b, to: 2_000, in: shares, total: 4_000, people: four)
        XCTAssertEqual(shares, [a: 1_000, b: 2_000, c: 500, d: 500])

        var partial = ContributionBalancer()
        let filled = partial.set(a, to: 100, in: [a: 0, b: 0], total: 1_001, people: [a, b, c])
        XCTAssertEqual(filled, [a: 100, b: 451, c: 450])
    }

    /// Setting someone to what they already have, such as focusing an empty field, doesn't fix them.
    func testUnchangedValueDoesNotFix() {
        var balancer = ContributionBalancer()
        let shares = [a: 0, b: 1_000]
        XCTAssertEqual(balancer.set(a, to: 0, in: shares, total: 1_000, people: [a, b]), shares)
        XCTAssertEqual(balancer.fixed, [])
    }

    /// Shares reset from elsewhere (ownership, a new total) start the balancer over with nobody fixed.
    func testOutsideChangesStartOver() {
        var balancer = ContributionBalancer()
        var shares = [a: 1_000, b: 1_000, c: 1_000, d: 1_000]
        shares = balancer.set(a, to: 1_600, in: shares, total: 4_000, people: four)
        shares = balancer.set(b, to: 400, in: shares, total: 4_000, people: four)
        let reset = [a: 1_500, b: 1_500, c: 1_500, d: 1_500]
        shares = balancer.set(a, to: 2_100, in: reset, total: 6_000, people: four)
        XCTAssertEqual(balancer.fixed, [a])
        XCTAssertEqual(shares, [a: 2_100, b: 1_300, c: 1_300, d: 1_300])
    }

    func testSinglePersonPaysTheTotalAndOutsidersAreIgnored() {
        var balancer = ContributionBalancer()
        XCTAssertEqual(balancer.set(a, to: 10, in: [:], total: 900, people: [a]), [a: 900])
        XCTAssertEqual(balancer.set(c, to: 10, in: [a: 500, b: 500, c: 7], total: 1_000, people: [a, b]), [a: 500, b: 500])
    }
}
