import PhotosUI
import SwiftUI
import UIKit

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
    @State private var selectedPeople: Set<Person> = [.alex, .jamie]
    @State private var shares: [Person: Int] = [:]
    @State private var splitMode: SplitMode = .equal
    @State private var description = "Shared groceries"
    @State private var payer: Person = .alex
    @State private var taxCents = 0
    @State private var discountCents = 0
    @State private var error: String?
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
            .sheet(isPresented: $showCamera) { CameraCapture(image: $image) }
            .onChange(of: captureRequest) { _, _ in if step == .capture { showCamera = true } }
            .onChange(of: image) { _, newImage in if newImage != nil { startReading() } }
            .onChange(of: selectedPhoto) { _, photo in load(photo) }
            .sensoryFeedback(.selection, trigger: items.filter(\.isSelected).count)
            .sensoryFeedback(.success, trigger: didSave)
        }
    }

    private var title: String { switch step { case .capture: "Add transaction"; case .reading: "Reading receipt"; case .select: "Select items"; case .people: "Who was involved?"; case .split: "Split expense" } }
    private var captureScreen: some View {
        ContentUnavailableView {
            Label("Scan a receipt", systemImage: "camera.viewfinder")
        } description: { Text("Take a photo to find individual costs, then choose only the items to share.") } actions: {
            Button("Open camera", systemImage: "camera") { showCamera = true }.buttonStyle(.borderedProminent)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose photo", systemImage: "photo") }.padding(.top, 8)
            Button("Enter manually") { items = [ReceiptItem(name: "", cents: 0)]; step = .select }.padding(.top, 12)
        }
    }
    private var readingScreen: some View {
        VStack(spacing: 16) { ProgressView().controlSize(.large); Text("Finding individual costs").font(.headline); Text("You’ll be able to review every item before sharing it.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var itemSelectionScreen: some View {
        List {
            Section("Receipt details") { DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date); TextField("Description", text: $description) }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            Section("Select items to share") {
                ForEach($items) { $item in Toggle(isOn: $item.isSelected) { HStack { TextField("Item", text: $item.name); Spacer(); CentsField(title: "0.00", cents: $item.cents).frame(width: 88) } } }.onDelete { items.remove(atOffsets: $0) }
                Button("Add item", systemImage: "plus") { items.append(ReceiptItem(name: "", cents: 0)) }
            }
            Section("Adjustments") { LabeledContent("Tax or fee") { CentsField(title: "0.00", cents: $taxCents).frame(width: 100) }; LabeledContent("Discount") { CentsField(title: "0.00", cents: $discountCents).frame(width: 100) } }
            Section { LabeledContent("Selected total", value: total.usd).fontWeight(.semibold) }
        }
        .safeAreaInset(edge: .bottom) { ContinueButton(title: "Confirm selected items", disabled: total == 0) { step = .people } }
    }
    private var peopleScreen: some View {
        List {
            Section("Recent people") {
                ForEach(Person.allCases) { person in
                    Toggle(isOn: Binding(get: { selectedPeople.contains(person) }, set: { selected in if selected { selectedPeople.insert(person) } else { selectedPeople.remove(person) } })) {
                        HStack { Text(person.initials).font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 34, height: 34).background(.gray, in: Circle()); VStack(alignment: .leading) { Text(person.rawValue); if person == .alex || person == .jamie { Text("Recent").font(.caption).foregroundStyle(.secondary) } } }
                    }
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
    private func load(_ photo: PhotosPickerItem?) { Task { guard let data = try? await photo?.loadTransferable(type: Data.self), let picture = UIImage(data: data) else { return }; image = picture } }
    private func startReading() { guard let image else { return }; step = .reading; Task { @MainActor in items = (try? ReceiptTextRecognizer.items(in: image)) ?? []; if items.isEmpty { items = [ReceiptItem(name: "", cents: 0)]; error = "No item prices were found. Add them manually." }; step = .select } }
    private func shareBinding(for person: Person) -> Binding<Int> { Binding(get: { shares[person] ?? 0 }, set: { shares[person] = $0 }) }
    private func setEqualSplit() { let people = selectedPeople.sorted { $0.rawValue < $1.rawValue }; guard !people.isEmpty else { return }; let base = total / people.count; let remainder = total % people.count; shares = Dictionary(uniqueKeysWithValues: people.enumerated().map { index, person in (person, base + (index < remainder ? 1 : 0)) }) }
    private func save() { store.add(Expense(description: description, transactionDate: purchaseDate, payer: payer, items: items, taxCents: taxCents, discountCents: discountCents, shares: shares, receiptImageData: image?.jpegData(compressionQuality: 0.72))); didSave.toggle(); reset(); finish() }
    private func reset() { step = .capture; image = nil; selectedPhoto = nil; items = []; selectedPeople = [.alex, .jamie]; shares = [:]; taxCents = 0; discountCents = 0; splitMode = .equal; description = "Shared groceries" }
    private func back() { switch step { case .select: step = .capture; case .people: step = .select; case .split: step = .people; default: break } }
}

private struct ContinueButton: View { let title: String; let disabled: Bool; let action: () -> Void; var body: some View { Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 10).background(.bar).disabled(disabled) } }
