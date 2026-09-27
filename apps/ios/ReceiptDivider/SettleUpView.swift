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
                ContentUnavailableView("No one to settle with", systemImage: "person.2", description: Text("Add friends from Profile → Friends first."))
            } else {
                Section {
                    Picker("With", selection: $other) {
                        ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let other { LabeledContent("Current balance", value: BalanceText.describe(balance, name: store.person(for: other).name)) }
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

enum BalanceText {
    /// "Alec owes you $12.00", "You owe Alec $12.00", or "Settled up".
    static func describe(_ cents: Int, name: String) -> String {
        cents > 0 ? "\(name) owes you \(cents.usd)" : cents < 0 ? "You owe \(name) \((-cents).usd)" : "Settled up"
    }
    /// "Alec and Willem owe you $6.00 each", "You owe $6.00 each to Alec, Willem, and Luke"; one name reads as `describe(_:name:)`.
    static func describe(_ cents: Int, names: [String]) -> String {
        guard names.count > 1 else { return describe(cents, name: names.first ?? "") }
        return cents > 0 ? "\(list(names)) owe you \(cents.usd) each" : cents < 0 ? "You owe \((-cents).usd) each to \(list(names))" : "Settled up"
    }
    /// Joins names in English with an Oxford comma: "A", "A and B", "A, B, and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: names.first ?? ""
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
    /// Merges people with the same signed balance into one group, largest amount first (owed to you before owed by you on ties), names A–Z.
    static func grouped(_ balances: [(person: LedgerPerson, cents: Int)]) -> [BalanceGroup] {
        Dictionary(grouping: balances.filter { $0.cents != 0 }, by: \.cents)
            .map { BalanceGroup(cents: $0.key, people: $0.value.map(\.person).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { abs($0.cents) != abs($1.cents) ? abs($0.cents) > abs($1.cents) : $0.cents > $1.cents }
    }
}
/// Everyone who owes you, or whom you owe, the same amount.
struct BalanceGroup: Identifiable, Hashable {
    let cents: Int; let people: [LedgerPerson]
    var id: Int { cents }
    var text: String { BalanceText.describe(cents, names: people.map(\.name)) }
}
