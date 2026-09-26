import SwiftUI

struct SettleUpView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    @State private var from: Person = .jamie
    @State private var amount = 0
    @State private var date = Date()
    @State private var didSave = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section("Current balance") { LabeledContent("Alex", value: store.alexBalance.usd) }
            Section("Record payment") {
                Picker("From", selection: $from) { ForEach(Person.allCases) { Text($0.rawValue).tag($0) } }
                LabeledContent("To", value: from.other.rawValue)
                CentsField(title: "Amount", cents: $amount)
                DatePicker("Payment date", selection: $date, displayedComponents: .date)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Settle up")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Recording…" : "Record", action: save).disabled(amount <= 0 || isSaving) } }
        .sensoryFeedback(.success, trigger: didSave)
    }

    private func save() {
        let payment = Payment(amount: amount, from: from, to: from.other, transactionDate: date)
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let token = try await authentication.accessToken()
                try await store.add(payment, accessToken: token)
                amount = 0
                didSave.toggle()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
