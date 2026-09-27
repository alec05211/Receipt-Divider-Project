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
struct Expense: Identifiable, Hashable, Codable {
    var id = UUID(); var description: String; var transactionDate: Date; var payer: Person; var items: [ReceiptItem]; var shares: [Person: Int]; var receiptImageData: Data?; var createdAt = Date(); var recordedTotalCents: Int?
    var total: Int { recordedTotalCents ?? max(0, items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents }) }
    /// Tax and discounts included in the selected items.
    var offsetTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.offsetCents } }
}
extension Expense {
    /// Expenses saved before item offsets stored tax and discount as separate amounts; those are spread onto the shared items.
    private enum LegacyKeys: String, CodingKey { case taxCents, discountCents }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); description = try container.decode(String.self, forKey: .description)
        transactionDate = try container.decode(Date.self, forKey: .transactionDate); payer = try container.decode(Person.self, forKey: .payer)
        items = try container.decode([ReceiptItem].self, forKey: .items); shares = try container.decode([Person: Int].self, forKey: .shares)
        receiptImageData = try container.decodeIfPresent(Data.self, forKey: .receiptImageData); createdAt = try container.decode(Date.self, forKey: .createdAt)
        recordedTotalCents = try container.decodeIfPresent(Int.self, forKey: .recordedTotalCents)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let tax = try legacy.decodeIfPresent(Int.self, forKey: .taxCents) ?? 0, discount = try legacy.decodeIfPresent(Int.self, forKey: .discountCents) ?? 0
        items.spread(tax - discount, where: \.isSelected)
    }
}
struct Payment: Identifiable, Hashable, Codable { var id = UUID(); var amount: Int; var from: Person; var to: Person; var transactionDate: Date; var createdAt = Date() }
enum Person: String, CaseIterable, Identifiable, Codable {
    case alex = "Alex", jamie = "Jamie", morgan = "Morgan", taylor = "Taylor"
    var id: String { rawValue }
    var other: Person { self == .alex ? .jamie : .alex }
    var initials: String { String(rawValue.prefix(1)) }
}

@MainActor
@Observable final class ExpenseStore {
    private let storageKeyPrefix = "receipt-divider-ledger-v2"
    private let api: LedgerAPIClient?
    private var personIDs: [Person: UUID] = [:]
    private var serverBalances: [UUID: Int] = [:]
    private var pendingEvidenceIDs: [UUID: UUID] = [:]
    private(set) var activeUserID: UUID?
    private(set) var hasLoadedRemoteData = false
    private(set) var isSyncing = false
    private(set) var friends: [APIFriend] = []
    private(set) var profile: APIProfile?
    /// Loaded profile pictures; nil records a user known to have none, so it isn't fetched again.
    private var avatars: [UUID: UIImage?] = [:]
    /// Bumped when the signed-in user's own picture changes, so views showing it reload.
    private(set) var avatarVersion = 0
    var syncError: String?
    var expenses: [Expense] = [] { didSet { persist() } }
    var payments: [Payment] = [] { didSet { persist() } }

    init(bundle: Bundle = .main) { api = LedgerAPIClient(bundle: bundle) }

    var isAPIConfigured: Bool { api != nil }
    var alexBalance: Int {
        if let alexID = personIDs[.alex], let balance = serverBalances[alexID] { return balance }
        let expenses = expenses.reduce(0) { $0 + ($1.payer == .alex ? $1.total : 0) - ($1.shares[.alex] ?? 0) }
        let payments = payments.reduce(0) { $0 + ($1.from == .alex ? $1.amount : 0) - ($1.to == .alex ? $1.amount : 0) }
        return expenses + payments
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
            if let identity { profile = try await api.updateIdentity(identity, token: accessToken) }
            var remotePeople = try await api.people(token: accessToken)
            for person in Person.allCases where !remotePeople.contains(where: { $0.displayName.caseInsensitiveCompare(person.rawValue) == .orderedSame }) {
                remotePeople.append(try await api.createPerson(displayName: person.rawValue, token: accessToken))
            }
            personIDs = Dictionary(uniqueKeysWithValues: Person.allCases.compactMap { person in
                remotePeople.first(where: { $0.displayName.caseInsensitiveCompare(person.rawValue) == .orderedSame }).map { (person, $0.id) }
            })
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

    func avatar(for userID: UUID, accessToken: String) async -> UIImage? {
        if let cached = avatars[userID] { return cached }
        guard let api, let data = try? await api.avatar(userID: userID, token: accessToken) else {
            avatars[userID] = .some(nil)
            return nil
        }
        let image = UIImage(data: data)
        avatars[userID] = .some(image)
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
        try await api.uploadAvatar(jpeg, token: accessToken)
        avatars[userID] = .some(resized)
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
        friends[index] = APIFriend(requestId: pending.requestId, userId: pending.userId, displayName: pending.displayName, username: pending.username, status: "accepted", direction: "friend")
        do {
            _ = try await api.acceptFriend(requestID: requestID, token: accessToken)
        } catch {
            if let index = friends.firstIndex(where: { $0.requestId == requestID }) { friends[index] = pending }
            throw error
        }
        try await refreshFriends(accessToken: accessToken)
        try await refresh(accessToken: accessToken)
    }

    func add(_ expense: Expense, accessToken: String) async throws {
        guard let api else { throw LedgerAPIClientError.configurationMissing }
        guard let payerID = personIDs[expense.payer] else { throw ExpenseStoreError.peopleNotReady }
        let allocations = try expense.shares.map { person, cents in
            guard let id = personIDs[person] else { throw ExpenseStoreError.peopleNotReady }
            return APIAllocation(personId: id, amountCents: cents)
        }
        var evidenceIDs: [UUID] = []
        if let image = expense.receiptImageData {
            if let pending = pendingEvidenceIDs[expense.id] { evidenceIDs = [pending] }
            else {
                let evidence = try await api.uploadReceipt(image, token: accessToken)
                pendingEvidenceIDs[expense.id] = evidence.id
                evidenceIDs = [evidence.id]
            }
        }
        let selectedItems = expense.items.filter(\.isSelected).map {
            APIExpenseItem(name: $0.name, amountCents: $0.cents, offsetCents: $0.offsetCents)
        }
        let request = CreateAPIExpense(
            clientRequestId: expense.id,
            description: expense.description,
            transactionDate: Self.dayFormatter.string(from: expense.transactionDate),
            payerPersonId: payerID,
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
        guard let fromID = personIDs[payment.from], let toID = personIDs[payment.to] else { throw ExpenseStoreError.peopleNotReady }
        _ = try await api.createPayment(
            CreateAPIPayment(
                clientRequestId: payment.id,
                fromPersonId: fromID,
                toPersonId: toID,
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
        serverBalances = [:]
        friends = []
        if let activeUserID { UserDefaults.standard.removeObject(forKey: storageKey(for: activeUserID)) }
    }

    func disconnect() {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        avatars = [:]
        personIDs = [:]
        serverBalances = [:]
        expenses = []
        payments = []
        syncError = nil
    }

    private func activate(_ userID: UUID) {
        activeUserID = nil
        hasLoadedRemoteData = false
        profile = nil
        personIDs = [:]
        serverBalances = [:]
        expenses = []
        payments = []
        activeUserID = userID
        restore(userID: userID)
    }

    private func apply(_ snapshot: APILedgerSnapshot) {
        let peopleByID = Dictionary(uniqueKeysWithValues: personIDs.map { ($1, $0) })
        expenses = snapshot.expenses.compactMap { remote in
            guard let payer = peopleByID[remote.payerPersonId] else { return nil }
            let shares = Dictionary(uniqueKeysWithValues: remote.allocations.compactMap { allocation in
                peopleByID[allocation.personId].map { ($0, allocation.amountCents) }
            })
            guard shares.count == remote.allocations.count else { return nil }
            return Expense(
                id: remote.id,
                description: remote.description,
                transactionDate: Self.dayFormatter.date(from: remote.transactionDate) ?? .now,
                payer: payer,
                items: remote.items.map { ReceiptItem(name: $0.name, cents: $0.amountCents, offsetCents: $0.offsetCents ?? 0, isSelected: true) },
                shares: shares,
                receiptImageData: nil,
                createdAt: Self.isoDate(remote.createdAt),
                recordedTotalCents: remote.totalCents
            )
        }
        payments = snapshot.payments.compactMap { remote in
            guard let from = peopleByID[remote.fromPersonId], let to = peopleByID[remote.toPersonId] else { return nil }
            return Payment(
                id: remote.id,
                amount: remote.amountCents,
                from: from,
                to: to,
                transactionDate: Self.dayFormatter.date(from: remote.transactionDate) ?? .now,
                createdAt: Self.isoDate(remote.createdAt)
            )
        }
        serverBalances = Dictionary(uniqueKeysWithValues: snapshot.balances.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func persist() {
        guard let activeUserID, let data = try? JSONEncoder().encode(LocalLedger(expenses: expenses, payments: payments)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
    }

    private func restore(userID: UUID) {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: userID)), let ledger = try? JSONDecoder().decode(LocalLedger.self, from: data) else { return }
        expenses = ledger.expenses
        payments = ledger.payments
    }

    private func storageKey(for userID: UUID) -> String { "\(storageKeyPrefix)-\(userID.uuidString.lowercased())" }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func isoDate(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .now
    }
}
private enum ExpenseStoreError: LocalizedError {
    case peopleNotReady
    var errorDescription: String? { "People are still syncing. Refresh the ledger and try again." }
}
private struct LocalLedger: Codable { var expenses: [Expense]; var payments: [Payment] }
extension Int { var usd: String { (Decimal(self) / 100).formatted(.currency(code: "USD")) } }
