import SwiftUI
import UIKit

/// The full expense review and editing component containing categorizer, naming, core controls,
/// and participant contribution sliders. Used during receipt capture and when routing from an existing expense.
struct ExpenseReviewEditorView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss

    private enum Mode { case draft, existing }
    private let mode: Mode

    @Binding private var externalCategory: ExpenseCategory?
    @Binding private var externalDescription: String
    @Binding private var externalTotal: Int
    @Binding private var externalPayer: UUID?
    @Binding private var externalPurchaseDate: Date
    @Binding private var externalShares: [UUID: Int]
    @Binding private var externalItems: [ReceiptItem]
    @Binding private var externalItemAssignments: [UUID: Set<UUID>]
    @Binding private var externalAdjustments: [ReceiptAdjustment]
    private let externalContributionDetents: [UUID: Int]

    @AppStorage(TipSplit.storageKey) private var tipSplit: TipSplit = .even
    @State private var internalCategory: ExpenseCategory?
    @State private var internalDescription: String = ""
    @State private var internalTotal: Int = 0
    @State private var internalPayer: UUID?
    @State private var internalPurchaseDate: Date = Date()
    @State private var internalShares: [UUID: Int] = [:]
    @State private var internalItems: [ReceiptItem] = []
    @State private var internalItemAssignments: [UUID: Set<UUID>] = [:]
    @State private var internalAdjustments: [ReceiptAdjustment] = []

    let participants: [UUID]
    let isEditable: Bool
    let showsToolbarSave: Bool
    let externalIsSaving: Bool
    let externalCanSave: Bool
    let externalOnSave: (() -> Void)?
    let onOpenAssignItems: (() -> Void)?
    let onPayerChanged: ((UUID?) -> Void)?

    @State private var internalIsSaving = false
    @State private var internalSaveError: String?
    @State private var balancer = ContributionBalancer()
    @State private var isSubtotalFocused = false
    @State private var isTaxFocused = false
    @State private var isTipFocused = false
    @State private var isTotalFocused = false
    let existingExpenseID: UUID?

    private var categoryBinding: Binding<ExpenseCategory?> {
        mode == .draft ? $externalCategory : $internalCategory
    }
    private var descriptionBinding: Binding<String> {
        mode == .draft ? $externalDescription : $internalDescription
    }
    private var totalBinding: Binding<Int> {
        mode == .draft ? $externalTotal : $internalTotal
    }
    private var payerBinding: Binding<UUID?> {
        mode == .draft ? $externalPayer : $internalPayer
    }
    private var dateBinding: Binding<Date> {
        mode == .draft ? $externalPurchaseDate : $internalPurchaseDate
    }
    private var sharesBinding: Binding<[UUID: Int]> {
        mode == .draft ? $externalShares : $internalShares
    }
    private var itemsBinding: Binding<[ReceiptItem]> {
        mode == .draft ? $externalItems : $internalItems
    }
    private var itemAssignmentsBinding: Binding<[UUID: Set<UUID>]> {
        mode == .draft ? $externalItemAssignments : $internalItemAssignments
    }
    private var adjustmentsBinding: Binding<[ReceiptAdjustment]> {
        mode == .draft ? $externalAdjustments : $internalAdjustments
    }


    private var isSaving: Bool {
        mode == .draft ? externalIsSaving : internalIsSaving
    }

    private var contributionDetents: [UUID: Int] {
        if mode == .draft { return externalContributionDetents }
        var ownedItems = itemsBinding.wrappedValue
        for index in ownedItems.indices {
            let existingOwners = ownedItems[index].ownerIDs
            ownedItems[index].ownerIDs = itemAssignmentsBinding.wrappedValue[ownedItems[index].id] ?? existingOwners
        }
        return (ownedItems + tipRows(for: ownedItems)).ownerShares(for: participants)
    }

    /// The tip as rows split the way Settings says, so shares from ownership include it.
    private func tipRows(for ownedItems: [ReceiptItem]) -> [ReceiptItem] {
        ownedItems.tipRows(adjustmentsBinding.wrappedValue.tipCents, among: Set(participants), split: tipSplit)
    }

    private var showsAssignmentSection: Bool {
        itemsBinding.wrappedValue.filter(\.isSelected).count > 1
    }

    private var allocationTotal: Int {
        participants.reduce(0) { $0 + (sharesBinding.wrappedValue[$1] ?? 0) }
    }

    private var canSave: Bool {
        if mode == .draft {
            return externalCanSave
        }
        guard isEditable else { return false }
        let name = descriptionBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty
    }

    private var subtotalCents: Int {
        let selectedItems = itemsBinding.wrappedValue.filter { $0.kind == .item && $0.isSelected }
        if selectedItems.isEmpty {
            return max(0, totalBinding.wrappedValue - taxCents - tipCents)
        }
        return selectedItems.reduce(0) { $0 + $1.netCents }
    }

    private var taxRate: Double? {
        adjustmentsBinding.wrappedValue.first(where: { $0.kind == .tax && $0.rate > 0 })?.rate
    }

    private var taxCents: Int {
        if let taxAdj = adjustmentsBinding.wrappedValue.first(where: { $0.kind == .tax }) {
            return taxAdj.amountCents
        }
        if adjustmentsBinding.wrappedValue.isEmpty, mode == .existing {
            let offset = itemsBinding.wrappedValue.filter(\.isSelected).reduce(0) { $0 + $1.globalOffsetCents }
            return max(0, offset)
        }
        return 0
    }

    private var tipCents: Int {
        adjustmentsBinding.wrappedValue.tipCents
    }

    private var otherAdjustments: [ReceiptAdjustment] {
        adjustmentsBinding.wrappedValue.filter { $0.kind != .tax && $0.kind != .tip }
    }

    private var itemDiscountTotal: Int {
        itemsBinding.wrappedValue.filter(\.isSelected).reduce(0) { $0 + $1.localOffsetCents }
    }

    private var subtotalBinding: Binding<Int> {
        Binding(
            get: { subtotalCents },
            set: { newSubtotal in
                guard isEditable else { return }
                let cents = max(0, newSubtotal)
                if itemsBinding.wrappedValue.isEmpty {
                    itemsBinding.wrappedValue = [ReceiptItem(name: "", cents: cents, isSelected: true)]
                } else if itemsBinding.wrappedValue.count == 1 {
                    itemsBinding.wrappedValue[0].cents = cents
                    itemsBinding.wrappedValue[0].localOffsetCents = 0
                } else {
                    let oldSubtotal = subtotalCents
                    if oldSubtotal > 0 {
                        var accumulated = 0
                        for i in 0..<itemsBinding.wrappedValue.count - 1 {
                            let proportion = Double(itemsBinding.wrappedValue[i].cents) / Double(oldSubtotal)
                            let newCents = Int((Double(cents) * proportion).rounded())
                            itemsBinding.wrappedValue[i].cents = newCents
                            accumulated += newCents
                        }
                        itemsBinding.wrappedValue[itemsBinding.wrappedValue.count - 1].cents = max(0, cents - accumulated)
                    } else {
                        let share = cents / itemsBinding.wrappedValue.count
                        let rem = cents % itemsBinding.wrappedValue.count
                        for i in 0..<itemsBinding.wrappedValue.count {
                            itemsBinding.wrappedValue[i].cents = share + (i < rem ? 1 : 0)
                        }
                    }
                }
                recalculateTotal()
            }
        )
    }

    private var taxBinding: Binding<Int> {
        Binding(
            get: { taxCents },
            set: { newTax in
                guard isEditable else { return }
                let cents = max(0, newTax)
                if let idx = adjustmentsBinding.wrappedValue.firstIndex(where: { $0.kind == .tax }) {
                    if cents == 0 {
                        adjustmentsBinding.wrappedValue.remove(at: idx)
                    } else {
                        adjustmentsBinding.wrappedValue[idx].amountCents = cents
                        adjustmentsBinding.wrappedValue[idx].rate = 0
                    }
                } else if cents > 0 {
                    if let tipIdx = adjustmentsBinding.wrappedValue.firstIndex(where: { $0.kind == .tip }) {
                        adjustmentsBinding.wrappedValue.insert(ReceiptAdjustment(kind: .tax, amountCents: cents), at: tipIdx)
                    } else {
                        adjustmentsBinding.wrappedValue.append(ReceiptAdjustment(kind: .tax, amountCents: cents))
                    }
                }
                recalculateTotal()
            }
        )
    }

    private var tipBinding: Binding<Int> {
        Binding(
            get: { tipCents },
            set: { newTip in
                guard isEditable else { return }
                let cents = max(0, newTip)
                if let idx = adjustmentsBinding.wrappedValue.firstIndex(where: { $0.kind == .tip }) {
                    if cents == 0 {
                        adjustmentsBinding.wrappedValue.remove(at: idx)
                    } else {
                        adjustmentsBinding.wrappedValue[idx].amountCents = cents
                    }
                } else if cents > 0 {
                    adjustmentsBinding.wrappedValue.append(ReceiptAdjustment(kind: .tip, amountCents: cents))
                }
                recalculateTotal()
            }
        )
    }

    private var editableTotalBinding: Binding<Int> {
        Binding(
            get: { totalBinding.wrappedValue },
            set: { newTotal in
                guard isEditable else { return }
                let cents = max(0, newTotal)
                let adjNet = adjustmentsBinding.wrappedValue.reduce(0) { sum, adj in
                    sum + (adj.kind == .discount ? -adj.amountCents : adj.amountCents)
                }
                let targetSubtotal = max(0, cents - adjNet)
                if itemsBinding.wrappedValue.isEmpty {
                    itemsBinding.wrappedValue = [ReceiptItem(name: "", cents: targetSubtotal, isSelected: true)]
                } else if itemsBinding.wrappedValue.count == 1 {
                    itemsBinding.wrappedValue[0].cents = targetSubtotal
                    itemsBinding.wrappedValue[0].localOffsetCents = 0
                } else {
                    let oldSubtotal = subtotalCents
                    if oldSubtotal > 0 {
                        var accumulated = 0
                        for i in 0..<itemsBinding.wrappedValue.count - 1 {
                            let proportion = Double(itemsBinding.wrappedValue[i].cents) / Double(oldSubtotal)
                            let newCents = Int((Double(targetSubtotal) * proportion).rounded())
                            itemsBinding.wrappedValue[i].cents = newCents
                            accumulated += newCents
                        }
                        itemsBinding.wrappedValue[itemsBinding.wrappedValue.count - 1].cents = max(0, targetSubtotal - accumulated)
                    } else {
                        let share = targetSubtotal / itemsBinding.wrappedValue.count
                        let rem = targetSubtotal % itemsBinding.wrappedValue.count
                        for i in 0..<itemsBinding.wrappedValue.count {
                            itemsBinding.wrappedValue[i].cents = share + (i < rem ? 1 : 0)
                        }
                    }
                }
                recalculateTotal()
            }
        )
    }

    private var hasAdditiveAmounts: Bool {
        (taxCents > 0 || isTaxFocused) ||
        (tipCents > 0 || isTipFocused) ||
        itemDiscountTotal != 0 ||
        otherAdjustments.contains { $0.amountCents != 0 }
    }

    private func recalculateTotal() {
        var items = itemsBinding.wrappedValue
        let applied = items.applyAdjustments(adjustmentsBinding.wrappedValue)
        itemsBinding.wrappedValue = items
        adjustmentsBinding.wrappedValue = applied
        let newTotal = items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents } + applied.tipCents
        totalBinding.wrappedValue = max(0, newTotal)
        if items.count <= 1 {
            guard newTotal > 0, !participants.isEmpty else { return }
            let base = newTotal / participants.count
            let remainder = newTotal % participants.count
            sharesBinding.wrappedValue = Dictionary(uniqueKeysWithValues: participants.enumerated().map { index, person in
                (person, base + (index < remainder ? 1 : 0))
            })
            balancer = ContributionBalancer()
        } else {
            recomputeAssignedShares()
        }
    }

    private func signedAdjustment(_ adjustment: ReceiptAdjustment) -> String {
        let amount = adjustment.amountCents
        return adjustment.kind == .discount ? "−\(amount.usd)" : amount.usd
    }

    /// Initializer for draft mode during new expense capture review.
    init(
        category: Binding<ExpenseCategory?>,
        description: Binding<String>,
        total: Binding<Int>,
        payer: Binding<UUID?>,
        purchaseDate: Binding<Date>,
        shares: Binding<[UUID: Int]>,
        adjustments: Binding<[ReceiptAdjustment]> = .constant([]),
        contributionDetents: [UUID: Int],
        participants: [UUID],
        items: Binding<[ReceiptItem]> = .constant([]),
        itemAssignments: Binding<[UUID: Set<UUID>]> = .constant([:]),
        isEditable: Bool = true,
        showsToolbarSave: Bool = false,
        isSaving: Bool = false,
        canSave: Bool = true,
        onSave: @escaping () -> Void,
        onOpenAssignItems: (() -> Void)? = nil,
        onPayerChanged: ((UUID?) -> Void)? = nil
    ) {
        self.mode = .draft
        self._externalCategory = category
        self._externalDescription = description
        self._externalTotal = total
        self._externalPayer = payer
        self._externalPurchaseDate = purchaseDate
        self._externalShares = shares
        self._externalItems = items
        self._externalItemAssignments = itemAssignments
        self._externalAdjustments = adjustments
        self.externalContributionDetents = contributionDetents
        self.participants = participants
        self.isEditable = isEditable
        self.showsToolbarSave = showsToolbarSave
        self.externalIsSaving = isSaving
        self.externalCanSave = canSave
        self.externalOnSave = onSave
        self.onOpenAssignItems = onOpenAssignItems
        self.onPayerChanged = onPayerChanged
        self.existingExpenseID = nil
    }

    /// Initializer for existing expense mode (e.g. routed from ExpenseDetailView).
    init(expense: Expense, isEditable: Bool = true) {
        self.mode = .existing
        self._externalCategory = .constant(nil)
        self._externalDescription = .constant("")
        self._externalTotal = .constant(0)
        self._externalPayer = .constant(nil)
        self._externalPurchaseDate = .constant(Date())
        self._externalShares = .constant([:])
        self._externalItems = .constant([])
        self._externalItemAssignments = .constant([:])
        self._externalAdjustments = .constant([])
        self.externalContributionDetents = [:]

        self._internalCategory = State(initialValue: expense.category)
        self._internalDescription = State(initialValue: expense.description)
        self._internalTotal = State(initialValue: expense.total)
        self._internalPayer = State(initialValue: expense.payer)
        self._internalPurchaseDate = State(initialValue: expense.transactionDate)
        self._internalShares = State(initialValue: expense.shares)
        self._internalItems = State(initialValue: expense.items)
        self._internalItemAssignments = State(initialValue: Dictionary(uniqueKeysWithValues: expense.items.map { ($0.id, $0.ownerIDs) }))
        self._internalAdjustments = State(initialValue: expense.adjustments)

        self.participants = expense.participants
        self.isEditable = isEditable
        self.showsToolbarSave = true
        self.externalIsSaving = false
        self.externalCanSave = true
        self.externalOnSave = nil
        self.onOpenAssignItems = nil
        self.onPayerChanged = nil
        self.existingExpenseID = expense.id
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Menu {
                        Button("None", systemImage: "circle.dashed") { categoryBinding.wrappedValue = nil }
                        ForEach(ExpenseCategory.allCases) { value in
                            Button(value.title, systemImage: value.symbol) { categoryBinding.wrappedValue = value }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: categoryBinding.wrappedValue?.symbol ?? "circle.dashed")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 46)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(categoryBinding.wrappedValue?.title ?? "Category")
                    .disabled(!isEditable)

                    TextField("What was this for?", text: descriptionBinding).submitLabel(.done)
                        .disabled(!isEditable)
                }
            }

            Section {
                VStack(spacing: 3) {
                    if hasAdditiveAmounts {
                        // Subtotal
                        HStack {
                            Spacer()
                            if isEditable {
                                CentsField(title: "0.00", cents: subtotalBinding, isFocusedBinding: $isSubtotalFocused)
                                    .accessibilityLabel("Subtotal")
                            } else {
                                Text(subtotalCents.usd)
                                    .accessibilityLabel("Subtotal")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isEditable { isSubtotalFocused = true }
                        }

                        // Tax
                        if taxCents > 0 || isTaxFocused {
                            HStack {
                                HStack(spacing: 4) {
                                    Text("Tax")
                                    if let taxRate, taxRate > 0 {
                                        Text("(\(RateField.format(taxRate))%)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isEditable {
                                    CentsField(title: "0.00", cents: taxBinding, isFocusedBinding: $isTaxFocused)
                                        .accessibilityLabel("Tax")
                                } else {
                                    Text(taxCents.usd)
                                        .accessibilityLabel("Tax")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isEditable { isTaxFocused = true }
                            }
                        }

                        // Tip
                        if tipCents > 0 || isTipFocused {
                            HStack {
                                Text("Tip")
                                Spacer()
                                if isEditable {
                                    CentsField(title: "0.00", cents: tipBinding, isFocusedBinding: $isTipFocused)
                                        .accessibilityLabel("Tip")
                                } else {
                                    Text(tipCents.usd)
                                        .accessibilityLabel("Tip")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isEditable { isTipFocused = true }
                            }
                        }

                        // Item discounts
                        if itemDiscountTotal != 0 {
                            HStack {
                                Text("Item discounts")
                                Spacer()
                                Text(itemDiscountTotal < 0 ? "−\((-itemDiscountTotal).usd)" : itemDiscountTotal.usd)
                            }
                        }

                        // Other adjustments
                        ForEach(otherAdjustments) { adjustment in
                            if adjustment.amountCents != 0 {
                                HStack {
                                    Text(adjustment.kind.title)
                                    Spacer()
                                    Text(signedAdjustment(adjustment))
                                }
                            }
                        }

                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1.5)
                            .padding(.vertical, 2)
                    }

                    // Total
                    HStack {
                        Spacer()
                        if isEditable {
                            CentsField(title: "0.00", cents: editableTotalBinding, isFocusedBinding: $isTotalFocused, fontWeight: .semibold)
                                .accessibilityLabel("Total")
                        } else {
                            Text(totalBinding.wrappedValue.usd)
                                .fontWeight(.semibold)
                                .accessibilityLabel("Total")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditable { isTotalFocused = true }
                    }
                }
                .padding(.vertical, 3)
                .contextMenu {
                    if isEditable {
                        if taxCents == 0 {
                            Button("Add tax", systemImage: "percent") {
                                taxBinding.wrappedValue = 1
                                isTaxFocused = true
                            }
                        }
                        if tipCents == 0 {
                            Button("Add tip", systemImage: "heart") {
                                tipBinding.wrappedValue = 1
                                isTipFocused = true
                            }
                        }
                    }
                }
            }

            Section {
                Picker("Paid by", selection: payerBinding) {
                    ForEach(participants, id: \.self) { person in
                        Text(store.name(for: person)).tag(Optional(person))
                    }
                }
                .disabled(!isEditable)

                LabeledContent("Date of expense") {
                    DatePicker("", selection: dateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .frame(maxHeight: 32)
                }
                .disabled(!isEditable)
            }

            Section {
                ForEach(participants, id: \.self) { person in
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(store.name(for: person))
                            Spacer()
                            ContributionAmountField(
                                name: store.name(for: person),
                                cents: shareBinding(for: person),
                                total: totalBinding.wrappedValue
                            )
                        }
                        if participants.count > 1 {
                            ContributionSlider(
                                name: store.name(for: person),
                                cents: shareBinding(for: person),
                                total: totalBinding.wrappedValue,
                                detent: contributionDetents[person] ?? 0
                            )
                            .disabled(!isEditable)
                        }
                    }
                }

                if showsAssignmentSection {
                    if let onOpenAssignItems {
                        Button {
                            onOpenAssignItems()
                        } label: {
                            HStack {
                                Text("Assign items")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    } else {
                        NavigationLink {
                            AssignItemsView(
                                items: itemsBinding,
                                itemAssignments: itemAssignmentsBinding,
                                participants: participants,
                                isEditable: isEditable,
                                onAssignmentsChanged: {
                                    recomputeAssignedShares()
                                },
                                onItemsChanged: { recomputeAssignedShares() }
                            )
                        } label: {
                            Text("Assign items")
                        }
                        .disabled(!isEditable)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(12)
        .scrollIndicators(.hidden)
        .navigationTitle("Review expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsToolbarSave {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        handleSave()
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
        .alert("Couldn’t save", isPresented: Binding(
            get: { internalSaveError != nil },
            set: { if !$0 { internalSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(internalSaveError ?? "")
        }
        .onChange(of: totalBinding.wrappedValue) { oldTotal, newTotal in
            guard itemsBinding.wrappedValue.count <= 1, newTotal > 0, !participants.isEmpty, newTotal != oldTotal else { return }
            let base = newTotal / participants.count
            let remainder = newTotal % participants.count
            sharesBinding.wrappedValue = Dictionary(uniqueKeysWithValues: participants.enumerated().map { index, person in
                (person, base + (index < remainder ? 1 : 0))
            })
            balancer = ContributionBalancer()
        }
        .onChange(of: payerBinding.wrappedValue) { _, newPayer in
            onPayerChanged?(newPayer)
        }
    }

    private func shareBinding(for person: UUID) -> Binding<Int> {
        Binding(
            get: { sharesBinding.wrappedValue[person] ?? 0 },
            set: { cents in
                guard isEditable else { return }
                sharesBinding.wrappedValue = balancer.set(
                    person,
                    to: cents,
                    in: sharesBinding.wrappedValue,
                    total: totalBinding.wrappedValue,
                    people: participants
                )
            }
        )
    }

    private func handleSave() {
        if mode == .draft {
            externalOnSave?()
        } else if let expenseID = existingExpenseID {
            Task {
                internalIsSaving = true
                do {
                    let token = try await authentication.accessToken()
                    try await store.updateExpense(
                        expenseID,
                        description: descriptionBinding.wrappedValue,
                        transactionDate: dateBinding.wrappedValue,
                        accessToken: token
                    )
                    dismiss()
                } catch {
                    internalSaveError = error.localizedDescription
                }
                internalIsSaving = false
            }
        }
    }

    private func recomputeAssignedShares() {
        guard !participants.isEmpty else { return }
        var ownedItems = itemsBinding.wrappedValue
        for index in ownedItems.indices {
            ownedItems[index].ownerIDs = itemAssignmentsBinding.wrappedValue[ownedItems[index].id, default: []]
        }
        sharesBinding.wrappedValue = (ownedItems + tipRows(for: ownedItems)).ownerShares(for: participants)
        let newTotal = itemsBinding.wrappedValue.filter {
            !(itemAssignmentsBinding.wrappedValue[$0.id]?.isEmpty ?? true)
        }.reduce(0) { $0 + $1.totalCents } + adjustmentsBinding.wrappedValue.tipCents
        if newTotal > 0 {
            totalBinding.wrappedValue = newTotal
        }
    }
}
