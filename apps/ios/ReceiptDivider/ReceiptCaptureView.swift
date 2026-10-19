import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReceiptCaptureView: View {
    enum Step: Int { case capture, reading, review, assign, split, contributions }
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let finish: () -> Void
    var openScannerTrigger: Int = 0

    init(finish: @escaping () -> Void, openScannerTrigger: Int = 0) {
        self.finish = finish
        self.openScannerTrigger = openScannerTrigger
    }
    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var items: [ReceiptItem] = []
    /// Receipt-wide discounts, taxes, tip and surcharges in receipt order; they set every row's global offset.
    @State private var adjustments: [ReceiptAdjustment] = []
    /// The total printed on the receipt, when recognition found one.
    @State private var printedTotalCents: Int?
    /// Set by Split All: everyone shares the printed total equally, whether or not the items add up to it.
    @State private var splitsPrintedTotal = false
    @State private var purchaseDate = Date()
    @State private var recognizedText: String?
    @State private var diagnostics: ReceiptDiagnostics?
    /// Which reader handled the last scan and how long it took, shown in Settings for developers.
    @AppStorage(ReceiptDiagnostics.lastScanKey) private var lastScan = ""
    @AppStorage(TipSplit.storageKey) private var tipSplit: TipSplit = .even
    /// User IDs of everyone splitting the expense; starts with the signed-in user.
    @State private var selectedPeople: Set<UUID> = []
    @State private var shares: [UUID: Int] = [:]
    /// Who owns each row. An unassigned row belongs to the payer.
    @State private var itemAssignments: [UUID: Set<UUID>] = [:]
    @State private var description = "Shared Expense"
    @State private var payer: UUID?
    @State private var category: ExpenseCategory?
    @State private var error: String?
    @State private var personSearch = ""
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    @State private var assignmentsLocked = false
    /// Invalidates a reading still in progress when another receipt starts or the flow resets.
    @State private var receiptAnalysisID: UUID?
    /// True while the receipt's items are still being read, after its text has been recognized.
    @State private var isExtracting = false
    /// Set when the user confirms participants before the items are read; the flow continues once they are.
    @State private var continuesAfterExtraction = false
    /// Manual entries have no total until Review expense, so participant selection can't require one.
    @State private var isManualEntry = false
    /// Exact manual state before confirmation, restored when Back rescinds the lock/autofill operation.
    @State private var assignmentsBeforeLock: [UUID: Set<UUID>]?

    /// A receipt with at most one item skips assignment and belongs to everyone selected.
    private var hasSingleItem: Bool { items.filter { $0.kind == .item }.count <= 1 }
    private var receiptTotal: Int { max(0, items.reduce(0) { $0 + $1.totalCents }) }
    private var total: Int {
        if splitsPrintedTotal, let printedTotalCents { return printedTotalCents }
        return max(0, expenseItems.reduce(0) { $0 + $1.totalCents } + adjustments.tipCents)
    }
    /// What each person owes from ownership: their items, plus their part of the tip as chosen in Settings.
    private func ownershipShares(_ items: [ReceiptItem]) -> [UUID: Int] {
        (items + items.tipRows(adjustments.tipCents, among: selectedPeople, split: tipSplit)).ownerShares(for: orderedSelection)
    }
    /// An even split of the printed total, used only after Split All.
    private var printedTotalShares: [UUID: Int]? {
        guard splitsPrintedTotal, let printedTotalCents else { return nil }
        return [ReceiptItem(name: "", cents: printedTotalCents, ownerIDs: selectedPeople)].ownerShares(for: orderedSelection)
    }
    /// The priced items and their owners in the saved expense. When no rows were assigned, all items belong to all selected participants.
    private var expenseItems: [ReceiptItem] {
        // A $0 row still counts when an adjustment is spread over it, as when tax is added to a $0 manual amount.
        var result = items.filter { $0.cents > 0 || $0.globalOffsetCents != 0 }
        let isDefaultEven = !hasAnyItemAssignments
        for index in result.indices {
            if isDefaultEven {
                result[index].ownerIDs = selectedPeople
            } else {
                let owners = itemAssignments[result[index].id, default: []].intersection(selectedPeople)
                result[index].ownerIDs = owners.isEmpty ? Set(payer.map { [$0] } ?? []) : owners
            }
            result[index].isSelected = true
            if result[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[index].name = result.count == 1 ? savedDescription : "Item"
            }
        }
        return result
    }
    private var savedDescription: String {
        let name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (category?.suggestedName ?? "Shared Expense") : name
    }
    /// Only assignments on current item rows count when choosing the toolbar action; a tip always belongs to everyone.
    private var hasAnyItemAssignments: Bool {
        items.contains { $0.kind == .item && !itemAssignments[$0.id, default: []].intersection(selectedPeople).isEmpty }
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
                case .split, .contributions: splitScreen
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
                        Text("Select participants").font(.headline)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { advanceFromReview() } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .accessibilityLabel("Continue")
                        }
                        .disabled(selectedPeople.isEmpty || (!isExtracting && !isManualEntry && total == 0))
                    }
                }
                if step == .assign {
                    ToolbarItem(placement: .confirmationAction) {
                        if assignmentsLocked {
                            Button("Continue") { confirmAssignments() }
                                .disabled(items.isEmpty || receiptTotal == 0)
                        } else if !hasAnyItemAssignments {
                            Button("Split All") { splitAll() }
                                .disabled(items.isEmpty || receiptTotal == 0)
                        } else {
                            Button { confirmAssignments() } label: {
                                Image(systemName: "checkmark").accessibilityLabel("Confirm assignments")
                            }
                            .disabled(items.isEmpty || receiptTotal == 0)
                        }
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
            .onChange(of: items) { applyAdjustments() }
            .onChange(of: adjustments) { applyAdjustments() }
            .onChange(of: openScannerTrigger) { _, newVal in
                guard newVal > 0 else { return }
                triggerScannerShortcut()
            }
            .overlay { if showSaveSuccess { SaveSuccessView().transition(.scale(scale: 0.75).combined(with: .opacity)) } }
            .alert("Couldn’t save", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    /// The scanner is unavailable in Simulator and on devices without a camera.
    private var canScan: Bool { VNDocumentCameraViewController.isSupported }
    private var title: String { switch step { case .capture: "Add expense"; case .reading: "Reading receipt"; case .review: "Select participants"; case .split: "Review expense"; case .assign: "Assign items"; case .contributions: "Edit contributions" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { EmptyView() } actions: {
            Button { showCamera = true } label: { Label("Scan receipt", systemImage: "doc.viewfinder").prominentLabel() }.buttonStyle(.borderedProminent).disabled(!canScan)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0, isSelected: true)]; adjustments = []; printedTotalCents = nil; splitsPrintedTotal = false; isManualEntry = true; step = .review }.padding(.top, 12)
        }
        .onAppear { ReceiptReader.prewarm() }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding items").font(.headline) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// Participant selection screen after recognition.
    private var reviewScreen: some View {
        combinedFriendsCard
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
            .onAppear {
                if selectedPeople.isEmpty, let me = store.activeUserID { selectedPeople = [me] }
                setDefaultPayer()
            }
            .onChange(of: selectedPeople) { _, _ in setDefaultPayer() }
    }

    private var combinedFriendsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search friends", text: $personSearch)
                    .submitLabel(.done)
                if !personSearch.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { personSearch = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 16)

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
            .scrollIndicators(.hidden)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .scenePadding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }
    private var assignmentScreen: some View {
        AssignItemsView(
            items: $items,
            itemAssignments: $itemAssignments,
            participants: orderedSelection,
            isEditable: true,
            assignmentsLocked: $assignmentsLocked,
            assignsNewItemsToAll: splitsPrintedTotal,
            onAssignmentsChanged: {
                splitsPrintedTotal = false
                shares = assignedShares()
            },
            onItemsChanged: { old, new in
                if splitsPrintedTotal {
                    for item in items where itemAssignments[item.id] == nil {
                        itemAssignments[item.id] = selectedPeople
                    }
                    shares = assignedShares()
                    return
                }
                // A price edit moves only its owners' contributions, keeping any adjusted by hand.
                shares = ShareAdjuster.applyingItemChanges(from: old, to: new, shares: shares, owners: owners(of:), people: orderedSelection, total: total)
            }
        )
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
    /// You first, then every friend by recency; searching narrows the same complete list.
    private var shownPeople: [LedgerPerson] {
        guard personSearch.isEmpty else {
            return friendsByRecency.filter { [$0.name, $0.username ?? ""].contains { $0.localizedCaseInsensitiveContains(personSearch) } }
        }
        return friendsByRecency
    }
    private var splitScreen: some View {
        ExpenseReviewEditorView(
            category: $category,
            description: $description,
            total: totalBinding,
            payer: $payer,
            purchaseDate: $purchaseDate,
            shares: $shares,
            adjustments: $adjustments,
            contributionDetents: printedTotalShares ?? ownershipShares(expenseItems),
            participants: orderedSelection,
            items: $items,
            itemAssignments: $itemAssignments,
            isEditable: true,
            showsToolbarSave: false,
            isSaving: isSaving,
            canSave: isValidSplit,
            onSave: { save() },
            onOpenAssignItems: {
                if assignmentsLocked { undoAssignmentConfirmation() }
                step = .assign
            },
            onPayerChanged: { reassignPayerRows(to: $0) }
        )
    }
    /// A library photo is cropped and flattened before reading, so the processed image is the only copy parsed and stored.
    /// Screenshots are read as they are.
    private func load(_ photo: PhotosPickerItem?) {
        guard let photo else { return }
        step = .reading
        Task { @MainActor in
            guard let data = try? await photo.loadTransferable(type: Data.self),
                  let prepared = await Task.detached(operation: { ReceiptImageProcessor.prepare(data) }).value else { step = .capture; return }
            image = prepared
        }
    }
    /// Recognizes the text, then lets the user choose participants while the items are read.
    private func startReading() {
        guard let image else { return }
        step = .reading
        let analysisID = UUID()
        receiptAnalysisID = analysisID
        isManualEntry = false
        isExtracting = true
        continuesAfterExtraction = false
        Task { @MainActor in
            // Cloud vision reads the photo while the device recognizes its text; the on-device reader is the fallback.
            let cloud = cloudReader(image)
            let recognized = await ReceiptReader.recognize(image)
            guard receiptAnalysisID == analysisID else { return }
            recognizedText = recognized.text
            step = .review
            let extraction = await ReceiptReader.extract(recognized, cloud: cloud)
            guard receiptAnalysisID == analysisID else { return }
            apply(extraction)
            isExtracting = false
            if continuesAfterExtraction {
                continuesAfterExtraction = false
                advanceFromReview()
            }
        }
    }
    private func cloudReader(_ image: UIImage) -> CloudReader? {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        let store = store, authentication = authentication
        return CloudReader { note in
            try await store.readReceiptImage(jpeg, note: note, accessToken: authentication.accessToken())
        }
    }
    private func apply(_ extraction: ReceiptExtraction) {
        items = extraction.items.map { item in
            var item = item
            item.isSelected = true
            return item
        }
        adjustments = extraction.adjustments
        recognizedText = extraction.recognizedText
        diagnostics = extraction.diagnostics
        if let diagnostics = extraction.diagnostics {
            lastScan = "\(diagnostics.reader.capitalized), \(diagnostics.totalSeconds.formatted(.number.precision(.fractionLength(1)))) s"
        }
        printedTotalCents = extraction.printedTotalCents
        category = extraction.category
        description = extraction.name
        if let date = extraction.purchaseDate { purchaseDate = date }
        error = extraction.warning
        if !items.contains(where: { $0.kind == .item }) {
            items = [ReceiptItem(name: "", cents: extraction.printedTotalCents ?? 0, isSelected: true)]
            adjustments = []
            error = extraction.printedTotalCents == nil ? "No prices found." : nil
        } else if items.count == 1, let printed = extraction.printedTotalCents, extraction.mismatchWarning != nil {
            matchPrintedTotal(printed)
            error = nil
        }
    }
    /// Spreads the adjustments over the rows whenever either changes, keeping every adjustment's amount, so each row's
    /// global offset and the total stay current. Final review moves contributions along with each amount edit; if they
    /// still don't add up to the total, the difference is spread without undoing any adjusted by hand.
    private func applyAdjustments() {
        var updated = items
        let applied = updated.distributeAdjustments(adjustments)
        if updated != items { items = updated }
        if applied != adjustments { adjustments = applied }
        if step == .split, allocationTotal != total, !splitsPrintedTotal {
            shares = ShareAdjuster.adding(0, weightedBy: [:], to: shares, people: orderedSelection, total: total)
        }
    }

    /// Who owns a row for moving contributions: its assignees, or everyone when nobody is assigned.
    private func owners(of item: ReceiptItem) -> Set<UUID> {
        hasAnyItemAssignments ? itemAssignments[item.id, default: []].intersection(selectedPeople) : []
    }
    private var totalBinding: Binding<Int> {
        // Final review edits the items and adjustments the total comes from, then sets it; an edit ends Split All.
        Binding(get: { total }, set: { _ in splitsPrintedTotal = false })
    }
    /// Keeps a lone item's printed price while recording the difference to the receipt total as its own offset.
    private func matchPrintedTotal(_ printed: Int) {
        guard items.count == 1, items[0].cents > 0 else { return }
        adjustments = []
        items[0].localOffsetCents = printed - items[0].cents
        items[0].globalOffsetCents = 0
    }
    private func advanceFromReview() {
        personSearch = ""
        if isExtracting {
            continuesAfterExtraction = true
            step = .reading
            return
        }
        prepareAssignmentsForReview()
        prepareFinalSplit()
        step = .split
    }

    /// Sets up default item assignments to all participants, or preserves valid customized assignments.
    private func prepareAssignmentsForReview() {
        let validPeople = selectedPeople
        if hasAnyItemAssignments {
            for item in items {
                itemAssignments[item.id] = itemAssignments[item.id, default: []].intersection(validPeople)
            }
        } else {
            // Keep itemAssignments empty so Assign Items opens blank with nobody assigned
            itemAssignments = [:]
        }
        splitsPrintedTotal = false
        assignmentsLocked = false
        assignmentsBeforeLock = nil
        shares = assignedShares()
        setDefaultPayer()
    }
    /// Gives every current row to every selected participant and uses the printed receipt total when available.
    private func splitAll() {
        withAnimation(.snappy(duration: 0.2)) {
            for item in items { itemAssignments[item.id] = selectedPeople }
            splitsPrintedTotal = printedTotalCents != nil
            shares = assignedShares()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// Confirmation continues immediately when every row is assigned. Otherwise it fills untouched rows to the payer
    /// and waits for Continue so the autofill remains visible.
    private func confirmAssignments() {
        // Assigning already set contributions from ownership, and price edits since only moved their owners' part, so
        // contributions adjusted by hand on final review are kept when they still add up.
        if assignmentsLocked {
            if allocationTotal != total || Set(shares.keys) != selectedPeople { shares = assignedShares() }
            step = .split
            return
        }
        setDefaultPayer()
        guard let payer else { return }
        assignmentsBeforeLock = itemAssignments
        let untouched = items.filter { itemAssignments[$0.id, default: []].isEmpty }
        guard !untouched.isEmpty else {
            assignmentsLocked = true
            if allocationTotal != total || Set(shares.keys) != selectedPeople { shares = assignedShares() }
            step = .split
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            for item in untouched { itemAssignments[item.id] = [payer] }
            shares = assignedShares()
            assignmentsLocked = true
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    /// Moves only rows that confirmation auto-assigned when the payer changes on final review.
    private func reassignPayerRows(to newPayer: UUID?) {
        guard assignmentsLocked, let newPayer, let assignmentsBeforeLock else { return }
        for item in items where assignmentsBeforeLock[item.id, default: []].isEmpty {
            itemAssignments[item.id] = [newPayer]
        }
        shares = assignedShares()
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
    /// Contributions from current ownership; Split All uses the printed total when one was recognized.
    private func assignedShares() -> [UUID: Int] {
        if let printedTotalShares { return printedTotalShares }
        if !hasAnyItemAssignments {
            return ownershipShares(items.map { item in
                var item = item
                item.ownerIDs = selectedPeople
                return item
            })
        }
        return ownershipShares(items.map { item in
            var item = item
            item.ownerIDs = itemAssignments[item.id, default: []]
            return item
        })
    }
    private func setDefaultPayer() {
        if payer.map(selectedPeople.contains) != true { payer = selectedPeople.contains(store.activeUserID ?? UUID()) ? store.activeUserID : orderedSelection.first }
    }
    /// Sets contributions from item ownership and defaults the payer to the signed-in participant.
    private func setItemSplit() {
        shares = printedTotalShares ?? ownershipShares(expenseItems)
        setDefaultPayer()
    }
    private func prepareFinalSplit() {
        let hasEveryPerson = Set(shares.keys) == selectedPeople
        if !hasEveryPerson || allocationTotal != total { setItemSplit() }
        else { setDefaultPayer() }
    }
    private func save() {
        guard let payer else { return }
        var expense = Expense(description: savedDescription, transactionDate: purchaseDate, payer: payer, items: expenseItems, shares: shares.filter { selectedPeople.contains($0.key) }, receiptImageData: image?.jpegData(compressionQuality: 0.72), recognizedText: recognizedText, category: category, adjustments: adjustments)
        expense.receiptDiagnostics = diagnostics.map { diagnostics in
            var diagnostics = diagnostics
            diagnostics.saved = ReceiptDiagnostics.Summary(name: savedDescription, category: category, purchaseDate: purchaseDate, items: expense.items,
                                                           adjustments: adjustments, subtotalCents: nil, totalCents: total)
            return diagnostics
        }
        expense.recordedTotalCents = total
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
    private func reset() { receiptAnalysisID = nil; isExtracting = false; isManualEntry = false; continuesAfterExtraction = false; step = .capture; image = nil; selectedPhoto = nil; items = []; adjustments = []; printedTotalCents = nil; splitsPrintedTotal = false; selectedPeople = []; payer = nil; shares = [:]; itemAssignments = [:]; assignmentsLocked = false; assignmentsBeforeLock = nil; personSearch = ""; purchaseDate = Date(); recognizedText = nil; diagnostics = nil; error = nil; description = "Shared Expense"; category = nil }
    private func triggerScannerShortcut() {
        guard canScan else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if step != .capture {
            reset()
        }
        showCamera = true
    }
    private func back() {
        switch step {
        case .review:
            // Going back abandons this receipt, so a reading still in progress can't fill in a later manual entry.
            personSearch = ""; receiptAnalysisID = nil; isExtracting = false; continuesAfterExtraction = false; diagnostics = nil; step = .capture
        case .assign:
            if assignmentsLocked { undoAssignmentConfirmation() }
            else { step = .split }
        case .split:
            step = .review
        case .contributions: step = .split
        default: break
        }
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



extension UUID: @retroactive Identifiable { public var id: UUID { self } }
