import SwiftUI

struct FriendsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var inviteUsername = ""
    @State private var isInviting = false
    @State private var errorMessage: String?

    private var accepted: [APIFriend] { store.friends.filter { $0.status == "accepted" } }
    private var incoming: [APIFriend] { store.friends.filter { $0.status == "pending" && $0.direction == "incoming" } }
    private var outgoing: [APIFriend] { store.friends.filter { $0.status == "pending" && $0.direction == "outgoing" } }

    var body: some View {
        List {
            Section("Invite a friend") {
                HStack {
                    TextField("username", text: $inviteUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(isInviting ? "Sending…" : "Invite", action: invite).disabled(isInviting || inviteUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Search uses an exact username. Email addresses stay private.").font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            if !incoming.isEmpty { Section("Requests") { ForEach(incoming) { friend in friendRow(friend, action: { accept(friend) }) } } }
            Section("Friends") {
                if accepted.isEmpty { ContentUnavailableView("No friends yet", systemImage: "person.2", description: Text("Invite someone by username to split expenses together.")) }
                else { ForEach(accepted) { friend in friendRow(friend) } }
            }
            if !outgoing.isEmpty { Section("Sent") { ForEach(outgoing) { friend in friendRow(friend) } } }
        }
        .navigationTitle("Friends")
        .refreshable { if let token = try? await authentication.accessToken() { try? await store.refreshFriends(accessToken: token) } }
    }

    private func friendRow(_ friend: APIFriend, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Text(String(friend.displayName.prefix(1))).font(.headline).foregroundStyle(.white).frame(width: 38, height: 38).background(.gray, in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(friend.displayName).font(.headline); Text("@\(friend.username)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let action { Button("Accept", action: action).buttonStyle(.borderedProminent) }
            else if friend.status == "pending" { Text("Pending").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func invite() { isInviting = true; errorMessage = nil; Task { do { let token = try await authentication.accessToken(); try await store.requestFriend(username: inviteUsername, accessToken: token); inviteUsername = "" } catch { errorMessage = error.localizedDescription }; isInviting = false } }
    private func accept(_ friend: APIFriend) { Task { do { let token = try await authentication.accessToken(); try await store.acceptFriend(friend.requestId, accessToken: token) } catch { errorMessage = error.localizedDescription } } }
}
