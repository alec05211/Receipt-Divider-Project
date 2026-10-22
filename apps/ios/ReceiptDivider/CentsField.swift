import SwiftUI
import Foundation

/// Edits a dollar amount as typed on the decimal pad: an empty field shows $0.00, and typing starts in the dollars
/// place, so "5" reads $5 and "45.24" reads $45.24. Focusing a field that holds an amount puts the cursor at the end, and
/// the text can be edited anywhere like any text field. Once editing ends the amount shows with two decimals.
struct CentsField: View {
    let title: String
    @Binding var cents: Int
    var isFocusedBinding: Binding<Bool>?
    var onFocusChange: ((Bool) -> Void)?
    var fontWeight: Font.Weight?
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    init(
        title: String,
        cents: Binding<Int>,
        isFocusedBinding: Binding<Bool>? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        fontWeight: Font.Weight? = nil
    ) {
        self.title = title
        self._cents = cents
        self.isFocusedBinding = isFocusedBinding
        self.onFocusChange = onFocusChange
        self.fontWeight = fontWeight
    }

    func fontWeight(_ weight: Font.Weight?) -> CentsField {
        var copy = self
        copy.fontWeight = weight
        return copy
    }

    var body: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                Text("$").foregroundStyle(.secondary)
                    .fontWeight(fontWeight)
                TextField(title, text: $text, selection: $selection)
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .autocorrectionDisabled()
                    .fontWeight(fontWeight)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }
        }
        .onAppear { text = CentsEntry.format(cents) }
        // A value set elsewhere, or clamped by the binding, shows even mid-edit; typed text that already means the
        // same amount, such as "12." or "12.5", is left alone.
        .onChange(of: cents) { _, newCents in
            if isFocused {
                if CentsEntry.cents(from: text) != newCents { text = CentsEntry.format(newCents) }
            } else {
                let formatted = CentsEntry.format(newCents)
                if text != formatted { text = formatted }
            }
        }
        .onChange(of: isFocused) { _, focused in
            if isFocusedBinding?.wrappedValue != focused {
                isFocusedBinding?.wrappedValue = focused
            }
            onFocusChange?(focused)
            if focused {
                text = cents == 0 ? "" : CentsEntry.format(cents)
                // After the tap has placed the cursor, move it to the end.
                DispatchQueue.main.async { selection = TextSelection(insertionPoint: text.endIndex) }
            } else {
                text = CentsEntry.format(cents)
            }
        }
        .onChange(of: isFocusedBinding?.wrappedValue) { _, externalFocused in
            if let externalFocused, isFocused != externalFocused {
                isFocused = externalFocused
            }
        }
        .onChange(of: text) { oldText, newText in
            guard isFocused else { return }
            guard let cleaned = CentsEntry.sanitize(newText) else {
                text = oldText
                return
            }
            if cleaned != newText { text = cleaned }
            let typed = CentsEntry.cents(from: cleaned)
            if typed != cents { cents = typed }
            // Read back through the binding, which may clamp the value.
            if cents != typed { text = CentsEntry.format(cents) }
        }
        .keyboardDoneButton($isFocused)
    }
}

/// The entry rules behind `CentsField`, kept free of SwiftUI so they can be unit tested.
enum CentsEntry {
    /// $9,999,999.99, which keeps every amount well within `Int`.
    static let maxDollarDigits = 7

    static func format(_ cents: Int) -> String {
        let cents = max(0, cents)
        return "\(cents / 100)." + String(format: "%02d", cents % 100)
    }

    /// The field text an edit leaves, or nil when the edit should be refused. Pasted symbols ("$", ",", spaces) are
    /// dropped and leading zeros before a digit are trimmed. Refused: a second decimal point, more than two decimals,
    /// more than `maxDollarDigits` dollar digits, or any other character.
    static func sanitize(_ text: String) -> String? {
        let kept = text.filter { !($0 == "$" || $0 == "," || $0.isWhitespace) }
        guard kept.allSatisfy({ $0.isASCIIDigit || $0 == "." }) else { return nil }
        let parts = kept.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        var dollars = Substring(parts[0])
        while dollars.count > 1, dollars.first == "0" { dollars = dollars.dropFirst() }
        guard dollars.count <= maxDollarDigits else { return nil }
        guard parts.count == 2 else { return String(dollars) }
        guard parts[1].count <= 2 else { return nil }
        return "\(dollars).\(parts[1])"
    }

    /// The amount sanitized text stands for: "" is 0, "5" is 500, "12." is 1200, ".5" is 50.
    static func cents(from text: String) -> Int {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let dollars = Int(parts.first.map(String.init) ?? "") ?? 0
        let fraction = parts.count > 1 ? String((parts[1] + "00").prefix(2)) : "00"
        return dollars * 100 + (Int(fraction) ?? 0)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Compact inline currency input without a leading spacer, styled as a tappable pill for inline sentence rows.
struct InlineCentsInput: View {
    @Binding var cents: Int
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 1) {
            Text("$")
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
            TextField("0.00", text: $text, selection: $selection)
                .keyboardType(.decimalPad)
                .focused($isFocused)
                .multilineTextAlignment(.leading)
                .fixedSize()
                .autocorrectionDisabled()
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { text = CentsEntry.format(cents) }
        .onChange(of: cents) { _, newCents in
            if isFocused {
                if CentsEntry.cents(from: text) != newCents { text = CentsEntry.format(newCents) }
            } else {
                let formatted = CentsEntry.format(newCents)
                if text != formatted { text = formatted }
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                text = cents == 0 ? "" : CentsEntry.format(cents)
                DispatchQueue.main.async { selection = TextSelection(insertionPoint: text.endIndex) }
            } else {
                text = CentsEntry.format(cents)
            }
        }
        .onChange(of: text) { oldText, newText in
            guard isFocused else { return }
            guard let cleaned = CentsEntry.sanitize(newText) else {
                text = oldText
                return
            }
            if cleaned != newText { text = cleaned }
            let typed = CentsEntry.cents(from: cleaned)
            if typed != cents { cents = typed }
            if cents != typed { text = CentsEntry.format(cents) }
        }
        .keyboardDoneButton($isFocused)
        .accessibilityLabel("Amount")
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
