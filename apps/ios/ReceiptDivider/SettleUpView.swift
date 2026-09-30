import SwiftUI

struct SettleUpView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    /// Preselects who you're settling with, e.g. when opened from their balance row.
    var initialPerson: UUID?
    @State private var other: UUID?
    @State private var theyPaidMe = true
    @State private var amount = 0
    @State private var date = Date()
    @State private var didSave = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// People you owe or who owe you, then any other friends.
    private var candidates: [LedgerPerson] {
        let owing = store.openBalances.map(\.person)
        let friends = store.splitCandidates.filter { $0.id != store.activeUserID && !owing.map(\.id).contains($0.id) }
        return owing + friends
    }
    private var balance: Int { other.flatMap { store.balances[$0] } ?? 0 }

    var body: some View {
        Form {
            if candidates.isEmpty {
                ContentUnavailableView("No one to settle with", systemImage: "person.2")
            } else {
                Section {
                    Picker("With", selection: $other) {
                        ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let other { LabeledContent("Current balance", value: store.describeBalance(balance, with: store.person(for: other).name)) }
                }
                Section("Record payment") {
                    Picker("Direction", selection: $theyPaidMe) {
                        Text("They paid me").tag(true)
                        Text("I paid them").tag(false)
                    }
                    .pickerStyle(.segmented)
                    CentsField(title: "Amount", cents: $amount)
                    DatePicker("Payment date", selection: $date, displayedComponents: .date)
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Settle up")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Recording…" : "Record", action: save).disabled(amount <= 0 || other == nil || isSaving) } }
        .sensoryFeedback(.success, trigger: didSave)
        .onAppear { if other == nil { select(initialPerson ?? candidates.first?.id) } }
        .onChange(of: other) { _, _ in suggestAmount() }
    }

    private func select(_ person: UUID?) { other = person; suggestAmount() }

    /// Defaults to settling the whole balance in whichever direction clears it.
    private func suggestAmount() {
        guard balance != 0 else { return }
        theyPaidMe = balance > 0
        amount = abs(balance)
    }

    private func save() {
        guard let me = store.activeUserID, let other else { return }
        let payment = Payment(amount: amount, from: theyPaidMe ? other : me, to: theyPaidMe ? me : other, transactionDate: date)
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let token = try await authentication.accessToken()
                try await store.add(payment, accessToken: token)
                amount = 0
                didSave.toggle()
                suggestAmount()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
