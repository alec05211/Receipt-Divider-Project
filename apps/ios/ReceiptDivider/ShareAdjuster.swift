import Foundation

/// Moves contributions by what an amount edit changed, so contributions adjusted by hand keep their adjustments.
///
/// - The change to a component is split over people by weights and added to what each already contributes: the tip by
///   the Split tip setting (evenly, or by each person's items), a tax by each person's taxed items, a discount or
///   surcharge by each person's items, and an item's price (or a single-amount subtotal) by that item's owners.
/// - An item with no owners counts as everyone's. With no weight anywhere, the change is split evenly.
/// - Everything is in whole cents: parts are rounded down and leftover cents go to the largest remainders, earlier people
///   winning ties. The result always adds up to the new total exactly, and nobody goes below zero: a reduction someone
///   can't absorb is taken from the others in proportion to what they contribute.
enum ShareAdjuster {
    /// Adds `change` to `shares`, split over `people` by `weights`, then makes the shares add up to `total`.
    static func adding(_ change: Int, weightedBy weights: [UUID: Int], to shares: [UUID: Int], people: [UUID], total: Int) -> [UUID: Int] {
        adding([(change, weights)], to: shares, people: people, total: total)
    }

    /// Adds each change split by its weights, then makes the shares add up to `total`.
    static func adding(_ changes: [(change: Int, weights: [UUID: Int])], to shares: [UUID: Int], people: [UUID], total: Int) -> [UUID: Int] {
        guard !people.isEmpty else { return [:] }
        var values = people.map { max(0, shares[$0] ?? 0) }
        var lastWeights = people.map { _ in 1 }
        for (change, weights) in changes where change != 0 {
            let parts = split(abs(change), by: weights, people: people)
            lastWeights = normalized(weights, people: people)
            for index in people.indices { values[index] += change.signum() * parts[index] }
        }
        return Dictionary(uniqueKeysWithValues: zip(people, reconcile(values, to: max(0, total), growBy: lastWeights)))
    }

    // MARK: Weights

    /// Each person's part of the counted item rows' prices after their own discounts; with `taxedOnly`, of taxed rows.
    static func itemWeights(_ items: [ReceiptItem], owners: (ReceiptItem) -> Set<UUID>, people: [UUID], taxedOnly: Bool = false) -> [UUID: Int] {
        let rows = items.filter { $0.isSelected && $0.kind == .item && (!taxedOnly || $0.taxed) && $0.netCents > 0 }.map { item in
            ReceiptItem(name: item.name, cents: item.netCents, isSelected: true, ownerIDs: ownersOrEveryone(owners(item), people: people))
        }
        return rows.ownerShares(for: people)
    }

    /// One part for each of the owners, or for everyone when there are none.
    static func ownerWeights(_ owners: Set<UUID>, people: [UUID]) -> [UUID: Int] {
        let owners = ownersOrEveryone(owners, people: people)
        return Dictionary(uniqueKeysWithValues: people.map { ($0, owners.contains($0) ? 1 : 0) })
    }

    /// Evenly, everyone has one part; by items, each person's part of the items.
    static func tipWeights(_ split: TipSplit, items: [ReceiptItem], owners: (ReceiptItem) -> Set<UUID>, people: [UUID]) -> [UUID: Int] {
        split == .even ? ownerWeights([], people: people) : itemWeights(items, owners: owners, people: people)
    }

    /// The weights for a change to `field`, from the amounts before the edit.
    static func weights(for field: ExpenseAmounts.Field, in amounts: ExpenseAmounts, owners: (ReceiptItem) -> Set<UUID>,
                        people: [UUID], tipSplit: TipSplit) -> [UUID: Int] {
        switch field {
        case .subtotal, .total:
            let item = amounts.items.first { $0.isSelected && $0.kind == .item }
            return ownerWeights(item.map(owners) ?? [], people: people)
        case .tip:
            return tipWeights(tipSplit, items: amounts.items, owners: owners, people: people)
        case .adjustment:
            let taxed = amounts.kind(of: field) == .tax
            return itemWeights(amounts.items, owners: owners, people: people, taxedOnly: taxed)
        }
    }

    // MARK: Item edits

    /// Adds each counted item row's change in price (after its own discount) to its owners' shares, counting an added
    /// row's whole price and a deleted row's as a reduction, then makes the shares add up to `total`.
    static func applyingItemChanges(from old: [ReceiptItem], to new: [ReceiptItem], shares: [UUID: Int],
                                    owners: (ReceiptItem) -> Set<UUID>, people: [UUID], total: Int) -> [UUID: Int] {
        func counted(_ items: [ReceiptItem]) -> [UUID: ReceiptItem] {
            Dictionary(items.filter { $0.isSelected && $0.kind == .item }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let before = counted(old), after = counted(new)
        let ids = new.map(\.id).filter { after[$0] != nil } + old.map(\.id).filter { after[$0] == nil && before[$0] != nil }
        let changes = ids.compactMap { id -> (change: Int, weights: [UUID: Int])? in
            let change = (after[id]?.netCents ?? 0) - (before[id]?.netCents ?? 0)
            guard change != 0, let item = after[id] ?? before[id] else { return nil }
            return (change, ownerWeights(owners(item), people: people))
        }
        return adding(changes, to: shares, people: people, total: total)
    }

    // MARK: Arithmetic

    private static func ownersOrEveryone(_ owners: Set<UUID>, people: [UUID]) -> Set<UUID> {
        let owners = owners.intersection(people)
        return owners.isEmpty ? Set(people) : owners
    }

    /// Non-negative weights in `people` order, all ones when none is positive.
    private static func normalized(_ weights: [UUID: Int], people: [UUID]) -> [Int] {
        let values = people.map { max(0, weights[$0] ?? 0) }
        return values.contains { $0 > 0 } ? values : people.map { _ in 1 }
    }

    private static func split(_ amount: Int, by weights: [UUID: Int], people: [UUID]) -> [Int] {
        ReceiptMath.distribute(amount, over: normalized(weights, people: people))
    }

    /// Clamps every value at zero and makes them add up to `total`: anything missing is added by `growBy`, and anything
    /// over is taken from everyone in proportion to what they have.
    static func reconcile(_ values: [Int], to total: Int, growBy weights: [Int]) -> [Int] {
        var values = values.map { max(0, $0) }
        let difference = total - values.reduce(0, +)
        if difference > 0 {
            let positive = weights.contains { $0 > 0 } ? weights.map { max(0, $0) } : weights.map { _ in 1 }
            for (index, part) in ReceiptMath.distribute(difference, over: positive).enumerated() { values[index] += part }
        } else if difference < 0 {
            // Taking at most everything there is, each part is no more than that value.
            for (index, part) in ReceiptMath.distribute(min(-difference, values.reduce(0, +)), over: values).enumerated() {
                values[index] -= part
            }
        }
        return values
    }
}
