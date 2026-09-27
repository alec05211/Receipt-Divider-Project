import SwiftUI

struct SettingsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @Binding var showResetConfirmation: Bool
    @AppStorage(ContributionSliderUnit.storageKey) private var sliderUnit: ContributionSliderUnit = .dollars

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
            Section {
                Picker("Slider unit", selection: $sliderUnit) { ForEach(ContributionSliderUnit.allCases) { Text($0.title).tag($0) } }
            } header: { Text("Contribution sliders") } footer: { Text("Sliders show each contribution in both dollars and percent of the total, with this unit on top and the other beneath it. They snap firmly to the equal share, lightly to every whole unit of this one, and faintly to the other.") }
            Section("Data") { Button("Clear cached data", role: .destructive) { showResetConfirmation = true } }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Clear this device's cached ledger?", isPresented: $showResetConfirmation, titleVisibility: .visible) { Button("Clear cached data", role: .destructive) { store.resetLocalCache() } }
    }
}
