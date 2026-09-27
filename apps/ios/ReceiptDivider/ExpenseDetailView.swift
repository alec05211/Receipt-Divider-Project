import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let expense: Expense
    @State private var receipt: UIImage?
    @State private var isLoadingReceipt = false
    @State private var title = ""
    @FocusState private var isEditingTitle: Bool
    @State private var renameError: String?

    /// The store's copy, so a rename (or a refresh) shows here as soon as it happens.
    private var current: Expense { store.expenses.first { $0.id == expense.id } ?? expense }
    /// You first, then everyone else by name.
    private var participants: [UUID] {
        current.participants.sorted { a, b in a == store.activeUserID ? b != store.activeUserID : b != store.activeUserID && store.name(for: a) < store.name(for: b) }
    }
    private var relatedExpenses: [Expense] {
        store.expenses.filter { candidate in
            candidate.id != current.id && !Set(candidate.shares.keys).isDisjoint(with: Set(participants))
        }.sorted { $0.transactionDate > $1.transactionDate }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    // Vertical so long names wrap; Return ends editing instead of adding a line.
                    TextField("Name", text: $title, axis: .vertical)
                        .font(.title2.bold())
                        .focused($isEditingTitle)
                        .submitLabel(.done)
                        .onChange(of: title) { _, newValue in
                            if newValue.contains("\n") {
                                title = newValue.replacingOccurrences(of: "\n", with: "")
                                isEditingTitle = false
                            } else if newValue.count > 200 {
                                title = String(newValue.prefix(200))
                            }
                        }
                    HStack(spacing: 6) {
                        Text("Total").foregroundStyle(.secondary)
                        Text(current.total.usd).fontWeight(.semibold)
                        Text("paid by").foregroundStyle(.secondary)
                        PersonBadge(person: current.payer)
                    }
                    .lineLimit(1)
                    Text(current.transactionDate, format: .dateTime.month(.wide).day().year())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Split") {
                ForEach(participants, id: \.self) { person in
                    HStack {
                        PersonBadge(person: person)
                        Spacer()
                        Text(current.shares[person, default: 0].usd).fontWeight(.semibold)
                    }
                }
            }

            Section {
                if let image = receipt ?? current.receiptImageData.flatMap(UIImage.init(data:)) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if isLoadingReceipt {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical)
                } else if !current.evidenceIDs.isEmpty {
                    ContentUnavailableView("Couldn’t load receipt", systemImage: "wifi.exclamationmark")
                } else {
                    ContentUnavailableView("No receipt", systemImage: "doc.text.image")
                }
                ForEach(current.items.filter(\.isSelected)) { item in
                    LabeledContent(item.name, value: item.cents.usd)
                }
                if current.offsetTotal != 0 { LabeledContent("Tax and discounts", value: current.offsetTotal < 0 ? "−\((-current.offsetTotal).usd)" : current.offsetTotal.usd) }
            }

            Section("Recent expenses with these people") {
                if relatedExpenses.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
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
        .task(id: current.evidenceIDs.first) { await loadReceipt() }
        .onAppear { title = current.description }
        .onChange(of: current.description) { _, newValue in if !isEditingTitle { title = newValue } }
        .onChange(of: isEditingTitle) { _, editing in if !editing { saveTitle() } }
        .alert("Couldn’t rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .navigationTitle("Expense")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension ExpenseDetailView {
    private func loadReceipt() async {
        guard receipt == nil, current.receiptImageData == nil, let evidenceID = current.evidenceIDs.first else { return }
        isLoadingReceipt = true
        if let token = try? await authentication.accessToken() { receipt = await store.receiptImage(evidenceID, accessToken: token) }
        isLoadingReceipt = false
    }

    /// Saves the edited name; a blank or unchanged one goes back to the current name.
    private func saveTitle() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current.description else {
            title = current.description
            return
        }
        title = name
        Task {
            do {
                try await store.renameExpense(expense.id, to: name, accessToken: authentication.accessToken())
            } catch {
                title = current.description
                renameError = error.localizedDescription
            }
        }
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
