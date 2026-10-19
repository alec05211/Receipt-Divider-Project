import Foundation

/// The amounts final review shows (subtotal, discounts, taxes, surcharges, tip, total), which of them are shown, and
/// what editing one changes. Items and adjustments are the only source of truth.
///
/// - Every component (the subtotal, each discount, tax and surcharge, and the tip) holds exactly the dollars typed in it.
///   Editing one never changes another: taxes and surcharges don't follow a rate.
/// - The total is the only computed amount: `subtotal + taxes + surcharges + tip − discounts`, always.
/// - The total can be typed only when it's the only amount shown on a single-amount expense; it then sets the subtotal,
///   so adding a component afterwards turns that total into the subtotal.
/// - The subtotal can be typed only with at most one item row (it sets that row's price). With more, it's the items'
///   sum and is edited through the items.
/// - A component at $0 isn't shown unless it's being edited, and can be added again.
/// - A discount can't exceed what it applies to.
struct ExpenseAmounts: Equatable {
    private(set) var items: [ReceiptItem]
    private(set) var adjustments: [ReceiptAdjustment]

    /// A line that can be edited.
    enum Field: Hashable { case subtotal, adjustment(UUID), tip, total }

    /// A line shown above the total. `field` is nil for one that can't be edited.
    struct Line: Identifiable, Equatable {
        let id: String
        let field: Field?
        let title: String
        /// The amount as typed; a discount is subtracted.
        let cents: Int
        let kind: ReceiptAdjustment.Kind?
        /// For a tax, the fraction of what it applies to, worked out from its amount.
        var rate: Double = 0
    }

    /// What the press-and-hold menu on the amounts offers.
    enum MenuItem: Hashable, Identifiable {
        case edit(Field, title: String)
        case editItems
        case add(ReceiptAdjustment.Kind)

        var id: Self { self }
        var title: String {
            switch self {
            case let .edit(_, title): title
            case .editItems: "Edit items"
            case let .add(kind): "Add \(kind.title.lowercased())"
            }
        }
    }

    /// Spreads `adjustments` over `items` by their amounts. Without adjustments the rows are kept as they are, since
    /// expenses saved before adjustments were recorded hold them only as global offsets.
    init(items: [ReceiptItem], adjustments: [ReceiptAdjustment]) {
        self.items = items
        self.adjustments = adjustments
        if !adjustments.isEmpty { distribute() }
    }

    // MARK: Amounts

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
    var discounts: [ReceiptAdjustment] { adjustments.filter { $0.kind == .discount } }
    var surcharges: [ReceiptAdjustment] { adjustments.filter { $0.kind == .surcharge } }
    /// The tip as entered. Any surcharge on it is part of that surcharge's line.
    var tipCents: Int {
        adjustments.filter { $0.kind == .tip }.reduce(0) { $0 + $1.amountCents } + legacyTipRows.reduce(0) { $0 + $1.totalCents }
    }
    /// Receipt-wide offsets on expenses saved before adjustments were recorded, where nothing else lists them.
    var unlistedOffsetCents: Int { adjustments.isEmpty ? itemRows.reduce(0) { $0 + $1.globalOffsetCents } : 0 }

    /// subtotal + taxes + surcharges + tip − discounts.
    var totalCents: Int {
        let discounts = discounts.reduce(0) { $0 + $1.amountCents }
        let surcharges = surcharges.reduce(0) { $0 + $1.amountCents }
        return max(0, subtotalCents + taxCents + surcharges + tipCents - discounts + unlistedOffsetCents)
    }

    /// Whether the subtotal can be typed: only for a single-amount expense, with at most one item row.
    var isSubtotalEditable: Bool { itemRows.count <= 1 && counted.allSatisfy { $0.kind == .item } }

    /// What `field` holds.
    func cents(of field: Field) -> Int {
        switch field {
        case .subtotal: subtotalCents
        case let .adjustment(id): adjustments.first { $0.id == id }?.amountCents ?? 0
        case .tip: tipCents
        case .total: totalCents
        }
    }

    /// The kind of adjustment `field` is, if it is one.
    func kind(of field: Field) -> ReceiptAdjustment.Kind? {
        switch field {
        case let .adjustment(id): adjustments.first { $0.id == id }?.kind
        case .tip: .tip
        case .subtotal, .total: nil
        }
    }

    // MARK: What's shown

    /// The lines shown above the total, top to bottom: subtotal, discounts, taxes, surcharges, then the tip. A line
    /// with no amount shows only while it's `editing` or its id is in `kept` (the lines shown when editing began, so the
    /// layout holds still while typing passes through $0). The subtotal shows whenever anything else does. Empty when
    /// the total is the only amount.
    func lines(editing: Field? = nil, keeping kept: Set<String> = []) -> [Line] {
        func shows(_ adjustment: ReceiptAdjustment) -> Bool {
            adjustment.amountCents != 0 || editing == .adjustment(adjustment.id) || kept.contains(adjustment.id.uuidString)
        }
        func line(_ adjustment: ReceiptAdjustment) -> Line {
            Line(id: adjustment.id.uuidString, field: .adjustment(adjustment.id), title: adjustment.kind.title,
                 cents: adjustment.amountCents, kind: adjustment.kind, rate: adjustment.rate)
        }
        var lines = (discounts.filter(shows) + taxes.filter(shows) + surcharges.filter(shows)).map(line)
        if unlistedOffsetCents != 0 {
            lines.append(Line(id: "unlisted", field: nil, title: "Adjustments", cents: unlistedOffsetCents, kind: nil))
        }
        if tipCents != 0 || editing == .tip || kept.contains("tip") {
            lines.append(Line(id: "tip", field: .tip, title: "Tip", cents: tipCents, kind: .tip))
        }
        guard !lines.isEmpty else { return [] }
        return [Line(id: "subtotal", field: .subtotal, title: "Subtotal", cents: subtotalCents, kind: nil)] + lines
    }

    /// Whether the total is the only amount shown, so it can be typed (on a single-amount expense).
    func isTotalOnly(editing: Field? = nil) -> Bool { lines(editing: editing).isEmpty }

    /// Edits for every shown line, top to bottom, then additions for the kinds not shown. An itemized receipt offers
    /// Edit items instead of editing its subtotal, or its total when that's the only amount.
    func menu(editing: Field? = nil, keeping kept: Set<String> = []) -> [MenuItem] {
        let shown = lines(editing: editing, keeping: kept)
        var menu: [MenuItem] = []
        if shown.isEmpty {
            menu.append(isSubtotalEditable ? .edit(.total, title: "Edit total") : .editItems)
        }
        for line in shown {
            guard let field = line.field else { continue }
            if field == .subtotal {
                menu.append(isSubtotalEditable ? .edit(.subtotal, title: "Edit subtotal") : .editItems)
                continue
            }
            var title = "Edit \(line.title.lowercased())"
            // Two lines of one kind are told apart by their amounts.
            if shown.filter({ $0.kind == line.kind }).count > 1 { title += " (\(line.cents.usd))" }
            menu.append(.edit(field, title: title))
        }
        let shownKinds = Set(shown.compactMap(\.kind))
        for kind in [ReceiptAdjustment.Kind.tax, .tip, .discount, .surcharge] where !shownKinds.contains(kind) {
            menu.append(.add(kind))
        }
        return menu
    }

    // MARK: Edits

    /// Sets `field` to `cents`. Nothing else changes except the total.
    mutating func set(_ field: Field, to cents: Int) {
        switch field {
        case .subtotal: setSubtotal(cents)
        case let .adjustment(id): setAdjustment(cents, id: id)
        case .tip: setTip(cents)
        case .total: setTotal(cents)
        }
    }

    /// Sets the single item row's price, creating the row if there is none.
    mutating func setSubtotal(_ cents: Int) {
        guard isSubtotalEditable else { return }
        let cents = max(0, cents)
        if let index = items.firstIndex(where: { $0.isSelected && $0.kind == .item }) {
            items[index].cents = cents
            items[index].localOffsetCents = 0
        } else {
            items.append(ReceiptItem(name: "", cents: cents, isSelected: true))
        }
        distribute()
    }

    /// Sets the discount, tax or surcharge `id` to `cents`. A discount can't exceed what it applies to.
    mutating func setAdjustment(_ cents: Int, id: UUID) {
        guard let index = adjustments.firstIndex(where: { $0.id == id && $0.kind != .tip }) else { return }
        adjustments[index].amountCents = max(0, cents)
        distribute()
    }

    /// Sets the tip to `cents`. A tip kept at zero keeps its place, so surcharges after it would still apply to it. Tip
    /// rows from an older expense become the tip adjustment.
    mutating func setTip(_ cents: Int) {
        let cents = max(0, cents)
        if let first = adjustments.firstIndex(where: { $0.kind == .tip }) {
            for index in adjustments.indices where adjustments[index].kind == .tip {
                adjustments[index].amountCents = index == first ? cents : 0
            }
        } else {
            for index in items.indices where items[index].kind == .tip { items[index].isSelected = false }
            adjustments.append(ReceiptAdjustment(kind: .tip, amountCents: cents))
            ensureItemRow()
        }
        distribute()
    }

    /// Sets the total when it's the only amount on a single-amount expense: it is then the subtotal.
    mutating func setTotal(_ cents: Int) {
        guard isTotalOnly(), isSubtotalEditable else { return }
        setSubtotal(cents)
    }

    /// Adds a line of `kind` at $0 and returns its field. One already there at $0 is reused, keeping its place. A new
    /// discount goes first, a new tax or surcharge before the tip, and a new tip last.
    @discardableResult
    mutating func add(_ kind: ReceiptAdjustment.Kind) -> Field {
        ensureItemRow()
        if kind == .tip {
            if !adjustments.contains(where: { $0.kind == .tip }) { setTip(0) }
            return .tip
        }
        if let existing = adjustments.first(where: { $0.kind == kind && $0.amountCents == 0 }) {
            return .adjustment(existing.id)
        }
        let adjustment = ReceiptAdjustment(kind: kind)
        let index = kind == .discount ? 0 : adjustments.firstIndex { $0.kind == .tip } ?? adjustments.endIndex
        adjustments.insert(adjustment, at: index)
        distribute()
        return .adjustment(adjustment.id)
    }

    /// Adjustments need an item row to be spread over.
    private mutating func ensureItemRow() {
        if !items.contains(where: { $0.isSelected && $0.kind == .item }) {
            items.append(ReceiptItem(name: "", cents: 0, isSelected: true))
        }
    }

    /// Spreads every adjustment over the counted rows without changing its amount.
    private mutating func distribute() {
        let indices = items.indices.filter { items[$0].isSelected }
        var rows = indices.map { items[$0] }
        adjustments = rows.distributeAdjustments(adjustments)
        for (index, row) in zip(indices, rows) { items[index] = row }
    }
}
