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
                displayName: authentication.pendingIdentity?.displayName ?? authentication.defaultDisplayName,
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

private enum AuthenticationStep { case email, code }

struct AuthenticationView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: AuthenticationMode = .signIn
    @State private var step: AuthenticationStep = .email
    @State private var email = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""
    @State private var code = ""
    @State private var appleNonce = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, code }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    brand
                    if step == .email { emailEntry } else { codeEntry }
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

    private var brand: some View {
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

    private var emailEntry: some View {
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
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.continue)
                    .onSubmit(sendCode)
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            errorMessage

            Button(action: sendCode) {
                Group {
                    if authentication.isWorking { ProgressView() }
                    else { Text(mode == .signIn ? "Email me a sign-in code" : "Create account with email") }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authentication.isWorking || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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

            Text("Email codes can sign you in or create a private Receipt Divider account—no password required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { focusedField = .email }
    }

    private var codeEntry: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Check your email").font(.title2.bold())
                Text("Enter the six-digit code sent to **\(email.trimmingCharacters(in: .whitespacesAndNewlines))**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("000000", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit().weight(.semibold))
                .focused($focusedField, equals: .code)
                .onChange(of: code) { _, value in
                    code = String(value.filter(\.isNumber).prefix(6))
                    if code.count == 6 { verifyCode() }
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            errorMessage

            Button(action: verifyCode) {
                Group {
                    if authentication.isWorking { ProgressView() }
                    else { Text("Continue") }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authentication.isWorking || code.count != 6)

            HStack(spacing: 18) {
                Button("Use a different email") {
                    code = ""
                    step = .email
                    authentication.clearError()
                }
                Button("Send another code", action: sendCode)
                    .disabled(authentication.isWorking)
            }
            .font(.subheadline)
        }
        .onAppear { focusedField = .code }
    }

    @ViewBuilder private var errorMessage: some View {
        if let message = authentication.errorMessage {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLiveRegion(.assertive)
        }
    }

    private func sendCode() {
        Task {
            let identity = mode == .createAccount ? AccountIdentity(firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines), lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) : nil
            if mode == .createAccount && (identity!.firstName.isEmpty || identity!.lastName.isEmpty || identity!.username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil) {
                authentication.errorMessage = "Enter your real first and last name and a 3–24 character username."
                return
            }
            if await authentication.sendEmailCode(to: email, createAccount: mode == .createAccount, identity: identity) {
                withAnimation { step = .code }
            }
        }
    }

    private func verifyCode() {
        guard !authentication.isWorking else { return }
        Task { await authentication.verifyEmailCode(code, email: email) }
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
