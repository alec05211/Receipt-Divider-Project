import Foundation

/// The amounts final review shows (subtotal, taxes, discounts, surcharges, tip, total) and what editing one of them
/// changes. Items and adjustments are the only source of truth; every line, and the total, is derived from them, so
///
/// `subtotal + taxes + surcharges − discounts + tip = total`
///
/// - Every line holds the dollar amount it shows. Taxes, discounts and surcharges keep their amounts when other lines
///   change; their rates are worked out from those amounts, so they're spread over the rows they apply to.
/// - Editing the subtotal, a tax, a discount, a surcharge or the tip changes the total by the same amount.
/// - Editing the total changes the tip, which can't go below zero. Below that, a single-amount expense's subtotal makes
///   up the rest (down to zero); an itemized receipt's total stays at its minimum.
/// - With more than one item row, the subtotal is the items' sum and isn't editable; nothing rewrites item prices.
/// - An adjustment with nothing to apply to comes to zero, and a discount can't exceed what it applies to.
struct ExpenseAmounts: Equatable {
    private(set) var items: [ReceiptItem]
    private(set) var adjustments: [ReceiptAdjustment]

    /// Spreads `adjustments` over `items` by their amounts. Without adjustments the rows are kept as they are, since
    /// expenses saved before adjustments were recorded hold them only as global offsets.
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

    /// The counted item rows' prices after their own discounts.
    var subtotalCents: Int { itemRows.reduce(0) { $0 + $1.netCents } }
    var taxes: [ReceiptAdjustment] { adjustments.filter { $0.kind == .tax } }
    var taxCents: Int { taxes.reduce(0) { $0 + $1.amountCents } }
    /// Receipt-wide discounts and surcharges, in receipt order.
    var otherAdjustments: [ReceiptAdjustment] { adjustments.filter { $0.kind == .discount || $0.kind == .surcharge } }
    /// The tip as entered. Any surcharge on it is part of that surcharge's line.
    var tipCents: Int {
        adjustments.filter { $0.kind == .tip }.reduce(0) { $0 + $1.amountCents } + legacyTipRows.reduce(0) { $0 + $1.totalCents }
    }
    /// Receipt-wide offsets on expenses saved before adjustments were recorded, where nothing else lists them.
    var unlistedOffsetCents: Int { adjustments.isEmpty ? itemRows.reduce(0) { $0 + $1.globalOffsetCents } : 0 }

    var totalCents: Int {
        let rows = itemRows.reduce(0) { $0 + $1.totalCents } + legacyTipRows.reduce(0) { $0 + $1.totalCents }
        return max(0, rows + adjustments.tipCents)
    }

    /// The total with no tip: the least the total can be without lowering anything else.
    var minimumTotalCents: Int { totalCents - tipCents }

    /// Whether the subtotal can be typed: only for a single-amount expense, with at most one item row.
    var isSubtotalEditable: Bool { itemRows.count <= 1 && counted.allSatisfy { $0.kind == .item } }

    // MARK: Edits

    /// Sets the single item row's price, creating the row if there is none. The total follows.
    mutating func setSubtotal(_ cents: Int) {
        guard isSubtotalEditable else { return }
        let cents = max(0, cents)
        if let index = items.firstIndex(where: { $0.isSelected && $0.kind == .item }) {
            items[index].cents = cents
            items[index].localOffsetCents = 0
        } else {
            items.append(ReceiptItem(name: "", cents: cents, isSelected: true))
        }
        apply()
    }

    /// Sets the tax, discount or surcharge `id` to `cents`. The total follows.
    mutating func setAdjustment(_ cents: Int, id: UUID) {
        guard let index = adjustments.firstIndex(where: { $0.id == id && $0.kind != .tip }) else { return }
        adjustments[index].amountCents = max(0, cents)
        apply()
    }

    /// Adds a tax of nothing before the tip, so a surcharge printed after the tip isn't moved, and returns its ID.
    @discardableResult
    mutating func addTax() -> UUID {
        let tax = ReceiptAdjustment(kind: .tax)
        adjustments.insert(tax, at: adjustments.firstIndex { $0.kind == .tip } ?? adjustments.endIndex)
        return tax.id
    }

    /// Sets the tip to `cents`. The total follows. A tip kept at zero keeps its place, so surcharges after it would
    /// still apply to it.
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

    /// Makes the total `cents` by changing the tip. Below the minimum total the tip is zero, and a single-amount
    /// expense's subtotal makes up the rest, down to zero; an itemized receipt stays at its minimum.
    mutating func setTotal(_ cents: Int) {
        let target = max(0, cents)
        let minimum = minimumTotalCents
        guard legacyTipRows.isEmpty else { return }
        if target >= minimum {
            setTip(target - minimum)
            return
        }
        setTip(0)
        if isSubtotalEditable { setSubtotal(subtotalCents - (minimum - target)) }
    }

    /// Spreads every adjustment by its amount: each rate is worked out from the amount and what it applies to.
    private mutating func apply() {
        adjustments = items.applyAdjustments(adjustments, resolving: Set(adjustments.map(\.id)))
    }
}
