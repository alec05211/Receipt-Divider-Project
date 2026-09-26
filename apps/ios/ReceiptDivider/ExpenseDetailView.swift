import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    @Environment(ExpenseStore.self) private var store
    let expense: Expense

    private var participants: [Person] { expense.shares.keys.sorted { $0.rawValue < $1.rawValue } }
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
                ForEach(participants) { person in
                    HStack {
                        PersonBadge(person: person)
                        Spacer()
                        Text(expense.shares[person, default: 0].usd).fontWeight(.semibold)
                    }
                }
                Text("The payer covered the full amount at purchase; each amount above is that person’s assigned share.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                            AvatarStack(people: related.shares.keys.sorted { $0.rawValue < $1.rawValue })
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
    let person: Person
    var body: some View {
        HStack(spacing: 6) {
            Text(person.initials).font(.caption2.weight(.bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(.gray, in: Circle())
            Text(person.rawValue)
        }
    }
}
