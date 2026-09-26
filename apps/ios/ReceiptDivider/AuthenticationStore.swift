import AuthenticationServices
import Foundation
import Observation
import Supabase

enum AppAuthenticationState: Equatable {
    case loading
    case signedOut
    case authenticated
    case configurationMissing
}

@MainActor
@Observable final class AuthenticationStore {
    private(set) var state: AppAuthenticationState = .loading
    private(set) var email: String?
    private(set) var isWorking = false
    var errorMessage: String?

    private let client: SupabaseClient?
    private var isObserving = false

    init(bundle: Bundle = .main) {
        client = SupabaseConfiguration.client(from: bundle)
        if client == nil { state = .configurationMissing }
    }

    func observeSession() async {
        guard !isObserving, let client else { return }
        isObserving = true
        for await (_, session) in client.auth.authStateChanges {
            email = session?.user.email
            state = session == nil ? .signedOut : .authenticated
            isWorking = false
        }
    }

    @discardableResult
    func sendEmailCode(to address: String, createAccount: Bool) async -> Bool {
        guard let client else { return false }
        let normalizedEmail = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(normalizedEmail) else {
            errorMessage = "Enter a valid email address."
            return false
        }

        return await perform {
            try await client.auth.signInWithOTP(
                email: normalizedEmail,
                shouldCreateUser: createAccount
            )
        }
    }

    @discardableResult
    func verifyEmailCode(_ code: String, email address: String) async -> Bool {
        guard let client else { return false }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            errorMessage = "Enter the six-digit code from your email."
            return false
        }

        return await perform {
            _ = try await client.auth.verifyOTP(
                email: address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                token: digits,
                type: .email
            )
        }
    }

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async {
        guard let client else { return }
        await perform {
            _ = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: rawNonce
                )
            )

            if let fullName {
                let formattedName = PersonNameComponentsFormatter().string(from: fullName)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !formattedName.isEmpty {
                    _ = try? await client.auth.update(
                        user: UserAttributes(data: ["full_name": .string(formattedName)])
                    )
                }
            }
        }
    }

    func signOut() async {
        guard let client else { return }
        await perform { try await client.auth.signOut() }
    }

    func show(error: Error) {
        let authorizationError = error as NSError
        if authorizationError.domain == ASAuthorizationError.errorDomain,
           authorizationError.code == ASAuthorizationError.canceled.rawValue { return }
        errorMessage = "Sign in could not be completed. Please try again."
    }

    func clearError() { errorMessage = nil }

    @discardableResult
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        do {
            try await operation()
            isWorking = false
            return true
        } catch {
            isWorking = false
            errorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[0].count > 0 && pieces[1].contains(".")
    }

    private static func friendlyMessage(for error: Error) -> String {
        let description = error.localizedDescription.lowercased()
        if description.contains("rate") || description.contains("too many") {
            return "Too many attempts. Wait a moment before requesting another code."
        }
        if description.contains("expired") {
            return "That code has expired. Request a new one and try again."
        }
        if description.contains("token") || description.contains("code") {
            return "That code is not valid. Check the email and try again."
        }
        if description.contains("user not found") || description.contains("signup") {
            return "No account was found for that email. Choose Create account to get started."
        }
        return "Authentication is unavailable right now. Please try again."
    }
}

private enum SupabaseConfiguration {
    static func client(from bundle: Bundle) -> SupabaseClient? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let key = bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
            !urlString.contains("YOUR_PROJECT"),
            !key.contains("YOUR_PUBLISHABLE_KEY"),
            let url = URL(string: urlString),
            !key.isEmpty
        else { return nil }

        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }
}
