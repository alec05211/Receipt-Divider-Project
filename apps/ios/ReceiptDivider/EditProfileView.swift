import PhotosUI
import SwiftUI

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
            }
            Section {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            } footer: { Text("3–24 lowercase letters, numbers, or underscores.") }
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
