import SwiftUI

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    /// The person whose balance row was tapped; opens Settle up preselected to them.
    @State private var settleUpPerson: UUID?
    var body: some View {
        NavigationStack {
            SummaryContent(balance: store.netBalance, balances: store.openBalances, expenses: store.expenses.sorted { $0.transactionDate > $1.transactionDate }) { settleUpPerson = $0 }
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
/// The balance card above the expenses, laid out like a grouped list. It's a scroll view rather than a List because
/// List can't animate a row's height: expanding the card cross-faded its content and jumped the expenses below.
private struct SummaryContent: View {
    let balance: Int
    let balances: [(person: LedgerPerson, cents: Int)]
    let expenses: [Expense]
    let settleUp: (UUID) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BalanceCard(balance: balance, balances: balances, settleUp: settleUp)
                Text("Expenses").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 8)
                if expenses.isEmpty { ContentUnavailableView("No shared expenses", systemImage: "receipt").groupedCard() }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(expenses.enumerated()), id: \.element.id) { index, expense in
                            if index > 0 { Divider().padding(.leading, 50) }
                            NavigationLink { ExpenseDetailView(expense: expense) } label: { ExpenseRow(expense: expense).disclosureRow() }.buttonStyle(RowButtonStyle())
                        }
                    }
                    .groupedCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
    }
}
private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
private extension View {
    /// A grouped list section's rounded background.
    func groupedCard(_ color: Color = Color(.secondarySystemGroupedBackground)) -> some View { background(color).clipShape(cardShape) }
    /// Row padding and a trailing chevron, like a List navigation row.
    func disclosureRow() -> some View {
        HStack(spacing: 8) { self; Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
    }
}
/// Highlights a row while it's pressed, as List does.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.primary).background(configuration.isPressed ? Color(.systemGray4) : .clear)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(balance.usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary)
                if balances.isEmpty { Text("All settled up").font(.subheadline) }
                else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(BalanceText.summary(balances)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(.subheadline)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !balances.isEmpty { withAnimation(.snappy) { isExpanded.toggle() } } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(balances.isEmpty ? [] : .isButton)
            .accessibilityValue(balances.isEmpty ? "" : isExpanded ? "Expanded" : "Collapsed")
            // The rows stay laid out and are uncovered by animating a clipped height, so the card grows as one
            // piece from the top and everything below moves with it.
            VStack(spacing: 0) {
                ForEach(balances, id: \.person.id) { entry in
                    Divider().padding(.leading, 58)
                    Button { settleUp(entry.person.id) } label: { BalanceRow(person: entry.person, cents: entry.cents) }.buttonStyle(RowButtonStyle())
                }
            }
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .groupedCard(Color(.systemGray5))
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
            Spacer(minLength: 0)
        }
        .disclosureRow()
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
