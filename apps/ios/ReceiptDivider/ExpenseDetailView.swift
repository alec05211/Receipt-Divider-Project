import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let expense: Expense
    @State private var receipt: UIImage?
    @State private var isLoadingReceipt = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var isEditingDate = false
    @State private var draftDate = Date.now
    @State private var editError: String?

    /// The store's copy, so an edit (or a refresh) shows here as soon as it happens.
    private var current: Expense { store.expenses.first { $0.id == expense.id } ?? expense }
    /// Only the person who paid owns an expense and may edit it.
    private var canEdit: Bool { current.payer == store.activeUserID }
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
                NavigationLink {
                    ExpenseReviewEditorView(expense: current, isEditable: canEdit)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.description).font(.title2.bold())
                        ViewThatFits(in: .horizontal) {
                            metadataLine(font: .subheadline, avatarSize: 20)
                            metadataLine(font: .caption, avatarSize: 18)
                            metadataLine(font: .caption2, avatarSize: 16)
                            metadataLine(font: .system(size: 9), avatarSize: 14)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
                // Press and hold to edit. An empty menu builder disables the menu, so only the payer gets one.
                .contextMenu {
                    if canEdit {
                        ForEach(ExpenseEdit.allCases) { edit in
                            Button(edit.title, systemImage: edit.systemImage) { begin(edit) }
                        }
                    }
                }
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
                    LabeledContent {
                        HStack(spacing: 8) {
                            if !item.ownerIDs.isEmpty { AvatarStack(people: Array(item.ownerIDs)) }
                            Text(item.cents.usd)
                        }
                    } label: {
                        Text(item.name)
                    }
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
        .alert("Edit name", isPresented: $isEditingName) {
            TextField("Name", text: $draftName)
                .onChange(of: draftName) { _, newValue in if newValue.count > 200 { draftName = String(newValue.prefix(200)) } }
            Button("Cancel", role: .cancel) {}
            Button("Save") { save(description: draftName) }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $isEditingDate) {
            NavigationStack {
                DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    .navigationTitle("Date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isEditingDate = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                isEditingDate = false
                                save(transactionDate: draftDate)
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Couldn’t save", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
        .navigationTitle("Expense")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metadataLine(font: Font, avatarSize: CGFloat) -> some View {
        let payer = store.person(for: current.payer)
        return HStack(spacing: 4) {
            Text(current.total.usd).fontWeight(.semibold)
            Text("paid by").foregroundStyle(.secondary)
            AvatarView(userID: current.payer, name: payer.name, etag: payer.avatarEtag, size: avatarSize)
                .accessibilityHidden(true)
            Text(payer.firstName)
            Text("on").foregroundStyle(.secondary)
            Text(current.transactionDate.formatted(date: .abbreviated, time: .omitted))
        }
        .font(font)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension ExpenseDetailView {
    private func loadReceipt() async {
        guard receipt == nil, current.receiptImageData == nil, let evidenceID = current.evidenceIDs.first else { return }
        isLoadingReceipt = true
        if let token = try? await authentication.accessToken() { receipt = await store.receiptImage(evidenceID, accessToken: token) }
        isLoadingReceipt = false
    }

    private func begin(_ edit: ExpenseEdit) {
        switch edit {
        case .name:
            draftName = current.description
            isEditingName = true
        case .date:
            draftDate = current.transactionDate
            isEditingDate = true
        }
    }

    /// Shows the edit at once; the store puts the old values back and this reports why if the server refuses it.
    private func save(description: String? = nil, transactionDate: Date? = nil) {
        Task {
            do {
                try await store.updateExpense(expense.id, description: description, transactionDate: transactionDate, accessToken: authentication.accessToken())
            } catch {
                editError = error.localizedDescription
            }
        }
    }
}

/// What the payer can change from the press-and-hold menu. Add a case here (and to `begin`) to offer a new edit.
private enum ExpenseEdit: CaseIterable, Identifiable {
    case name, date

    var id: Self { self }
    var title: String {
        switch self {
        case .name: "Edit name"
        case .date: "Edit date"
        }
    }
    var systemImage: String {
        switch self {
        case .name: "pencil"
        case .date: "calendar"
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
