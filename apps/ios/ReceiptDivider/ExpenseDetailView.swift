import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    @Environment(ExpenseStore.self) private var store
    let expense: Expense

    /// You first, then everyone else by name.
    private var participants: [UUID] {
        expense.participants.sorted { a, b in a == store.activeUserID ? b != store.activeUserID : b != store.activeUserID && store.name(for: a) < store.name(for: b) }
    }
    private var relatedExpenses: [Expense] {
        store.expenses.filter { candidate in
            candidate.id != expense.id && !Set(candidate.shares.keys).isDisjoint(with: Set(participants))
        }.sorted { $0.transactionDate > $1.transactionDate }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(expense.description).font(.title2.bold())
                    Text(expense.transactionDate, format: .dateTime.month(.wide).day().year())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Cost breakdown") {
                LabeledContent("Total", value: expense.total.usd).fontWeight(.semibold)
                HStack {
                    Text("Paid by")
                    Spacer()
                    PersonBadge(person: expense.payer)
                    Text(expense.total.usd).fontWeight(.semibold)
                }
            }

            Section("Who owes what") {
                ForEach(participants, id: \.self) { person in
                    HStack {
                        PersonBadge(person: person)
                        Spacer()
                        Text(expense.shares[person, default: 0].usd).fontWeight(.semibold)
                    }
                }
            }

            Section("Receipt evidence") {
                if let data = expense.receiptImageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ContentUnavailableView("No receipt image", systemImage: "doc.text.image", description: Text("This transaction was entered without a photo."))
                }
                ForEach(expense.items.filter(\.isSelected)) { item in
                    LabeledContent(item.name, value: item.cents.usd)
                }
                if expense.offsetTotal != 0 { LabeledContent("Tax and discounts", value: expense.offsetTotal < 0 ? "−\((-expense.offsetTotal).usd)" : expense.offsetTotal.usd) }
            }

            Section("Recent transactions with these people") {
                if relatedExpenses.isEmpty {
                    Text("No other shared transactions yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(relatedExpenses.prefix(8)) { related in
                        HStack(spacing: 10) {
                            AvatarStack(people: related.participants)
                            VStack(alignment: .leading) {
                                Text(related.description).font(.headline)
                                Text(related.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(related.total.usd).fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonBadge: View {
    @Environment(ExpenseStore.self) private var store
    let person: UUID
    var body: some View {
        let details = store.person(for: person)
        HStack(spacing: 6) {
            AvatarView(userID: person, name: details.name, etag: details.avatarEtag, size: 24)
            Text(store.name(for: person))
        }
    }
}
