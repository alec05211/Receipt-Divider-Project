import Foundation
import Observation
import UIKit

struct ReceiptItem: Identifiable, Hashable, Codable {
    /// A tip row is split evenly among everyone on the expense rather than assigned like an item.
    enum Kind: String, Codable, Sendable { case item, tip }
    var id = UUID(); var name: String
    /// The price printed on the receipt.
    var cents: Int
    /// What the receipt ties to this item alone, such as its own discount (negative).
    var localOffsetCents = 0
    /// The item's share of the receipt-wide discounts, taxes and surcharges, set by `applyAdjustments`.
    var globalOffsetCents = 0
    var kind = Kind.item
    /// Whether receipt tax applies to this item.
    var taxed = true
    var isSelected = false
    /// User IDs of the people who had this item. Ownership only says who had what; `Expense.shares` holds what each owes.
    var ownerIDs: Set<UUID> = []
    /// The price after the item's own offset: what receipt-wide adjustments are applied to.
    var netCents: Int { cents + localOffsetCents }
    var totalCents: Int { cents + localOffsetCents + globalOffsetCents }
}
extension ReceiptItem {
    /// Items cached by builds before offsets were split stored one combined `offsetCents`.
    private enum LegacyKeys: String, CodingKey { case offsetCents }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); name = try container.decode(String.self, forKey: .name); cents = try container.decode(Int.self, forKey: .cents)
        localOffsetCents = try container.decodeIfPresent(Int.self, forKey: .localOffsetCents) ?? 0
        let legacyOffset = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .offsetCents)
        globalOffsetCents = try container.decodeIfPresent(Int.self, forKey: .globalOffsetCents) ?? legacyOffset ?? 0
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .item
        taxed = try container.decodeIfPresent(Bool.self, forKey: .taxed) ?? true
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        ownerIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .ownerIDs) ?? []
    }
}
extension Array where Element == ReceiptItem {
    /// What each of `people` owes for the items they own: every item is divided equally among its owners among
    /// `people`. Exact shares are rounded down and the leftover cents go to the largest fractions, earlier `people`
    /// winning ties, so the shares add up to the owned items' total and everyone owning everything is an even split.
    func ownerShares(for people: [UUID]) -> [UUID: Int] {
        var exact = Dictionary(uniqueKeysWithValues: people.map { ($0, 0.0) })
        var total = 0
        for item in self {
            let owners = people.filter(item.ownerIDs.contains)
            guard !owners.isEmpty else { continue }
            total += item.totalCents
            for owner in owners { exact[owner, default: 0] += Double(item.totalCents) / Double(owners.count) }
        }
        // The small allowance keeps a share like 2.9999999 from rounding down to 2.
        let whole = exact.mapValues { Int(($0 + 1e-9).rounded(.down)) }
        let fraction = { (person: UUID) in exact[person, default: 0] - Double(whole[person, default: 0]) }
        let remainder = total - whole.values.reduce(0, +)
        let byFraction = people.enumerated().sorted { a, b in
            let (fractionA, fractionB) = (fraction(a.element), fraction(b.element))
            return abs(fractionA - fractionB) > 1e-9 ? fractionA > fractionB : a.offset < b.offset
        }
        var result = whole
        for (_, person) in byFraction.prefix(Swift.max(0, remainder)) { result[person, default: 0] += 1 }
        return result
    }
}
/// `payer` and the keys of `shares` are user IDs. `receiptImageData` and `recognizedText` are only set before saving;
/// saved receipts are fetched by `evidenceIDs`. Expenses split from the same receipt share its evidence ID.
struct Expense: Identifiable, Hashable, Codable {
    var id = UUID(); var description: String; var transactionDate: Date; var payer: UUID; var items: [ReceiptItem]; var shares: [UUID: Int]; var receiptImageData: Data?; var createdAt = Date(); var recordedTotalCents: Int?; var evidenceIDs: [UUID] = []; var recognizedText: String?
    var category: ExpenseCategory? = nil
    /// Receipt-wide discounts, taxes, tip and surcharges, in the order the receipt applies them.
    var adjustments: [ReceiptAdjustment] = []
    var total: Int { recordedTotalCents ?? max(0, items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents }) }
    /// The selected items' own discounts.
    var itemDiscountTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.localOffsetCents } }
    /// The selected items' share of receipt-wide adjustments, for expenses saved before adjustments were recorded.
    var globalOffsetTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.globalOffsetCents } }
    var participants: [UUID] { Array(shares.keys) }
}
/// What an expense was for, chosen by hand. Optional; older expenses have none.
enum ExpenseCategory: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case groceries, restaurant, movie, concert
    var id: Self { self }
    var title: String {
        switch self {
        case .groceries: "Groceries"
        case .restaurant: "Restaurant"
        case .movie: "Movie"
        case .concert: "Concert"
        }
    }
    var symbol: String {
        switch self {
        case .groceries: "cart.fill"
        case .restaurant: "fork.knife"
        case .movie: "film.fill"
        case .concert: "music.mic"
        }
    }
    var suggestedName: String {
        switch self {
        case .groceries: "Grocery Purchase"
        case .restaurant: "Restaurant Meal"
        case .movie: "Movie Tickets"
        case .concert: "Concert Tickets"
        }
    }
}

enum SelfReferenceMode: String, CaseIterable, Identifiable {
    static let storageKey = "self-reference-mode"
    case fullName, me, you
    var id: Self { self }
    var title: String {
        switch self {
        case .fullName: "Full name"
        case .me: "Me"
        case .you: "You"
        }
    }
}
struct Payment: Identifiable, Hashable, Codable { var id = UUID(); var amount: Int; var from: UUID; var to: UUID; var transactionDate: Date; var createdAt = Date() }
/// An app user who appears in the signed-in user's ledger: themselves, a friend, or someone they share a transaction with.
struct LedgerPerson: Identifiable, Hashable, Codable {
    let id: UUID; var displayName: String?; var username: String?; var avatarEtag: String?
    var name: String { displayName ?? username.map { "@\($0)" } ?? "Unknown" }
    var firstName: String { displayName?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name }
}

@MainActor
@Observable final class ExpenseStore {
    /// Bumped when the cached expense format changes, so an older cache is ignored rather than failing to decode.
    private let storageKeyPrefix = "receipt-divider-ledger-v4"
    private let api: LedgerAPIClient?
    private var pendingEvidenceIDs: [UUID: UUID] = [:]
    /// Optimistic expenses keyed by the same client request ID used for idempotent server creation.
    private var pendingExpenses: [UUID: Expense] = [:]
    private var confirmedBalances: [UUID: Int] = [:]
    private(set) var pendingExpenseIDs: Set<UUID> = []
    private(set) var selfReferenceMode = SelfReferenceMode(rawValue: UserDefaults.standard.string(forKey: SelfReferenceMode.storageKey) ?? "") ?? .fullName
    private(set) var activeUserID: UUID?
    private(set) var hasLoadedRemoteData = false
    private(set) var isSyncing = false
    private(set) var friends: [APIFriend] = []
    private(set) var profile: APIProfile?
    private(set) var isDeveloper = false
    /// Loaded profile pictures with the etag they were fetched for; a nil image records a user known to have none.
    private var avatars: [UUID: (etag: String?, image: UIImage?)] = [:]
    /// Receipt images by evidence ID. They never change once uploaded, so they're kept for the session.
    private var receiptImages: [UUID: UIImage] = [:]
    /// Bumped when the signed-in user's own picture changes, so views showing it reload.
    private(set) var avatarVersion = 0
    var syncError: String?
    var expenseSaveError: String?
    /// Everyone who appears in the ledger, by user ID.
    private(set) var people: [UUID: LedgerPerson] = [:]
    /// What each person owes the signed-in user; negative when the signed-in user owes them.
    private(set) var balances: [UUID: Int] = [:]
    var expenses: [Expense] = [] { didSet { persist() } }
    var payments: [Payment] = [] { didSet { persist() } }

    init(bundle: Bundle = .main) { api = LedgerAPIClient(bundle: bundle) }

    var isAPIConfigured: Bool { api != nil }
    /// Positive when others owe the signed-in user overall.
    var netBalance: Int { balances.values.reduce(0, +) }
    /// People with an unsettled balance, largest amount first.
    var openBalances: [(person: LedgerPerson, cents: Int)] {
        balances.filter { $0.value != 0 }.map { (person(for: $0.key), $0.value) }.sorted { abs($0.cents) > abs($1.cents) }
    }
    /// The signed-in user followed by their accepted friends: everyone they can split with.
    var splitCandidates: [LedgerPerson] {
        let me = activeUserID.map { person(for: $0) }
        let friendPeople = friends.filter { $0.status == "accepted" }.map { LedgerPerson(id: $0.userId, displayName: $0.displayName, username: $0.username, avatarEtag: $0.avatarEtag) }
        return (me.map { [$0] } ?? []) + friendPeople.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func person(for userID: UUID) -> LedgerPerson {
        if let person = people[userID] { return person }
        if let friend = friends.first(where: { $0.userId == userID }) { return LedgerPerson(id: userID, displayName: friend.displayName, username: friend.username, avatarEtag: friend.avatarEtag) }
        if userID == activeUserID, let profile { return LedgerPerson(id: userID, displayName: profile.displayName, username: profile.username) }
        return LedgerPerson(id: userID)
    }
    /// Uses the account holder's chosen self-reference everywhere a participant name appears.
    func name(for userID: UUID) -> String { userID == activeUserID ? selfReferenceName : person(for: userID).name }
    var selfReferenceName: String {
        switch selfReferenceMode {
        case .fullName: profile?.displayName ?? activeUserID.map { person(for: $0).name } ?? "Me"
        case .me: "Me"
        case .you: "You"
        }
    }
    var selfReferenceSubject: String {
        switch selfReferenceMode {
        case .fullName: selfReferenceName
        case .me: "I"
        case .you: "You"
        }
    }
    var selfReferenceObject: String {
        switch selfReferenceMode {
        case .fullName: selfReferenceName
        case .me: "me"
        case .you: "you"
        }
    }
    func updateSelfReference(_ mode: SelfReferenceMode) {
        selfReferenceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SelfReferenceMode.storageKey)
    }
    func describeBalance(_ cents: Int, with name: String) -> String {
        guard cents != 0 else { return "Settled up" }
        if cents > 0 { return "\(name) owes \(selfReferenceObject) \(cents.usd)" }
        let verb = selfReferenceMode == .fullName ? "owes" : "owe"
        return "\(selfReferenceSubject) \(verb) \(name) \((-cents).usd)"
    }

    func synchronize(userID: UUID, identity: AccountIdentity? = nil, accessToken: String) async {
        guard let api else {
            syncError = "The live ledger API is not configured."
            return
        }
        if activeUserID != userID { activate(userID) }
        isSyncing = true
        syncError = nil
        do {
            profile = try await api.ensureProfile(token: accessToken)
            isDeveloper = profile?.isDeveloper ?? false
            if let settings = try? await api.settings(token: accessToken) { applySliderUnit(settings.sliderUnit) }
            if let identity { profile = try await api.updateIdentity(identity, token: accessToken) }
            try await refresh(accessToken: accessToken)
            friends = try await api.friends(token: accessToken)
            hasLoadedRemoteData = true
        } catch {
            syncError = error.localizedDescription
        }
        isSyncing = false
    }

    func refresh(accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        apply(try await api.snapshot(token: accessToken))
    }
    func isExpensePending(_ expenseID: UUID) -> Bool { pendingExpenseIDs.contains(expenseID) }
    func searchUsers(_ query: String, accessToken: String) async throws -> [APIUserResult] {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        return try await api.searchUsers(query: query, token: accessToken)
    }

    /// Returns the user's picture, refetching when `etag` differs from the cached copy's. A nil `etag` accepts any cached copy.
    /// Network failures aren't cached, so the next appearance tries again.
    func avatar(for userID: UUID, etag: String?, accessToken: String) async -> UIImage? {
        if let cached = avatars[userID], etag == nil || cached.etag == etag { return cached.image }
        guard let api else { return nil }
        do {
            let image = try await api.avatar(userID: userID, token: accessToken).flatMap(UIImage.init(data:))
            avatars[userID] = (etag, image)
            return image
        } catch {
            return nil
        }
    }

    /// Fetches a saved receipt image; nil if it can't be loaded right now.
    func receiptImage(_ evidenceID: UUID, accessToken: String) async -> UIImage? {
        if let cached = receiptImages[evidenceID] { return cached }
        guard let api, let data = try? await api.evidenceImage(id: evidenceID, token: accessToken), let image = UIImage(data: data) else { return nil }
        receiptImages[evidenceID] = image
        return image
    }

    /// Uploads a square, 512-point JPEG of the chosen photo as the signed-in user's profile picture.
    func uploadAvatar(_ image: UIImage, userID: UUID, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let resized = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { _ in
            image.draw(in: CGRect(x: -crop.minX * 512 / side, y: -crop.minY * 512 / side, width: image.size.width * 512 / side, height: image.size.height * 512 / side))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { throw LedgerAPIClientError.invalidResponse }
        let etag = try await api.uploadAvatar(jpeg, token: accessToken)
        avatars[userID] = (etag, resized)
        avatarVersion += 1
    }

    /// Saves the slider unit to the account, restoring the account's unit if the server rejects it.
    func updateSliderUnit(_ unit: ContributionSliderUnit, accessToken: String) async {
        guard let api, unit.rawValue != savedSliderUnit else { return }
        do { applySliderUnit(try await api.updateSliderUnit(unit.rawValue, token: accessToken).sliderUnit) }
        catch { applySliderUnit(savedSliderUnit) }
    }
    /// The unit last confirmed by the server; the phone keeps a copy for the sliders to read.
    private var savedSliderUnit: String?
    private func applySliderUnit(_ rawValue: String?) {
        savedSliderUnit = rawValue
        guard let rawValue, ContributionSliderUnit(rawValue: rawValue) != nil else { return }
        UserDefaults.standard.set(rawValue, forKey: ContributionSliderUnit.storageKey)
    }

    func updateProfile(_ identity: AccountIdentity, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        profile = try await api.updateIdentity(identity, token: accessToken)
    }
    var friendCount: Int { friends.filter { $0.status == "accepted" }.count }
    func refreshFriends(accessToken: String) async throws { guard let api else { throw LedgerAPIClientError.configurationMissing }; friends = try await api.friends(token: accessToken) }
    func requestFriend(username: String, accessToken: String) async throws { guard let api else { throw LedgerAPIClientError.configurationMissing }; _ = try await api.requestFriend(username: username, token: accessToken); try await refreshFriends(accessToken: accessToken) }
    /// Shows the friend as accepted immediately, and restores the request if the server rejects it.
    func acceptFriend(_ requestID: UUID, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        guard let index = friends.firstIndex(where: { $0.requestId == requestID }) else {
            _ = try await api.acceptFriend(requestID: requestID, token: accessToken)
            try await refreshFriends(accessToken: accessToken)
            try await refresh(accessToken: accessToken)
            return
        }
        let pending = friends[index]
        friends[index] = APIFriend(requestId: pending.requestId, userId: pending.userId, displayName: pending.displayName, username: pending.username, avatarEtag: pending.avatarEtag, status: "accepted", direction: "friend")
        do {
            _ = try await api.acceptFriend(requestID: requestID, token: accessToken)
        } catch {
            if let index = friends.firstIndex(where: { $0.requestId == requestID }) { friends[index] = pending }
            throw error
        }
        try await refreshFriends(accessToken: accessToken)
        try await refresh(accessToken: accessToken)
    }
    /// Takes the friend off the list immediately, and puts them back if the server rejects it.
    func removeFriend(_ userID: UUID, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        let previous = friends
        friends.removeAll { $0.userId == userID }
        do {
            try await api.removeFriend(userID: userID, token: accessToken)
        } catch {
            friends = previous
            throw error
        }
        try await refreshFriends(accessToken: accessToken)
    }

    /// Inserts the actual client-created expense into local history before its image and database row finish uploading.
    /// It is reconciled by `clientRequestId`, so it cannot become a second expense when the server snapshot arrives.
    func stage(_ expense: Expense) {
        var preview = expense
        preview.recognizedText = nil
        pendingExpenses[expense.id] = preview
        pendingExpenseIDs.insert(expense.id)
        if !expenses.contains(where: { $0.id == expense.id }) { expenses.append(preview) }
        rebuildBalances()
    }

    /// Uploads `receiptImageData` unless the expense already names its `evidenceIDs`, as a later expense from a receipt
    /// saved earlier does, so every expense from one receipt shares that receipt's evidence. The caller stages it first.
    @discardableResult
    func syncStaged(_ expense: Expense, accessToken: String) async throws -> [UUID] {
        guard let api else {
            discardPendingExpense(expense.id)
            expenseSaveError = LedgerAPIClientError.configurationMissing.localizedDescription
            throw LedgerAPIClientError.configurationMissing
        }
        do {
            // Sorted so a retry after relaunch sends the same request.
            let allocations = expense.shares.sorted { $0.key.uuidString < $1.key.uuidString }.map { APIAllocation(userId: $0.key, amountCents: $0.value) }
            var evidenceIDs = expense.evidenceIDs
            if evidenceIDs.isEmpty, let image = expense.receiptImageData {
                if let pending = pendingEvidenceIDs[expense.id] { evidenceIDs = [pending] }
                else {
                    let evidence = try await api.uploadReceipt(image, token: accessToken)
                    pendingEvidenceIDs[expense.id] = evidence.id
                    receiptImages[evidence.id] = UIImage(data: image)
                    evidenceIDs = [evidence.id]
                    // Only for troubleshooting a misread, so a failure here shouldn't block saving.
                    if let text = expense.recognizedText, !text.isEmpty { try? await api.putEvidenceText(text, evidenceID: evidence.id, token: accessToken) }
                }
            }
            let selectedItems = expense.items.filter(\.isSelected).map {
                APIExpenseItem(name: $0.name, amountCents: $0.cents, localOffsetCents: $0.localOffsetCents, globalOffsetCents: $0.globalOffsetCents,
                               kind: $0.kind.rawValue, taxed: $0.taxed, ownerIds: $0.ownerIDs.sorted { $0.uuidString < $1.uuidString })
            }
            let request = CreateAPIExpense(
                clientRequestId: expense.id,
                description: expense.description,
                category: expense.category?.rawValue,
                transactionDate: Self.dayFormatter.string(from: expense.transactionDate),
                payerId: expense.payer,
                currency: "USD",
                totalCents: expense.total,
                evidenceIds: evidenceIDs,
                items: selectedItems,
                adjustments: expense.adjustments.map { APIAdjustment(kind: $0.kind.rawValue, amountCents: $0.amountCents, rate: $0.kind == .tip ? nil : $0.rate) },
                allocations: allocations
            )
            _ = try await api.createExpense(request, token: accessToken)
            pendingEvidenceIDs[expense.id] = nil
            do { try await refresh(accessToken: accessToken) }
            catch { syncError = error.localizedDescription }
            return evidenceIDs
        } catch {
            discardPendingExpense(expense.id)
            syncError = error.localizedDescription
            expenseSaveError = error.localizedDescription
            throw error
        }
    }

    /// Applies an edit immediately and restores the previous values if the server rejects it. Only the payer may edit;
    /// a blank name is ignored, and a call that changes nothing does nothing.
    func updateExpense(_ expenseID: UUID, description: String? = nil, transactionDate: Date? = nil, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        guard let index = expenses.firstIndex(where: { $0.id == expenseID }) else { return }
        let previous = expenses[index]
        var edited = previous
        var changes = UpdateAPIExpense()
        if let name = description?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != previous.description {
            edited.description = name
            changes.description = name
        }
        if let transactionDate {
            let day = Self.dayFormatter.string(from: transactionDate)
            if day != Self.dayFormatter.string(from: previous.transactionDate) {
                edited.transactionDate = Self.dayFormatter.date(from: day) ?? transactionDate
                changes.transactionDate = day
            }
        }
        guard changes.description != nil || changes.transactionDate != nil else { return }
        expenses[index] = edited
        do {
            let saved = try await api.updateExpense(id: expenseID, changes: changes, token: accessToken)
            if let index = expenses.firstIndex(where: { $0.id == expenseID }) {
                expenses[index].description = saved.description
                if let day = Self.dayFormatter.date(from: saved.transactionDate) { expenses[index].transactionDate = day }
            }
        } catch {
            // Undo only what this edit set, in case a refresh has replaced it since.
            if let index = expenses.firstIndex(where: { $0.id == expenseID }) {
                if changes.description != nil, expenses[index].description == edited.description { expenses[index].description = previous.description }
                if changes.transactionDate != nil, expenses[index].transactionDate == edited.transactionDate { expenses[index].transactionDate = previous.transactionDate }
            }
            throw error
        }
    }

    func add(_ payment: Payment, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        _ = try await api.createPayment(
            CreateAPIPayment(
                clientRequestId: payment.id,
                fromUserId: payment.from,
                toUserId: payment.to,
                amountCents: payment.amount,
                transactionDate: Self.dayFormatter.string(from: payment.transactionDate)
            ),
            token: accessToken
        )
        try await refresh(accessToken: accessToken)
    }

    /// Developer-only: deletes every account's expenses and payments on the server, then reloads.
    func resetServerLedger(accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        try await api.resetLedgerData(token: accessToken)
        receiptImages = [:]
        pendingEvidenceIDs = [:]
        pendingExpenses = [:]
        pendingExpenseIDs = []
        try await refresh(accessToken: accessToken)
    }

    func resetLocalCache() {
        expenses = []
        payments = []
        pendingExpenses = [:]
        pendingExpenseIDs = []
        confirmedBalances = [:]
        people = [:]
        balances = [:]
        friends = []
        if let activeUserID { UserDefaults.standard.removeObject(forKey: storageKey(for: activeUserID)) }
    }

    func disconnect() {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        isDeveloper = false
        savedSliderUnit = nil
        avatars = [:]
        receiptImages = [:]
        pendingEvidenceIDs = [:]
        pendingExpenses = [:]
        pendingExpenseIDs = []
        confirmedBalances = [:]
        people = [:]
        balances = [:]
        friends = []
        expenses = []
        payments = []
        syncError = nil
        expenseSaveError = nil
    }

    private func activate(_ userID: UUID) {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        pendingEvidenceIDs = [:]
        pendingExpenses = [:]
        pendingExpenseIDs = []
        confirmedBalances = [:]
        people = [:]
        balances = [:]
        friends = []
        expenses = []
        payments = []
        activeUserID = userID
        restore(userID: userID)
    }

    private func apply(_ snapshot: APILedgerSnapshot) {
        let acknowledged = Set(snapshot.expenses.map(\.clientRequestId))
        for id in acknowledged { pendingExpenses[id] = nil; pendingExpenseIDs.remove(id) }
        people = Dictionary(snapshot.people.map { ($0.userId, LedgerPerson(id: $0.userId, displayName: $0.displayName, username: $0.username, avatarEtag: $0.avatarEtag)) }, uniquingKeysWith: { first, _ in first })
        confirmedBalances = Dictionary(snapshot.balances.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }, uniquingKeysWith: +)
        let confirmedExpenses = snapshot.expenses.map { remote in
            Expense(
                id: remote.id,
                description: remote.description,
                transactionDate: Self.dayFormatter.date(from: remote.transactionDate) ?? .now,
                payer: remote.payerId,
                items: remote.items.map {
                    ReceiptItem(name: $0.name, cents: $0.amountCents, localOffsetCents: $0.localOffsetCents ?? 0, globalOffsetCents: $0.globalOffsetCents ?? 0,
                                kind: $0.kind.flatMap(ReceiptItem.Kind.init(rawValue:)) ?? .item, taxed: $0.taxed ?? true, isSelected: true, ownerIDs: Set($0.ownerIds ?? []))
                },
                shares: Dictionary(remote.allocations.map { ($0.userId, $0.amountCents) }, uniquingKeysWith: +),
                receiptImageData: nil,
                createdAt: Self.isoDate(remote.createdAt),
                recordedTotalCents: remote.totalCents,
                evidenceIDs: remote.evidenceIds,
                category: remote.category.flatMap(ExpenseCategory.init(rawValue:)),
                adjustments: (remote.adjustments ?? []).compactMap { adjustment in
                    ReceiptAdjustment.Kind(rawValue: adjustment.kind).map { ReceiptAdjustment(kind: $0, rate: adjustment.rate ?? 0, amountCents: adjustment.amountCents) }
                }
            )
        }
        expenses = confirmedExpenses + Array(pendingExpenses.values)
        payments = snapshot.payments.map { remote in
            Payment(
                id: remote.id,
                amount: remote.amountCents,
                from: remote.fromUserId,
                to: remote.toUserId,
                transactionDate: Self.dayFormatter.date(from: remote.transactionDate) ?? .now,
                createdAt: Self.isoDate(remote.createdAt)
            )
        }
        rebuildBalances()
    }

    private func discardPendingExpense(_ id: UUID) {
        pendingExpenses[id] = nil
        pendingExpenseIDs.remove(id)
        pendingEvidenceIDs[id] = nil
        expenses.removeAll { $0.id == id }
        rebuildBalances()
    }

    /// Applies the same payer/allocation rule as the server to the confirmed balances plus optimistic expenses.
    private func rebuildBalances() {
        var result = confirmedBalances
        guard let me = activeUserID else { balances = result; return }
        for expense in pendingExpenses.values {
            for (person, cents) in expense.shares where person != expense.payer {
                if expense.payer == me { result[person, default: 0] += cents }
                else if person == me { result[expense.payer, default: 0] -= cents }
            }
        }
        balances = result
    }

    private func persist() {
        let confirmedExpenses = expenses.filter { !pendingExpenseIDs.contains($0.id) }
        guard let activeUserID, let data = try? JSONEncoder().encode(LocalLedger(expenses: confirmedExpenses, payments: payments, people: Array(people.values), balances: confirmedBalances)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
    }

    private func restore(userID: UUID) {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: userID)), let ledger = try? JSONDecoder().decode(LocalLedger.self, from: data) else { return }
        people = Dictionary(ledger.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        balances = ledger.balances
        confirmedBalances = ledger.balances
        expenses = ledger.expenses
        payments = ledger.payments
    }

    private func storageKey(for userID: UUID) -> String { "\(storageKeyPrefix)-\(userID.uuidString.lowercased())" }

    /// Transaction dates are calendar days, so they're read and written in the user's time zone. Using UTC here
    /// turned a saved "2026-09-27" into 5 PM on the 26th in US time zones, and pushed evening dates to the next day.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func isoDate(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .now
    }
}
private struct LocalLedger: Codable { var expenses: [Expense]; var payments: [Payment]; var people: [LedgerPerson]; var balances: [UUID: Int] }
extension Int { var usd: String { (Decimal(self) / 100).formatted(.currency(code: "USD")) } }
