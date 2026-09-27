import Foundation
import Observation
import UIKit

struct ReceiptItem: Identifiable, Hashable, Codable {
    var id = UUID(); var name: String; var cents: Int
    /// The item's part of the receipt's tax and discounts, kept apart so `cents` stays the printed price.
    /// Negative when discounts outweigh tax.
    var offsetCents = 0
    var isSelected = false
    var totalCents: Int { cents + offsetCents }
}
extension ReceiptItem {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); name = try container.decode(String.self, forKey: .name); cents = try container.decode(Int.self, forKey: .cents)
        offsetCents = try container.decodeIfPresent(Int.self, forKey: .offsetCents) ?? 0
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }
}
extension Array where Element == ReceiptItem {
    /// Adds an amount (tax minus discounts) to the offsets of the matching items, in proportion to what each
    /// costs after its own discounts. Rounding cents go to the largest fractions, so the offsets add up exactly.
    mutating func spread(_ amount: Int, where include: (ReceiptItem) -> Bool = { _ in true }) {
        let targets = indices.filter { include(self[$0]) && self[$0].totalCents > 0 }
        let base = targets.reduce(0) { $0 + self[$1].totalCents }
        guard amount != 0, base > 0 else { return }
        let exact = targets.map { (index: $0, value: Double(amount) * Double(self[$0].totalCents) / Double(base)) }
        for share in exact { self[share.index].offsetCents += Int(share.value.rounded(.towardZero)) }
        let remainder = amount - exact.reduce(0) { $0 + Int($1.value.rounded(.towardZero)) }
        let byFraction = exact.sorted { abs($0.value.truncatingRemainder(dividingBy: 1)) > abs($1.value.truncatingRemainder(dividingBy: 1)) }
        for share in byFraction.prefix(abs(remainder)) { self[share.index].offsetCents += remainder.signum() }
    }
}
/// `payer` and the keys of `shares` are user IDs. `receiptImageData` and `recognizedText` are only set before saving;
/// saved receipts are fetched by `evidenceIDs`.
struct Expense: Identifiable, Hashable, Codable {
    var id = UUID(); var description: String; var transactionDate: Date; var payer: UUID; var items: [ReceiptItem]; var shares: [UUID: Int]; var receiptImageData: Data?; var createdAt = Date(); var recordedTotalCents: Int?; var evidenceIDs: [UUID] = []; var recognizedText: String?
    var total: Int { recordedTotalCents ?? max(0, items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents }) }
    /// Tax and discounts included in the selected items.
    var offsetTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.offsetCents } }
    var participants: [UUID] { Array(shares.keys) }
}
struct Payment: Identifiable, Hashable, Codable { var id = UUID(); var amount: Int; var from: UUID; var to: UUID; var transactionDate: Date; var createdAt = Date() }
/// An app user who appears in the signed-in user's ledger: themselves, a friend, or someone they share a transaction with.
struct LedgerPerson: Identifiable, Hashable, Codable {
    let id: UUID; var displayName: String?; var username: String?; var avatarEtag: String?
    var name: String { displayName ?? username.map { "@\($0)" } ?? "Unknown" }
}

@MainActor
@Observable final class ExpenseStore {
    private let storageKeyPrefix = "receipt-divider-ledger-v3"
    private let api: LedgerAPIClient?
    private var pendingEvidenceIDs: [UUID: UUID] = [:]
    private(set) var activeUserID: UUID?
    private(set) var hasLoadedRemoteData = false
    private(set) var isSyncing = false
    private(set) var friends: [APIFriend] = []
    private(set) var profile: APIProfile?
    /// Loaded profile pictures with the etag they were fetched for; a nil image records a user known to have none.
    private var avatars: [UUID: (etag: String?, image: UIImage?)] = [:]
    /// Receipt images by evidence ID. They never change once uploaded, so they're kept for the session.
    private var receiptImages: [UUID: UIImage] = [:]
    /// Bumped when the signed-in user's own picture changes, so views showing it reload.
    private(set) var avatarVersion = 0
    var syncError: String?
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
    /// "You" for the signed-in user, otherwise the person's name.
    func name(for userID: UUID) -> String { userID == activeUserID ? "You" : person(for: userID).name }

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

    func add(_ expense: Expense, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        let allocations = expense.shares.map { APIAllocation(userId: $0.key, amountCents: $0.value) }
        var evidenceIDs: [UUID] = []
        if let image = expense.receiptImageData {
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
            APIExpenseItem(name: $0.name, amountCents: $0.cents, offsetCents: $0.offsetCents)
        }
        let request = CreateAPIExpense(
            clientRequestId: expense.id,
            description: expense.description,
            transactionDate: Self.dayFormatter.string(from: expense.transactionDate),
            payerId: expense.payer,
            currency: "USD",
            totalCents: expense.total,
            evidenceIds: evidenceIDs,
            items: selectedItems,
            allocations: allocations
        )
        _ = try await api.createExpense(request, token: accessToken)
        pendingEvidenceIDs[expense.id] = nil
        try await refresh(accessToken: accessToken)
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

    func resetLocalCache() {
        expenses = []
        payments = []
        people = [:]
        balances = [:]
        friends = []
        if let activeUserID { UserDefaults.standard.removeObject(forKey: storageKey(for: activeUserID)) }
    }

    func disconnect() {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        avatars = [:]
        receiptImages = [:]
        people = [:]
        balances = [:]
        friends = []
        expenses = []
        payments = []
        syncError = nil
    }

    private func activate(_ userID: UUID) {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        people = [:]
        balances = [:]
        friends = []
        expenses = []
        payments = []
        activeUserID = userID
        restore(userID: userID)
    }

    private func apply(_ snapshot: APILedgerSnapshot) {
        people = Dictionary(snapshot.people.map { ($0.userId, LedgerPerson(id: $0.userId, displayName: $0.displayName, username: $0.username, avatarEtag: $0.avatarEtag)) }, uniquingKeysWith: { first, _ in first })
        balances = Dictionary(snapshot.balances.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }, uniquingKeysWith: +)
        expenses = snapshot.expenses.map { remote in
            Expense(
                id: remote.id,
                description: remote.description,
                transactionDate: Self.dayFormatter.date(from: remote.transactionDate) ?? .now,
                payer: remote.payerId,
                items: remote.items.map { ReceiptItem(name: $0.name, cents: $0.amountCents, offsetCents: $0.offsetCents ?? 0, isSelected: true) },
                shares: Dictionary(remote.allocations.map { ($0.userId, $0.amountCents) }, uniquingKeysWith: +),
                receiptImageData: nil,
                createdAt: Self.isoDate(remote.createdAt),
                recordedTotalCents: remote.totalCents,
                evidenceIDs: remote.evidenceIds
            )
        }
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
    }

    private func persist() {
        guard let activeUserID, let data = try? JSONEncoder().encode(LocalLedger(expenses: expenses, payments: payments, people: Array(people.values), balances: balances)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
    }

    private func restore(userID: UUID) {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: userID)), let ledger = try? JSONDecoder().decode(LocalLedger.self, from: data) else { return }
        people = Dictionary(ledger.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        balances = ledger.balances
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
