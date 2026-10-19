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
    @State private var isPickingDate = false
    @State private var internalSaveError: String?
    @State private var balancer = ContributionBalancer()
    @State private var isSubtotalFocused = false
    /// The tax, discount or surcharge field being edited, and a tax just added that shows until it's left.
    @State private var focusedAdjustmentID: UUID?
    @State private var revealedAdjustmentID: UUID?
    @State private var isTipFocused = false
    @State private var isAddingTip = false
    @State private var isTotalFocused = false
    @State private var amountEdit: AmountEdit?
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

    /// Amounts are only edited before saving: a saved expense saves just its name and date.
    private var canEditAmounts: Bool { isEditable && mode == .draft }

    private var amounts: ExpenseAmounts {
        ExpenseAmounts(items: itemsBinding.wrappedValue, adjustments: adjustmentsBinding.wrappedValue)
    }

    private enum AmountField: Hashable { case subtotal, adjustment(UUID), tip, total }

    /// The field being typed in, the amounts from before it was touched, and what it holds. Each keystroke is applied
    /// to those amounts, so a value passed through on the way (such as $0) doesn't change anything for good.
    private struct AmountEdit {
        let field: AmountField
        let base: ExpenseAmounts
        var typed: Int
    }

    private var focusedAmountField: AmountField? {
        if isSubtotalFocused { return .subtotal }
        if let focusedAdjustmentID { return .adjustment(focusedAdjustmentID) }
        if isTipFocused { return .tip }
        if isTotalFocused { return .total }
        return nil
    }

    /// Applies an edit of `field` to the items and adjustments, then sets the total they come to.
    private func editAmounts(_ field: AmountField, typed: Int, _ change: (inout ExpenseAmounts) -> Void) {
        guard canEditAmounts else { return }
        let base = amountEdit?.field == field ? amountEdit!.base : amounts
        amountEdit = AmountEdit(field: field, base: base, typed: typed)
        var edited = base
        change(&edited)
        if edited.items != itemsBinding.wrappedValue { itemsBinding.wrappedValue = edited.items }
        if edited.adjustments != adjustmentsBinding.wrappedValue { adjustmentsBinding.wrappedValue = edited.adjustments }
        totalBinding.wrappedValue = edited.totalCents
    }

    /// What `field` shows: what's being typed in it, otherwise its amount.
    private func shown(_ field: AmountField, _ cents: Int) -> Int {
        amountEdit?.field == field ? amountEdit!.typed : cents
    }

    private var subtotalBinding: Binding<Int> {
        Binding(
            get: { shown(.subtotal, amounts.subtotalCents) },
            set: { cents in editAmounts(.subtotal, typed: cents) { $0.setSubtotal(cents) } }
        )
    }

    private func adjustmentBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { shown(.adjustment(id), amounts.adjustments.first { $0.id == id }?.amountCents ?? 0) },
            set: { cents in editAmounts(.adjustment(id), typed: cents) { $0.setAdjustment(cents, id: id) } }
        )
    }

    private func adjustmentFocusBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { focusedAdjustmentID == id },
            set: { focused in
                if focused { focusedAdjustmentID = id } else if focusedAdjustmentID == id { focusedAdjustmentID = nil }
            }
        )
    }

    private var tipBinding: Binding<Int> {
        Binding(
            get: { shown(.tip, amounts.tipCents) },
            set: { cents in editAmounts(.tip, typed: cents) { $0.setTip(cents) } }
        )
    }

    private var editableTotalBinding: Binding<Int> {
        Binding(
            get: { shown(.total, totalBinding.wrappedValue) },
            set: { cents in editAmounts(.total, typed: cents) { $0.setTotal(cents) } }
        )
    }

    /// Taxes with an amount, plus one being added or edited.
    private var shownTaxes: [ReceiptAdjustment] {
        amounts.taxes.filter { $0.amountCents > 0 || $0.id == focusedAdjustmentID || $0.id == revealedAdjustmentID }
    }

    private var showsTip: Bool { amounts.tipCents > 0 || isTipFocused || isAddingTip }

    private var hasAdditiveAmounts: Bool {
        let lines = amounts
        return !shownTaxes.isEmpty || showsTip || lines.unlistedOffsetCents != 0
            || lines.otherAdjustments.contains { $0.amountCents != 0 }
    }

    private func addTax() {
        var id = amounts.taxes.first?.id
        if id == nil {
            var edited = amounts
            id = edited.addTax()
            adjustmentsBinding.wrappedValue = edited.adjustments
        }
        guard let id else { return }
        revealedAdjustmentID = id
        // The field has to exist before it can take focus.
        Task { @MainActor in focusedAdjustmentID = id }
    }

    private func addTip() {
        isAddingTip = true
        Task { @MainActor in isTipFocused = true }
    }

    private func signed(_ cents: Int) -> String {
        cents < 0 ? "−\((-cents).usd)" : cents.usd
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

    private var payerDateRow: some View {
        let payer = payerBinding.wrappedValue.map { store.person(for: $0) }
        return HStack(spacing: 6) {
            Text("Paid by")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Menu {
                Picker("Paid by", selection: payerBinding) {
                    ForEach(participants, id: \.self) { person in
                        Text(store.name(for: person)).tag(Optional(person))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let payer {
                        AvatarView(userID: payer.id, name: payer.name, etag: payer.avatarEtag, size: 22)
                    }
                    Text(payer?.firstName ?? "Choose")
                        .font(.body)
                    if isEditable {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .disabled(!isEditable)
            .accessibilityLabel("Paid by \(payer?.name ?? "")")
            Text("on")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            let dateText = Text(dateBinding.wrappedValue.formatted(date: .abbreviated, time: .omitted))
                .font(.body)
            if isEditable {
                Button {
                    isPickingDate = true
                } label: {
                    dateText
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Date of expense")
                .popover(isPresented: $isPickingDate) {
                    DatePicker("Date of expense", selection: dateBinding, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                        .frame(width: 320)
                        .presentationCompactAdaptation(.popover)
                }
            } else {
                dateText
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .allowsTightening(true)
        .frame(maxWidth: .infinity, alignment: .center)
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
                .frame(height: 36)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                payerDateRow
                    .frame(height: 36)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }

            Section {
                let lines = amounts
                let editsTotal = canEditAmounts && lines.isSubtotalEditable
                VStack(spacing: 3) {
                    if hasAdditiveAmounts {
                        HStack {
                            Text("Subtotal")
                            Spacer()
                            if editsTotal {
                                CentsField(title: "0.00", cents: subtotalBinding, isFocusedBinding: $isSubtotalFocused)
                                    .accessibilityLabel("Subtotal")
                            } else {
                                Text(lines.subtotalCents.usd)
                                    .accessibilityLabel("Subtotal")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editsTotal { isSubtotalFocused = true }
                        }

                        ForEach(shownTaxes) { tax in
                            HStack {
                                HStack(spacing: 4) {
                                    Text("Tax")
                                    if tax.rate > 0 {
                                        Text("(\(RateField.format(tax.rate))%)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if canEditAmounts {
                                    CentsField(title: "0.00", cents: adjustmentBinding(tax.id), isFocusedBinding: adjustmentFocusBinding(tax.id))
                                        .accessibilityLabel("Tax")
                                } else {
                                    Text(tax.amountCents.usd)
                                        .accessibilityLabel("Tax")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if canEditAmounts { focusedAdjustmentID = tax.id }
                            }
                        }

                        ForEach(lines.otherAdjustments) { adjustment in
                            if adjustment.amountCents != 0 || adjustment.id == focusedAdjustmentID {
                                HStack {
                                    Text(adjustment.kind.title)
                                    Spacer()
                                    if canEditAmounts {
                                        if adjustment.kind == .discount {
                                            Text("−").foregroundStyle(.secondary)
                                        }
                                        CentsField(title: "0.00", cents: adjustmentBinding(adjustment.id), isFocusedBinding: adjustmentFocusBinding(adjustment.id))
                                            .accessibilityLabel(adjustment.kind.title)
                                    } else {
                                        Text(signedAdjustment(adjustment))
                                            .accessibilityLabel(adjustment.kind.title)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if canEditAmounts { focusedAdjustmentID = adjustment.id }
                                }
                            }
                        }

                        if lines.unlistedOffsetCents != 0 {
                            HStack {
                                Text("Adjustments")
                                Spacer()
                                Text(signed(lines.unlistedOffsetCents))
                            }
                        }

                        if showsTip {
                            HStack {
                                Text("Tip")
                                Spacer()
                                if canEditAmounts {
                                    CentsField(title: "0.00", cents: tipBinding, isFocusedBinding: $isTipFocused)
                                        .accessibilityLabel("Tip")
                                } else {
                                    Text(lines.tipCents.usd)
                                        .accessibilityLabel("Tip")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if canEditAmounts { isTipFocused = true }
                            }
                        }

                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1.5)
                            .padding(.vertical, 2)
                    }

                    // Total
                    HStack {
                        if !hasAdditiveAmounts {
                            Text("Total")
                        }
                        Spacer()
                        if editsTotal {
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
                        if editsTotal { isTotalFocused = true }
                    }
                }
                .padding(.vertical, 3)
                .contextMenu {
                    if canEditAmounts {
                        if shownTaxes.isEmpty {
                            Button("Add tax", systemImage: "percent") { addTax() }
                        }
                        if !showsTip {
                            Button("Add tip", systemImage: "heart") { addTip() }
                        }
                    }
                }
                .onChange(of: focusedAmountField) { _, field in
                    if amountEdit?.field != field { amountEdit = nil }
                }
                .onChange(of: focusedAdjustmentID) { _, focused in
                    if focused == nil { revealedAdjustmentID = nil }
                }
                .onChange(of: isTipFocused) { _, focused in
                    if !focused { isAddingTip = false }
                }
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
    }
}
