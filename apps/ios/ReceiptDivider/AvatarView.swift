import SwiftUI

/// A user's profile picture, falling back to their initial while loading or when they haven't set one.
struct AvatarView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    let userID: UUID?
    let name: String?
    var size: CGFloat = 38
    var hasAvatar = true
    @State private var image: UIImage?

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
        .task(id: userID) {
            guard let userID, hasAvatar, let token = try? await authentication.accessToken() else { return }
            image = await store.avatar(for: userID, accessToken: token)
        }
    }

}
