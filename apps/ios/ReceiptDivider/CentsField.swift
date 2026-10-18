import SwiftUI
import Foundation

/// Edits a dollar amount the way a cash register does: the field shows the amount with two decimals, each digit typed
/// shifts in from the right (1, 2, 3, 4 reads $12.34), and backspace drops the last digit.
struct CentsField: View {
    let title: String
    @Binding var cents: Int
    var isFocusedBinding: Binding<Bool>?
    var onFocusChange: ((Bool) -> Void)?
    var fontWeight: Font.Weight?
    @State private var text = ""
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
                TextField(title, text: $text)
                    .keyboardType(.numberPad)
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
        // The text always mirrors `cents`, so a value set elsewhere, or clamped by the binding, shows even mid-edit.
        .onChange(of: cents) { _, newCents in
            let formatted = CentsEntry.format(newCents)
            if text != formatted { text = formatted }
        }
        .onChange(of: isFocused) { _, focused in
            if isFocusedBinding?.wrappedValue != focused {
                isFocusedBinding?.wrappedValue = focused
            }
            onFocusChange?(focused)
            text = CentsEntry.format(cents)
        }
        .onChange(of: isFocusedBinding?.wrappedValue) { _, externalFocused in
            if let externalFocused, isFocused != externalFocused {
                isFocused = externalFocused
            }
        }
        .onChange(of: text) { oldText, newText in
            guard newText != CentsEntry.format(cents) else { return }
            if isFocused {
                let newCents = CentsEntry.cents(editing: oldText, to: newText)
                if newCents != cents { cents = newCents }
            }
            // Read back through the binding, which may clamp the value.
            let formatted = CentsEntry.format(cents)
            if text != formatted { text = formatted }
        }
        .keyboardDoneButton($isFocused)
    }
}

/// The cash-register entry rules behind `CentsField`, kept free of SwiftUI so they can be unit tested. The field's text
/// is always `format(cents)`; an edit is read as the characters it removed and inserted rather than by cursor position,
/// so digits always enter from the right and deletions always drop the rightmost digits.
enum CentsEntry {
    /// $9,999,999.99, which keeps every amount well within `Int`.
    static let maxDigits = 9

    static func format(_ cents: Int) -> String {
        let cents = max(0, cents)
        return "\(cents / 100)." + String(format: "%02d", cents % 100)
    }

    /// The amount a run of typed digits stands for, ignoring leading zeros and any digits past `maxDigits`.
    static func cents(fromDigits text: String) -> Int {
        let digits = text.filter(\.isASCIIDigit).drop(while: { $0 == "0" })
        return Int(String(digits.prefix(maxDigits))) ?? 0
    }

    /// The amount after the field's text changes from `oldText` to `newText`.
    static func cents(editing oldText: String, to newText: String) -> Int {
        let old = Array(oldText), new = Array(newText)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let removed = old[prefix..<(old.count - suffix)]
        let inserted = String(new[prefix..<(new.count - suffix)])

        // A pasted amount with a decimal point, such as "12.5" or "$1,234.56", replaces the value as written.
        if inserted.contains("."), let pasted = parseAmount(inserted) { return pasted }

        let oldCents = cents(fromDigits: oldText)
        var buffer = oldCents > 0 ? String(oldCents) : ""
        // Deleting only the decimal point still drops a digit, as backspace would.
        let dropCount = removed.isEmpty ? 0 : max(1, removed.filter(\.isASCIIDigit).count)
        buffer.removeLast(min(dropCount, buffer.count))
        return cents(fromDigits: buffer + inserted.filter(\.isASCIIDigit))
    }

    /// Parses text like "12.5", "$1,234.56" or "7" as dollars, or nil when it is not an amount that fits.
    static func parseAmount(_ text: String) -> Int? {
        let cleaned = text.filter { $0.isASCIIDigit || $0 == "." }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, parts.count <= 2 else { return nil }
        let dollars = parts[0].drop(while: { $0 == "0" })
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard dollars.count <= maxDigits - 2, !(dollars.isEmpty && fraction.isEmpty) else { return nil }
        return (Int(String(dollars)) ?? 0) * 100 + (Int(String((fraction + "00").prefix(2))) ?? 0)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
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
