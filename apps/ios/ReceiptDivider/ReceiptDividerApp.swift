import SwiftUI

@main
struct ReceiptDividerApp: App {
    @State private var store = ExpenseStore()
    @State private var authentication = AuthenticationStore()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(store)
                .environment(authentication)
        }
    }
}
