import SwiftUI

struct SettleUpView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var from: Person = .jamie
    @State private var amount = 0
    @State private var date = Date()
    @State private var didSave = false
    var body: some View {
        Form {
            Section("Current balance") { LabeledContent("Alex", value: store.alexBalance.usd) }
            Section("Record payment") {
                Picker("From", selection: $from) { ForEach(Person.allCases) { Text($0.rawValue).tag($0) } }
                LabeledContent("To", value: from.other.rawValue)
                CentsField(title: "Amount", cents: $amount)
                DatePicker("Payment date", selection: $date, displayedComponents: .date)
            }
        }
        .navigationTitle("Settle up")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Record") { store.add(Payment(amount: amount, from: from, to: from.other, transactionDate: date)); amount = 0; didSave.toggle() }.disabled(amount <= 0) } }
        .sensoryFeedback(.success, trigger: didSave)
    }
}
