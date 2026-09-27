import SwiftUI

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showResetConfirmation = false
    /// The person whose balance row was tapped; opens Settle up preselected to them.
    @State private var settleUpPerson: UUID?
    private var expenses: [Expense] { store.expenses.sorted { $0.transactionDate > $1.transactionDate } }
    private var payments: [Payment] { store.payments.sorted { $0.transactionDate > $1.transactionDate } }
    var body: some View {
        NavigationStack {
            List {
                Section { BalanceCard(balance: store.netBalance).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                let groups = BalanceText.grouped(store.openBalances)
                if !groups.isEmpty {
                    Section("Balances") {
                        ForEach(groups) { group in
                            if group.people.count == 1, let person = group.people.first {
                                Button { settleUpPerson = person.id } label: { BalanceRow(group: group) }.foregroundStyle(.primary)
                            } else {
                                // Several people share this row, so ask which one the payment is with.
                                Menu {
                                    Section("Record a payment with") { ForEach(group.people) { person in Button(person.name) { settleUpPerson = person.id } } }
                                } label: { BalanceRow(group: group) }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                Section("Expenses") {
                    if expenses.isEmpty { ContentUnavailableView("No shared expenses", systemImage: "receipt", description: Text("Add a receipt to start your shared history.")) }
                    else { ForEach(expenses) { expense in NavigationLink { ExpenseDetailView(expense: expense) } label: { ExpenseRow(expense: expense) } } }
                }
                if !payments.isEmpty { Section("Payments") { ForEach(payments) { PaymentRow(payment: $0) } } }
            }
            .navigationTitle("Summary")
            .navigationDestination(item: $settleUpPerson) { SettleUpView(initialPerson: $0) }
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
private struct BalanceCard: View {
    let balance: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(balance.usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary)
            Text(balance == 0 ? "All settled up" : balance > 0 ? "You’re owed in total" : "You owe in total").font(.subheadline)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.vertical, 4)
    }
}
/// One person's balance with their photo, or several people's shared balance with overlapping photos.
private struct BalanceRow: View {
    let group: BalanceGroup
    var body: some View {
        HStack(spacing: 12) {
            if group.people.count == 1, let person = group.people.first { AvatarView(userID: person.id, name: person.name, etag: person.avatarEtag, size: 30) }
            else { AvatarStack(people: group.people.map(\.id), size: 30) }
            Text(group.text).multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
private struct ExpenseRow: View {
    let expense: Expense
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "receipt").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(expense.description).font(.headline)
                HStack(spacing: 6) { AvatarStack(people: expense.participants); Text(expense.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(expense.total.usd).fontWeight(.semibold)
        }
    }
}
private struct PaymentRow: View {
    @Environment(ExpenseStore.self) private var store
    let payment: Payment
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.name(for: payment.from)) paid \(store.name(for: payment.to))").font(.headline)
                Text(payment.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(payment.amount.usd).fontWeight(.semibold)
        }
    }
}
/// Up to four participants' photos, overlapping; the signed-in user is listed first.
struct AvatarStack: View {
    @Environment(ExpenseStore.self) private var store
    let people: [UUID]
    var size: CGFloat = 18
    private var ordered: [UUID] { people.sorted { a, b in a == store.activeUserID ? b != store.activeUserID : b != store.activeUserID && store.name(for: a) < store.name(for: b) } }
    var body: some View {
        HStack(spacing: -size / 3) {
            ForEach(ordered.prefix(4), id: \.self) { id in
                let person = store.person(for: id)
                AvatarView(userID: id, name: person.name, etag: person.avatarEtag, size: size).overlay(Circle().stroke(.background, lineWidth: 1))
            }
        }
    }
}
