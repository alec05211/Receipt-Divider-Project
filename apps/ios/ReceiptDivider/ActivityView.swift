import SwiftUI

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var showResetConfirmation = false
    @State private var showSettleUp = false
    private var transactions: [Transaction] { (store.expenses.map(Transaction.expense) + store.payments.map(Transaction.payment)).sorted { $0.date > $1.date } }
    var body: some View {
        NavigationStack {
            List {
                Section { BalanceCard(balance: store.alexBalance) { showSettleUp = true }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
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
            .navigationDestination(isPresented: $showSettleUp) { SettleUpView() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView(showResetConfirmation: $showResetConfirmation) } label: { Image(systemName: "gearshape") } } }
        }
    }
}
private struct BalanceCard: View { let balance: Int; let recordPayment: () -> Void; var body: some View { let other = Person.jamie.rawValue; VStack(alignment: .leading, spacing: 4) { Text(balance.usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary); Text(balance == 0 ? "All settled up" : balance > 0 ? "Owed by \(other)" : "Owed to \(other)").font(.subheadline); Divider().padding(.vertical, 8); Button(action: recordPayment) { Label("Record a payment", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold)) }.buttonStyle(.borderless) }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 20, style: .continuous)).padding(.vertical, 4) } }
private enum Transaction: Identifiable { case expense(Expense), payment(Payment); var id: UUID { switch self { case .expense(let value): value.id; case .payment(let value): value.id } }; var date: Date { switch self { case .expense(let value): value.transactionDate; case .payment(let value): value.transactionDate } } }
private struct TransactionRow: View { let transaction: Transaction; var body: some View { switch transaction { case .expense(let expense): HStack(spacing: 12) { Image(systemName: "receipt").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(expense.description).font(.headline); HStack(spacing: 6) { AvatarStack(people: expense.shares.keys.sorted { $0.rawValue < $1.rawValue }); Text(expense.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Text(expense.total.usd).fontWeight(.semibold) }; case .payment(let payment): HStack { Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary); VStack(alignment: .leading) { Text("Payment recorded").font(.headline); Text("\(payment.from.rawValue) paid \(payment.to.rawValue)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(payment.amount.usd).fontWeight(.semibold) } } } }
struct AvatarStack: View { let people: [Person]; var body: some View { HStack(spacing: -6) { ForEach(people.prefix(4)) { person in Text(person.initials).font(.caption2.weight(.bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(.gray, in: Circle()).overlay(Circle().stroke(.background, lineWidth: 1)) } } } }
