import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReceiptCaptureView: View {
    enum Step: Int { case capture, reading, select, people, assign, split }
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let finish: () -> Void
    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var items: [ReceiptItem] = []
    @State private var purchaseDate = Date()
    @State private var recognizedText: String?
    /// The receipt's evidence once an earlier expense from it was saved; later expenses from it reuse this instead of uploading again.
    @State private var receiptEvidenceID: UUID?
    /// Items an earlier expense from this receipt already includes; shown dimmed but still selectable.
    @State private var claimedItemIDs: Set<UUID> = []
    /// User IDs of everyone splitting the expense; starts with the signed-in user.
    @State private var selectedPeople: Set<UUID> = []
    @State private var shares: [UUID: Int] = [:]
    /// Item-to-person choices used by Assign Items. An empty set excludes the row from this expense.
    @State private var itemAssignments: [UUID: Set<UUID>] = [:]
    /// Tracks whose contribution the user has fixed, so edits only move everyone else.
    @State private var balancer = ContributionBalancer()
    @State private var description = "Shared Expense"
    @State private var payer: UUID?
    @State private var category: ExpenseCategory?
    @State private var layout: ExpenseLayout = .selectItems
    @State private var error: String?
    @State private var editingItemID: UUID?
    @State private var personSearch = ""
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    @State private var assignmentPopoverItemID: UUID?

    private var includedItemIDs: Set<UUID> {
        switch layout {
        case .splitTotal: Set(items.filter { $0.totalCents > 0 }.map(\.id))
        case .selectItems: Set(items.filter(\.isSelected).map(\.id))
        case .assignItems: Set(itemAssignments.compactMap { $0.value.isEmpty ? nil : $0.key })
        }
    }
    /// Includes each included item's share of tax and discounts, which the item list doesn't show.
    private var total: Int { max(0, items.filter { includedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.totalCents }) }
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
                case .assign: assignmentScreen
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
            .overlay { if showSaveSuccess { SaveSuccessView().transition(.scale(scale: 0.75).combined(with: .opacity)) } }
        }
    }

    /// The scanner is unavailable in Simulator and on devices without a camera.
    private var canScan: Bool { VNDocumentCameraViewController.isSupported }
    private var title: String { switch step { case .capture: "Add expense"; case .reading: "Reading receipt"; case .select: "Review expense"; case .people: "Split with"; case .assign: "Assign items"; case .split: "Split expense" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { EmptyView() } actions: {
            Button { showCamera = true } label: { Label("Scan receipt", systemImage: "doc.viewfinder").prominentLabel() }.buttonStyle(.borderedProminent).disabled(!canScan)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; step = .select }.padding(.top, 12)
        }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding items").font(.headline) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var itemSelectionScreen: some View {
        List {
            Section { Picker("Split by", selection: $layout) { ForEach(ExpenseLayout.allCases) { Text($0.title).tag($0) } } }
            Section("Receipt details") { DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date) }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            if layout == .splitTotal {
                Section { LabeledContent("Expense total", value: total.usd).fontWeight(.semibold) }
            } else if layout == .assignItems {
                Section("Items") {
                    ForEach($items) { $item in
                        HStack {
                            Text(item.name.isEmpty ? "Unnamed item" : item.name).foregroundStyle(item.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Text(item.cents.usd).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
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
        }
        .safeAreaInset(edge: .bottom) {
            ContinueButton(title: layout == .assignItems ? "Choose people" : "Split \(total.usd)", disabled: layout != .assignItems && total == 0) { step = .people }
        }
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
                if store.splitCandidates.count <= 1 { Text("Add friends in Settings.") }
            }
        }
        .searchable(text: $personSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
        .submitLabel(.done)
        .overlay { if shownPeople.isEmpty { ContentUnavailableView.search(text: personSearch) } }
        .onAppear { if selectedPeople.isEmpty, let me = store.activeUserID { selectedPeople = [me] } }
        .safeAreaInset(edge: .bottom) {
            ContinueButton(title: "Confirm people", disabled: selectedPeople.isEmpty) {
                personSearch = ""
                if layout == .assignItems { prepareAssignments(); step = .assign }
                else { setEqualSplit(); step = .split }
            }
        }
    }
    private var assignmentScreen: some View {
        List {
            Section { Picker("Split by", selection: layoutBinding) { ForEach(ExpenseLayout.allCases) { Text($0.title).tag($0) } } }
            Section {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(item.name.isEmpty ? "Unnamed item" : item.name).fontWeight(.medium)
                            Spacer()
                            Text(item.totalCents.usd).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(orderedSelection, id: \.self) { person in
                                    let assigned = itemAssignments[item.id, default: []].contains(person)
                                    Button {
                                        if assigned { itemAssignments[item.id, default: []].remove(person) }
                                        else { itemAssignments[item.id, default: []].insert(person) }
                                        shares = assignedShares()
                                    } label: {
                                        Label(store.name(for: person), systemImage: assigned ? "checkmark.circle.fill" : "circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(assigned ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.45) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        assignmentPopoverItemID = item.id
                    }
                    .popover(
                        isPresented: Binding(
                            get: { assignmentPopoverItemID == item.id },
                            set: { isPresented in if !isPresented && assignmentPopoverItemID == item.id { assignmentPopoverItemID = nil } }
                        ),
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .trailing
                    ) {
                        AssignmentPeoplePopover(
                            itemName: item.name.isEmpty ? "Unnamed item" : item.name,
                            people: recentAssignmentPeople,
                            assignedPeople: Binding(
                                get: { itemAssignments[item.id, default: []] },
                                set: { people in
                                    itemAssignments[item.id] = people
                                    shares = assignedShares()
                                }
                            )
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityAction(named: "Assign people") { assignmentPopoverItemID = item.id }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueButton(title: "Continue with \(total.usd)", disabled: total == 0) { shares = assignedShares(); setDefaultPayer(); step = .split }
        }
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
    /// Selected participants in recent-use order for the assignment row's press-and-hold shortcut.
    private var recentAssignmentPeople: [UUID] {
        friendsByRecency.map(\.id).filter(selectedPeople.contains)
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
            Section { Picker("Split by", selection: layoutBinding) { ForEach(ExpenseLayout.allCases) { Text($0.title).tag($0) } } }
            Section("Name") {
                TextField("What was this for?", text: $description).submitLabel(.done)
                Picker("Category", selection: $category) {
                    Text("None").tag(ExpenseCategory?.none)
                    ForEach(ExpenseCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
                }
            }
            Section { Picker("Paid by", selection: $payer) { ForEach(orderedSelection, id: \.self) { Text(store.name(for: $0)).tag(Optional($0)) } }; LabeledContent("Expense total", value: total.usd).fontWeight(.semibold) }
            Section("Contributions") {
                ForEach(orderedSelection, id: \.self) { person in
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(store.name(for: person))
                            Spacer()
                            ContributionAmountField(name: store.name(for: person), cents: shareBinding(for: person), total: total)
                        }
                        if selectedPeople.count > 1 { ContributionSlider(name: store.name(for: person), cents: shareBinding(for: person), total: total, detent: equalShare(for: person)) }
                    }
                }
            }
            if !isValidSplit { Section { Text("Contributions must total \(total.usd). Currently \(allocationTotal.usd).") .foregroundStyle(.red) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .safeAreaInset(edge: .bottom) {
            // Save keeps its natural width; the pair is centered together, so Save sits just left of center.
            HStack(spacing: 12) {
                Button { save() } label: { Text(isSaving ? "Saving…" : "Save expense").prominentLabel() }.buttonStyle(.borderedProminent)
                Button { save(createNew: true) } label: { Image(systemName: "plus").fontWeight(.semibold) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("Save and add another")
            }
            .controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 10).disabled(!isValidSplit || isSaving)
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
    private func startReading() {
        guard let image else { return }
        step = .reading
        Task { @MainActor in
            let scan = (try? await Task.detached { try ReceiptTextRecognizer.scan(image) }.value) ?? ReceiptScan()
            let suggestion = ExpenseSuggester.suggest(from: scan)
            items = scan.items
            recognizedText = scan.recognizedText
            category = suggestion.category
            layout = suggestion.layout
            description = suggestion.name
            if layout != .selectItems { for index in items.indices { items[index].isSelected = true } }
            if let date = scan.purchaseDate { purchaseDate = date }
            error = scan.mismatchWarning
            if items.isEmpty { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; error = "No prices found." }
            step = .select
        }
    }
    private var layoutBinding: Binding<ExpenseLayout> {
        Binding(get: { layout }, set: { newLayout in
            guard newLayout != layout else { return }
            layout = newLayout
            shares = [:]
            balancer = ContributionBalancer()
            if step == .assign || step == .split { step = .select }
        })
    }
    /// Starts Assign Items from the existing selection when possible; otherwise every parsed row is shared initially.
    private func prepareAssignments() {
        let validPeople = selectedPeople
        itemAssignments = itemAssignments.reduce(into: [UUID: Set<UUID>]()) { result, entry in
            let kept = entry.value.intersection(validPeople)
            if !kept.isEmpty { result[entry.key] = kept }
        }
        if itemAssignments.isEmpty {
            let selected = items.filter(\.isSelected)
            for item in selected.isEmpty ? items : selected { itemAssignments[item.id] = validPeople }
        }
        shares = assignedShares()
        setDefaultPayer()
    }
    private func assignedShares() -> [UUID: Int] {
        var result = Dictionary(uniqueKeysWithValues: orderedSelection.map { ($0, 0) })
        for item in items {
            let people = orderedSelection.filter { itemAssignments[item.id, default: []].contains($0) }
            guard !people.isEmpty else { continue }
            let base = item.totalCents / people.count, remainder = item.totalCents % people.count
            for (index, person) in people.enumerated() { result[person, default: 0] += base + (index < remainder ? 1 : 0) }
        }
        return result
    }
    private func setDefaultPayer() {
        if payer.map(selectedPeople.contains) != true { payer = selectedPeople.contains(store.activeUserID ?? UUID()) ? store.activeUserID : orderedSelection.first }
    }
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
        setDefaultPayer()
    }
    /// With `createNew`, stays on this receipt afterwards so another expense can be split from it.
    private func save(createNew: Bool = false) {
        guard let payer else { return }
        let name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedItemIDs = includedItemIDs
        var savedItems = items
        for index in savedItems.indices { savedItems[index].isSelected = savedItemIDs.contains(savedItems[index].id) }
        var expense = Expense(description: name.isEmpty ? (category?.suggestedName ?? "Shared Expense") : name, transactionDate: purchaseDate, payer: payer, items: savedItems, shares: shares.filter { selectedPeople.contains($0.key) }, receiptImageData: image?.jpegData(compressionQuality: 0.72), recognizedText: recognizedText, category: category)
        // A receipt already saved with an earlier expense is attached again rather than uploaded twice.
        if let receiptEvidenceID { expense.evidenceIDs = [receiptEvidenceID]; expense.receiptImageData = nil }
        isSaving = true
        error = nil
        Task {
            do {
                let token = try await authentication.accessToken()
                store.stage(expense)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
                withAnimation(.spring(duration: 0.3, bounce: 0.25)) { showSaveSuccess = true }
                if createNew {
                    let upload = Task { try await store.syncStaged(expense, accessToken: token) }
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeOut(duration: 0.2)) { showSaveSuccess = false }
                    let evidenceIDs = try await upload.value
                    startNextExpense(receiptEvidenceID: evidenceIDs.first)
                } else {
                    Task { try? await store.syncStaged(expense, accessToken: token) }
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeOut(duration: 0.2)) { showSaveSuccess = false }
                    reset()
                    finish()
                }
            } catch {
                self.error = error.localizedDescription
                withAnimation(.easeOut(duration: 0.2)) { showSaveSuccess = false }
            }
            isSaving = false
        }
    }
    private func reset() { step = .capture; image = nil; selectedPhoto = nil; items = []; selectedPeople = []; payer = nil; shares = [:]; itemAssignments = [:]; assignmentPopoverItemID = nil; balancer = ContributionBalancer(); personSearch = ""; purchaseDate = Date();recognizedText = nil; receiptEvidenceID = nil; claimedItemIDs = []; error = nil; description = "Shared Expense"; category = nil; layout = .selectItems }
    /// Keeps the scanned receipt (image, items, date and recognized text) for another expense from it, marks the items just
    /// saved as claimed, and clears the item, people and contribution choices.
    private func startNextExpense(receiptEvidenceID savedEvidenceID: UUID?) {
        receiptEvidenceID = savedEvidenceID ?? receiptEvidenceID
        claimedItemIDs.formUnion(includedItemIDs)
        for index in items.indices { items[index].isSelected = false }
        selectedPeople = []; payer = nil; shares = [:]; itemAssignments = [:]; assignmentPopoverItemID = nil; balancer = ContributionBalancer(); personSearch = ""; error = nil; description = "Shared Expense"; category = nil; layout = .selectItems
        step = .select
    }
    /// Leaving the item list for a new photo or manual entry ends the link to the receipt saved earlier.
    private func back() { switch step { case .select: receiptEvidenceID = nil; claimedItemIDs = []; step = .capture; case .people: personSearch = ""; step = .select; case .assign: step = .people; case .split: step = layout == .assignItems ? .assign : .people; default: break } }
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

private struct SaveSuccessView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(.green)
            Text("Saved").font(.headline)
        }
        .padding(28)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct ContinueButton: View { let title: String; let disabled: Bool; let action: () -> Void; var body: some View { Button(action: action) { Text(title).prominentLabel() }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 10).disabled(disabled) } }

/// Compact assignment shortcut shown by pressing and holding an item row.
private struct AssignmentPeoplePopover: View {
    @Environment(ExpenseStore.self) private var store
    let itemName: String
    let people: [UUID]
    @Binding var assignedPeople: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(itemName).font(.headline).lineLimit(1).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people, id: \.self) { personID in
                        let person = store.person(for: personID)
                        let isAssigned = assignedPeople.contains(personID)
                        Button {
                            if isAssigned { assignedPeople.remove(personID) }
                            else { assignedPeople.insert(personID) }
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(userID: personID, name: person.name, etag: person.avatarEtag, size: 32)
                                Text(person.firstName).foregroundStyle(.primary)
                                Spacer()
                                SelectionCircle(isSelected: isAssigned)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isAssigned ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 250)
    }
}

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
