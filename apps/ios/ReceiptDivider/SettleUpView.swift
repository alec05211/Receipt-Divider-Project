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

                if let other {
                    let itemsTheyOwe = itemsTheyOweMe(other: other)
                    if !itemsTheyOwe.isEmpty {
                        Section("\(store.person(for: other).firstName) owes \(store.selfReferenceObject)") {
                            ForEach(itemsTheyOwe) { item in
                                HStack {
                                    Text(item.descriptor)
                                    Spacer()
                                    Text(item.cents.usd)
                                }
                            }
                        }
                    }

                    let itemsIOwe = itemsIOweThem(other: other)
                    if !itemsIOwe.isEmpty {
                        let verb = store.selfReferenceMode == .fullName ? "owes" : "owe"
                        Section("\(store.selfReferenceSubject) \(verb) \(store.person(for: other).firstName)") {
                            ForEach(itemsIOwe) { item in
                                HStack {
                                    Text(item.descriptor)
                                    Spacer()
                                    Text(item.cents.usd)
                                }
                            }
                        }
                    }
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
        .scrollIndicators(.hidden)
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

    private struct SettleUpItem: Identifiable {
        let id = UUID()
        let descriptor: String
        let cents: Int
    }

    private func itemDescriptor(itemName: String, expense: Expense) -> String {
        let name = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = name.isEmpty ? expense.description : name
        if let category = expense.category {
            let tag = category.title.lowercased()
            if baseName.localizedCaseInsensitiveCompare(tag) == .orderedSame {
                return baseName
            }
            return "\(baseName) (\(tag))"
        } else if !expense.description.isEmpty && baseName.localizedCaseInsensitiveCompare(expense.description) != .orderedSame {
            return "\(baseName) (\(expense.description))"
        }
        return baseName
    }

    private func itemsTheyOweMe(other: UUID) -> [SettleUpItem] {
        guard let me = store.activeUserID, balance != 0 else { return [] }
        let expenses = store.expenses
            .filter { $0.payer == me && $0.participants.contains(other) }
            .sorted { $0.transactionDate < $1.transactionDate }

        var credit = store.payments
            .filter { $0.from == other && $0.to == me }
            .reduce(0) { $0 + $1.amount }

        var result: [SettleUpItem] = []
        for expense in expenses {
            let listsTip = expense.adjustments.contains { $0.kind == .tip }
            let selected = expense.items.filter { $0.isSelected && !(listsTip && $0.kind == .tip) }
            if selected.isEmpty {
                let share = expense.shares[other, default: 0]
                if share > 0 {
                    if credit >= share {
                        credit -= share
                    } else {
                        let remaining = share - credit
                        credit = 0
                        result.append(SettleUpItem(
                            descriptor: itemDescriptor(itemName: expense.description, expense: expense),
                            cents: remaining
                        ))
                    }
                }
            } else {
                for item in selected {
                    let isOwner = item.ownerIDs.isEmpty || item.ownerIDs.contains(other)
                    if isOwner {
                        let ownersCount = max(1, item.ownerIDs.isEmpty ? expense.participants.count : item.ownerIDs.count)
                        let share = item.cents / ownersCount
                        if share > 0 {
                            if credit >= share {
                                credit -= share
                            } else {
                                let remaining = share - credit
                                credit = 0
                                result.append(SettleUpItem(
                                    descriptor: itemDescriptor(itemName: item.name, expense: expense),
                                    cents: remaining
                                ))
                            }
                        }
                    }
                }
            }
        }
        return result.reversed()
    }

    private func itemsIOweThem(other: UUID) -> [SettleUpItem] {
        guard let me = store.activeUserID, balance != 0 else { return [] }
        let expenses = store.expenses
            .filter { $0.payer == other && $0.participants.contains(me) }
            .sorted { $0.transactionDate < $1.transactionDate }

        var credit = store.payments
            .filter { $0.from == me && $0.to == other }
            .reduce(0) { $0 + $1.amount }

        var result: [SettleUpItem] = []
        for expense in expenses {
            let listsTip = expense.adjustments.contains { $0.kind == .tip }
            let selected = expense.items.filter { $0.isSelected && !(listsTip && $0.kind == .tip) }
            if selected.isEmpty {
                let share = expense.shares[me, default: 0]
                if share > 0 {
                    if credit >= share {
                        credit -= share
                    } else {
                        let remaining = share - credit
                        credit = 0
                        result.append(SettleUpItem(
                            descriptor: itemDescriptor(itemName: expense.description, expense: expense),
                            cents: remaining
                        ))
                    }
                }
            } else {
                for item in selected {
                    let isOwner = item.ownerIDs.isEmpty || item.ownerIDs.contains(me)
                    if isOwner {
                        let ownersCount = max(1, item.ownerIDs.isEmpty ? expense.participants.count : item.ownerIDs.count)
                        let share = item.cents / ownersCount
                        if share > 0 {
                            if credit >= share {
                                credit -= share
                            } else {
                                let remaining = share - credit
                                credit = 0
                                result.append(SettleUpItem(
                                    descriptor: itemDescriptor(itemName: item.name, expense: expense),
                                    cents: remaining
                                ))
                            }
                        }
                    }
                }
            }
        }
        return result.reversed()
    }
}
