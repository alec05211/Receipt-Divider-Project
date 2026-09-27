import SwiftUI

/// A user's profile picture, falling back to their initial while loading or when they haven't set one.
struct AvatarView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let userID: UUID?
    let name: String?
    var size: CGFloat = 38
    /// The photo's etag from search or the friends list: nil means no photo, and a new value refetches it.
    private var etag: String?
    private var knowsEtag = false
    @State private var image: UIImage?

    /// Shows whatever photo the user has (used for the signed-in user's own picture).
    init(userID: UUID?, name: String?, size: CGFloat = 38) {
        self.userID = userID
        self.name = name
        self.size = size
    }

    /// Shows the photo version the server last reported, reloading when it changes.
    init(userID: UUID, name: String, etag: String?, size: CGFloat = 38) {
        self.init(userID: userID, name: name, size: size)
        self.etag = etag
        knowsEtag = true
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(name.flatMap(\.first).map(String.init) ?? "?")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.gray)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: "\(userID?.uuidString ?? "")|\(etag ?? "")") {
            guard let userID else { return }
            if knowsEtag && etag == nil { image = nil; return }
            guard let token = try? await authentication.accessToken() else { return }
            image = await store.avatar(for: userID, etag: etag, accessToken: token)
        }
    }

}
