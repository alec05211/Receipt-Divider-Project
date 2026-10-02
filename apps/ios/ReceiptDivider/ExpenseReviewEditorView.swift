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
    @Binding private var externalLayout: ExpenseLayout
    @Binding private var externalShares: [UUID: Int]

    @State private var internalCategory: ExpenseCategory?
    @State private var internalDescription: String = ""
    @State private var internalTotal: Int = 0
    @State private var internalPayer: UUID?
    @State private var internalPurchaseDate: Date = Date()
    @State private var internalLayout: ExpenseLayout = .splitTotal
    @State private var internalShares: [UUID: Int] = [:]

    let participants: [UUID]
    let isEditable: Bool
    let showsToolbarSave: Bool
    let externalIsSaving: Bool
    let externalCanSave: Bool
    let externalOnSave: (() -> Void)?

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
    private var layoutBinding: Binding<ExpenseLayout> {
        mode == .draft ? $externalLayout : $internalLayout
    }
    private var sharesBinding: Binding<[UUID: Int]> {
        mode == .draft ? $externalShares : $internalShares
    }

    private var isSaving: Bool {
        mode == .draft ? externalIsSaving : internalIsSaving
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
        layout: Binding<ExpenseLayout>,
        shares: Binding<[UUID: Int]>,
        participants: [UUID],
        isEditable: Bool = true,
        showsToolbarSave: Bool = false,
        isSaving: Bool = false,
        canSave: Bool = true,
        onSave: @escaping () -> Void
    ) {
        self.mode = .draft
        self._externalCategory = category
        self._externalDescription = description
        self._externalTotal = total
        self._externalPayer = payer
        self._externalPurchaseDate = purchaseDate
        self._externalLayout = layout
        self._externalShares = shares
        self.participants = participants
        self.isEditable = isEditable
        self.showsToolbarSave = showsToolbarSave
        self.externalIsSaving = isSaving
        self.externalCanSave = canSave
        self.externalOnSave = onSave
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
        self._externalLayout = .constant(.splitTotal)
        self._externalShares = .constant([:])

        self._internalCategory = State(initialValue: expense.category)
        self._internalDescription = State(initialValue: expense.description)
        self._internalTotal = State(initialValue: expense.total)
        self._internalPayer = State(initialValue: expense.payer)
        self._internalPurchaseDate = State(initialValue: expense.transactionDate)
        self._internalLayout = State(initialValue: expense.items.filter(\.isSelected).isEmpty ? .splitTotal : .assignItems)
        self._internalShares = State(initialValue: expense.shares)

        self.participants = expense.participants
        self.isEditable = isEditable
        self.showsToolbarSave = true
        self.externalIsSaving = false
        self.externalCanSave = true
        self.externalOnSave = nil
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
                    if isEditable {
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

                Picker("Split by", selection: layoutBinding) {
                    ForEach(ExpenseLayout.allCases) { layoutCase in
                        Text(layoutCase.title).tag(layoutCase)
                    }
                }
                .disabled(!isEditable)
            }

            Section("Contributions") {
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
                                detent: equalShare(for: person)
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
            guard newTotal > 0, !participants.isEmpty, newTotal != oldTotal else { return }
            let base = newTotal / participants.count
            let remainder = newTotal % participants.count
            sharesBinding.wrappedValue = Dictionary(uniqueKeysWithValues: participants.enumerated().map { index, person in
                (person, base + (index < remainder ? 1 : 0))
            })
            balancer = ContributionBalancer()
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

    private func equalShare(for person: UUID) -> Int {
        guard let index = participants.firstIndex(of: person), !participants.isEmpty else { return 0 }
        let total = totalBinding.wrappedValue
        return total / participants.count + (index < total % participants.count ? 1 : 0)
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
}
