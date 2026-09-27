import PhotosUI
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
                Section("Your balance") { LabeledContent("Overall", value: store.netBalance == 0 ? "Settled up" : store.netBalance > 0 ? "You’re owed \(store.netBalance.usd)" : "You owe \((-store.netBalance).usd)") }
            }
            .navigationTitle("Profile")
            .task {
                if let token = try? await authentication.accessToken() { try? await store.refreshFriends(accessToken: token) }
            }
        }
    }

    private var profileHeader: some View {
        let name = store.profile?.displayName
        return HStack(spacing: 14) {
            AvatarView(userID: authentication.userID, name: name, size: 52).id(store.avatarVersion)
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
    @State private var photoItem: PhotosPickerItem?
    @State private var isUploadingPhoto = false

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
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        AvatarView(userID: authentication.userID, name: store.profile?.displayName, size: 88).id(store.avatarVersion)
                        PhotosPicker(isUploadingPhoto ? "Uploading…" : "Choose photo", selection: $photoItem, matching: .images)
                            .disabled(isUploadingPhoto)
                    }
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
            Section {
                TextField("First name", text: $firstName).textContentType(.givenName).submitLabel(.done)
                TextField("Last name", text: $lastName).textContentType(.familyName).submitLabel(.done)
            } footer: { Text("Friends see your first and last name.") }
            Section {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            } footer: { Text("3–24 lowercase letters, numbers, or underscores. Friends find you by username.") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .onChange(of: photoItem) { _, item in if let item { uploadPhoto(item) } }
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

    private func uploadPhoto(_ item: PhotosPickerItem) {
        guard let userID = authentication.userID else { return }
        isUploadingPhoto = true
        errorMessage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw LedgerAPIClientError.invalidResponse
                }
                try await store.uploadAvatar(image, userID: userID, accessToken: try await authentication.accessToken())
            } catch {
                errorMessage = "Couldn’t update your photo. \(error.localizedDescription)"
            }
            photoItem = nil
            isUploadingPhoto = false
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
