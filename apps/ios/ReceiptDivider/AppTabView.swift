import SwiftUI

enum AppTab: Hashable { case transactions, add, settings }

struct AppTabView: View {
    @State private var selection: AppTab = .transactions
    @State private var openScannerTrigger = 0

    private var tabBinding: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { newTab in
                if newTab == selection {
                    if newTab == .add {
                        openScannerTrigger += 1
                    }
                } else {
                    selection = newTab
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabBinding) {
            ActivityView().tabItem { Label("Summary", systemImage: "clock") }.tag(AppTab.transactions)
            ReceiptCaptureView(finish: { selection = .transactions }, openScannerTrigger: openScannerTrigger)
                .tabItem { Label("Add expense", systemImage: "plus.circle.fill") }.tag(AppTab.add)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        // Standard TabView deliberately owns its appearance. Current iOS applies
        // the system Liquid Glass treatment when available.
        .tint(.primary)
    }
}
