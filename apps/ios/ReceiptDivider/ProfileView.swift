import SwiftUI

struct ProfileView: View {
    @Environment(ExpenseStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Text("A").font(.title3.weight(.bold)).foregroundStyle(.white).frame(width: 52, height: 52).background(.gray, in: Circle())
                        VStack(alignment: .leading) { Text("Alex").font(.headline); Text("Your personal profile").font(.subheadline).foregroundStyle(.secondary) }
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
