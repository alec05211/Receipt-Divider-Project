import SwiftUI
import UIKit

/// Standalone, portable component for assigning participants to receipt items.
struct AssignItemsView: View {
    @Environment(ExpenseStore.self) private var store
    @Binding var items: [ReceiptItem]
    @Binding var itemAssignments: [UUID: Set<UUID>]
    let participants: [UUID]
    let isEditable: Bool
    @Binding var assignmentsLocked: Bool
    var onAssignmentsChanged: (() -> Void)?

    @State private var activeAssignmentTarget: AssignmentTarget? = .all
    @State private var editingItemID: UUID?

    init(
        items: Binding<[ReceiptItem]>,
        itemAssignments: Binding<[UUID: Set<UUID>]>,
        participants: [UUID],
        isEditable: Bool = true,
        assignmentsLocked: Binding<Bool> = .constant(false),
        onAssignmentsChanged: (() -> Void)? = nil
    ) {
        self._items = items
        self._itemAssignments = itemAssignments
        self.participants = participants
        self.isEditable = isEditable
        self._assignmentsLocked = assignmentsLocked
        self.onAssignmentsChanged = onAssignmentsChanged
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
                        Text(item.totalCents.usd).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                    .frame(height: 26)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isEditable, !assignmentsLocked, let target = activeAssignmentTarget else { return }
                        toggleAssignment(target, for: item.id)
                    }
                    .accessibilityAction(named: "Assign people") {
                        guard isEditable, !assignmentsLocked, let target = activeAssignmentTarget else { return }
                        toggleAssignment(target, for: item.id)
                    }
                    .swipeActions {
                        if isEditable && !assignmentsLocked {
                            Button("Edit", systemImage: "pencil") { editingItemID = item.id }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                items.removeAll { $0.id == item.id }
                                itemAssignments[item.id] = nil
                                onAssignmentsChanged?()
                            }
                        }
                    }
                }
                if isEditable && !assignmentsLocked {
                    Button("Add item", systemImage: "plus") {
                        let item = ReceiptItem(name: "", cents: 0)
                        items.append(item)
                        editingItemID = item.id
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Assign items")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingItemID) { id in
            if let index = items.firstIndex(where: { $0.id == id }) {
                ItemEditor(item: $items[index])
            }
        }
        .onChange(of: items) { _, _ in onAssignmentsChanged?() }
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
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
