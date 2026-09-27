import SwiftUI

struct ProfileView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { EditProfileView() } label: { profileHeader }
                }
                Section { friendsButton.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("Your balance") { LabeledContent("Current balance", value: store.alexBalance.usd); NavigationLink { SettleUpView() } label: { Label("Record a payment", systemImage: "arrow.left.arrow.right") } }
            }
            .navigationTitle("Profile")
        }
    }

    private var profileHeader: some View {
        let name = store.profile?.displayName
        return HStack(spacing: 14) {
            Text(name.map { String($0.prefix(1)) } ?? "?").font(.title3.weight(.bold)).foregroundStyle(.white).frame(width: 52, height: 52).background(.gray, in: Circle())
            VStack(alignment: .leading) {
                Text(name ?? "Add your name").font(.headline)
                if let username = store.profile?.username { Text("@\(username)").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var friendsButton: some View {
        if #available(iOS 26.0, *) {
            friendsLink.buttonStyle(.glass)
        } else {
            friendsLink.buttonStyle(.bordered)
        }
    }

    private var friendsLink: some View {
        NavigationLink { FriendsView() } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill").font(.title3).frame(width: 38, height: 38)
                Text("Friends").font(.headline)
                Spacer()
                Text("\(store.friendCount)").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.tint)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Friends, \(store.friendCount)")
    }
}

struct EditProfileView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var identity: AccountIdentity {
        AccountIdentity(
            firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
            lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
    private var isValid: Bool {
        !identity.firstName.isEmpty && !identity.lastName.isEmpty
            && identity.username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("First name", text: $firstName).textContentType(.givenName)
                TextField("Last name", text: $lastName).textContentType(.familyName)
            } footer: { Text("Friends see your first and last name.") }
            Section {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("3–24 lowercase letters, numbers, or underscores. Friends find you by username.") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving { ProgressView() } else { Button("Save", action: save).disabled(!isValid) }
            }
        }
        .onAppear {
            firstName = store.profile?.firstName ?? ""
            lastName = store.profile?.lastName ?? ""
            username = store.profile?.username ?? ""
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.updateProfile(identity, accessToken: try await authentication.accessToken())
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
