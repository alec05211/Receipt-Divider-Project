import Foundation

enum LedgerAPIClientError: LocalizedError, Sendable {
    case configurationMissing
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing: "The ledger API URL is missing from the app configuration."
        case .invalidResponse: "The ledger service returned an unreadable response."
        case .requestFailed(_, let message): message
        }
    }
}

actor LedgerAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(bundle: Bundle = .main, session: URLSession = .shared) {
        guard
            let value = bundle.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
            let url = URL(string: value),
            url.scheme == "https"
        else { return nil }
        baseURL = url
        self.session = session
    }

    /// Creates the caller's profile and ledger on first use, and returns the current profile.
    func ensureProfile(token: String) async throws -> APIProfile {
        try await send(path: "/v1/profile", method: "PUT", token: token)
    }
    func updateIdentity(_ identity: AccountIdentity, token: String) async throws -> APIProfile {
        try await send(path: "/v1/profile/identity", method: "PUT", token: token, body: encoder.encode(identity))
    }

    func settings(token: String) async throws -> APISettings { try await send(path: "/v1/settings", token: token) }
    func updateSliderUnit(_ unit: String, token: String) async throws -> APISettings {
        try await send(path: "/v1/settings", method: "PATCH", token: token, body: encoder.encode(["sliderUnit": unit]))
    }
    func updateTipSplit(_ split: String, token: String) async throws -> APISettings {
        try await send(path: "/v1/settings", method: "PATCH", token: token, body: encoder.encode(["tipSplit": split]))
    }

    func searchUsers(query: String, token: String) async throws -> [APIUserResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await send(path: "/v1/users/search?q=\(encoded)", token: token)
    }

    /// Returns nil when the user has no profile picture (or it isn't visible to the caller).
    func avatar(userID: UUID, token: String) async throws -> Data? {
        let (data, status) = try await perform(path: "/v1/users/\(userID.uuidString.lowercased())/avatar", method: "GET", token: token, contentType: nil, body: nil)
        if status == 404 || status == 403 { return nil }
        try check(data: data, status: status)
        return data
    }

    /// Returns the new photo's etag.
    func uploadAvatar(_ jpeg: Data, token: String) async throws -> String {
        try await (send(path: "/v1/profile/avatar", method: "PUT", token: token, contentType: "image/jpeg", body: jpeg) as APIAvatarUpload).etag
    }

    func friends(token: String) async throws -> [APIFriend] { try await send(path: "/v1/friends", token: token) }
    func requestFriend(username: String, token: String) async throws -> APIFriend {
        try await send(path: "/v1/friend-requests", method: "POST", token: token, body: encoder.encode(FriendRequest(username: username)))
    }
    func acceptFriend(requestID: UUID, token: String) async throws -> APIFriend {
        try await send(path: "/v1/friend-requests/\(requestID.uuidString)/accept", method: "POST", token: token, body: Data("{}".utf8))
    }
    func removeFriend(userID: UUID, token: String) async throws {
        let (data, status) = try await perform(path: "/v1/friends/\(userID.uuidString.lowercased())", method: "DELETE", token: token, contentType: nil, body: nil)
        try check(data: data, status: status)
    }

    func snapshot(token: String) async throws -> APILedgerSnapshot {
        try await send(path: "/v1/transactions", token: token)
    }

    /// Returns nil when the image doesn't exist or isn't visible to the caller.
    func evidenceImage(id: UUID, token: String) async throws -> Data? {
        let (data, status) = try await perform(path: "/v1/evidence/\(id.uuidString.lowercased())/image", method: "GET", token: token, contentType: nil, body: nil)
        if status == 404 { return nil }
        try check(data: data, status: status)
        return data
    }

    func uploadReceipt(_ data: Data, token: String) async throws -> APIEvidence {
        try await send(
            path: "/v1/evidence?kind=receipt",
            method: "POST",
            token: token,
            contentType: "image/jpeg",
            body: data
        )
    }

    /// `note` is a problem with a first reading, for a re-read.
    func readReceiptImage(_ data: Data, note: String?, token: String) async throws -> APIReceiptReading {
        let query = note.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "?note=\($0)" } ?? ""
        return try await send(
            path: "/v1/receipts/parse\(query)",
            method: "POST",
            token: token,
            contentType: "image/jpeg",
            body: data
        )
    }

    func putEvidenceText(_ text: String, diagnostics: ReceiptDiagnostics?, evidenceID: UUID, token: String) async throws {
        struct Body: Encodable { let text: String; let diagnostics: ReceiptDiagnostics? }
        let (data, status) = try await perform(path: "/v1/evidence/\(evidenceID.uuidString.lowercased())/text", method: "PUT", token: token, contentType: "application/json", body: encoder.encode(Body(text: text, diagnostics: diagnostics)))
        try check(data: data, status: status)
    }

    func createExpense(_ request: CreateAPIExpense, token: String) async throws -> APIExpense {
        try await send(path: "/v1/expenses", method: "POST", token: token, body: encoder.encode(request))
    }

    /// Edits an expense for everyone on it; only its payer may do this. Omitted fields stay as they are.
    func updateExpense(id: UUID, changes: UpdateAPIExpense, token: String) async throws -> APIExpense {
        try await send(path: "/v1/expenses/\(id.uuidString.lowercased())", method: "PATCH", token: token, body: encoder.encode(changes))
    }

    func createPayment(_ request: CreateAPIPayment, token: String) async throws -> APIPayment {
        try await send(path: "/v1/payments", method: "POST", token: token, body: encoder.encode(request))
    }

    /// Developer-only: deletes every account's expenses and payments. Accounts and friendships are kept.
    func resetLedgerData(token: String) async throws {
        let (data, status) = try await perform(path: "/v1/developer/reset-ledger", method: "POST", token: token, contentType: "application/json", body: encoder.encode(["confirm": "DELETE"]))
        try check(data: data, status: status)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        token: String,
        contentType: String = "application/json",
        body: Data? = nil
    ) async throws -> Response {
        let (data, status) = try await perform(path: path, method: method, token: token, contentType: body == nil ? nil : contentType, body: body)
        try check(data: data, status: status)
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw LedgerAPIClientError.invalidResponse }
    }

    private func perform(path: String, method: String, token: String, contentType: String?, body: Data?) async throws -> (Data, Int) {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw LedgerAPIClientError.configurationMissing
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LedgerAPIClientError.invalidResponse }
        return (data, http.statusCode)
    }

    private func check(data: Data, status: Int) throws {
        guard !(200..<300).contains(status) else { return }
        let message = (try? decoder.decode(APIErrorEnvelope.self, from: data).error.message)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        throw LedgerAPIClientError.requestFailed(status: status, message: message)
    }
}

/// The name fields are nil until the user sets them; `displayName` is always "First Last".
/// `isDeveloper` is only sent when fetching the profile, not after an identity update.
struct APIProfile: Decodable, Sendable { let id: UUID; let firstName: String?; let lastName: String?; let username: String?; let displayName: String?; let isDeveloper: Bool? }
/// `sliderUnit` is "dollars" or "percent"; `tipSplit` is "even" or "proportional", missing from an older API.
struct APISettings: Decodable, Sendable { let currency: String; let sliderUnit: String; let tipSplit: String? }
/// Someone in the caller's ledger: themselves, a friend, or anyone they share a transaction with.
struct APILedgerPerson: Decodable, Sendable { let userId: UUID; let displayName: String?; let username: String?; let avatarEtag: String? }
struct APIEvidence: Decodable, Sendable { let id: UUID; let kind: String; let contentType: String; let etag: String; let createdAt: String }
/// A receipt read from its photo by cloud vision: its printed rows top to bottom, each labeled as `ReceiptLabels.Kind`
/// names them. Empty strings mean not found.
struct APIReceiptReading: Codable, Sendable {
    /// `text` is the row without its price; `price` is the amount at its right end as printed, or empty. `name` is an
    /// item's name tidied by the model, or empty.
    struct Row: Codable, Sendable { let text: String; let price: String?; let kind: String; let taxed: Bool; var name: String? = nil }
    let merchant: String
    let category: String
    let purchaseDate: String
    let rows: [Row]
    let expenseName: String
}
/// `amountCents` is the printed price; the two offsets are the item's own discount and its share of receipt-wide
/// adjustments. `kind` is "item" or "tip". `ownerIds` are the people who had the item; an item sent without owners
/// belongs to the payer.
struct APIExpenseItem: Codable, Sendable {
    let name: String; let amountCents: Int; let localOffsetCents: Int?; let globalOffsetCents: Int?
    let kind: String?; let taxed: Bool?; let ownerIds: [UUID]?
}
/// `kind` is "discount", "tax", "tip" or "surcharge"; `rate` is a fraction (0.06 for 6%) and is nil for a tip.
struct APIAdjustment: Codable, Sendable { let kind: String; let amountCents: Int; let rate: Double? }
struct APIAllocation: Codable, Sendable { let userId: UUID; let amountCents: Int }

struct CreateAPIExpense: Encodable, Sendable {
    let clientRequestId: UUID
    let description: String
    /// Omitted when nil.
    let category: String?
    let transactionDate: String
    let payerId: UUID
    let currency: String
    let totalCents: Int
    let evidenceIds: [UUID]
    let items: [APIExpenseItem]
    let adjustments: [APIAdjustment]
    let allocations: [APIAllocation]
}

/// The editable fields of an expense; nil fields are left out of the request.
struct UpdateAPIExpense: Encodable, Sendable {
    var description: String?
    var transactionDate: String?
}

struct APIExpense: Decodable, Sendable {
    let id: UUID
    let clientRequestId: UUID
    let description: String
    /// Kept as a string so a category this build doesn't know shows as uncategorized instead of failing the snapshot.
    let category: String?
    let transactionDate: String
    let payerId: UUID
    let totalCents: Int
    let items: [APIExpenseItem]
    /// In receipt order; nil from a server that predates adjustments.
    let adjustments: [APIAdjustment]?
    let allocations: [APIAllocation]
    let evidenceIds: [UUID]
    let createdAt: String
}

struct CreateAPIPayment: Encodable, Sendable {
    let clientRequestId: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let amountCents: Int
    let transactionDate: String
}

struct APIPayment: Decodable, Sendable {
    let id: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let amountCents: Int
    let transactionDate: String
    let createdAt: String
}

/// `balances` maps each other person's user ID to what they owe the caller (negative: what the caller owes them).
struct APILedgerSnapshot: Decodable, Sendable {
    let currency: String
    let people: [APILedgerPerson]
    let expenses: [APIExpense]
    let payments: [APIPayment]
    let balances: [String: Int]
    let netBalance: Int
}
/// A user found by search; `relationship` is "none", "outgoing", "incoming", or "friend".
struct APIUserResult: Decodable, Identifiable, Sendable {
    let userId: UUID; let displayName: String; let username: String; let avatarEtag: String?
    var relationship: String; let requestId: UUID?
    var id: UUID { userId }
}
private struct APIAvatarUpload: Decodable { let etag: String }

struct APIFriend: Decodable, Identifiable, Sendable {
    let requestId: UUID; let userId: UUID; let displayName: String; let username: String; let avatarEtag: String?
    let status: String; let direction: String
    var id: UUID { requestId }
}

private struct FriendRequest: Encodable { let username: String }
private struct APIErrorEnvelope: Decodable { let error: APIErrorBody }
private struct APIErrorBody: Decodable { let code: String; let message: String }
