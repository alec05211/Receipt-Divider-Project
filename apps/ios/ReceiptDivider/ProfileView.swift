import SwiftUI

struct ProfileView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Text(String(authentication.defaultDisplayName.prefix(1))).font(.title3.weight(.bold)).foregroundStyle(.white).frame(width: 52, height: 52).background(.gray, in: Circle())
                        VStack(alignment: .leading) { Text(authentication.defaultDisplayName).font(.headline); Text("Your Supabase profile").font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                Section { friendsButton.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("Your balance") { LabeledContent("Current balance", value: store.alexBalance.usd); NavigationLink { SettleUpView() } label: { Label("Record a payment", systemImage: "arrow.left.arrow.right") } }
            }
            .navigationTitle("Profile")
        }
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
