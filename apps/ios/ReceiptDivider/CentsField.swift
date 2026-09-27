import SwiftUI
import Foundation

struct CentsField: View {
    let title: String
    @Binding var cents: Int
    @FocusState private var isFocused: Bool

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
            .focused($isFocused)
            .multilineTextAlignment(.trailing)
            .fixedSize()
        }
        .toolbar {
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }.fontWeight(.semibold)
                }
            }
        }
    }
}
