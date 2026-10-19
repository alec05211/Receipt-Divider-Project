import Foundation

/// Keeps contributions adding up to the total as people edit them, whether by dragging a slider or typing an amount.
/// Both go through `set`, so they behave the same. Everything is in whole cents.
///
/// - Editing a contribution fixes it. The difference between the total and everything fixed is shared among the people
///   still free: each absorbs an equal part of the change from where they stood, so raising one of four contributions
///   by $2 lowers each of the other three by $2/3. Cents that don't divide evenly go one each to the first free people
///   in participant order.
/// - No free contribution goes below zero: once one reaches zero the rest of the change is shared among the others, and
///   the edited value is capped at what the other fixed contributions leave of the total.
/// - One person always stays free. Editing the last free person frees whoever has been fixed longest.
/// - Shares that start empty count as zero, so the first edit splits what's left of the total evenly among the free
///   people; prefilled shares each move by an equal part of the change instead.
/// - When the shares, total, or people change from outside (contributions reset from item ownership, a new total), the
///   balancer starts over with nobody fixed.
struct ContributionBalancer {
    /// People whose contribution is fixed, least recently edited first.
    private(set) var fixed: [UUID] = []
    /// Everyone's shares from when the person being edited was first touched. Each edit spreads from these rather than
    /// the last update, so rounding cents don't pile onto one person over the course of a drag or while typing.
    private var start: (person: UUID, shares: [UUID: Int])?
    /// What the last edit produced, to notice changes made elsewhere.
    private var last: (shares: [UUID: Int], total: Int, people: [UUID])?

    /// Sets `person`'s contribution and returns everyone's shares, which add up to `total` whenever the starting shares
    /// did or `total` is no more than they leave room for. With only one person, their contribution is the whole total.
    /// Setting someone to the amount they already have changes nothing and doesn't fix them.
    mutating func set(_ person: UUID, to cents: Int, in shares: [UUID: Int], total: Int, people: [UUID]) -> [UUID: Int] {
        var current = shares.filter { people.contains($0.key) }
        for other in people where current[other] == nil { current[other] = 0 }
        guard people.contains(person) else { return current }
        guard people.count > 1 else { current[person] = max(total, 0); return current }
        if let last, last.shares != current || last.total != total || last.people != people {
            fixed = []
            start = nil
        }
        guard cents != current[person] || fixed.contains(person) else { return current }

        if start?.person != person { start = (person, current) }
        fixed.removeAll { $0 == person }
        fixed.append(person)
        if fixed.count == people.count { fixed.removeFirst() }

        let base = start?.shares ?? current
        let otherFixed = fixed.dropLast().reduce(0) { $0 + (base[$1] ?? 0) }
        let value = min(max(cents, 0), max(total - otherFixed, 0))
        let free = people.filter { !fixed.contains($0) }
        let change = total - otherFixed - value - free.reduce(0) { $0 + (base[$1] ?? 0) }
        var result = base
        result[person] = value
        for (other, cents) in zip(free, Self.spread(change, over: free.map { base[$0] ?? 0 })) { result[other] = cents }
        last = (result, total, people)
        return result
    }

    /// Adds `amount` to `values` in equal parts, leftover cents going one each to the first. Anyone reaching zero stops
    /// shrinking and the rest is shared among the others.
    static func spread(_ amount: Int, over values: [Int]) -> [Int] {
        var values = values, remaining = amount
        while remaining != 0 {
            let open = values.indices.filter { remaining > 0 || values[$0] > 0 }
            guard !open.isEmpty else { break }
            let part = remaining / open.count
            for index in open where remaining != 0 {
                let applied = max(part != 0 ? part : remaining.signum(), -values[index])
                values[index] += applied
                remaining -= applied
            }
        }
        return values
    }
}
