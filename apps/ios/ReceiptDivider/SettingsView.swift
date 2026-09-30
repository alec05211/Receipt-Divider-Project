import SwiftUI

struct SettingsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showResetConfirmation = false
    @State private var showServerReset = false
    @AppStorage(ContributionSliderUnit.storageKey) private var sliderUnit: ContributionSliderUnit = .dollars

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { EditProfileView() } label: { profileHeader }
                    HStack {
                        if let email = authentication.email {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Signed in as").font(.caption).foregroundStyle(.secondary)
                                Text(email).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button("Sign out") { Task { await authentication.signOut() } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(authentication.isWorking)
                    }
                }
                Section {
                    NavigationLink { FriendsView() } label: {
                        LabeledContent { Text("\(store.friendCount)") } label: { Label("Friends", systemImage: "person.2") }
                    }
                    NavigationLink { PaymentsView() } label: { Label("Payments", systemImage: "arrow.left.arrow.right.circle") }
                }
                Section("App") {
                    LabeledContent("Currency", value: "USD")
                    Picker("Self reference", selection: Binding(
                        get: { store.selfReferenceMode },
                        set: { store.updateSelfReference($0) }
                    )) { ForEach(SelfReferenceMode.allCases) { Text($0.title).tag($0) } }
                }
                Section("Contribution sliders") {
                    Picker("Slider unit", selection: $sliderUnit) { ForEach(ContributionSliderUnit.allCases) { Text($0.title).tag($0) } }
                        .onChange(of: sliderUnit) { _, unit in
                            Task { if let token = try? await authentication.accessToken() { await store.updateSliderUnit(unit, accessToken: token) } }
                        }
                }
                Section("Data") { Button("Clear cached data", role: .destructive) { showResetConfirmation = true } }
                if store.isDeveloper {
                    Section("Developer") { Button("Delete all expenses and payments", role: .destructive) { showServerReset = true } }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear this device's cached ledger?", isPresented: $showResetConfirmation, titleVisibility: .visible) { Button("Clear cached data", role: .destructive) { store.resetLocalCache() } }
            .sheet(isPresented: $showServerReset) { ServerResetView() }
            .task {
                if let token = try? await authentication.accessToken() { try? await store.refreshFriends(accessToken: token) }
            }
        }
    }

    private var profileHeader: some View {
        let name = store.profile?.displayName
        return HStack(spacing: 14) {
            AvatarView(userID: authentication.userID, name: name, size: 60).id(store.avatarVersion)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? "Add your name").font(.title3.weight(.semibold))
                if let username = store.profile?.username { Text("@\(username)").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Wipes every account's expenses and payments on the server; the destructive button only enables once DELETE is typed.
private struct ServerResetView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Type DELETE to erase every account's expenses and payments")
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section {
                    Button(role: .destructive) { Task { await delete() } } label: {
                        if isDeleting { ProgressView() } else { Text("Delete everything") }
                    }
                    .disabled(confirmation != "DELETE" || isDeleting)
                }
            }
            .navigationTitle("Delete all data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isDeleting) } }
            .interactiveDismissDisabled(isDeleting)
        }
    }

    private func delete() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await store.resetServerLedger(accessToken: try await authentication.accessToken())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }
}
