import SwiftUI
import Foundation

struct CentsField: View {
    let title: String
    @Binding var cents: Int

    var body: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            Text("$").foregroundStyle(.secondary)
            TextField(title, text: Binding(
                get: { String(format: "%.2f", Double(cents) / 100) },
                set: { text in
                    let value = Double(text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0
                    cents = max(0, Int((value * 100).rounded()))
                }
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .fixedSize()
        }
    }
}
