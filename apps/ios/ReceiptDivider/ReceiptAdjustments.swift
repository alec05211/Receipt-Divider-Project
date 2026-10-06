import Foundation

/// A receipt-wide discount, tax, tip or surcharge. An expense lists them in the order the receipt applies them, because
/// each one applies to the running cost left by the ones before it.
struct ReceiptAdjustment: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case discount, tax, tip, surcharge
        var title: String {
            switch self {
            case .discount: "Discount"
            case .tax: "Tax"
            case .tip: "Tip"
            case .surcharge: "Surcharge"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    /// For a discount, tax or surcharge, the fraction of the running cost it applies to (0.06 for 6%). Unused for a tip.
    var rate: Double = 0
    /// For a tip, the tip itself. For anything else, what the adjustment came to, set by `applyAdjustments`.
    var amountCents = 0
    /// For a tip, its share of surcharges printed after it, set by `applyAdjustments`; split evenly along with the tip.
    var chargesCents = 0
}

extension Array where Element == ReceiptAdjustment {
    /// What the tip costs everyone together: the tip plus any surcharge charged on it.
    var tipCents: Int { filter { $0.kind == .tip }.reduce(0) { $0 + $1.amountCents + $1.chargesCents } }
}

extension Array where Element == ReceiptItem {
    /// Sets every item's global offset by applying `adjustments` in order, and returns them with the amounts they came to.
    ///
    /// Each item has a running cost, starting at its price after its own offset. A discount then applies to items, tax
    /// to taxed items, and a surcharge to every item and to any tip printed before it. The tip isn't an item: it adds its
    /// own amount at its step and keeps its share of later surcharges as `chargesCents`. Each step's amount is shared in
    /// proportion to the running costs, rounded so the shares add up to it exactly.
    @discardableResult
    mutating func applyAdjustments(_ adjustments: [ReceiptAdjustment]) -> [ReceiptAdjustment] {
        walk(adjustments) { adjustment, _ in adjustment.rate }
    }

    /// The adjustments printed on a receipt, with each rate worked out from its printed amount and the running cost
    /// it applied to, so applying them reproduces the printed amounts exactly. An adjustment printed with only a
    /// percent carries it as `rate` and `amountCents` of zero. Also applies them to these items.
    mutating func resolveAdjustments(_ printed: [ReceiptAdjustment]) -> [ReceiptAdjustment] {
        walk(printed) { adjustment, base in
            adjustment.amountCents > 0 && base > 0 ? Double(adjustment.amountCents) / Double(base) : adjustment.rate
        }
    }

    private mutating func walk(_ adjustments: [ReceiptAdjustment], rate: (ReceiptAdjustment, Int) -> Double) -> [ReceiptAdjustment] {
        var running = map(\.netCents)
        // The tips' running cost, which surcharges after them apply to like an item's.
        var tips = 0
        var applied = adjustments
        for index in applied.indices {
            let kind = applied[index].kind
            if kind == .tip {
                applied[index].chargesCents = 0
                tips += applied[index].amountCents
                continue
            }
            let targets = indices.filter { row in
                running[row] > 0 && (kind == .surcharge || (self[row].kind == .item && (kind != .tax || self[row].taxed)))
            }
            let weights = targets.map { running[$0] } + (kind == .surcharge && tips > 0 ? [tips] : [])
            let base = weights.reduce(0, +)
            // A discount can at most take a row's cost to zero.
            applied[index].rate = Swift.min(Swift.max(0, rate(applied[index], base)), kind == .discount ? 1 : .infinity)
            let amount = Int((applied[index].rate * Double(base)).rounded())
            applied[index].amountCents = amount
            let shares = ReceiptMath.distribute(amount, over: weights)
            for (row, share) in zip(targets, shares) { running[row] += kind == .discount ? -share : share }
            if shares.count > targets.count, let tipIndex = applied.firstIndex(where: { $0.kind == .tip }) {
                applied[tipIndex].chargesCents += shares[targets.count]
                tips += shares[targets.count]
            }
        }
        for row in indices { self[row].globalOffsetCents = running[row] - self[row].netCents }
        return applied
    }
}

extension ReceiptItem {
    /// One row per unit of a printed line, so each can be assigned on its own. The line's price and its discount are
    /// split as evenly as the cents allow. A line that can't give every unit a cent stays one row.
    static func rows(name: String, quantity: Int, lineCents: Int, discountCents: Int = 0, taxed: Bool = true) -> [ReceiptItem] {
        let count = (1...50).contains(quantity) && lineCents >= quantity ? quantity : 1
        return zip(ReceiptMath.split(lineCents, into: count), ReceiptMath.split(discountCents, into: count)).map { cents, discount in
            ReceiptItem(name: name, cents: cents, localOffsetCents: -discount, taxed: taxed)
        }
    }
}

enum ReceiptMath {
    /// Splits a non-negative `amount` in proportion to non-negative `weights`. Each part is rounded down and the leftover
    /// cents go to the largest remainders, earlier parts winning ties, so the parts add up to `amount` exactly.
    static func distribute(_ amount: Int, over weights: [Int]) -> [Int] {
        let base = weights.reduce(0, +)
        guard amount > 0, base > 0 else { return weights.map { _ in 0 } }
        var parts = weights.map { amount * $0 / base }
        let remainders = weights.map { amount * $0 % base }
        let leftover = amount - parts.reduce(0, +)
        let order = remainders.indices.sorted { remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1 }
        for index in order.prefix(leftover) { parts[index] += 1 }
        return parts
    }

    /// Splits `total` into `count` parts as equal as the cents allow, earlier parts taking the extra cents.
    static func split(_ total: Int, into count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0..<count).map { total / count + ($0 < total % count ? 1 : 0) }
    }
}
