import SwiftUI
import Foundation

struct CentsField: View {
    let title: String
    @Binding var cents: Int

    var body: some View {
        TextField(title, text: Binding(
            get: { String(format: "%.2f", Double(cents) / 100) },
            set: { cents = max(0, Int((Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100)) }
        ))
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
    }
}
