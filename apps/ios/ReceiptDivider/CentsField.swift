import SwiftUI
import Foundation

struct CentsField: View {
    let title: String
    @Binding var cents: Int
    var isFocusedBinding: Binding<Bool>? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    @State private var text = ""
    @FocusState private var isFocused: Bool
    init(title: String, cents: Binding<Int>) {
        self.title = title
        self._cents = cents
        self.isFocusedBinding = nil
        self.onFocusChange = nil
    }

    init(
        title: String,
        cents: Binding<Int>,
        isFocusedBinding: Binding<Bool>?,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.title = title
        self._cents = cents
        self.isFocusedBinding = isFocusedBinding
        self.onFocusChange = onFocusChange
    }

    @Environment(\.fontWeight) private var envFontWeight

    var body: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                Text("$").foregroundStyle(.secondary)
                    .fontWeight(envFontWeight)
                TextField(title, text: $text)
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .autocorrectionDisabled()
                    .fontWeight(envFontWeight)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }
        }
        .onAppear { text = formatted }
        .onChange(of: cents) { _, _ in
            if !isFocused { text = formatted }
        }
        .onChange(of: isFocused) { _, focused in
            if isFocusedBinding?.wrappedValue != focused {
                isFocusedBinding?.wrappedValue = focused
            }
            onFocusChange?(focused)
            if focused {
                if cents == 0 {
                    text = ""
                }
            } else {
                text = formatted
            }
        }
        .onChange(of: isFocusedBinding?.wrappedValue) { _, externalFocused in
            if let externalFocused, isFocused != externalFocused {
                isFocused = externalFocused
            }
        }
        .onChange(of: text) { _, newText in
            guard isFocused else { return }
            let cleaned = newText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty {
                cents = 0
            } else if let value = Double(cleaned) {
                cents = max(0, Int((value * 100).rounded()))
            }
        }
        .keyboardDoneButton($isFocused)
    }

    private var formatted: String {
        String(format: "%.2f", Double(cents) / 100)
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

/// Edits a rate such as 0.06 as a percent ("6"), to up to three decimal places. Like `PercentField`, the typed text is
/// kept while editing.
struct RateField: View {
    @Binding var rate: Double
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
                    rate = max(0, Double(text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0) / 100
                }
            Text("%").foregroundStyle(.secondary)
        }
        .onAppear { text = Self.format(rate) }
        .onChange(of: rate) { if !isFocused { text = Self.format(rate) } }
        .onChange(of: isFocused) { if !isFocused { text = Self.format(rate) } }
        .keyboardDoneButton($isFocused)
    }

    /// A rate worked out from printed amounts is rarely exact, such as 8.001% for an 8% tax, so one within a
    /// two-hundredth of a percent of a whole number shows as that number.
    static func format(_ rate: Double) -> String {
        let percent = rate * 100, whole = percent.rounded()
        return (abs(percent - whole) < 0.005 ? whole : percent).formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
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
