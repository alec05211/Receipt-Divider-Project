import Foundation
import Observation

struct ReceiptItem: Identifiable, Hashable, Codable {
    var id = UUID(); var name: String; var cents: Int
    /// The item's part of the receipt's tax and discounts, kept apart so `cents` stays the printed price.
    /// Negative when discounts outweigh tax.
    var offsetCents = 0
    var isSelected = false
    var totalCents: Int { cents + offsetCents }
}
extension ReceiptItem {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); name = try container.decode(String.self, forKey: .name); cents = try container.decode(Int.self, forKey: .cents)
        offsetCents = try container.decodeIfPresent(Int.self, forKey: .offsetCents) ?? 0
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }
}
extension Array where Element == ReceiptItem {
    /// Adds an amount (tax minus discounts) to the offsets of the matching items, in proportion to what each
    /// costs after its own discounts. Rounding cents go to the largest fractions, so the offsets add up exactly.
    mutating func spread(_ amount: Int, where include: (ReceiptItem) -> Bool = { _ in true }) {
        let targets = indices.filter { include(self[$0]) && self[$0].totalCents > 0 }
        let base = targets.reduce(0) { $0 + self[$1].totalCents }
        guard amount != 0, base > 0 else { return }
        let exact = targets.map { (index: $0, value: Double(amount) * Double(self[$0].totalCents) / Double(base)) }
        for share in exact { self[share.index].offsetCents += Int(share.value.rounded(.towardZero)) }
        let remainder = amount - exact.reduce(0) { $0 + Int($1.value.rounded(.towardZero)) }
        let byFraction = exact.sorted { abs($0.value.truncatingRemainder(dividingBy: 1)) > abs($1.value.truncatingRemainder(dividingBy: 1)) }
        for share in byFraction.prefix(abs(remainder)) { self[share.index].offsetCents += remainder.signum() }
    }
}
struct Expense: Identifiable, Hashable, Codable {
    var id = UUID(); var description: String; var transactionDate: Date; var payer: Person; var items: [ReceiptItem]; var shares: [Person: Int]; var receiptImageData: Data?; var createdAt = Date()
    var total: Int { max(0, items.filter(\.isSelected).reduce(0) { $0 + $1.totalCents }) }
    /// Tax and discounts included in the selected items.
    var offsetTotal: Int { items.filter(\.isSelected).reduce(0) { $0 + $1.offsetCents } }
}
extension Expense {
    /// Expenses saved before item offsets stored tax and discount as separate amounts; those are spread onto the shared items.
    private enum LegacyKeys: String, CodingKey { case taxCents, discountCents }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); description = try container.decode(String.self, forKey: .description)
        transactionDate = try container.decode(Date.self, forKey: .transactionDate); payer = try container.decode(Person.self, forKey: .payer)
        items = try container.decode([ReceiptItem].self, forKey: .items); shares = try container.decode([Person: Int].self, forKey: .shares)
        receiptImageData = try container.decodeIfPresent(Data.self, forKey: .receiptImageData); createdAt = try container.decode(Date.self, forKey: .createdAt)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let tax = try legacy.decodeIfPresent(Int.self, forKey: .taxCents) ?? 0, discount = try legacy.decodeIfPresent(Int.self, forKey: .discountCents) ?? 0
        items.spread(tax - discount, where: \.isSelected)
    }
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
