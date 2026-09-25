import Foundation
import Observation

struct ReceiptItem: Identifiable, Hashable, Codable { var id = UUID(); var name: String; var cents: Int; var isSelected = true }
struct Expense: Identifiable, Hashable, Codable {
    var id = UUID(); var description: String; var transactionDate: Date; var payer: Person; var items: [ReceiptItem]; var taxCents: Int; var discountCents: Int; var shares: [Person: Int]; var receiptImageData: Data?; var createdAt = Date()
    var itemTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.cents } }
    var total: Int { max(0, itemTotal + taxCents - discountCents) }
}
struct Payment: Identifiable, Hashable, Codable { var id = UUID(); var amount: Int; var from: Person; var to: Person; var transactionDate: Date; var createdAt = Date() }
enum Person: String, CaseIterable, Identifiable, Codable {
    case alex = "Alex", jamie = "Jamie", morgan = "Morgan", taylor = "Taylor"
    var id: String { rawValue }
    var other: Person { self == .alex ? .jamie : .alex }
    var initials: String { String(rawValue.prefix(1)) }
}
enum SplitMode: String, CaseIterable, Identifiable { case equal = "Split equally", custom = "Custom amounts"; var id: String { rawValue } }

@Observable final class ExpenseStore {
    private let storageKey = "receipt-divider-ledger-v1"
    var expenses: [Expense] = [] { didSet { persist() } }
    var payments: [Payment] = [] { didSet { persist() } }
    init() { restore() }
    var alexBalance: Int {
        let expenses = expenses.reduce(0) { $0 + ($1.payer == .alex ? $1.total : 0) - ($1.shares[.alex] ?? 0) }
        let payments = payments.reduce(0) { $0 + ($1.to == .alex ? $1.amount : 0) - ($1.from == .alex ? $1.amount : 0) }
        return expenses + payments
    }
    func add(_ expense: Expense) { expenses.append(expense); expenses.sort { $0.transactionDate > $1.transactionDate } }
    func add(_ payment: Payment) { payments.append(payment); payments.sort { $0.transactionDate > $1.transactionDate } }
    func reset() { expenses = []; payments = [] }
    private func persist() { guard let data = try? JSONEncoder().encode(LocalLedger(expenses: expenses, payments: payments)) else { return }; UserDefaults.standard.set(data, forKey: storageKey) }
    private func restore() { guard let data = UserDefaults.standard.data(forKey: storageKey), let ledger = try? JSONDecoder().decode(LocalLedger.self, from: data) else { return }; expenses = ledger.expenses; payments = ledger.payments }
}
private struct LocalLedger: Codable { var expenses: [Expense]; var payments: [Payment] }
extension Int { var usd: String { (Decimal(self) / 100).formatted(.currency(code: "USD")) } }
