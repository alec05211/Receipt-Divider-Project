import SwiftUI

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
    private let externalContributionDetents: [UUID: Int]

    @State private var internalCategory: ExpenseCategory?
    @State private var internalDescription: String = ""
    @State private var internalTotal: Int = 0
    @State private var internalPayer: UUID?
    @State private var internalPurchaseDate: Date = Date()
    @State private var internalShares: [UUID: Int] = [:]
    @State private var internalItems: [ReceiptItem] = []
    @State private var internalItemAssignments: [UUID: Set<UUID>] = [:]

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
        return ownedItems.ownerShares(for: participants)
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

    /// Initializer for draft mode during new expense capture review.
    init(
        category: Binding<ExpenseCategory?>,
        description: Binding<String>,
        total: Binding<Int>,
        payer: Binding<UUID?>,
        purchaseDate: Binding<Date>,
        shares: Binding<[UUID: Int]>,
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
        self.externalContributionDetents = [:]

        self._internalCategory = State(initialValue: expense.category)
        self._internalDescription = State(initialValue: expense.description)
        self._internalTotal = State(initialValue: expense.total)
        self._internalPayer = State(initialValue: expense.payer)
        self._internalPurchaseDate = State(initialValue: expense.transactionDate)
        self._internalShares = State(initialValue: expense.shares)
        self._internalItems = State(initialValue: expense.items)
        self._internalItemAssignments = State(initialValue: Dictionary(uniqueKeysWithValues: expense.items.map { ($0.id, $0.ownerIDs) }))

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
                            Text(categoryBinding.wrappedValue?.title ?? "None")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    .disabled(!isEditable)

                    TextField("What was this for?", text: descriptionBinding).submitLabel(.done)
                        .disabled(!isEditable)
                }
            }

            Section {
                LabeledContent("Expense total") {
                    if isEditable && itemsBinding.wrappedValue.count <= 1 {
                        CentsField(title: "0.00", cents: totalBinding).fontWeight(.semibold)
                    } else {
                        Text(totalBinding.wrappedValue.usd).fontWeight(.semibold)
                    }
                }

                Picker("Paid by", selection: payerBinding) {
                    ForEach(participants, id: \.self) { person in
                        Text(store.name(for: person)).tag(Optional(person))
                    }
                }
                .disabled(!isEditable)

                DatePicker("Date of expense", selection: dateBinding, displayedComponents: .date)
                    .disabled(!isEditable)
            }

            if showsAssignmentSection {
                Section {
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
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(12)
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
        sharesBinding.wrappedValue = ownedItems.ownerShares(for: participants)
        let newTotal = itemsBinding.wrappedValue.filter {
            !(itemAssignmentsBinding.wrappedValue[$0.id]?.isEmpty ?? true)
        }.reduce(0) { $0 + $1.totalCents }
        if newTotal > 0 {
            totalBinding.wrappedValue = newTotal
        }
    }
}
