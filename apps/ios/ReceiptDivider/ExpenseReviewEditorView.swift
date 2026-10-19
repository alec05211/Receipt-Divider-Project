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
    /// The amount line chosen from the press-and-hold menu, shown as a field until editing ends, and whether that field
    /// has focus.
    @State private var editingField: ExpenseAmounts.Field?
    @State private var focusedField: ExpenseAmounts.Field?
    @State private var amountEdit: AmountEdit?
    @State private var isShowingAssignItems = false
    /// On a saved expense, Assign items' confirmation, which fills unassigned rows to the payer; Back restores them.
    @State private var confirmation = AssignmentConfirmation()
    /// On a saved expense, whether its amounts or contributions were changed, so saving sends them.
    @State private var amountsEdited = false
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
        return (ownedItems + tipRows(for: ownedItems)).ownerShares(for: participants)
    }

    /// The rows with their owners from Assign Items and adjustments spread over them.
    private var ownedItems: [ReceiptItem] {
        amounts.items.map { item in
            var item = item
            item.ownerIDs = itemAssignmentsBinding.wrappedValue[item.id] ?? item.ownerIDs
            return item
        }
    }

    /// Who owns a row for moving contributions; nobody means everyone.
    private func owners(of item: ReceiptItem) -> Set<UUID> {
        (itemAssignmentsBinding.wrappedValue[item.id] ?? item.ownerIDs).intersection(participants)
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
        return !name.isEmpty && (!amountsEdited || allocationTotal == totalBinding.wrappedValue)
    }

    /// Before saving, and on a saved expense for its payer or creator.
    private var canEditAmounts: Bool { isEditable }

    private var amounts: ExpenseAmounts {
        ExpenseAmounts(items: itemsBinding.wrappedValue, adjustments: adjustmentsBinding.wrappedValue)
    }

    /// The field being typed in, the amounts and contributions from before it was touched, and what it holds. Each
    /// keystroke is applied to those, so a value passed through on the way (such as $0) doesn't change anything for good.
    private struct AmountEdit {
        let field: ExpenseAmounts.Field
        let base: ExpenseAmounts
        let baseShares: [UUID: Int]
        var typed: Int
    }

    /// Sets `field` to `typed`, then the total, then moves contributions by the change: each person's part of it is added
    /// to what they contribute, so contributions adjusted by hand keep their adjustments.
    private func editAmount(_ field: ExpenseAmounts.Field, typed: Int) {
        guard canEditAmounts else { return }
        let edit = amountEdit?.field == field ? amountEdit! : AmountEdit(field: field, base: amounts, baseShares: sharesBinding.wrappedValue, typed: typed)
        amountEdit = AmountEdit(field: field, base: edit.base, baseShares: edit.baseShares, typed: typed)
        var edited = edit.base
        edited.set(field, to: typed)
        if edited.items != itemsBinding.wrappedValue { itemsBinding.wrappedValue = edited.items }
        if edited.adjustments != adjustmentsBinding.wrappedValue { adjustmentsBinding.wrappedValue = edited.adjustments }
        totalBinding.wrappedValue = edited.totalCents
        let change = edited.cents(of: field) - edit.base.cents(of: field)
        let weights = ShareAdjuster.weights(for: field, in: edit.base, owners: owners(of:), people: participants, tipSplit: tipSplit)
        sharesBinding.wrappedValue = ShareAdjuster.adding(change, weightedBy: weights, to: edit.baseShares, people: participants, total: edited.totalCents)
        amountsEdited = true
    }

    /// The lines shown when the current edit began, kept on screen until it ends.
    private var keptLines: Set<String> {
        guard let edit = amountEdit else { return [] }
        return Set(edit.base.lines(editing: edit.field).map(\.id))
    }

    private func amountBinding(_ field: ExpenseAmounts.Field) -> Binding<Int> {
        Binding(
            get: { amountEdit?.field == field ? amountEdit!.typed : amounts.cents(of: field) },
            set: { editAmount(field, typed: $0) }
        )
    }

    private func focusBinding(_ field: ExpenseAmounts.Field) -> Binding<Bool> {
        Binding(
            get: { focusedField == field },
            set: { focused in
                if focused { focusedField = field } else if focusedField == field { focusedField = nil }
            }
        )
    }

    /// Shows `field` as a field and focuses it once it's on screen and the menu has closed.
    private func beginEditing(_ field: ExpenseAmounts.Field) {
        editingField = field
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if editingField == field { focusedField = field }
        }
    }

    private func perform(_ item: ExpenseAmounts.MenuItem) {
        switch item {
        case let .edit(field, _):
            beginEditing(field)
        case .editItems:
            openAssignItems()
        case let .add(kind):
            var edited = amounts
            let field = edited.add(kind)
            if edited.items != itemsBinding.wrappedValue { itemsBinding.wrappedValue = edited.items }
            if edited.adjustments != adjustmentsBinding.wrappedValue { adjustmentsBinding.wrappedValue = edited.adjustments }
            beginEditing(field)
        }
    }

    private func openAssignItems() {
        if let onOpenAssignItems { onOpenAssignItems(); return }
        if confirmation.isLocked { undoAssignmentConfirmation() }
        isShowingAssignItems = true
    }

    private func menuSymbol(_ item: ExpenseAmounts.MenuItem) -> String {
        switch item {
        case .edit: "pencil"
        case .editItems: "list.bullet"
        case .add: "plus"
        }
    }

    private func display(_ line: ExpenseAmounts.Line) -> String {
        if line.kind == .discount { return "−\(line.cents.usd)" }
        return line.cents < 0 ? "−\((-line.cents).usd)" : line.cents.usd
    }

    @ViewBuilder
    private func amountLine(_ line: ExpenseAmounts.Line) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text(line.title)
                if line.kind == .tax, line.rate > 0 {
                    Text("(\(RateField.format(line.rate))%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if canEditAmounts, let field = line.field, editingField == field {
                if line.kind == .discount {
                    Text("−").foregroundStyle(.secondary)
                }
                CentsField(title: "0.00", cents: amountBinding(field), isFocusedBinding: focusBinding(field))
                    .accessibilityLabel(line.title)
            } else {
                Text(display(line))
                    .accessibilityLabel(line.title)
            }
        }
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
                let lines = amounts.lines(editing: editingField, keeping: keptLines)
                VStack(spacing: 3) {
                    if !lines.isEmpty {
                        ForEach(lines) { line in amountLine(line) }

                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1.5)
                            .padding(.vertical, 2)
                    }

                    // Total
                    HStack {
                        if lines.isEmpty {
                            Text("Total")
                        }
                        Spacer()
                        if canEditAmounts, editingField == .total {
                            CentsField(title: "0.00", cents: amountBinding(.total), isFocusedBinding: focusBinding(.total), fontWeight: .semibold)
                                .accessibilityLabel("Total")
                        } else {
                            Text(totalBinding.wrappedValue.usd)
                                .fontWeight(.semibold)
                                .accessibilityLabel("Total")
                        }
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                // Press and hold to edit. An empty menu builder disables the menu, so only those who may edit get one.
                .contextMenu {
                    if canEditAmounts {
                        ForEach(amounts.menu(editing: editingField, keeping: keptLines)) { item in
                            Button(item.title, systemImage: menuSymbol(item)) { perform(item) }
                        }
                    }
                }
                .onChange(of: focusedField) { _, field in
                    // Leaving the field ends editing: it shows as a value again, and a line left at $0 goes away.
                    if field == nil {
                        editingField = nil
                        amountEdit = nil
                    } else if amountEdit?.field != field {
                        amountEdit = nil
                    }
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
                    Button {
                        openAssignItems()
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
                    .disabled(!isEditable)
                }
            }
        }
        .navigationDestination(isPresented: $isShowingAssignItems) {
            AssignItemsView(
                items: itemsBinding,
                itemAssignments: itemAssignmentsBinding,
                participants: participants,
                isEditable: isEditable,
                assignmentsLocked: confirmation.isLocked,
                onAssignmentsChanged: { recomputeAssignedShares() },
                onItemsChanged: { old, new in itemsChanged(from: old, to: new) },
                onSplitAll: { splitAll() },
                onConfirm: { confirmAssignments() },
                canConfirm: !itemsBinding.wrappedValue.isEmpty && amounts.totalCents > 0,
                onUndoConfirmation: { undoAssignmentConfirmation() }
            )
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
        .onChange(of: payerBinding.wrappedValue) { _, newPayer in
            if let onPayerChanged { onPayerChanged(newPayer) } else { reassignFilledRows(to: newPayer) }
        }
    }

    private func shareBinding(for person: UUID) -> Binding<Int> {
        Binding(
            get: { sharesBinding.wrappedValue[person] ?? 0 },
            set: { cents in
                guard isEditable else { return }
                amountsEdited = true
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
            if amountsEdited, let message = amounts.saveError {
                internalSaveError = message
                return
            }
            Task {
                internalIsSaving = true
                do {
                    let token = try await authentication.accessToken()
                    let edit = amountsEdited ? ExpenseStore.AmountsEdit(
                        totalCents: totalBinding.wrappedValue,
                        items: ExpenseAmounts(items: ownedItems, adjustments: amounts.adjustments)
                            .savedItems(named: descriptionBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                        adjustments: amounts.adjustments,
                        shares: sharesBinding.wrappedValue.filter { participants.contains($0.key) }
                    ) : nil
                    try await store.updateExpense(
                        expenseID,
                        description: descriptionBinding.wrappedValue,
                        category: .some(categoryBinding.wrappedValue),
                        transactionDate: dateBinding.wrappedValue,
                        payer: payerBinding.wrappedValue,
                        amounts: edit,
                        accessToken: token
                    )
                    dismiss()
                } catch LedgerAPIClientError.staleExpense {
                    // Start over from the expense as it is now.
                    if let current = store.expenses.first(where: { $0.id == expenseID }) { load(current) }
                    internalSaveError = LedgerAPIClientError.staleExpense.localizedDescription
                } catch {
                    internalSaveError = error.localizedDescription
                }
                internalIsSaving = false
            }
        }
    }

    /// Resets a saved expense's fields to `expense`.
    private func load(_ expense: Expense) {
        internalCategory = expense.category
        internalDescription = expense.description
        internalTotal = expense.total
        internalPayer = expense.payer
        internalPurchaseDate = expense.transactionDate
        internalShares = expense.shares
        internalItems = expense.items
        internalItemAssignments = Dictionary(expense.items.map { ($0.id, $0.ownerIDs) }, uniquingKeysWith: { first, _ in first })
        internalAdjustments = expense.adjustments
        editingField = nil
        focusedField = nil
        amountEdit = nil
        amountsEdited = false
        confirmation.reset()
        balancer = ContributionBalancer()
    }

    /// Gives every row to everyone.
    private func splitAll() {
        withAnimation(.snappy(duration: 0.2)) {
            for item in itemsBinding.wrappedValue { itemAssignmentsBinding.wrappedValue[item.id] = Set(participants) }
            recomputeAssignedShares()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Confirmation closes Assign items at once when every row has an owner. Otherwise it fills the rest to the payer
    /// and waits for Continue so the autofill stays visible. Either way contributions follow ownership, keeping any
    /// adjusted by hand while they still add up.
    private func confirmAssignments() {
        if confirmation.isLocked {
            finishAssigning()
            return
        }
        guard let payer = payerBinding.wrappedValue else { return }
        var confirmed = confirmation, assignments = itemAssignmentsBinding.wrappedValue
        guard confirmed.confirm(itemsBinding.wrappedValue, assignments: &assignments, payer: payer) else {
            confirmation = confirmed
            finishAssigning()
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            itemAssignmentsBinding.wrappedValue = assignments
            recomputeAssignedShares()
            confirmation = confirmed
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func finishAssigning() {
        if allocationTotal != totalBinding.wrappedValue || !Set(participants).isSubset(of: sharesBinding.wrappedValue.keys) {
            recomputeAssignedShares()
        }
        isShowingAssignItems = false
    }

    private func undoAssignmentConfirmation() {
        let confirmed = itemAssignmentsBinding.wrappedValue
        withAnimation(.snappy(duration: 0.2)) {
            confirmation.undo(&itemAssignmentsBinding.wrappedValue)
            if itemAssignmentsBinding.wrappedValue != confirmed { recomputeAssignedShares() }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Moves only the rows confirmation filled when the payer changes.
    private func reassignFilledRows(to newPayer: UUID?) {
        guard mode == .existing, confirmation.isLocked, let newPayer else { return }
        confirmation.reassignFilledRows(itemsBinding.wrappedValue, assignments: &itemAssignmentsBinding.wrappedValue, to: newPayer)
        recomputeAssignedShares()
    }

    private func recomputeAssignedShares() {
        guard !participants.isEmpty else { return }
        amountsEdited = true
        let items = amounts.items.map { item in
            var item = item
            item.ownerIDs = itemAssignmentsBinding.wrappedValue[item.id, default: []]
            return item
        }
        sharesBinding.wrappedValue = (items + tipRows(for: items)).ownerShares(for: participants)
    }

    /// An item's price edit moves only its owners' contributions, and the total follows.
    private func itemsChanged(from old: [ReceiptItem], to new: [ReceiptItem]) {
        let total = ExpenseAmounts(items: new, adjustments: adjustmentsBinding.wrappedValue).totalCents
        if mode == .existing { internalTotal = total }
        amountsEdited = true
        sharesBinding.wrappedValue = ShareAdjuster.applyingItemChanges(
            from: old, to: new, shares: sharesBinding.wrappedValue, owners: owners(of:), people: participants, total: total
        )
    }
}
