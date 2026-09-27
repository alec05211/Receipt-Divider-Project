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
        .keyboardDoneButton($isFocused)
    }
}

/// Edits an amount in cents as a percent of `total`, to up to two decimal places. The typed text is kept while editing so
/// partial entries like "12." aren't reformatted; it reflects `cents` again once editing ends or the value moves elsewhere.
struct PercentField: View {
    @Binding var cents: Int
    let total: Int
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .focused($isFocused)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .onChange(of: text) { _, text in
                    guard isFocused else { return }
                    let value = Double(text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0
                    cents = max(0, Int((value * Double(total) / 100).rounded()))
                }
            Text("%").foregroundStyle(.secondary)
        }
        .onAppear { text = formatted }
        .onChange(of: cents) { if !isFocused { text = formatted } }
        .onChange(of: total) { if !isFocused { text = formatted } }
        .onChange(of: isFocused) { if !isFocused { text = formatted } }
        .keyboardDoneButton($isFocused)
    }

    private var formatted: String {
        (total > 0 ? Double(cents) * 100 / Double(total) : 0).formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

private extension View {
    func keyboardDoneButton(_ isFocused: FocusState<Bool>.Binding) -> some View {
        toolbar {
            if isFocused.wrappedValue {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused.wrappedValue = false }.fontWeight(.semibold)
                }
            }
        }
    }
}
