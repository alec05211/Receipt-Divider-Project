import AuthenticationServices
import Foundation
import Observation
import Supabase

enum AppAuthenticationState: Equatable {
    case loading
    case signedOut
    case authenticated
    case resettingPassword
    case configurationMissing
}
struct AccountIdentity: Codable, Sendable, Equatable {
    let firstName: String; let lastName: String; let username: String
}

@MainActor
@Observable final class AuthenticationStore {
    private(set) var state: AppAuthenticationState = .loading
    private(set) var email: String?
    private(set) var userID: UUID?
    private(set) var isWorking = false
    var errorMessage: String?
    private(set) var pendingIdentity: AccountIdentity?

    private let client: SupabaseClient?
    private var isObserving = false
    private var isResettingPassword = false

    init(bundle: Bundle = .main) {
        client = SupabaseConfiguration.client(from: bundle)
        if client == nil { state = .configurationMissing }
    }

    func observeSession() async {
        guard !isObserving, let client else { return }
        isObserving = true
        for await (_, session) in client.auth.authStateChanges {
            email = session?.user.email
            userID = session?.user.id
            if session == nil { isResettingPassword = false }
            state = session == nil ? .signedOut : isResettingPassword ? .resettingPassword : .authenticated
            isWorking = false
        }
    }

    @discardableResult
    func signIn(email address: String, password: String) async -> Bool {
        guard let client, let email = validatedEmail(address) else { return false }
        guard !password.isEmpty else {
            errorMessage = "Enter your password."
            return false
        }
        return await perform { _ = try await client.auth.signIn(email: email, password: password) }
    }

    @discardableResult
    func createAccount(email address: String, password: String, identity: AccountIdentity) async -> Bool {
        guard let client, let email = validatedEmail(address), validateNewPassword(password) else { return false }
        pendingIdentity = identity
        return await perform {
            let response = try await client.auth.signUp(email: email, password: password)
            if response.session == nil { throw AuthenticationStoreError.confirmationRequired }
        }
    }

    @discardableResult
    func sendPasswordReset(to address: String) async -> Bool {
        guard let client, let email = validatedEmail(address) else { return false }
        return await perform {
            try await client.auth.resetPasswordForEmail(email, redirectTo: SupabaseConfiguration.passwordResetURL)
        }
    }

    /// Completes the password reset link from the email; the user then chooses a new password.
    func handleIncomingURL(_ url: URL) async {
        guard let client, url.scheme == SupabaseConfiguration.passwordResetURL.scheme else { return }
        isResettingPassword = true
        let succeeded = await perform { _ = try await client.auth.session(from: url) }
        if succeeded { state = .resettingPassword } else { isResettingPassword = false }
    }

    @discardableResult
    func updatePassword(_ password: String) async -> Bool {
        guard let client, validateNewPassword(password) else { return false }
        let succeeded = await perform { _ = try await client.auth.update(user: UserAttributes(password: password)) }
        if succeeded {
            isResettingPassword = false
            state = .authenticated
        }
        return succeeded
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

    func accessToken() async throws -> String {
        guard let client else { throw AuthenticationStoreError.configurationMissing }
        return try await client.auth.session.accessToken
    }

    func show(error: Error) {
        let authorizationError = error as NSError
        if authorizationError.domain == ASAuthorizationError.errorDomain,
           authorizationError.code == ASAuthorizationError.canceled.rawValue { return }
        errorMessage = "Sign in could not be completed. Please try again."
    }

    func clearError() { errorMessage = nil }
    func identityApplied() { pendingIdentity = nil }

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

    private func validatedEmail(_ address: String) -> String? {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(email) else {
            errorMessage = "Enter a valid email address."
            return nil
        }
        return email
    }

    private func validateNewPassword(_ password: String) -> Bool {
        guard password.count >= Self.minimumPasswordLength else {
            errorMessage = "Use at least \(Self.minimumPasswordLength) characters for your password."
            return false
        }
        return true
    }

    static let minimumPasswordLength = 8

    private static func looksLikeEmail(_ value: String) -> Bool {
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[0].count > 0 && pieces[1].contains(".")
    }

    private static func friendlyMessage(for error: Error) -> String {
        if case AuthenticationStoreError.confirmationRequired = error {
            return "Check your email to confirm your account, then sign in."
        }
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .invalidCredentials: return "That email and password don’t match. Try again or reset your password."
            case .userAlreadyExists, .emailExists: return "An account already exists for that email. Choose Sign in instead."
            case .weakPassword: return "Choose a stronger password."
            case .samePassword: return "Choose a password you haven’t used before."
            case .overRequestRateLimit, .overEmailSendRateLimit: return "Too many attempts. Wait a moment and try again."
            case .flowStateExpired, .otpExpired: return "That reset link has expired. Request a new one and try again."
            case .emailProviderDisabled: return "Email sign-in is turned off for this app. Use Sign in with Apple for now."
            default: break
            }
        }
        return "Authentication is unavailable right now. Please try again."
    }
}

private enum AuthenticationStoreError: Error { case configurationMissing, confirmationRequired }

private enum SupabaseConfiguration {
    /// Must be listed under Authentication → URL Configuration → Redirect URLs in Supabase.
    static let passwordResetURL = URL(string: "receiptdivider://reset-password")!

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
