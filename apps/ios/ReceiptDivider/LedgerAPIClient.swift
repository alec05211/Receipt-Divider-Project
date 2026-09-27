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

    func people(token: String) async throws -> [APIPerson] {
        try await send(path: "/v1/people", token: token)
    }

    func createPerson(displayName: String, token: String) async throws -> APIPerson {
        try await send(
            path: "/v1/people",
            method: "POST",
            token: token,
            body: encoder.encode(PersonRequest(displayName: displayName))
        )
    }

    func friends(token: String) async throws -> [APIFriend] { try await send(path: "/v1/friends", token: token) }
    func requestFriend(username: String, token: String) async throws -> APIFriend {
        try await send(path: "/v1/friend-requests", method: "POST", token: token, body: encoder.encode(FriendRequest(username: username)))
    }
    func acceptFriend(requestID: UUID, token: String) async throws -> APIFriend {
        try await send(path: "/v1/friend-requests/\(requestID.uuidString)/accept", method: "POST", token: token, body: Data("{}".utf8))
    }

    func snapshot(token: String) async throws -> APILedgerSnapshot {
        try await send(path: "/v1/transactions", token: token)
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

    func createExpense(_ request: CreateAPIExpense, token: String) async throws -> APIExpense {
        try await send(path: "/v1/expenses", method: "POST", token: token, body: encoder.encode(request))
    }

    func createPayment(_ request: CreateAPIPayment, token: String) async throws -> APIPayment {
        try await send(path: "/v1/payments", method: "POST", token: token, body: encoder.encode(request))
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        token: String,
        contentType: String = "application/json",
        body: Data? = nil
    ) async throws -> Response {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw LedgerAPIClientError.configurationMissing
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LedgerAPIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw LedgerAPIClientError.requestFailed(status: http.statusCode, message: message)
        }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw LedgerAPIClientError.invalidResponse }
    }
}

/// The name fields are nil until the user sets them; `displayName` is always "First Last".
struct APIProfile: Decodable, Sendable { let id: UUID; let firstName: String?; let lastName: String?; let username: String?; let displayName: String? }
struct APIPerson: Decodable, Sendable { let id: UUID; let displayName: String; let createdAt: String }
struct APIEvidence: Decodable, Sendable { let id: UUID; let kind: String; let contentType: String; let etag: String; let createdAt: String }
struct APIExpenseItem: Codable, Sendable { let name: String; let amountCents: Int; let offsetCents: Int? }
struct APIAllocation: Codable, Sendable { let personId: UUID; let amountCents: Int }

struct CreateAPIExpense: Encodable, Sendable {
    let clientRequestId: UUID
    let description: String
    let transactionDate: String
    let payerPersonId: UUID
    let currency: String
    let totalCents: Int
    let evidenceIds: [UUID]
    let items: [APIExpenseItem]
    let allocations: [APIAllocation]
}

struct APIExpense: Decodable, Sendable {
    let id: UUID
    let description: String
    let transactionDate: String
    let payerPersonId: UUID
    let totalCents: Int
    let items: [APIExpenseItem]
    let allocations: [APIAllocation]
    let evidenceIds: [UUID]
    let createdAt: String
}

struct CreateAPIPayment: Encodable, Sendable {
    let clientRequestId: UUID
    let fromPersonId: UUID
    let toPersonId: UUID
    let amountCents: Int
    let transactionDate: String
}

struct APIPayment: Decodable, Sendable {
    let id: UUID
    let fromPersonId: UUID
    let toPersonId: UUID
    let amountCents: Int
    let transactionDate: String
    let createdAt: String
}

struct APILedgerSnapshot: Decodable, Sendable {
    let version: Int
    let currency: String
    let people: [APIPerson]
    let expenses: [APIExpense]
    let payments: [APIPayment]
    let balances: [String: Int]
}
struct APIFriend: Decodable, Identifiable, Sendable {
    let requestId: UUID; let userId: UUID; let displayName: String; let username: String
    let status: String; let direction: String
    var id: UUID { requestId }
}

private struct PersonRequest: Encodable { let displayName: String }
private struct FriendRequest: Encodable { let username: String }
private struct APIErrorEnvelope: Decodable { let error: APIErrorBody }
private struct APIErrorBody: Decodable { let code: String; let message: String }
