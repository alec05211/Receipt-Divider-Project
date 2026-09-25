import SwiftUI

enum AppTab: Hashable { case transactions, add, profile }

struct AppTabView: View {
    @State private var selection: AppTab = .transactions
    @State private var captureRequest = 0

    var body: some View {
        TabView(selection: $selection) {
            ActivityView().tabItem { Label("Transactions", systemImage: "clock") }.tag(AppTab.transactions)
            ReceiptCaptureView(captureRequest: $captureRequest, finish: { selection = .transactions })
                .tabItem { Label("Add expense", systemImage: "plus.circle.fill") }.tag(AppTab.add)
            ProfileView().tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(AppTab.profile)
        }
        .onChange(of: selection) { _, tab in if tab == .add { captureRequest += 1 } }
        // Standard TabView deliberately owns its appearance. Current iOS applies
        // the system Liquid Glass treatment when available.
        .tint(.primary)
    }
}
