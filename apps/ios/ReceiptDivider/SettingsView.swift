import SwiftUI

struct SettingsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @Binding var showResetConfirmation: Bool

    var body: some View {
        List {
            Section("Account") {
                if let email = authentication.email { LabeledContent("Signed in as", value: email) }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await authentication.signOut() }
                }
                .disabled(authentication.isWorking)
            }
            Section("App") { LabeledContent("Currency", value: "USD"); LabeledContent("Receipt storage", value: "On this device") }
            Section("Data") { Button("Reset local data", role: .destructive) { showResetConfirmation = true } }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset this device's local ledger?", isPresented: $showResetConfirmation, titleVisibility: .visible) { Button("Reset local data", role: .destructive) { store.reset() } }
    }
}
