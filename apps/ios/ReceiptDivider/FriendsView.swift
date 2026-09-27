import SwiftUI

struct FriendsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var query = ""
    @State private var results: [APIUserResult] = []
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var busyIDs: Set<UUID> = []

    /// How often the open Friends screen checks for new requests and acceptances.
    private static let pollInterval: Duration = .seconds(5)
    /// Pause after typing stops before searching, so each keystroke doesn't send a request.
    private static let searchDelay: Duration = .milliseconds(300)

    private var accepted: [APIFriend] { store.friends.filter { $0.status == "accepted" } }
    private var incoming: [APIFriend] { store.friends.filter { $0.status == "pending" && $0.direction == "incoming" } }
    private var outgoing: [APIFriend] { store.friends.filter { $0.status == "pending" && $0.direction == "outgoing" } }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearchActive: Bool { trimmedQuery.count >= 2 }

    var body: some View {
        List {
            if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
            if isSearchActive { searchResults } else { friendSections }
        }
        .navigationTitle("Friends")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name or username")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable { await reload() }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        .task(id: trimmedQuery) { await search() }
    }

    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            if hasSearched { ContentUnavailableView.search(text: trimmedQuery) }
        } else {
            Section("People") {
                ForEach(results) { user in
                    personRow(userID: user.userId, name: user.displayName, username: user.username, hasAvatar: user.hasAvatar) { resultAction(user) }
                }
            }
        }
    }

    @ViewBuilder private var friendSections: some View {
        if !incoming.isEmpty {
            Section("Requests") {
                ForEach(incoming) { friend in
                    personRow(userID: friend.userId, name: friend.displayName, username: friend.username) { acceptButton(friend.requestId) }
                }
            }
        }
        Section("Friends") {
            if accepted.isEmpty {
                ContentUnavailableView("No friends yet", systemImage: "person.2", description: Text("Search for someone by name or username to invite them."))
            } else {
                ForEach(accepted) { friend in personRow(userID: friend.userId, name: friend.displayName, username: friend.username) { EmptyView() } }
            }
        }
        if !outgoing.isEmpty {
            Section("Sent") {
                ForEach(outgoing) { friend in
                    personRow(userID: friend.userId, name: friend.displayName, username: friend.username) { pendingLabel }
                }
            }
        }
    }

    private func personRow(userID: UUID, name: String, username: String, hasAvatar: Bool = true, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            AvatarView(userID: userID, name: name, hasAvatar: hasAvatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("@\(username)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }

    @ViewBuilder private func resultAction(_ user: APIUserResult) -> some View {
        if busyIDs.contains(user.userId) {
            ProgressView()
        } else {
            switch user.relationship {
            case "friend": Label("Friends", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            case "outgoing": pendingLabel
            case "incoming": if let requestID = user.requestId { acceptButton(requestID, userID: user.userId) }
            default: Button("Invite") { invite(user) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    private var pendingLabel: some View { Text("Pending").font(.caption).foregroundStyle(.secondary) }

    @ViewBuilder private func acceptButton(_ requestID: UUID, userID: UUID? = nil) -> some View {
        if busyIDs.contains(requestID) { ProgressView() }
        else { Button("Accept") { accept(requestID, userID: userID) }.buttonStyle(.borderedProminent).controlSize(.small) }
    }

    private func search() async {
        guard isSearchActive else { results = []; hasSearched = false; return }
        try? await Task.sleep(for: Self.searchDelay)
        guard !Task.isCancelled, let token = try? await authentication.accessToken() else { return }
        do {
            let found = try await store.searchUsers(trimmedQuery, accessToken: token)
            guard !Task.isCancelled else { return }
            results = found
            hasSearched = true
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func invite(_ user: APIUserResult) {
        guard busyIDs.insert(user.userId).inserted else { return }
        errorMessage = nil
        Task {
            do {
                try await store.requestFriend(username: user.username, accessToken: try await authentication.accessToken())
                setRelationship("outgoing", for: user.userId)
            } catch {
                errorMessage = error.localizedDescription
            }
            busyIDs.remove(user.userId)
        }
    }

    private func accept(_ requestID: UUID, userID: UUID?) {
        guard busyIDs.insert(requestID).inserted else { return }
        errorMessage = nil
        Task {
            do {
                try await store.acceptFriend(requestID, accessToken: try await authentication.accessToken())
                if let userID { setRelationship("friend", for: userID) }
            } catch {
                errorMessage = error.localizedDescription
            }
            busyIDs.remove(requestID)
        }
    }

    private func setRelationship(_ relationship: String, for userID: UUID) {
        if let index = results.firstIndex(where: { $0.userId == userID }) { results[index].relationship = relationship }
    }

    private func reload() async {
        guard let token = try? await authentication.accessToken() else { return }
        try? await store.refreshFriends(accessToken: token)
    }
}
