import SwiftUI
import UIKit

/// Standalone, portable component for assigning participants to receipt items.
struct AssignItemsView: View {
    @Environment(ExpenseStore.self) private var store
    @Binding var items: [ReceiptItem]
    @Binding var itemAssignments: [UUID: Set<UUID>]
    let participants: [UUID]
    let isEditable: Bool
    let assignmentsLocked: Bool
    let assignsNewItemsToAll: Bool
    var onAssignmentsChanged: (() -> Void)?
    /// Called with the rows before and after each change to them.
    var onItemsChanged: ((_ old: [ReceiptItem], _ new: [ReceiptItem]) -> Void)?
    /// The top-right action: Split All while nobody is assigned (when given), then the checkmark, then Continue once
    /// confirmed. Both of the last two call `onConfirm`. Without it there is no action.
    var onSplitAll: (() -> Void)?
    var onConfirm: (() -> Void)?
    var canConfirm: Bool
    /// When given, Back replaces the navigation back button while confirmed and calls this instead of leaving.
    var onUndoConfirmation: (() -> Void)?

    @State private var activeAssignmentTarget: AssignmentTarget? = .all
    @State private var editingItemID: UUID?

    init(
        items: Binding<[ReceiptItem]>,
        itemAssignments: Binding<[UUID: Set<UUID>]>,
        participants: [UUID],
        isEditable: Bool = true,
        assignmentsLocked: Bool = false,
        assignsNewItemsToAll: Bool = false,
        onAssignmentsChanged: (() -> Void)? = nil,
        onItemsChanged: ((_ old: [ReceiptItem], _ new: [ReceiptItem]) -> Void)? = nil,
        onSplitAll: (() -> Void)? = nil,
        onConfirm: (() -> Void)? = nil,
        canConfirm: Bool = true,
        onUndoConfirmation: (() -> Void)? = nil
    ) {
        self._items = items
        self._itemAssignments = itemAssignments
        self.participants = participants
        self.isEditable = isEditable
        self.assignmentsLocked = assignmentsLocked
        self.assignsNewItemsToAll = assignsNewItemsToAll
        self.onAssignmentsChanged = onAssignmentsChanged
        self.onItemsChanged = onItemsChanged
        self.onSplitAll = onSplitAll
        self.onConfirm = onConfirm
        self.canConfirm = canConfirm
        self.onUndoConfirmation = onUndoConfirmation
    }

    /// Only assignments on item rows count when choosing the action; a tip always belongs to everyone.
    private var hasAnyItemAssignments: Bool {
        items.contains { $0.kind == .item && !itemAssignments[$0.id, default: []].isDisjoint(with: participants) }
    }

    /// Selected participants sorted by recent shared transactions, signed-in user first.
    private var filterPeople: [UUID] {
        let latest = store.expenses.reduce(into: [UUID: Date]()) { dates, expense in
            for person in expense.participants { dates[person] = max(dates[person] ?? .distantPast, expense.transactionDate) }
        }
        return participants.sorted { a, b in
            if (a == store.activeUserID) != (b == store.activeUserID) { return a == store.activeUserID }
            let (dateA, dateB) = (latest[a] ?? .distantPast, latest[b] ?? .distantPast)
            if dateA != dateB { return dateA > dateB }
            return store.name(for: a).localizedCaseInsensitiveCompare(store.name(for: b)) == .orderedAscending
        }
    }

    var body: some View {
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
                        let assigned = filterPeople.filter { itemAssignments[item.id, default: []].contains($0) }
                        if !assigned.isEmpty { AvatarStack(people: assigned, size: 22) }
                        // The receipt's price after the item's own discount; receipt-wide tax and fees come later.
                        Text(item.netCents.usd).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                    .frame(height: 26)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    // A tip always belongs to everyone.
                    .onTapGesture {
                        guard isEditable, !assignmentsLocked, item.kind == .item, let target = activeAssignmentTarget else { return }
                        toggleAssignment(target, for: item.id)
                    }
                    .accessibilityAction(named: "Assign people") {
                        guard isEditable, !assignmentsLocked, item.kind == .item, let target = activeAssignmentTarget else { return }
                        toggleAssignment(target, for: item.id)
                    }
                    .swipeActions {
                        if isEditable && !assignmentsLocked {
                            Button("Edit", systemImage: "pencil") { editingItemID = item.id }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                items.removeAll { $0.id == item.id }
                                itemAssignments[item.id] = nil
                            }
                        }
                    }
                }
                if isEditable && !assignmentsLocked {
                    Button("Add item", systemImage: "plus") {
                        let item = ReceiptItem(name: "", cents: 0, isSelected: true)
                        items.append(item)
                        if assignsNewItemsToAll { itemAssignments[item.id] = Set(participants) }
                        editingItemID = item.id
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollIndicators(.hidden)
        .navigationTitle("Assign items")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingItemID) { id in
            if let index = items.firstIndex(where: { $0.id == id }) {
                ItemEditor(item: $items[index])
            }
        }
        .onChange(of: items) { old, new in onItemsChanged?(old, new) }
        .navigationBarBackButtonHidden(onUndoConfirmation != nil && assignmentsLocked)
        .toolbar {
            if let onUndoConfirmation, assignmentsLocked {
                ToolbarItem(placement: .topBarLeading) { Button("Back") { onUndoConfirmation() } }
            }
            if let onConfirm {
                ToolbarItem(placement: .confirmationAction) {
                    Group {
                        if assignmentsLocked {
                            Button("Continue") { onConfirm() }
                        } else if !hasAnyItemAssignments, let onSplitAll {
                            Button("Split All") { onSplitAll() }
                        } else {
                            Button { onConfirm() } label: {
                                Image(systemName: "checkmark").accessibilityLabel("Confirm assignments")
                            }
                        }
                    }
                    .disabled(!canConfirm)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            assignmentFilters
        }
        .onAppear {
            if activeAssignmentTarget == nil {
                activeAssignmentTarget = .all
            }
        }
    }

    private var assignmentFilters: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let horizontalPadding: CGFloat = 16
            let availableWidth = geometry.size.width - horizontalPadding * 2
            let pillWidth = (availableWidth - spacing * 4) / 5
            let totalPills = 1 + filterPeople.count
            let isScrollable = totalPills > 5

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    let allIsActive = activeAssignmentTarget == .all
                    Button { selectAssignmentTarget(.all) } label: {
                        AssignmentTargetPill(title: "All", isActive: allIsActive, width: pillWidth) {
                            Image(systemName: "person.3.fill").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEditable || assignmentsLocked)
                    .accessibilityAddTraits(allIsActive ? .isSelected : [])

                    ForEach(filterPeople, id: \.self) { personID in
                        let person = store.person(for: personID)
                        let isActive = activeAssignmentTarget == .person(personID)
                        Button { selectAssignmentTarget(.person(personID)) } label: {
                            AssignmentTargetPill(title: person.firstName, isActive: isActive, width: pillWidth) {
                                AvatarView(userID: personID, name: person.name, etag: person.avatarEtag, size: 20)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEditable || assignmentsLocked)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
                .frame(minWidth: isScrollable ? nil : geometry.size.width, alignment: .center)
            }
        }
        .frame(height: 56)
        .background(.bar)
    }

    private func selectAssignmentTarget(_ target: AssignmentTarget) {
        activeAssignmentTarget = target
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func toggleAssignment(_ target: AssignmentTarget, for itemID: UUID) {
        switch target {
        case .all:
            if Set(participants).isSubset(of: itemAssignments[itemID, default: []]) {
                itemAssignments[itemID, default: []].subtract(participants)
            } else {
                itemAssignments[itemID, default: []].formUnion(participants)
            }
        case let .person(personID):
            if itemAssignments[itemID, default: []].contains(personID) {
                itemAssignments[itemID, default: []].remove(personID)
            } else {
                itemAssignments[itemID, default: []].insert(personID)
            }
        }
        onAssignmentsChanged?()
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Confirming Assign items: every row nobody has goes to the payer and the rows lock until Continue, so the autofill
/// shows first. Back restores ownership exactly as it was before confirming.
struct AssignmentConfirmation: Equatable {
    /// Ownership from before confirming, which Back restores; nil until confirmed.
    private(set) var assignmentsBefore: [UUID: Set<UUID>]?
    var isLocked: Bool { assignmentsBefore != nil }

    /// Locks the rows and gives each one nobody has to `payer`. Returns whether any were filled; when none were,
    /// Assign items can close at once.
    @discardableResult
    mutating func confirm(_ items: [ReceiptItem], assignments: inout [UUID: Set<UUID>], payer: UUID) -> Bool {
        assignmentsBefore = assignments
        let unassigned = items.filter { assignments[$0.id, default: []].isEmpty }
        for item in unassigned { assignments[item.id] = [payer] }
        return !unassigned.isEmpty
    }

    /// Restores ownership from before confirming and unlocks the rows.
    mutating func undo(_ assignments: inout [UUID: Set<UUID>]) {
        if let assignmentsBefore { assignments = assignmentsBefore }
        assignmentsBefore = nil
    }

    /// Gives the rows confirmation filled to a new `payer`.
    func reassignFilledRows(_ items: [ReceiptItem], assignments: inout [UUID: Set<UUID>], to payer: UUID) {
        guard let assignmentsBefore else { return }
        for item in items where assignmentsBefore[item.id, default: []].isEmpty { assignments[item.id] = [payer] }
    }

    /// Forgets the confirmation without changing ownership.
    mutating func reset() { assignmentsBefore = nil }
}

enum AssignmentTarget: Equatable {
    case all
    case person(UUID)
}

struct AssignmentTargetPill<Icon: View>: View {
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

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: ReceiptItem
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $item.name).submitLabel(.done)
                LabeledContent("Price") { CentsField(title: "0.00", cents: $item.cents) }
                if item.kind == .item {
                    LabeledContent("Discount") { CentsField(title: "0.00", cents: discountBinding) }
                    Toggle("Taxed", isOn: $item.taxed)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    /// The item's own discount, entered as a positive amount and kept as a negative local offset.
    private var discountBinding: Binding<Int> {
        Binding(get: { -item.localOffsetCents }, set: { item.localOffsetCents = -min(max(0, $0), item.cents) })
    }
}
