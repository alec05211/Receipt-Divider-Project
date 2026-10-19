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
    /// Kept while retrying a payment that may already have reached the server, so it's recorded once; any change to
    /// the payment starts a new one.
    @State private var paymentID = UUID()

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

                if let other, let me = store.activeUserID {
                    let theirBreakdown = owedBreakdown(debtor: other, creditor: me)
                    let myBreakdown = owedBreakdown(debtor: me, creditor: other)
                    if !theirBreakdown.items.isEmpty || !myBreakdown.items.isEmpty {
                        Section {
                            if !theirBreakdown.items.isEmpty {
                                personSummaryRow(person: other, totalCents: theirBreakdown.totalCents, items: theirBreakdown.items)
                            }
                            if !myBreakdown.items.isEmpty {
                                personSummaryRow(person: me, totalCents: myBreakdown.totalCents, items: myBreakdown.items)
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
        .onChange(of: other) { _, _ in suggestAmount(); paymentID = UUID() }
        .onChange(of: theyPaidMe) { _, _ in paymentID = UUID() }
        .onChange(of: amount) { _, _ in paymentID = UUID() }
        .onChange(of: date) { _, _ in paymentID = UUID() }
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
        let payment = Payment(id: paymentID, amount: amount, from: theyPaidMe ? other : me, to: theyPaidMe ? me : other, transactionDate: date)
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

    private struct OwedBreakdown {
        let totalCents: Int
        let items: [SettleUpItem]
    }

    private func personSummaryRow(person: UUID, totalCents: Int, items: [SettleUpItem]) -> some View {
        let details = store.person(for: person)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    AvatarView(userID: person, name: details.name, etag: details.avatarEtag, size: 24)
                    Text(store.name(for: person))
                }
                Spacer()
                Text(totalCents.usd).fontWeight(.semibold)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack {
                            Text(item.descriptor)
                                .lineLimit(1)
                            Spacer()
                            Text(item.cents.usd)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
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

    private func owedBreakdown(debtor: UUID, creditor: UUID) -> OwedBreakdown {
        guard balance != 0 else { return OwedBreakdown(totalCents: 0, items: []) }
        let expenses = store.expenses
            .filter { $0.payer == creditor && $0.participants.contains(debtor) }
            .sorted { $0.transactionDate < $1.transactionDate }

        var credit = store.payments
            .filter { $0.from == debtor && $0.to == creditor }
            .reduce(0) { $0 + $1.amount }

        var totalCents = 0
        var result: [SettleUpItem] = []
        for expense in expenses {
            let expenseShare = expense.shares[debtor, default: 0]
            guard expenseShare > 0 else { continue }
            if credit >= expenseShare {
                credit -= expenseShare
                continue
            }
            let remainingExpenseShare = expenseShare - credit
            var itemCredit = credit
            credit = 0
            totalCents += remainingExpenseShare

            var expenseItems: [SettleUpItem] = []
            for (item, share) in expense.itemCharges(for: debtor) where share > 0 {
                if itemCredit >= share {
                    itemCredit -= share
                } else {
                    let remaining = share - itemCredit
                    itemCredit = 0
                    expenseItems.append(SettleUpItem(
                        descriptor: itemDescriptor(itemName: item.name, expense: expense),
                        cents: remaining
                    ))
                }
            }
            if expenseItems.isEmpty {
                expenseItems.append(SettleUpItem(
                    descriptor: itemDescriptor(itemName: expense.description, expense: expense),
                    cents: remainingExpenseShare
                ))
            }
            result.append(contentsOf: expenseItems)
        }
        return OwedBreakdown(totalCents: totalCents, items: result.reversed())
    }
}
