import AuthenticationServices
import CryptoKit
import SwiftUI

struct AppRootView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ExpenseStore.self) private var store

    var body: some View {
        Group {
            switch authentication.state {
            case .loading:
                ProgressView("Restoring your session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                AuthenticationView()
            case .authenticated:
                if let userID = authentication.userID { ConnectedLedgerView(userID: userID) }
                else { ProgressView("Preparing your account…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            case .resettingPassword:
                NewPasswordView()
            case .configurationMissing:
                ContentUnavailableView(
                    "Connect Supabase",
                    systemImage: "key.horizontal",
                    description: Text("Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to project.yml, then regenerate the Xcode project.")
                )
            }
        }
        .animation(.snappy, value: authentication.state)
        .task { await authentication.observeSession() }
        .onChange(of: authentication.state) { _, state in if state == .signedOut { store.disconnect() } }
        .onOpenURL { url in Task { await authentication.handleIncomingURL(url) } }
    }
}

private struct ConnectedLedgerView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ExpenseStore.self) private var store
    let userID: UUID

    var body: some View {
        Group {
            if store.activeUserID == userID && store.hasLoadedRemoteData {
                AppTabView()
            } else if let message = store.syncError, !store.isSyncing {
                ContentUnavailableView {
                    Label("Couldn’t load your ledger", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await connect() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading your ledger…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: userID) { await connect() }
    }

    private func connect() async {
        do {
            await store.synchronize(
                userID: userID,
                identity: authentication.pendingIdentity,
                accessToken: try await authentication.accessToken()
            )
            if store.hasLoadedRemoteData { authentication.identityApplied() }
        } catch {
            store.syncError = error.localizedDescription
        }
    }
}

private enum AuthenticationMode: String, CaseIterable, Identifiable {
    case signIn = "Sign in"
    case createAccount = "Create account"
    var id: Self { self }
}

private enum AuthenticationStep { case credentials, resetSent }

struct AuthenticationView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: AuthenticationMode = .signIn
    @State private var step: AuthenticationStep = .credentials
    @State private var email = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var appleNonce = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    AuthenticationBrand()
                    if step == .credentials { credentialsEntry } else { resetSent }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarBackButtonHidden()
        }
        .onChange(of: mode) { _, _ in authentication.clearError() }
    }

    private var credentialsEntry: some View {
        VStack(spacing: 20) {
            Picker("Account action", selection: $mode) {
                ForEach(AuthenticationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                if mode == .createAccount {
                    TextField("First name", text: $firstName).textContentType(.givenName).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    TextField("Last name", text: $lastName).textContentType(.familyName).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                }
                Text("Email address").font(.headline)
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Password").font(.headline)
                    Spacer()
                    if mode == .signIn {
                        Button("Forgot password?", action: sendReset)
                            .font(.subheadline)
                            .disabled(authentication.isWorking)
                    }
                }
                SecureField(mode == .signIn ? "Password" : "At least \(AuthenticationStore.minimumPasswordLength) characters", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            errorMessage

            Button(action: submit) {
                Group {
                    if authentication.isWorking { ProgressView() }
                    else { Text(mode == .signIn ? "Sign in" : "Create account") }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authentication.isWorking || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

            HStack {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }

            SignInWithAppleButton(.continue, onRequest: prepareAppleRequest, onCompletion: finishAppleRequest)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(authentication.isWorking)
        }
        .onAppear { focusedField = .email }
    }

    private var resetSent: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Check your email").font(.title2.bold())
                Text("We sent a password reset link to **\(email.trimmingCharacters(in: .whitespacesAndNewlines))**. Open it on this iPhone to choose a new password.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if authentication.isWorking { ProgressView() }

            errorMessage

            HStack(spacing: 18) {
                Button("Back to sign in") {
                    step = .credentials
                    authentication.clearError()
                }
                Button("Send another link", action: sendReset)
                    .disabled(authentication.isWorking)
            }
            .font(.subheadline)
        }
    }

    private var errorMessage: some View { AuthenticationErrorMessage() }

    private func submit() {
        guard !authentication.isWorking else { return }
        Task {
            let identity = mode == .createAccount ? AccountIdentity(firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines), lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) : nil
            if mode == .createAccount && (identity!.firstName.isEmpty || identity!.lastName.isEmpty || identity!.username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil) {
                authentication.errorMessage = "Enter your real first and last name and a 3–24 character username."
                return
            }
            if mode == .signIn {
                await authentication.signIn(email: email, password: password)
            } else {
                await authentication.createAccount(email: email, password: password, identity: identity!)
            }
        }
    }

    private func sendReset() {
        Task {
            if await authentication.sendPasswordReset(to: email) {
                withAnimation { step = .resetSent }
            }
        }
    }

    private func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = UUID().uuidString
        appleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func finishAppleRequest(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                !appleNonce.isEmpty
            else {
                authentication.show(error: AuthenticationViewError.missingAppleCredential)
                return
            }
            Task {
                await authentication.signInWithApple(
                    idToken: idToken,
                    rawNonce: appleNonce,
                    fullName: credential.fullName
                )
            }
        case .failure(let error):
            authentication.show(error: error)
        }
    }
}

private enum AuthenticationViewError: Error { case missingAppleCredential }

private struct AuthenticationBrand: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "receipt.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Receipt Divider").font(.largeTitle.bold())
                Text("Shared costs, without the guesswork.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

private struct AuthenticationErrorMessage: View {
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        if let message = authentication.errorMessage {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { AccessibilityNotification.Announcement(message).post() }
                .onChange(of: message) { _, newMessage in
                    AccessibilityNotification.Announcement(newMessage).post()
                }
        }
    }
}

private struct NewPasswordView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    AuthenticationBrand()

                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text("Choose a new password").font(.title2.bold())
                            Text("Use at least \(AuthenticationStore.minimumPasswordLength) characters.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        SecureField("New password", text: $password)
                            .textContentType(.newPassword)
                            .focused($isFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .padding(14)
                            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        AuthenticationErrorMessage()

                        Button(action: save) {
                            Group {
                                if authentication.isWorking { ProgressView() }
                                else { Text("Save password") }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(authentication.isWorking || password.isEmpty)

                        Button("Cancel") { Task { await authentication.signOut() } }
                            .font(.subheadline)
                            .disabled(authentication.isWorking)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !authentication.isWorking else { return }
        Task { await authentication.updatePassword(password) }
    }
}
