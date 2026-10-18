import Foundation

/// The amounts final review shows (subtotal, item discounts, taxes, tip, other adjustments, total) and what editing
/// one of them changes. Items and adjustments are the only source of truth; every line, and the total, is derived from
/// them, so the lines always add up to the total:
///
/// `subtotal + item discounts + taxes − discounts + surcharges + tip (+ unlisted offsets) = total`
///
/// - The subtotal is the counted item rows' printed prices; their own discounts are the item discounts line.
/// - Discounts, taxes and surcharges keep their rates, so they follow the rows they apply to. The tip is an amount.
/// - Editing the subtotal sets the single row's price; the rates stay, so tax follows.
/// - Editing a tax sets its amount, and its rate is worked out from what it applies to; the subtotal stays.
/// - Editing the tip sets its amount; the subtotal and rates stay.
/// - Editing the total finds the subtotal that, with the same rates and tip, comes to it. When no subtotal comes to it
///   exactly because of rounding, the last rate-based adjustment absorbs the cent or two.
/// - The subtotal and total are only editable with at most one item row: an itemized receipt's subtotal is its items,
///   and its total follows them and the adjustments.
struct ExpenseAmounts: Equatable {
    private(set) var items: [ReceiptItem]
    private(set) var adjustments: [ReceiptAdjustment]

    /// Re-applies `adjustments` to `items`, so offsets and adjustment amounts are current. Without adjustments the rows
    /// are kept as they are, since expenses saved before adjustments were recorded hold them only as global offsets.
    init(items: [ReceiptItem], adjustments: [ReceiptAdjustment]) {
        self.items = items
        self.adjustments = adjustments
        if !adjustments.isEmpty { apply() }
    }

    // MARK: Lines

    /// Rows that count toward the expense.
    private var counted: [ReceiptItem] { items.filter(\.isSelected) }
    private var itemRows: [ReceiptItem] { counted.filter { $0.kind == .item } }
    /// Tip rows from expenses saved before the tip was an adjustment; ignored once there is a tip adjustment.
    private var legacyTipRows: [ReceiptItem] {
        adjustments.contains { $0.kind == .tip } ? [] : counted.filter { $0.kind == .tip }
    }

    var subtotalCents: Int { itemRows.reduce(0) { $0 + $1.cents } }
    /// The item rows' own discounts (negative), or other differences recorded on a row.
    var itemOffsetCents: Int { itemRows.reduce(0) { $0 + $1.localOffsetCents } }
    var taxes: [ReceiptAdjustment] { adjustments.filter { $0.kind == .tax } }
    var taxCents: Int { taxes.reduce(0) { $0 + $1.amountCents } }
    /// The tip as entered. Any surcharge on it is part of that surcharge's line.
    var tipCents: Int {
        adjustments.filter { $0.kind == .tip }.reduce(0) { $0 + $1.amountCents } + legacyTipRows.reduce(0) { $0 + $1.totalCents }
    }
    /// Receipt-wide discounts and surcharges, in receipt order.
    var otherAdjustments: [ReceiptAdjustment] { adjustments.filter { $0.kind == .discount || $0.kind == .surcharge } }
    /// Receipt-wide offsets on expenses saved before adjustments were recorded, where nothing else lists them.
    var unlistedOffsetCents: Int { adjustments.isEmpty ? itemRows.reduce(0) { $0 + $1.globalOffsetCents } : 0 }

    var totalCents: Int {
        let rows = itemRows.reduce(0) { $0 + $1.totalCents } + legacyTipRows.reduce(0) { $0 + $1.totalCents }
        return max(0, rows + adjustments.tipCents)
    }

    /// Whether the subtotal and total can be typed: only with at most one item row and no legacy tip rows.
    var isSubtotalEditable: Bool { itemRows.count <= 1 && counted.allSatisfy { $0.kind == .item } }

    // MARK: Edits

    /// Sets the single item row's price, creating the row if there is none. The rates stay, so tax follows.
    mutating func setSubtotal(_ cents: Int) {
        guard isSubtotalEditable else { return }
        setPrice(max(0, cents))
        apply()
    }

    /// Sets the tax `id` to `cents`, working out its rate from what it applies to. The subtotal stays.
    mutating func setTax(_ cents: Int, id: UUID) {
        guard let index = adjustments.firstIndex(where: { $0.id == id && $0.kind == .tax }) else { return }
        adjustments[index].amountCents = max(0, cents)
        apply(resolving: [id])
    }

    /// Adds a tax of nothing before the tip, so a surcharge printed after the tip isn't moved, and returns its ID.
    @discardableResult
    mutating func addTax() -> UUID {
        let tax = ReceiptAdjustment(kind: .tax)
        adjustments.insert(tax, at: adjustments.firstIndex { $0.kind == .tip } ?? adjustments.endIndex)
        return tax.id
    }

    /// Sets the tip to `cents`. A tip kept at zero keeps its place, so surcharges after it still apply to it.
    mutating func setTip(_ cents: Int) {
        let cents = max(0, cents)
        if let first = adjustments.firstIndex(where: { $0.kind == .tip }) {
            for index in adjustments.indices where adjustments[index].kind == .tip {
                adjustments[index].amountCents = index == first ? cents : 0
            }
        } else if cents > 0 {
            adjustments.append(ReceiptAdjustment(kind: .tip, amountCents: cents))
        } else {
            return
        }
        apply()
    }

    /// Finds the subtotal that, with the same rates and tip, comes to `cents`. A total below what a zero subtotal
    /// comes to leaves the subtotal at zero.
    mutating func setTotal(_ cents: Int) {
        guard isSubtotalEditable else { return }
        let target = max(0, cents)
        let start = self
        func total(_ price: Int) -> Int {
            var trial = start
            trial.setPrice(price)
            trial.apply()
            return trial.totalCents
        }
        var low = 0
        var high = max(target, 1)
        while total(high) < target, high < 1_000_000_000 { low = high; high *= 2 }
        // The smallest price whose total reaches the target; the total never falls as the price rises.
        while low < high {
            let middle = (low + high) / 2
            if total(middle) < target { low = middle + 1 } else { high = middle }
        }
        setPrice(low)
        apply()
        absorbRounding(towards: target)
    }

    // MARK: Helpers

    /// When rounding keeps the total a cent or two over `target`, takes the difference from the last rate-based
    /// adjustment, whose amount reaches the total one for one. Leaves everything as it is if that doesn't work.
    private mutating func absorbRounding(towards target: Int) {
        let excess = totalCents - target
        guard excess > 0, excess <= 5, let index = adjustments.lastIndex(where: { $0.kind != .tip }) else { return }
        var trial = self
        if trial.adjustments[index].kind == .discount {
            trial.adjustments[index].amountCents += excess
        } else {
            guard trial.adjustments[index].amountCents >= excess else { return }
            trial.adjustments[index].amountCents -= excess
        }
        trial.apply(resolving: [trial.adjustments[index].id])
        if trial.totalCents == target { self = trial }
    }

    /// Sets the price of the single item row, keeping its own discount where the price still covers it.
    private mutating func setPrice(_ cents: Int) {
        guard let index = items.firstIndex(where: { $0.isSelected && $0.kind == .item }) else {
            items.append(ReceiptItem(name: "", cents: cents, isSelected: true))
            return
        }
        items[index].cents = cents
        if items[index].localOffsetCents < 0 { items[index].localOffsetCents = max(items[index].localOffsetCents, -cents) }
    }

    private mutating func apply(resolving ids: Set<UUID> = []) {
        adjustments = items.applyAdjustments(adjustments, resolving: ids)
    }
}
