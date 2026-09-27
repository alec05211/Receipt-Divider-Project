import SwiftUI

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showResetConfirmation = false
    @State private var settleUpPerson: SettleUpTarget?
    private var transactions: [Transaction] { (store.expenses.map(Transaction.expense) + store.payments.map(Transaction.payment)).sorted { $0.date > $1.date } }
    var body: some View {
        NavigationStack {
            List {
                Section { BalanceCard(balance: store.netBalance) { settleUpPerson = SettleUpTarget(id: nil) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if !store.openBalances.isEmpty {
                    Section("Balances") {
                        ForEach(store.openBalances, id: \.person.id) { entry in
                            Button { settleUpPerson = SettleUpTarget(id: entry.person.id) } label: {
                                HStack(spacing: 12) {
                                    AvatarView(userID: entry.person.id, name: entry.person.name, etag: entry.person.avatarEtag, size: 30)
                                    Text(BalanceText.describe(entry.cents, name: entry.person.name))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("Transactions") {
                    if transactions.isEmpty { ContentUnavailableView("No shared expenses", systemImage: "receipt", description: Text("Add a receipt to start your shared history.")) }
                    else { ForEach(transactions) { transaction in
                        switch transaction {
                        case .expense(let expense): NavigationLink { ExpenseDetailView(expense: expense) } label: { TransactionRow(transaction: transaction) }
                        case .payment: TransactionRow(transaction: transaction)
                        }
                    } }
                }
            }
            .navigationTitle("Summary")
            .navigationDestination(item: $settleUpPerson) { target in SettleUpView(initialPerson: target.id) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView(showResetConfirmation: $showResetConfirmation) } label: { Image(systemName: "gearshape") } } }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    /// Friends can add expenses that include you, so the list reloads whenever it appears.
    private func refresh() async {
        guard let token = try? await authentication.accessToken() else { return }
        try? await store.refresh(accessToken: token)
    }
}
private struct SettleUpTarget: Identifiable, Hashable { let id: UUID? }
private struct BalanceCard: View {
    let balance: Int
    let recordPayment: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(abs(balance).usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary)
            Text(balance == 0 ? "All settled up" : balance > 0 ? "You're owed in total" : "You owe in total").font(.subheadline)
            Divider().padding(.vertical, 8)
            Button(action: recordPayment) { Label("Record a payment", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold)) }.buttonStyle(.borderless)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.vertical, 4)
    }
}
private enum Transaction: Identifiable { case expense(Expense), payment(Payment); var id: UUID { switch self { case .expense(let value): value.id; case .payment(let value): value.id } }; var date: Date { switch self { case .expense(let value): value.transactionDate; case .payment(let value): value.transactionDate } } }
private struct TransactionRow: View {
    @Environment(ExpenseStore.self) private var store
    let transaction: Transaction
    var body: some View {
        switch transaction {
        case .expense(let expense):
            HStack(spacing: 12) {
                Image(systemName: "receipt").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(expense.description).font(.headline)
                    HStack(spacing: 6) { AvatarStack(people: expense.participants); Text(expense.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(expense.total.usd).fontWeight(.semibold)
            }
        case .payment(let payment):
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Payment recorded").font(.headline)
                    Text("\(store.name(for: payment.from)) paid \(store.name(for: payment.to))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(payment.amount.usd).fontWeight(.semibold)
            }
        }
    }
}
/// Up to four participants' photos, overlapping; the signed-in user is listed first.
struct AvatarStack: View {
    @Environment(ExpenseStore.self) private var store
    let people: [UUID]
    private var ordered: [UUID] { people.sorted { a, b in a == store.activeUserID ? b != store.activeUserID : b != store.activeUserID && store.name(for: a) < store.name(for: b) } }
    var body: some View {
        HStack(spacing: -6) {
            ForEach(ordered.prefix(4), id: \.self) { id in
                let person = store.person(for: id)
                AvatarView(userID: id, name: person.name, etag: person.avatarEtag, size: 18).overlay(Circle().stroke(.background, lineWidth: 1))
            }
        }
    }
}
