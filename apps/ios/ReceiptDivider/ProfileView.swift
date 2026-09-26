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
                Section("Your balance") { LabeledContent("Current balance", value: store.alexBalance.usd); NavigationLink { SettleUpView() } label: { Label("Record a payment", systemImage: "arrow.left.arrow.right") } }
                Section("People") {
                    ForEach(Person.allCases) { person in Label(person.rawValue, systemImage: "person.circle") }
                    Button("Manage people", systemImage: "person.2") {}
                }
            }
            .navigationTitle("Profile")
        }
    }
}
