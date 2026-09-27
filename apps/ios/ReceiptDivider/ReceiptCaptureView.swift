import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReceiptCaptureView: View {
    enum Step: Int { case capture, reading, select, people, split }
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let finish: () -> Void
    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var items: [ReceiptItem] = []
    @State private var purchaseDate = Date()
    @State private var dateNote: String?
    @State private var recognizedText: String?
    /// The receipt's evidence once an earlier expense from it was saved; later expenses from it reuse this instead of uploading again.
    @State private var receiptEvidenceID: UUID?
    /// Items an earlier expense from this receipt already includes; shown dimmed but still selectable.
    @State private var claimedItemIDs: Set<UUID> = []
    /// User IDs of everyone splitting the expense; starts with the signed-in user.
    @State private var selectedPeople: Set<UUID> = []
    @State private var shares: [UUID: Int] = [:]
    /// Tracks whose contribution the user has fixed, so edits only move everyone else.
    @State private var balancer = ContributionBalancer()
    @State private var description = "Shared groceries"
    @State private var payer: UUID?
    @State private var error: String?
    @State private var editingItemID: UUID?
    @State private var didSave = false
    @State private var personSearch = ""
    @State private var isSaving = false

    /// Includes each selected item's share of tax and discounts, which the item list doesn't show.
    private var total: Int { max(0, items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents }) }
    private var allocationTotal: Int { selectedPeople.reduce(0) { $0 + (shares[$1] ?? 0) } }
    private var isValidSplit: Bool { !selectedPeople.isEmpty && allocationTotal == total && payer.map(selectedPeople.contains) == true }
    /// The signed-in user first, then everyone else by name.
    private var orderedSelection: [UUID] {
        selectedPeople.sorted { a, b in
            if (a == store.activeUserID) != (b == store.activeUserID) { return a == store.activeUserID }
            return store.name(for: a).localizedCaseInsensitiveCompare(store.name(for: b)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .capture: captureScreen
                case .reading: readingScreen
                case .select: itemSelectionScreen
                case .people: peopleScreen
                case .split: splitScreen
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if step != .capture && step != .reading { ToolbarItem(placement: .topBarLeading) { Button("Back") { back() } } } }
            .fullScreenCover(isPresented: $showCamera) { DocumentScanner(image: $image).ignoresSafeArea() }
            .onChange(of: image) { _, newImage in if newImage != nil { startReading() } }
            .onChange(of: selectedPhoto) { _, photo in load(photo) }
            .sensoryFeedback(.selection, trigger: items.filter(\.isSelected).count)
            .sensoryFeedback(.success, trigger: didSave)
        }
    }

    /// The scanner is unavailable in Simulator and on devices without a camera.
    private var canScan: Bool { VNDocumentCameraViewController.isSupported }
    private var title: String { switch step { case .capture: "Add expense"; case .reading: "Reading receipt"; case .select: "Select items"; case .people: "Split with"; case .split: "Split expense" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { Text("Take a photo to find individual costs, then choose only the items to share.") } actions: {
            Button { showCamera = true } label: { Label("Scan receipt", systemImage: "doc.viewfinder").prominentLabel() }.buttonStyle(.borderedProminent).disabled(!canScan)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; step = .select }.padding(.top, 12)
        }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding individual costs").font(.headline); Text("You’ll be able to review every item before sharing it.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var itemSelectionScreen: some View {
        List {
            Section { DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date) } header: { Text("Receipt details") } footer: { if let dateNote { Text(dateNote) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            if !claimedItemIDs.isEmpty { Section { Text("Dimmed items are already in an expense you saved from this receipt.").font(.footnote).foregroundStyle(.secondary) } }
            Section("Select items to share") {
                ForEach($items) { $item in
                    Button { withAnimation(.snappy(duration: 0.15)) { item.isSelected.toggle() } } label: {
                        HStack {
                            Text(item.name.isEmpty ? "Unnamed item" : item.name).foregroundStyle(item.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Text(item.cents.usd).monospacedDigit().foregroundStyle(.secondary)
                            SelectionCircle(isSelected: item.isSelected)
                        }
                        .opacity(claimedItemIDs.contains(item.id) && !item.isSelected ? 0.4 : 1)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .sensoryFeedback(.selection, trigger: item.isSelected)
                    .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                    .accessibilityValue(claimedItemIDs.contains(item.id) ? "In an earlier expense" : "")
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editingItemID = item.id }
                        Button("Delete", systemImage: "trash", role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button("Add item", systemImage: "plus") { let item = ReceiptItem(name: "", cents: 0, isSelected: true); items.append(item); editingItemID = item.id }
            }
        }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Split \(total.usd)", disabled: total == 0) { step = .people } }
        .sheet(item: $editingItemID) { id in
            if let index = items.firstIndex(where: { $0.id == id }) { ItemEditor(item: $items[index]) }
        }
    }
    private var peopleScreen: some View {
        List {
            Section {
                ForEach(shownPeople) { person in
                    let isSelected = selectedPeople.contains(person.id)
                    Button { withAnimation(.snappy(duration: 0.15)) { if isSelected { selectedPeople.remove(person.id) } else { selectedPeople.insert(person.id) } } } label: {
                        HStack(spacing: 12) {
                            AvatarView(userID: person.id, name: person.name, etag: person.avatarEtag, size: 34)
                            Text(store.name(for: person.id))
                            Spacer()
                            SelectionCircle(isSelected: isSelected)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .sensoryFeedback(.selection, trigger: isSelected)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            } footer: {
                if store.splitCandidates.count <= 1 { Text("Add friends from Profile → Friends to split expenses with them.") }
            }
        }
        .searchable(text: $personSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
        .submitLabel(.done)
        .overlay { if shownPeople.isEmpty { ContentUnavailableView.search(text: personSearch) } }
        .onAppear { if selectedPeople.isEmpty, let me = store.activeUserID { selectedPeople = [me] } }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Confirm people", disabled: selectedPeople.isEmpty) { personSearch = ""; setEqualSplit(); step = .split } }
    }
    /// You first, then friends ordered by their latest shared transaction; friends never shared with are alphabetical.
    private var friendsByRecency: [LedgerPerson] {
        let latest = store.expenses.reduce(into: [UUID: Date]()) { dates, expense in
            for person in expense.participants { dates[person] = max(dates[person] ?? .distantPast, expense.transactionDate) }
        }
        return store.splitCandidates.enumerated().sorted { a, b in
            if (a.element.id == store.activeUserID) != (b.element.id == store.activeUserID) { return a.element.id == store.activeUserID }
            let (dateA, dateB) = (latest[a.element.id] ?? .distantPast, latest[b.element.id] ?? .distantPast)
            return dateA != dateB ? dateA > dateB : a.offset < b.offset
        }.map(\.element)
    }
    /// You and your most recent friends for quick tapping, plus anyone already selected from a search. Searching covers every friend.
    private var shownPeople: [LedgerPerson] {
        guard personSearch.isEmpty else {
            return friendsByRecency.filter { [$0.name, $0.username ?? ""].contains { $0.localizedCaseInsensitiveContains(personSearch) } }
        }
        return friendsByRecency.enumerated().filter { $0.offset < 6 || selectedPeople.contains($0.element.id) }.map(\.element)
    }
    private var splitScreen: some View {
        List {
            Section("Name") { TextField("What was this for?", text: $description).submitLabel(.done) }
            Section { Picker("Paid by", selection: $payer) { ForEach(orderedSelection, id: \.self) { Text(store.name(for: $0)).tag(Optional($0)) } }; LabeledContent("Expense total", value: total.usd).fontWeight(.semibold) }
            Section("Contributions") {
                ForEach(orderedSelection, id: \.self) { person in
                    VStack(spacing: 4) {
                        LabeledContent(store.name(for: person)) { CentsField(title: "0.00", cents: shareBinding(for: person)).frame(width: 100) }
                        if selectedPeople.count > 1 { ContributionSlider(name: store.name(for: person), cents: shareBinding(for: person), total: total, detent: equalShare(for: person)) }
                    }
                }
            }
            if !isValidSplit { Section { Text("Contributions must total \(total.usd). Currently \(allocationTotal.usd).") .foregroundStyle(.red) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { save() } label: { Text(isSaving ? "Saving…" : "Save expense").prominentLabel().frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                Button { save(createNew: true) } label: { Image(systemName: "plus").fontWeight(.semibold) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("Save and add another")
                    .accessibilityHint("Saves this expense and starts another split from the same receipt.")
            }
            .controlSize(.large).padding(.horizontal).padding(.vertical, 10).disabled(!isValidSplit || isSaving)
        }
    }
    /// A library photo is cropped and flattened before reading, so the processed image is the only copy parsed and stored.
    private func load(_ photo: PhotosPickerItem?) {
        guard let photo else { return }
        step = .reading
        Task { @MainActor in
            guard let data = try? await photo.loadTransferable(type: Data.self), let picture = UIImage(data: data) else { step = .capture; return }
            image = await Task.detached { ReceiptImageProcessor.flatten(picture) }.value
        }
    }
    private func startReading() { guard let image else { return }; step = .reading; Task { @MainActor in let scan = (try? await Task.detached { try ReceiptTextRecognizer.scan(image) }.value) ?? ReceiptScan(); items = scan.items; recognizedText = scan.recognizedText; if let date = scan.purchaseDate { purchaseDate = date; dateNote = "Purchase date read from the receipt." } else { dateNote = "No date was found on the receipt, so today is used. Change it if the purchase was earlier." }; error = scan.mismatchWarning; if items.isEmpty { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; error = "No item prices were found. Add them manually." }; step = .select } }
    /// Editing one contribution rebalances the others so they always add up to the total.
    private func shareBinding(for person: UUID) -> Binding<Int> {
        Binding(get: { shares[person] ?? 0 }, set: { cents in
            shares = balancer.set(person, to: cents, in: shares, total: total, people: orderedSelection)
        })
    }
    /// The share `setEqualSplit` gives `person`: an equal part, plus one of the leftover cents for the first people.
    private func equalShare(for person: UUID) -> Int {
        let people = orderedSelection
        guard let index = people.firstIndex(of: person) else { return 0 }
        return total / people.count + (index < total % people.count ? 1 : 0)
    }
    /// Splits the total evenly; extra cents go to the first people in `orderedSelection`. Defaults the payer to you.
    private func setEqualSplit() {
        let people = orderedSelection
        guard !people.isEmpty else { return }
        let base = total / people.count, remainder = total % people.count
        shares = Dictionary(uniqueKeysWithValues: people.enumerated().map { index, person in (person, base + (index < remainder ? 1 : 0)) })
        balancer = ContributionBalancer()
        if payer.map(selectedPeople.contains) != true { payer = selectedPeople.contains(store.activeUserID ?? UUID()) ? store.activeUserID : people.first }
    }
    /// With `createNew`, stays on this receipt afterwards so another expense can be split from it.
    private func save(createNew: Bool = false) {
        guard let payer else { return }
        let name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var expense = Expense(description: name.isEmpty ? "Shared groceries" : name, transactionDate: purchaseDate, payer: payer, items: items, shares: shares.filter { selectedPeople.contains($0.key) }, receiptImageData: image?.jpegData(compressionQuality: 0.72), recognizedText: recognizedText)
        // A receipt already saved with an earlier expense is attached again rather than uploaded twice.
        if let receiptEvidenceID { expense.evidenceIDs = [receiptEvidenceID]; expense.receiptImageData = nil }
        isSaving = true
        error = nil
        Task {
            do {
                let token = try await authentication.accessToken()
                let evidenceIDs = try await store.add(expense, accessToken: token)
                didSave.toggle()
                if createNew { startNextExpense(receiptEvidenceID: evidenceIDs.first) } else { reset(); finish() }
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
    private func reset() { step = .capture; image = nil; selectedPhoto = nil; items = []; selectedPeople = []; payer = nil; shares = [:]; balancer = ContributionBalancer(); personSearch = ""; purchaseDate = Date(); dateNote = nil; recognizedText = nil; receiptEvidenceID = nil; claimedItemIDs = []; error = nil; description = "Shared groceries" }
    /// Keeps the scanned receipt (image, items, date and recognized text) for another expense from it, marks the items just
    /// saved as claimed, and clears the item, people and contribution choices.
    private func startNextExpense(receiptEvidenceID savedEvidenceID: UUID?) {
        receiptEvidenceID = savedEvidenceID ?? receiptEvidenceID
        claimedItemIDs.formUnion(items.filter(\.isSelected).map(\.id))
        for index in items.indices { items[index].isSelected = false }
        selectedPeople = []; payer = nil; shares = [:]; balancer = ContributionBalancer(); personSearch = ""; error = nil; description = "Shared groceries"
        step = .select
    }
    /// Leaving the item list for a new photo or manual entry ends the link to the receipt saved earlier.
    private func back() { switch step { case .select: receiptEvidenceID = nil; claimedItemIDs = []; step = .capture; case .people: personSearch = ""; step = .select; case .split: step = .people; default: break } }
}

/// Keeps contributions adding up to the total. Touching a contribution fixes it; the change is split equally among
/// everyone not fixed. One person always stays free: touching the last free one frees whoever was touched longest ago.
struct ContributionBalancer {
    /// People whose contribution is fixed, least recently touched first.
    private(set) var fixed: [UUID] = []
    /// Everyone's shares from when the person being edited was first touched. Each edit spreads from these rather than
    /// the last update, so rounding cents don't pile onto one person over the course of a drag.
    private var start: (person: UUID, shares: [UUID: Int])?

    /// Sets `person`'s contribution and returns the rebalanced shares. The value is capped so the free people never drop
    /// below zero. With only one person, their contribution is always the whole total.
    mutating func set(_ person: UUID, to cents: Int, in shares: [UUID: Int], total: Int, people: [UUID]) -> [UUID: Int] {
        var result = shares.filter { people.contains($0.key) }
        guard people.count > 1, people.contains(person) else { result[person] = total; return result }
        if start?.person != person { start = (person, result) }
        fixed.removeAll { $0 == person || !people.contains($0) }
        fixed.append(person)
        if fixed.count == people.count { fixed.removeFirst() }
        let base = start?.shares ?? result
        let otherFixed = fixed.dropLast().reduce(0) { $0 + (base[$1] ?? 0) }
        let value = min(max(cents, 0), total - otherFixed)
        let free = people.filter { !fixed.contains($0) }
        let change = total - otherFixed - value - free.reduce(0) { $0 + (base[$1] ?? 0) }
        result[person] = value
        for (other, cents) in zip(free, Self.spread(change, over: free.map { base[$0] ?? 0 })) { result[other] = cents }
        return result
    }

    /// Adds `amount` to `values` in equal parts, leftover cents going to the first. Anyone reaching zero stops shrinking
    /// and the rest is shared among the others.
    static func spread(_ amount: Int, over values: [Int]) -> [Int] {
        var values = values, remaining = amount
        while remaining != 0 {
            let open = values.indices.filter { remaining > 0 || values[$0] > 0 }
            guard !open.isEmpty else { break }
            let part = remaining / open.count
            for index in open where remaining != 0 {
                let applied = max(part != 0 ? part : remaining.signum(), -values[index])
                values[index] += applied
                remaining -= applied
            }
        }
        return values
    }
}

private struct ContinueButton: View { let title: String; let disabled: Bool; let action: () -> Void; var body: some View { Button(action: action) { Text(title).prominentLabel() }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 10).disabled(disabled) } }

private extension View {
    func prominentLabel() -> some View { modifier(ProminentLabel()) }
}

/// The app tint is `.primary`, so a prominent button fills black in light mode and white in dark mode while the
/// system label stays white. The background color is always the opposite of the fill; a disabled button's fill
/// is a faint wash of the tint, so its label uses `.primary`, which the disabled style dims to gray.
private struct ProminentLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.foregroundStyle(isEnabled ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary)) }
}

/// Trailing selection indicator drawn with the same symbols iOS uses for list selection.
private struct SelectionCircle: View {
    let isSelected: Bool
    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace, options: .speed(2)))
            .accessibilityHidden(true)
    }
}

private struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: ReceiptItem
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $item.name).submitLabel(.done)
                LabeledContent("Price") { CentsField(title: "0.00", cents: $item.cents) }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

extension UUID: @retroactive Identifiable { public var id: UUID { self } }
