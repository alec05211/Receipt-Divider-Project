import SwiftUI
import UIKit

struct ActivityView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    var body: some View {
        NavigationStack {
            SummaryContent(balance: store.netBalance, balances: store.openBalances, expenses: store.expenses.sorted { $0.transactionDate > $1.transactionDate })
                .navigationTitle("Summary")
                .navigationBarTitleDisplayMode(.inline)
                .task { await refresh() }
                .refreshable { await refresh() }
                .alert("Couldn’t save expense", isPresented: Binding(
                    get: { store.expenseSaveError != nil },
                    set: { if !$0 { store.expenseSaveError = nil } }
                )) { Button("OK") { store.expenseSaveError = nil } } message: { Text(store.expenseSaveError ?? "Try again.") }
        }
    }

    /// Friends can add expenses that include you, so the list reloads whenever it appears.
    private func refresh() async {
        guard let token = try? await authentication.accessToken() else { return }
        try? await store.refresh(accessToken: token)
    }
}
/// The balance card above the expenses, laid out like a grouped list.
private struct SummaryContent: View {
    let balance: Int
    let balances: [(person: LedgerPerson, cents: Int)]
    let expenses: [Expense]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink { BalancesView() } label: { BalanceCard(balance: balance, balances: balances) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55) })
                Text("Expenses").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 8)
                if expenses.isEmpty { ContentUnavailableView("No shared expenses", systemImage: "receipt").groupedCard() }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(expenses.enumerated()), id: \.element.id) { index, expense in
                            if index > 0 { Divider().padding(.leading, 50) }
                            NavigationLink { ExpenseDetailView(expense: expense) } label: { ExpenseRow(expense: expense).disclosureRow() }
                                .buttonStyle(RowButtonStyle())
                                .simultaneousGesture(TapGesture().onEnded { UISelectionFeedbackGenerator().selectionChanged() })
                        }
                    }
                    .groupedCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
/// The overall balance and a one-line, width-aware summary. The enclosing NavigationLink makes the entire card a button.
private struct BalanceCard: View {
    let balance: Int
    let balances: [(person: LedgerPerson, cents: Int)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(balance.usd).font(.title.bold()).foregroundStyle(balance > 0 ? .green : balance < 0 ? .red : .primary)
            if balances.isEmpty {
                Text("All settled up").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    summary(BalanceSummary.full(for: balances))
                    summary(BalanceSummary.limited(for: balances, namesPerGroup: 3))
                    summary(BalanceSummary.limited(for: balances, namesPerGroup: 2))
                    summary(BalanceSummary.limited(for: balances, namesPerGroup: 1))
                    summary(BalanceSummary.limited(for: balances, namesPerGroup: 0))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(BalanceSummary.full(for: balances))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .groupedCard(Color(.systemGray5))
    }

    private func summary(_ value: String) -> some View {
        Text(value).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// Every open balance. Each row opens the existing Settle Up screen with that person selected.
private struct BalancesView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var selectedPerson: LedgerPerson?
    var body: some View {
        List {
            if store.openBalances.isEmpty {
                ContentUnavailableView("All settled up", systemImage: "checkmark.circle")
            } else {
                ForEach(store.openBalances, id: \.person.id) { entry in
                    Button {
                        selectedPerson = entry.person
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        BalanceRow(person: entry.person, cents: entry.cents)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Balances")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPerson) { person in
            SettleUpView(initialPerson: person.id)
        }
    }
}

/// One person's balance with their photo.
private struct BalanceRow: View {
    @Environment(ExpenseStore.self) private var store
    let person: LedgerPerson
    let cents: Int
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userID: person.id, name: person.name, etag: person.avatarEtag, size: 30)
            Text(relationship)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var relationship: String {
        let me = store.activeUserID.map { store.person(for: $0).firstName } ?? "Me"
        if cents > 0 { return "\(person.firstName) owes \(me) \(cents.usd)" }
        return "\(me) owes \(person.firstName) \((-cents).usd)"
    }
}

private enum BalanceSummary {
    static func full(for balances: [(person: LedgerPerson, cents: Int)]) -> String {
        let owedBy = balances.filter { $0.cents > 0 }.map(\.person.firstName)
        let owedTo = balances.filter { $0.cents < 0 }.map(\.person.firstName)
        return render(owedBy: owedBy, owedTo: owedTo, byLimit: owedBy.count, toLimit: owedTo.count)
    }

    static func limited(for balances: [(person: LedgerPerson, cents: Int)], namesPerGroup: Int) -> String {
        let owedBy = balances.filter { $0.cents > 0 }.map(\.person.firstName)
        let owedTo = balances.filter { $0.cents < 0 }.map(\.person.firstName)
        return render(owedBy: owedBy, owedTo: owedTo, byLimit: min(namesPerGroup, owedBy.count), toLimit: min(namesPerGroup, owedTo.count))
    }

    private static func render(owedBy: [String], owedTo: [String], byLimit: Int, toLimit: Int) -> String {
        [segment("Owed by", names: owedBy, limit: byLimit), segment("Owed to", names: owedTo, limit: toLimit)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func segment(_ label: String, names: [String], limit: Int) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: ", ")
        let hidden = names.count - min(limit, names.count)
        if shown.isEmpty { return "\(label) +\(hidden)" }
        return hidden > 0 ? "\(label) \(shown), +\(hidden)" : "\(label) \(shown)"
    }
}
private struct ExpenseRow: View {
    @Environment(ExpenseStore.self) private var store
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
            if store.isExpensePending(expense.id) { ProgressView().controlSize(.small).accessibilityLabel("Uploading") }
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
