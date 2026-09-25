import SwiftUI

@main
struct ReceiptDividerApp: App {
    @State private var store = ExpenseStore()

    var body: some Scene {
        WindowGroup {
            AppTabView().environment(store)
        }
    }
}
