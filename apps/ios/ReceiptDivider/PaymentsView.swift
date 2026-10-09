import SwiftUI

/// Every recorded payment between you and your friends, newest first.
struct PaymentsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AuthenticationStore.self) private var authentication
    private var payments: [Payment] { store.payments.sorted { $0.transactionDate > $1.transactionDate } }

    var body: some View {
        List {
            if payments.isEmpty {
                ContentUnavailableView("No payments", systemImage: "arrow.left.arrow.right.circle")
            } else {
                ForEach(payments) { PaymentRow(payment: $0) }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Payments")
        .refreshable {
            guard let token = try? await authentication.accessToken() else { return }
            try? await store.refresh(accessToken: token)
        }
    }
}
private struct PaymentRow: View {
    @Environment(ExpenseStore.self) private var store
    let payment: Payment
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.name(for: payment.from)) paid \(store.name(for: payment.to))").font(.headline)
                Text(payment.transactionDate, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(payment.amount.usd).fontWeight(.semibold)
        }
    }
}
