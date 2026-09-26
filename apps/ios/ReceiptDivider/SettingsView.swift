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
            Section("App") { LabeledContent("Currency", value: "USD"); LabeledContent("Ledger", value: "Supabase"); LabeledContent("Receipt storage", value: "Supabase database") }
            Section("Data") { Button("Clear cached data", role: .destructive) { showResetConfirmation = true } }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Clear this device's cached ledger?", isPresented: $showResetConfirmation, titleVisibility: .visible) { Button("Clear cache", role: .destructive) { store.resetLocalCache() } }
    }
}
