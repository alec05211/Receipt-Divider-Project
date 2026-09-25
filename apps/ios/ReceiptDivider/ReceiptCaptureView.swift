import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReceiptCaptureView: View {
    enum Step: Int { case capture, reading, select, people, split }
    @Environment(ExpenseStore.self) private var store
    @Binding var captureRequest: Int
    let finish: () -> Void
    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var items: [ReceiptItem] = []
    @State private var purchaseDate = Date()
    @State private var dateNote: String?
    @State private var selectedPeople: Set<Person> = [.alex, .jamie]
    @State private var shares: [Person: Int] = [:]
    @State private var splitMode: SplitMode = .equal
    @State private var description = "Shared groceries"
    @State private var payer: Person = .alex
    @State private var taxCents = 0
    @State private var discountCents = 0
    @State private var error: String?
    @State private var editingItemID: UUID?
    @State private var didSave = false

    private var itemTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.cents } }
    private var total: Int { max(0, itemTotal + taxCents - discountCents) }
    private var allocationTotal: Int { selectedPeople.reduce(0) { $0 + (shares[$1] ?? 0) } }
    private var isValidSplit: Bool { !selectedPeople.isEmpty && allocationTotal == total }

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
            .onChange(of: captureRequest) { _, _ in if step == .capture && canScan { showCamera = true } }
            .onChange(of: image) { _, newImage in if newImage != nil { startReading() } }
            .onChange(of: selectedPhoto) { _, photo in load(photo) }
            .sensoryFeedback(.selection, trigger: items.filter(\.isSelected).count)
            .sensoryFeedback(.success, trigger: didSave)
        }
    }

    /// The scanner is unavailable in Simulator and on devices without a camera.
    private var canScan: Bool { VNDocumentCameraViewController.isSupported }
    private var title: String { switch step { case .capture: "Add transaction"; case .reading: "Reading receipt"; case .select: "Select items"; case .people: "Who was involved?"; case .split: "Split expense" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { Text("Take a photo to find individual costs, then choose only the items to share.") } actions: {
            Button("Scan receipt", systemImage: "doc.viewfinder") { showCamera = true }.buttonStyle(.borderedProminent).disabled(!canScan)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0)]; step = .select }.padding(.top, 12)
        }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding individual costs").font(.headline); Text("You’ll be able to review every item before sharing it.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var itemSelectionScreen: some View {
        List {
            Section { DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date); TextField("Description", text: $description) } header: { Text("Receipt details") } footer: { if let dateNote { Text(dateNote) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            Section("Select items to share") {
                ForEach($items) { $item in
                    Button { item.isSelected.toggle() } label: {
                        HStack {
                            Text(item.name.isEmpty ? "Unnamed item" : item.name).foregroundStyle(item.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Text(item.cents.usd).monospacedDigit().foregroundStyle(.secondary)
                            SelectionCircle(isSelected: item.isSelected)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .sensoryFeedback(.selection, trigger: item.isSelected)
                    .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editingItemID = item.id }
                        Button("Delete", systemImage: "trash", role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button("Add item", systemImage: "plus") { let item = ReceiptItem(name: "", cents: 0); items.append(item); editingItemID = item.id }
            }
            Section("Adjustments") { LabeledContent("Tax or fee") { CentsField(title: "0.00", cents: $taxCents).frame(width: 100) }; LabeledContent("Discount") { CentsField(title: "0.00", cents: $discountCents).frame(width: 100) } }
            Section { LabeledContent("Selected total", value: total.usd).fontWeight(.semibold) }
        }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Confirm selected items", disabled: total == 0) { step = .people } }
        .sheet(item: $editingItemID) { id in
            if let index = items.firstIndex(where: { $0.id == id }) { ItemEditor(item: $items[index]) }
        }
    }
    private var peopleScreen: some View {
        List {
            Section("Recent people") {
                ForEach(Person.allCases) { person in
                    let isSelected = selectedPeople.contains(person)
                    Button { if isSelected { selectedPeople.remove(person) } else { selectedPeople.insert(person) } } label: {
                        HStack { Text(person.initials).font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 34, height: 34).background(.gray, in: Circle()); VStack(alignment: .leading) { Text(person.rawValue); if person == .alex || person == .jamie { Text("Recent").font(.caption).foregroundStyle(.secondary) } }; Spacer(); SelectionCircle(isSelected: isSelected) }
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .sensoryFeedback(.selection, trigger: isSelected)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Section { Text("Each transaction has its own participant list. Saved groups can be added later as optional shortcuts.").font(.footnote).foregroundStyle(.secondary) }
        }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Confirm people", disabled: selectedPeople.isEmpty) { setEqualSplit(); step = .split } }
    }
    private var splitScreen: some View {
        List {
            Section { Picker("Paid by", selection: $payer) { ForEach(Array(selectedPeople).sorted { $0.rawValue < $1.rawValue }) { Text($0.rawValue).tag($0) } }; Picker("Split", selection: $splitMode) { ForEach(SplitMode.allCases) { Text($0.rawValue).tag($0) } }.onChange(of: splitMode) { _, mode in if mode == .equal { setEqualSplit() } }; LabeledContent("Expense total", value: total.usd).fontWeight(.semibold) }
            Section("Contributions") { ForEach(Array(selectedPeople).sorted { $0.rawValue < $1.rawValue }) { person in LabeledContent(person.rawValue) { CentsField(title: "0.00", cents: shareBinding(for: person)).frame(width: 100).disabled(splitMode == .equal) } } }
            if !isValidSplit { Section { Text("Contributions must total \(total.usd). Currently \(allocationTotal.usd).") .foregroundStyle(.red) } }
        }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Save transaction", disabled: !isValidSplit) { save() } }
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
    private func startReading() { guard let image else { return }; step = .reading; Task { @MainActor in let scan = (try? await Task.detached { try ReceiptTextRecognizer.scan(image) }.value) ?? ReceiptScan(); items = scan.items; taxCents = scan.taxCents; if let date = scan.purchaseDate { purchaseDate = date; dateNote = "Purchase date read from the receipt." } else { dateNote = "No date was found on the receipt, so today is used. Change it if the purchase was earlier." }; error = scan.mismatchWarning; if items.isEmpty { items = [ReceiptItem(name: "", cents: 0)]; error = "No item prices were found. Add them manually." }; step = .select } }
    private func shareBinding(for person: Person) -> Binding<Int> { Binding(get: { shares[person] ?? 0 }, set: { shares[person] = $0 }) }
    private func setEqualSplit() { let people = selectedPeople.sorted { $0.rawValue < $1.rawValue }; guard !people.isEmpty else { return }; let base = total / people.count; let remainder = total % people.count; shares = Dictionary(uniqueKeysWithValues: people.enumerated().map { index, person in (person, base + (index < remainder ? 1 : 0)) }) }
    private func save() { store.add(Expense(description: description, transactionDate: purchaseDate, payer: payer, items: items, taxCents: taxCents, discountCents: discountCents, shares: shares, receiptImageData: image?.jpegData(compressionQuality: 0.72))); didSave.toggle(); reset(); finish() }
    private func reset() { step = .capture; image = nil; selectedPhoto = nil; items = []; selectedPeople = [.alex, .jamie]; shares = [:]; taxCents = 0; discountCents = 0; purchaseDate = Date(); dateNote = nil; error = nil; splitMode = .equal; description = "Shared groceries" }
    private func back() { switch step { case .select: step = .capture; case .people: step = .select; case .split: step = .people; default: break } }
}

private struct ContinueButton: View { let title: String; let disabled: Bool; let action: () -> Void; var body: some View { Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 10).background(.bar).disabled(disabled) } }

/// Trailing selection indicator drawn with the same symbols iOS uses for list selection.
private struct SelectionCircle: View {
    let isSelected: Bool
    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

private struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: ReceiptItem
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $item.name)
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
