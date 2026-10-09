import SwiftUI
import UIKit

@main
struct ReceiptDividerApp: App {
    @State private var store = ExpenseStore()
    @State private var authentication = AuthenticationStore()

    init() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(store)
                .environment(authentication)
                .scrollIndicators(.hidden)
        }
    }
}
