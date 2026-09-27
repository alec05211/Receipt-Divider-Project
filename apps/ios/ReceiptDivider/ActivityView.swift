import SwiftUI

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    /// The person whose balance row was tapped; opens Settle up preselected to them.
    @State private var settleUpPerson: UUID?
    private var expenses: [Expense] { store.expenses.sorted { $0.transactionDate > $1.transactionDate } }
    var body: some View {
        NavigationStack {
            List {
                Section { BalanceCard(balance: store.netBalance, balances: store.openBalances) { settleUpPerson = $0 }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("Expenses") {
                    if expenses.isEmpty { ContentUnavailableView("No shared expenses", systemImage: "receipt") }
                    else { ForEach(expenses) { expense in NavigationLink { ExpenseDetailView(expense: expense) } label: { ExpenseRow(expense: expense) } } }
                }
            }
            .navigationTitle("Summary")
            .navigationDestination(item: $settleUpPerson) { SettleUpView(initialPerson: $0) }
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
/// The overall balance, a one-line summary of who's involved, and a disclosure of each person's balance ("All settled up" when there are none).
private struct BalanceCard: View {
    let balance: Int
    let balances: [(person: LedgerPerson, cents: Int)]
    /// Called with the person whose balance row was tapped.
    let settleUp: (UUID) -> Void
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(balance.usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary)
            if balances.isEmpty { Text("All settled up").font(.subheadline) }
            else {
                Button { withAnimation(.snappy) { isExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(BalanceText.summary(balances)).multilineTextAlignment(.leading)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(.subheadline).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(balances.enumerated()), id: \.element.person.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 42) }
                            Button { settleUp(entry.person.id) } label: { BalanceRow(person: entry.person, cents: entry.cents) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.vertical, 4)
    }
}
/// One person's balance with their photo; tapping it opens Settle up with them.
private struct BalanceRow: View {
    let person: LedgerPerson
    let cents: Int
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userID: person.id, name: person.name, etag: person.avatarEtag, size: 30)
            Text(BalanceText.describe(cents, name: person.name)).multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
private struct ExpenseRow: View {
    let expense: Expense
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: expense.category?.symbol ?? "receipt").foregroundStyle(.secondary).frame(width: 24)
                .accessibilityLabel(expense.category?.title ?? "Expense")
            VStack(alignment: .leading, spacing: 4) {
                Text(expense.description).font(.headline)
                HStack(spacing: 6) { AvatarStack(people: expense.participants); Text(expense.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(expense.total.usd).fontWeight(.semibold)
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
