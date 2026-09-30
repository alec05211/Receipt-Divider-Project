import PhotosUI
import SwiftUI
import UIKit

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
    @State private var pendingPhoto: UIImage?
    @State private var showPhotoCrop = false
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
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            } footer: { Text("3–24 lowercase letters, numbers, or underscores.") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .onChange(of: photoItem) { _, item in if let item { uploadPhoto(item) } }
        .sheet(isPresented: $showPhotoCrop, onDismiss: { pendingPhoto = nil; photoItem = nil }) {
            if let pendingPhoto { AvatarCropView(image: pendingPhoto) { uploadPhoto($0) } }
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

    private func uploadPhoto(_ item: PhotosPickerItem) {
        isUploadingPhoto = true
        errorMessage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw LedgerAPIClientError.invalidResponse
                }
                pendingPhoto = image
                showPhotoCrop = true
            } catch {
                errorMessage = "Couldn’t open your photo. \(error.localizedDescription)"
                photoItem = nil
            }
            isUploadingPhoto = false
        }
    }

    private func uploadPhoto(_ image: UIImage) {
        guard let userID = authentication.userID else { return }
        isUploadingPhoto = true
        errorMessage = nil
        Task {
            do {
                try await store.uploadAvatar(image, userID: userID, accessToken: try await authentication.accessToken())
            } catch {
                errorMessage = "Couldn’t update your photo. \(error.localizedDescription)"
            }
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

/// Avatar cropper. The image always covers the circular preview; dragging repositions it and pinching zooms further in.
private struct AvatarCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let use: (UIImage) -> Void
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(1, min(proxy.size.width - 32, proxy.size.height - 80))
                let baseScale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                let displayed = CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom)
                VStack {
                    Spacer(minLength: 0)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: displayed.width, height: displayed.height)
                        .offset(offset)
                        .frame(width: side, height: side)
                        .clipped()
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .gesture(dragGesture(side: side, displayed: displayed))
                        .simultaneousGesture(zoomGesture(side: side, baseScale: baseScale))
                        .overlay { Circle().stroke(.primary.opacity(0.8), lineWidth: 1) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use Photo") {
                            let cropped = renderedCrop(side: side, baseScale: baseScale)
                            dismiss()
                            use(cropped)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func dragGesture(side: CGFloat, displayed: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in offset = clamped(settledOffset + value.translation, side: side, displayed: displayed) }
            .onEnded { _ in settledOffset = offset }
    }

    private func zoomGesture(side: CGFloat, baseScale: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(settledZoom * value, 1), 5)
                let displayed = CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom)
                offset = clamped(offset, side: side, displayed: displayed)
            }
            .onEnded { _ in settledZoom = zoom; settledOffset = offset }
    }

    private func clamped(_ proposed: CGSize, side: CGFloat, displayed: CGSize) -> CGSize {
        let limitX = max(0, (displayed.width - side) / 2)
        let limitY = max(0, (displayed.height - side) / 2)
        return CGSize(width: min(max(proposed.width, -limitX), limitX), height: min(max(proposed.height, -limitY), limitY))
    }

    /// Draws the transformed viewport directly at upload resolution, preserving UIImage orientation correctly.
    private func renderedCrop(side: CGFloat, baseScale: CGFloat) -> UIImage {
        let output: CGFloat = 512
        let factor = output / side
        let displayed = CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom)
        let origin = CGPoint(x: (side - displayed.width) / 2 + offset.width, y: (side - displayed.height) / 2 + offset.height)
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output)).image { _ in
            image.draw(in: CGRect(x: origin.x * factor, y: origin.y * factor, width: displayed.width * factor, height: displayed.height * factor))
        }
    }
}

private func + (left: CGSize, right: CGSize) -> CGSize { CGSize(width: left.width + right.width, height: left.height + right.height) }
