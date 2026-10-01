import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReceiptCaptureView: View {
    enum Step: Int { case capture, reading, review, assign, split, contributions }
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let finish: () -> Void
    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var items: [ReceiptItem] = []
    @State private var reviewedTotalCents: Int?
    @State private var purchaseDate = Date()
    @State private var recognizedText: String?
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
    @State private var layout: ExpenseLayout = .splitTotal
    @State private var error: String?
    @State private var editingItemID: UUID?
    @State private var personSearch = ""
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    @State private var activeAssignmentTarget: AssignmentTarget?
    @State private var assignmentsLocked = false
    /// Invalidates a slow semantic refinement when another receipt starts or the flow resets.
    @State private var receiptAnalysisID: UUID?
    /// Exact manual state before confirmation, restored when Back rescinds the lock/autofill operation.
    @State private var assignmentsBeforeLock: [UUID: Set<UUID>]?
    /// iOS 17 fallback heights for the fixed Review expense lists; newer releases measure their content instead.
    @ScaledMetric(relativeTo: .body) private var reviewControlRowHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .footnote) private var reviewWarningHeight: CGFloat = 82

    private var includedItemIDs: Set<UUID> {
        switch layout {
        case .splitTotal: Set(items.filter { $0.totalCents > 0 }.map(\.id))
        case .assignItems: Set(itemAssignments.compactMap { $0.value.isEmpty ? nil : $0.key })
        }
    }
    private var receiptTotal: Int { max(0, items.reduce(0) { $0 + $1.totalCents }) }
    /// Before assignments exist, Assign Items reviews the whole receipt; afterwards its total follows assigned rows.
    private var total: Int {
        switch layout {
        case .splitTotal: return max(0, reviewedTotalCents ?? receiptTotal)
        case .assignItems:
            guard !itemAssignments.isEmpty || step == .review else { return 0 }
            if itemAssignments.isEmpty { return receiptTotal }
            return max(0, items.filter { includedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.totalCents })
        }
    }
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
                case .review: reviewScreen
                case .assign: assignmentScreen
                case .split: splitScreen
                case .contributions: contributionsScreen
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .capture && step != .reading {
                    ToolbarItem(placement: .topBarLeading) { Button("Back") { back() } }
                }
                if step == .review {
                    ToolbarItem(placement: .principal) {
                        Text("Review expense").font(.headline)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Split") { advanceFromReview() }
                            .disabled(selectedPeople.isEmpty || total == 0)
                    }
                }
                if step == .assign {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { confirmAssignments() } label: {
                            if assignmentsLocked { Text("Continue") }
                            else { Image(systemName: "checkmark").accessibilityLabel("Confirm assignments") }
                        }
                        .disabled(items.isEmpty || receiptTotal == 0)
                    }
                }
                if step == .split {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") { save() }
                            .disabled(!isValidSplit || isSaving)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) { DocumentScanner(image: $image).ignoresSafeArea() }
            .onChange(of: image) { _, newImage in if newImage != nil { startReading() } }
            .onChange(of: selectedPhoto) { _, photo in load(photo) }
            .overlay { if showSaveSuccess { SaveSuccessView().transition(.scale(scale: 0.75).combined(with: .opacity)) } }
        }
    }

    /// The scanner is unavailable in Simulator and on devices without a camera.
    private var canScan: Bool { VNDocumentCameraViewController.isSupported }
    private var title: String { switch step { case .capture: "Add expense"; case .reading: "Reading receipt"; case .review, .split: "Review expense"; case .assign: "Assign items"; case .contributions: "Edit contributions" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { EmptyView() } actions: {
            Button { showCamera = true } label: { Label("Scan receipt", systemImage: "doc.viewfinder").prominentLabel() }.buttonStyle(.borderedProminent).disabled(!canScan)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; reviewedTotalCents = 0; layout = .splitTotal; step = .review }.padding(.top, 12)
        }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding items").font(.headline) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// Receipt details and participant selection share the first screen after recognition.
    private var reviewScreen: some View {
        VStack(spacing: 12) {
            List {
                Section {
                    if layout == .splitTotal {
                        LabeledContent("Expense total") { CentsField(title: "0.00", cents: totalBinding).fontWeight(.semibold) }
                    } else {
                        LabeledContent("Expense total", value: total.usd).fontWeight(.semibold)
                    }
                    DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                    Picker("Split by", selection: reviewLayoutBinding) { ForEach(ExpenseLayout.allCases) { Text($0.title).tag($0) } }
                    Picker("Paid by", selection: $payer) { ForEach(orderedSelection, id: \.self) { Text(store.name(for: $0)).tag(Optional($0)) } }
                }
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search friends", text: $personSearch).submitLabel(.done)
                        if !personSearch.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { personSearch = "" }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .reviewListStyle()
            .fixedReviewList(estimatedHeight: reviewControlRowHeight * 5 + 28)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shownPeople.enumerated()), id: \.element.id) { index, person in
                        let isSelected = selectedPeople.contains(person.id)
                        Button {
                            withAnimation(.snappy(duration: 0.15)) {
                                if isSelected { selectedPeople.remove(person.id) }
                                else { selectedPeople.insert(person.id) }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(userID: person.id, name: person.name, etag: person.avatarEtag, size: 34)
                                Text(store.name(for: person.id))
                                Spacer()
                                SelectionCircle(isSelected: isSelected)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .sensoryFeedback(.selection, trigger: isSelected)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        if index < shownPeople.count - 1 {
                            Divider().padding(.leading, 62).padding(.trailing, 16)
                        }
                    }
                    if shownPeople.isEmpty {
                        ContentUnavailableView.search(text: personSearch)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    if store.splitCandidates.count <= 1 {
                        Text("Add friends in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .scenePadding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if let error {
                List {
                    Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
                .reviewListStyle()
                .fixedReviewList(estimatedHeight: reviewWarningHeight)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if selectedPeople.isEmpty, let me = store.activeUserID { selectedPeople = [me] }
            setDefaultPayer()
        }
        .onChange(of: selectedPeople) { _, _ in setDefaultPayer() }
    }
    private var assignmentScreen: some View {
        List {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Text(item.name.isEmpty ? "Unnamed item" : item.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            .mask {
                                LinearGradient(
                                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.58), .init(color: .clear, location: 0.95)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                        let assigned = recentAssignmentPeople.filter { itemAssignments[item.id, default: []].contains($0) }
                        if !assigned.isEmpty { AvatarStack(people: assigned, size: 22) }
                        Text(item.totalCents.usd).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                    .frame(height: 26)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !assignmentsLocked, let target = activeAssignmentTarget else { return }
                        toggleAssignment(target, for: item.id)
                    }
                    .accessibilityAction(named: "Assign people") {
                        if !assignmentsLocked, let target = activeAssignmentTarget { toggleAssignment(target, for: item.id) }
                    }
                    .swipeActions {
                        if !assignmentsLocked {
                            Button("Edit", systemImage: "pencil") { editingItemID = item.id }
                            Button("Delete", systemImage: "trash", role: .destructive) { items.removeAll { $0.id == item.id }; itemAssignments[item.id] = nil; shares = assignedShares() }
                        }
                    }
                }
                if !assignmentsLocked {
                    Button("Add item", systemImage: "plus") { let item = ReceiptItem(name: "", cents: 0); items.append(item); editingItemID = item.id }
                }
            }
        }
        .sheet(item: $editingItemID) { id in
            if let index = items.firstIndex(where: { $0.id == id }) { ItemEditor(item: $items[index]) }
        }
        .onChange(of: items) { _, _ in shares = assignedShares() }
        .safeAreaInset(edge: .bottom) {
            assignmentFilters
        }
    }

    private var assignmentFilters: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let horizontalPadding: CGFloat = 16
            let pillWidth = (geometry.size.width - horizontalPadding * 2 - spacing * 4) / 5
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    let allIsActive = activeAssignmentTarget == .all
                    Button { selectAssignmentTarget(.all) } label: {
                        AssignmentTargetPill(title: "All", isActive: allIsActive, width: pillWidth) {
                            Image(systemName: "person.3.fill").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(assignmentsLocked)
                    .accessibilityAddTraits(allIsActive ? .isSelected : [])

                    ForEach(recentAssignmentPeople, id: \.self) { personID in
                        let person = store.person(for: personID)
                        let isActive = activeAssignmentTarget == .person(personID)
                        Button { selectAssignmentTarget(.person(personID)) } label: {
                            AssignmentTargetPill(title: person.firstName, isActive: isActive, width: pillWidth) {
                                AvatarView(userID: personID, name: person.name, etag: person.avatarEtag, size: 20)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(assignmentsLocked)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
            }
        }
        .frame(height: 56)
        .background(.bar)
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
    /// Selected participants in recent-use order for the assignment filter strip.
    private var recentAssignmentPeople: [UUID] {
        friendsByRecency.map(\.id).filter(selectedPeople.contains)
    }
    /// You first, then every friend by recency; searching narrows the same complete list.
    private var shownPeople: [LedgerPerson] {
        guard personSearch.isEmpty else {
            return friendsByRecency.filter { [$0.name, $0.username ?? ""].contains { $0.localizedCaseInsensitiveContains(personSearch) } }
        }
        return friendsByRecency
    }
    private var splitScreen: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Menu {
                        Button("None", systemImage: "circle.dashed") { category = nil }
                        ForEach(ExpenseCategory.allCases) { value in
                            Button(value.title, systemImage: value.symbol) { category = value }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category?.symbol ?? "circle.dashed")
                            Text(category?.title ?? "None")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    TextField("What was this for?", text: $description).submitLabel(.done)
                }
            }
            Section {
                Picker("Paid by", selection: $payer) { ForEach(orderedSelection, id: \.self) { Text(store.name(for: $0)).tag(Optional($0)) } }
                DatePicker("Date of expense", selection: $purchaseDate, displayedComponents: .date)
                Picker("Split by", selection: layoutBinding) { ForEach(ExpenseLayout.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Expense total", value: total.usd).fontWeight(.semibold)
            }
            Section {
                Button("Edit Contributions") { step = .contributions }
            }
            if !isValidSplit { Section { Text("Contributions must total \(total.usd). Currently \(allocationTotal.usd).") .foregroundStyle(.red) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
    }
    private var contributionsScreen: some View {
        List {
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
        }
        .safeAreaInset(edge: .bottom) {
            ContinueButton(title: "Done", disabled: !isValidSplit) { step = .split }
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
        let analysisID = UUID()
        receiptAnalysisID = analysisID
        Task { @MainActor in
            let scan = (try? await ReceiptTextRecognizer.scan(image)) ?? ReceiptScan()
            guard receiptAnalysisID == analysisID else { return }
            let suggestion = ExpenseSuggester.suggest(from: scan)
            items = scan.items
            recognizedText = scan.recognizedText
            category = suggestion.category
            layout = suggestion.layout
            description = suggestion.name
            for index in items.indices { items[index].isSelected = true }
            reviewedTotalCents = scan.printedTotalCents ?? receiptTotal
            if let date = scan.purchaseDate { purchaseDate = date }
            error = scan.mismatchWarning
            if items.isEmpty {
                items = [ReceiptItem(name: "", cents: 0, isSelected: true)]
                reviewedTotalCents = scan.printedTotalCents ?? 0
                if scan.printedTotalCents != nil { error = nil }
                else { error = "No prices found." }
            }
            step = .review

            // Semantic cleanup can take several seconds on-device. Review is usable immediately, and refinements
            // apply only while the corresponding field still has its original extracted value.
            let originalNames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
            let originalDescription = description
            let originalCategory = category
            let originalTotal = reviewedTotalCents
            let originalDate = purchaseDate
            let originalError = error
            let analysis = await OnDeviceReceiptAnalyzer.analyze(scan)
            guard receiptAnalysisID == analysisID, step == .review else { return }
            for refined in analysis.scan.items {
                guard let index = items.firstIndex(where: { $0.id == refined.id }),
                      let originalName = originalNames[refined.id],
                      items[index].name == originalName else { continue }
                items[index].name = refined.name
            }
            if description == originalDescription { description = analysis.suggestion.name }
            if category == originalCategory { category = analysis.suggestion.category }
            if reviewedTotalCents == originalTotal { reviewedTotalCents = analysis.scan.printedTotalCents ?? originalTotal }
            if purchaseDate == originalDate, let refinedDate = analysis.scan.purchaseDate { purchaseDate = refinedDate }
            if error == originalError { error = analysis.scan.mismatchWarning }
        }
    }
    private var totalBinding: Binding<Int> {
        Binding(get: { total }, set: { reviewedTotalCents = max(0, $0) })
    }
    private var reviewLayoutBinding: Binding<ExpenseLayout> {
        Binding(get: { layout }, set: { newLayout in
            guard newLayout != layout else { return }
            layout = newLayout
            if newLayout == .splitTotal, reviewedTotalCents == nil { reviewedTotalCents = receiptTotal }
            shares = [:]
            balancer = ContributionBalancer()
        })
    }
    private func advanceFromReview() {
        personSearch = ""
        if layout == .assignItems {
            prepareAssignments()
            step = .assign
        } else {
            prepareFinalSplit()
            step = .split
        }
    }
    private var layoutBinding: Binding<ExpenseLayout> {
        Binding(get: { layout }, set: { newLayout in
            guard newLayout != layout else { return }
            layout = newLayout
            if newLayout == .splitTotal, reviewedTotalCents == nil { reviewedTotalCents = receiptTotal }
            shares = [:]
            balancer = ContributionBalancer()
            if step == .assign || step == .split || step == .contributions { step = .review }
        })
    }
    /// Preserves valid prior assignments and starts with All as the active assignment target.
    private func prepareAssignments() {
        let validPeople = selectedPeople
        itemAssignments = itemAssignments.reduce(into: [UUID: Set<UUID>]()) { result, entry in
            let kept = entry.value.intersection(validPeople)
            if !kept.isEmpty { result[entry.key] = kept }
        }
        activeAssignmentTarget = .all
        assignmentsLocked = false
        assignmentsBeforeLock = nil
        shares = assignedShares()
        setDefaultPayer()
    }
    private func selectAssignmentTarget(_ target: AssignmentTarget) {
        activeAssignmentTarget = target
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func toggleAssignment(_ target: AssignmentTarget, for itemID: UUID) {
        switch target {
        case .all:
            if selectedPeople.isSubset(of: itemAssignments[itemID, default: []]) { itemAssignments[itemID, default: []].subtract(selectedPeople) }
            else { itemAssignments[itemID, default: []].formUnion(selectedPeople) }
        case let .person(personID):
            if itemAssignments[itemID, default: []].contains(personID) { itemAssignments[itemID, default: []].remove(personID) }
            else { itemAssignments[itemID, default: []].insert(personID) }
        }
        shares = assignedShares()
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// The first confirmation visibly assigns every untouched row to the payer. A second press continues.
    private func confirmAssignments() {
        if assignmentsLocked {
            shares = assignedShares()
            step = .split
            return
        }
        setDefaultPayer()
        guard let payer else { return }
        assignmentsBeforeLock = itemAssignments
        withAnimation(.snappy(duration: 0.2)) {
            for item in items where itemAssignments[item.id, default: []].isEmpty {
                itemAssignments[item.id] = [payer]
            }
            shares = assignedShares()
            assignmentsLocked = true
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    private func undoAssignmentConfirmation() {
        withAnimation(.snappy(duration: 0.2)) {
            if let assignmentsBeforeLock { itemAssignments = assignmentsBeforeLock }
            shares = assignedShares()
            assignmentsLocked = false
            assignmentsBeforeLock = nil
        }
        UISelectionFeedbackGenerator().selectionChanged()
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
    private func prepareFinalSplit() {
        let hasEveryPerson = Set(shares.keys) == selectedPeople
        if !hasEveryPerson || allocationTotal != total { setEqualSplit() }
        else { setDefaultPayer() }
    }
    private func save() {
        guard let payer else { return }
        let name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split Total saves the reviewed amount without line items; Assign Items saves only assigned rows.
        let savedItemIDs: Set<UUID> = layout == .splitTotal ? [] : includedItemIDs
        var savedItems = items
        for index in savedItems.indices { savedItems[index].isSelected = savedItemIDs.contains(savedItems[index].id) }
        var expense = Expense(description: name.isEmpty ? (category?.suggestedName ?? "Shared Expense") : name, transactionDate: purchaseDate, payer: payer, items: savedItems, shares: shares.filter { selectedPeople.contains($0.key) }, receiptImageData: image?.jpegData(compressionQuality: 0.72), recognizedText: recognizedText, category: category)
        if layout == .splitTotal { expense.recordedTotalCents = total }
        isSaving = true
        error = nil
        Task {
            do {
                let token = try await authentication.accessToken()
                store.stage(expense)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
                withAnimation(.spring(duration: 0.3, bounce: 0.25)) { showSaveSuccess = true }
                Task { try? await store.syncStaged(expense, accessToken: token) }
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.2)) { showSaveSuccess = false }
                reset()
                finish()
            } catch {
                self.error = error.localizedDescription
                withAnimation(.easeOut(duration: 0.2)) { showSaveSuccess = false }
            }
            isSaving = false
        }
    }
    private func reset() { receiptAnalysisID = nil; step = .capture; image = nil; selectedPhoto = nil; items = []; reviewedTotalCents = nil; selectedPeople = []; payer = nil; shares = [:]; itemAssignments = [:]; activeAssignmentTarget = nil; assignmentsLocked = false; assignmentsBeforeLock = nil; balancer = ContributionBalancer(); personSearch = ""; purchaseDate = Date(); recognizedText = nil; error = nil; description = "Shared Expense"; category = nil; layout = .splitTotal }
    private func back() {
        switch step {
        case .review: personSearch = ""; step = .capture
        case .assign:
            if assignmentsLocked { undoAssignmentConfirmation() }
            else { step = .review }
        case .split:
            if layout == .assignItems {
                step = .assign
                if assignmentsLocked { undoAssignmentConfirmation() }
            } else {
                step = .review
            }
        case .contributions: step = .split
        default: break
        }
    }
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

private enum AssignmentTarget: Equatable {
    case all
    case person(UUID)
}

private struct AssignmentTargetPill<Icon: View>: View {
    let title: String
    let isActive: Bool
    let width: CGFloat
    let icon: Icon

    init(title: String, isActive: Bool, width: CGFloat, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.isActive = isActive
        self.width = width
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title).lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(isActive ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
        .padding(.horizontal, 5)
        .frame(width: width, height: 36)
        .background(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.thinMaterial), in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
    }
}

private extension View {
    func prominentLabel() -> some View { modifier(ProminentLabel()) }
    func reviewListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .listSectionSpacing(12)
    }
    func fixedReviewList(estimatedHeight: CGFloat) -> some View { modifier(FixedReviewList(estimatedHeight: estimatedHeight)) }
}

/// A non-scrolling list framed to exactly its content, since row heights vary by iOS release and text size.
private struct FixedReviewList: ViewModifier {
    let estimatedHeight: CGFloat
    @State private var contentHeight: CGFloat?
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .scrollDisabled(true)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in if height > 0 { contentHeight = height } }
                .frame(height: contentHeight ?? estimatedHeight)
        } else {
            content.scrollDisabled(true).frame(height: estimatedHeight)
        }
    }
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
