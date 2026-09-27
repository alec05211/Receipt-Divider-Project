import SwiftUI

enum AppTab: Hashable { case transactions, add, settings }

struct AppTabView: View {
    @State private var selection: AppTab = .transactions

    var body: some View {
        TabView(selection: $selection) {
            ActivityView().tabItem { Label("Summary", systemImage: "clock") }.tag(AppTab.transactions)
            ReceiptCaptureView(finish: { selection = .transactions })
                .tabItem { Label("Add expense", systemImage: "plus.circle.fill") }.tag(AppTab.add)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        // Standard TabView deliberately owns its appearance. Current iOS applies
        // the system Liquid Glass treatment when available.
        .tint(.primary)
    }
}
