import SwiftUI

struct SettingsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showResetConfirmation = false
    @AppStorage(ContributionSliderUnit.storageKey) private var sliderUnit: ContributionSliderUnit = .dollars

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { EditProfileView() } label: { profileHeader }
                    if let email = authentication.email { LabeledContent("Signed in as", value: email) }
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await authentication.signOut() }
                    }
                    .disabled(authentication.isWorking)
                }
                Section {
                    NavigationLink { FriendsView() } label: {
                        LabeledContent { Text("\(store.friendCount)") } label: { Label("Friends", systemImage: "person.2") }
                    }
                    NavigationLink { PaymentsView() } label: { Label("Payments", systemImage: "arrow.left.arrow.right.circle") }
                }
                Section("App") { LabeledContent("Currency", value: "USD"); LabeledContent("Ledger", value: "Supabase"); LabeledContent("Receipt storage", value: "Supabase database") }
                Section {
                    Picker("Slider unit", selection: $sliderUnit) { ForEach(ContributionSliderUnit.allCases) { Text($0.title).tag($0) } }
                } header: { Text("Contribution sliders") } footer: { Text("Sliders tick at every whole dollar or whole percent of the total as you drag.") }
                Section("Data") { Button("Clear cached data", role: .destructive) { showResetConfirmation = true } }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear this device's cached ledger?", isPresented: $showResetConfirmation, titleVisibility: .visible) { Button("Clear cached data", role: .destructive) { store.resetLocalCache() } }
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
