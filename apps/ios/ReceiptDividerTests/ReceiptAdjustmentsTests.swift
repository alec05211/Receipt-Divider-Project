import XCTest
@testable import ReceiptDivider

final class ReceiptAdjustmentsTests: XCTestCase {
    func testQuantityBecomesOneRowPerUnit() {
        let rows = ReceiptItem.rows(name: "Soda", quantity: 3, lineCents: 1_000, discountCents: 100)
        XCTAssertEqual(rows.map(\.cents), [334, 333, 333])
        XCTAssertEqual(rows.map(\.localOffsetCents), [-34, -33, -33])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        // A line too cheap to give every unit a cent stays one row.
        XCTAssertEqual(ReceiptItem.rows(name: "Gum", quantity: 3, lineCents: 2).map(\.cents), [2])
    }

    /// A $10 burger with a $1 coupon and an untaxed $5 salad: 6% tax on the burger, a $4 tip, then a 3% card surcharge
    /// on everything including the tip.
    func testAdjustmentsApplyInReceiptOrder() {
        var rows = [
            ReceiptItem(name: "Burger", cents: 1_000, localOffsetCents: -100),
            ReceiptItem(name: "Salad", cents: 500, taxed: false),
        ]
        let adjustments = rows.resolveAdjustments([
            ReceiptAdjustment(kind: .tax, amountCents: 54),
            ReceiptAdjustment(kind: .tip, amountCents: 400),
            ReceiptAdjustment(kind: .surcharge, amountCents: 56),
        ])

        XCTAssertEqual(adjustments.map(\.amountCents), [54, 400, 56])
        XCTAssertEqual(adjustments[0].rate, 0.06, accuracy: 1e-9)
        XCTAssertEqual(adjustments[2].rate, 56.0 / 1_854, accuracy: 1e-9)
        // Only the burger is taxed; the surcharge reaches every item and the tip, which keeps its share apart.
        XCTAssertEqual(rows[0].globalOffsetCents, 54 + 29)
        XCTAssertEqual(rows[1].globalOffsetCents, 15)
        XCTAssertEqual(adjustments[1].chargesCents, 12)
        XCTAssertEqual(adjustments.tipCents, 412)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalCents } + adjustments.tipCents, 1_910)
    }

    func testSurchargePrintedBeforeTheTipIsNotChargedOnIt() {
        var rows = [ReceiptItem(name: "Pasta", cents: 2_000)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .surcharge, amountCents: 60), ReceiptAdjustment(kind: .tip, amountCents: 400)])
        XCTAssertEqual(rows.map(\.globalOffsetCents), [60])
        XCTAssertEqual(adjustments.tipCents, 400)
    }

    func testDiscountAndTaxReproduceTheirPrintedAmountsInEitherOrder() {
        var discountFirst = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 1_000)]
        let first = discountFirst.resolveAdjustments([ReceiptAdjustment(kind: .discount, amountCents: 200), ReceiptAdjustment(kind: .tax, amountCents: 108)])
        XCTAssertEqual(first.map(\.rate), [0.1, 0.06])
        XCTAssertEqual(discountFirst.reduce(0) { $0 + $1.totalCents }, 1_908)

        var taxFirst = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 1_000)]
        let second = taxFirst.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 120), ReceiptAdjustment(kind: .discount, amountCents: 212)])
        XCTAssertEqual(second.map(\.rate), [0.06, 0.1])
        XCTAssertEqual(taxFirst.reduce(0) { $0 + $1.totalCents }, 1_908)
    }

    func testRoundedSharesAddUpToThePrintedAmount() {
        var rows = [333, 333, 334, 1].map { ReceiptItem(name: "Item", cents: $0) }
        rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 70)])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.globalOffsetCents }, 70)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalCents }, 1_071)
    }

    func testRatesApplyToTheRowsThatRemain() {
        var rows = [ReceiptItem(name: "A", cents: 1_000), ReceiptItem(name: "B", cents: 500)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, amountCents: 120)])
        rows.removeLast()
        let applied = rows.applyAdjustments(adjustments)
        XCTAssertEqual(applied[0].amountCents, 80)
        XCTAssertEqual(rows[0].totalCents, 1_080)
    }

    func testPercentOnlyAdjustmentUsesThePrintedRate() {
        var rows = [ReceiptItem(name: "A", cents: 2_500)]
        let adjustments = rows.resolveAdjustments([ReceiptAdjustment(kind: .tax, rate: 0.08)])
        XCTAssertEqual(adjustments[0].amountCents, 200)
        XCTAssertEqual(rows[0].totalCents, 2_700)
    }

    /// Contributions add the tip, plus its surcharge, as a share everyone owns, so it's split evenly whatever each ordered.
    func testTipIsSplitEvenlyWhateverEachPersonOrdered() {
        let (ben, alec) = (UUID(), UUID())
        let items = [ReceiptItem(name: "Steak", cents: 3_000, ownerIDs: [ben]), ReceiptItem(name: "Soup", cents: 1_000, ownerIDs: [alec])]
        let tip = [ReceiptAdjustment(kind: .tip, amountCents: 800)].tipCents
        XCTAssertEqual((items + [ReceiptItem(name: "Tip", cents: tip, ownerIDs: [ben, alec])]).ownerShares(for: [ben, alec]), [ben: 3_400, alec: 1_400])
    }

    func testRatesCloseToAWholePercentShowAsWhole() {
        XCTAssertEqual(RateField.format(0.08001), "8")
        XCTAssertEqual(RateField.format(0.0400099), "4")
        XCTAssertEqual(RateField.format(0.06625), "6.625")
    }

    func testMismatchesAreReportedNotFixed() {
        var extraction = ReceiptExtraction(items: [ReceiptItem(name: "A", cents: 1_000)], subtotalCents: 1_100, printedTotalCents: 1_100)
        XCTAssertEqual(extraction.issues.count, 2)
        XCTAssertNotNil(extraction.mismatchWarning)
        extraction.items[0].cents = 1_100
        XCTAssertTrue(extraction.issues.isEmpty)
    }

    func testMissingTotalIsAWarningAndAnIssue() {
        let extraction = ReceiptExtraction(items: [ReceiptItem(name: "A", cents: 1_000)])
        XCTAssertNil(extraction.mismatchWarning)
        XCTAssertNotNil(extraction.warning)
        XCTAssertEqual(extraction.issues, ["No total was found."])
    }

    /// Text recognition returned the names and the prices as two columns; rows are rebuilt from their positions.
    func testColumnsAreRebuiltIntoPrintedRows() {
        let names = ["Brisket", "Coke Cherry", "Subtotal", "Total"], prices = ["36.00", "3.85", "39.85", "39.85"]
        let fragments = names.enumerated().map { ReceiptTextRecognizer.Fragment(text: $0.element, box: CGRect(x: 0.05, y: 0.9 - Double($0.offset) * 0.05, width: 0.3, height: 0.02)) }
            + prices.enumerated().map { ReceiptTextRecognizer.Fragment(text: $0.element, box: CGRect(x: 0.75, y: 0.9 - Double($0.offset) * 0.05, width: 0.15, height: 0.02)) }
        XCTAssertEqual(ReceiptTextRecognizer.layoutText(fragments).components(separatedBy: "\n"),
                       ["Brisket  36.00", "Coke Cherry  3.85", "Subtotal  39.85", "Total  39.85"])
    }

    func testRowsTakeTheirPriceFromTheRightEnd() {
        let row = ReceiptRow("Hot Tea  2 x $3.25  6.50")
        XCTAssertEqual(row.amountCents, 650)
        XCTAssertEqual(row.quantity, 2)
        XCTAssertEqual(row.name, "Hot Tea")
        XCTAssertEqual(ReceiptRow("1 Cheeseburger  $11.69").name, "Cheeseburger")
        XCTAssertEqual(ReceiptRow("SALE -1.00").amountCents, -100)
        XCTAssertEqual(ReceiptRow("GREEK YOGURT 6.98 F").amountCents, 698)
        XCTAssertEqual(ReceiptRow("Total (Non-Cash)  427,12").amountCents, 42_712)
        XCTAssertEqual(ReceiptRow("TAX 7.000% 0.80").percent, 7)
        XCTAssertEqual(ReceiptRow("2 Iced Tea  7.00").quantity, 2)
        XCTAssertEqual(ReceiptRow("1 16oz Ribeye  64.00").name, "16oz Ribeye")
        XCTAssertEqual(ReceiptRow("1 Milk Shake  $6. 19").amountCents, 619)
        XCTAssertTrue(ReceiptRow("2 @ 3.49").isQuantityDetail)
        XCTAssertFalse(ReceiptRow("2 Iced Tea  7.00").isQuantityDetail)
        XCTAssertNil(ReceiptRow("Order #22038:1").amountCents)
        XCTAssertNil(ReceiptRow("Platter (Pick 2 Sides)").amountCents)
    }

    /// Prices come from the rows; the labels only say what each priced row is. Separate cash and card totals make the
    /// difference a final surcharge, and an automatic gratuity is the tip.
    func testLabelsTurnRowsIntoItemsAndAdjustments() {
        let rows = ["Brisket  2 x $18.00  36.00", "     Platter (Pick 2 Sides)", "Coke  4.00", "COUPON  -1.00", "Subtotal  39.00",
                    "Tax 8%  3.12", "Gratuity  8.00", "Total (Cash)  50.12", "Total (Non-Cash)  52.12", "18%: $7.20: $59.32"].map(ReceiptRow.init)
        let labels = ReceiptLabels(merchant: "Smokehouse", category: .restaurant, purchaseDate: "2026-10-05", rows: [
            .init(row: 0, kind: .item, taxed: false), .init(row: 1, kind: .item, taxed: false),
            .init(row: 2, kind: .itemDiscount, taxed: true), .init(row: 3, kind: .subtotal, taxed: true),
            .init(row: 4, kind: .tax, taxed: true), .init(row: 5, kind: .tip, taxed: true),
            .init(row: 6, kind: .cashTotal, taxed: true), .init(row: 7, kind: .total, taxed: true),
            .init(row: 8, kind: .other, taxed: true),
        ], expenseName: "")
        let extraction = ReceiptExtraction(rows: rows, labels: labels, text: "")
        XCTAssertEqual(extraction.items.map(\.name), ["Brisket", "Brisket", "Coke"])
        XCTAssertEqual(extraction.items.map(\.cents), [1_800, 1_800, 400])
        // The tip comes before the card total's surcharge, so it carries its share of that too.
        XCTAssertEqual(extraction.adjustments.first { $0.kind == .tip }?.amountCents, 800)
        XCTAssertEqual(extraction.adjustments.tipCents, 832)
        XCTAssertEqual(extraction.items[2].localOffsetCents, -100)
        XCTAssertTrue(extraction.items.allSatisfy(\.taxed))
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertEqual(extraction.adjustments.last?.amountCents, 200)
        XCTAssertEqual(extraction.adjustments.first?.rate ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(extraction.printedTotalCents, 5_212)
        XCTAssertEqual(extraction.name, "Smokehouse Meal")
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    /// Two totals without a cash total are a printed total and a final one written in after the tip, not cash and card.
    func testLaterTotalIsFinalAndNotASurcharge() {
        let rows = ["Ribeye  64.00", "Subtotal  64.00", "Tax  5.76", "Total  69.76", "Tip:  6.00", "Total:  75.76"].map(ReceiptRow.init)
        let labels = ReceiptLabels(merchant: "", category: .restaurant, purchaseDate: "", rows: [
            .init(row: 0, kind: .item, taxed: true), .init(row: 1, kind: .subtotal, taxed: true), .init(row: 2, kind: .tax, taxed: true),
            .init(row: 3, kind: .total, taxed: true), .init(row: 4, kind: .tip, taxed: true), .init(row: 5, kind: .total, taxed: true),
        ], expenseName: "")
        let extraction = ReceiptExtraction(rows: rows, labels: labels, text: "")
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip])
        XCTAssertEqual(extraction.printedTotalCents, 7_576)
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    func testUnlabeledSummaryRowsAreAnIssue() {
        let rows = ["Ribeye  64.00", "Subtotal  64.00", "Total  64.00", "Tip:  6.00"].map(ReceiptRow.init)
        let labels = ReceiptLabels(merchant: "", category: .restaurant, purchaseDate: "", rows: [
            .init(row: 1, kind: .subtotal, taxed: true), .init(row: 2, kind: .total, taxed: true),
        ], expenseName: "")
        XCTAssertEqual(ReceiptExtraction(rows: rows, labels: labels, text: "").unlabeledRows, [3])
    }

    func testParserReadingBecomesAdjustments() {
        var scan = ReceiptScan(items: [ReceiptItem(name: "Item", cents: 1_000, localOffsetCents: -100)], taxCents: 54, discountCents: 0)
        scan.printedTotalCents = 954
        let extraction = ReceiptExtraction(scan)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax])
        XCTAssertEqual(extraction.adjustments[0].rate, 0.06, accuracy: 1e-9)
        XCTAssertNil(extraction.mismatchWarning)
    }

    /// A cloud reading is worked out like the on-device model's: amounts come from its rows' prices, quantities become
    /// one row per unit, a discount row reduces the item above it, and the cash and card totals make a surcharge.
    func testCloudReadingIsWorkedOutLikeTheModels() {
        let rows: [(String, String, String, Bool)] = [
            ("SMOKEHOUSE", "", "other", true), ("Brisket 2 x $18.00", "36.00", "item", false), ("Coke", "4.00", "item", true),
            ("COUPON", "1.00-", "itemDiscount", true), ("Subtotal", "39.00", "subtotal", true), ("Tax 8%", "3.12", "tax", true),
            ("Gratuity", "8.00", "tip", true), ("Total (Cash)", "50.12", "cashTotal", true), ("Total (Non-Cash)", "52.12", "total", true),
            ("18%: $7.20: $59.32", "", "other", true),
        ]
        let extraction = ReceiptExtraction(cloudReading(rows), text: "")
        XCTAssertEqual(extraction.items.map(\.name), ["Brisket", "Brisket", "Coke"])
        XCTAssertEqual(extraction.items.map(\.cents), [1_800, 1_800, 400])
        XCTAssertEqual(extraction.items[2].localOffsetCents, -100)
        XCTAssertEqual(extraction.adjustments.map(\.kind), [.tax, .tip, .surcharge])
        XCTAssertEqual(extraction.adjustments.tipCents, 832)
        XCTAssertEqual(extraction.printedTotalCents, 5_212)
        XCTAssertEqual(extraction.subtotalCents, 3_900)
        XCTAssertEqual(extraction.category, .restaurant)
        XCTAssertEqual(extraction.name, "Smokehouse Meal")
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    func testCloudReadingNamesMapToLabels() {
        XCTAssertEqual(ReceiptLabels.Kind("itemDiscount"), .itemDiscount)
        XCTAssertEqual(ReceiptLabels.Kind("cashTotal"), .cashTotal)
        XCTAssertNil(ReceiptLabels.Kind("invented"))
        XCTAssertEqual(ReceiptLabels.Category("groceries"), .groceries)
        XCTAssertEqual(ReceiptLabels.Category("invented"), .other)
    }

    /// A row without a price has none, so a unit price in its text isn't taken for its price; a bare quantity detail
    /// still multiplies to the item above it.
    func testCloudRowWithoutAPriceKeepsItsUnitPriceOutOfTheItems() {
        let rows: [(String, String, String, Bool)] = [
            ("Hot Tea 2 x $3.25", "", "item", true), ("Lemons", "6.98", "item", true), ("2 @ 3.49", "", "detail", true),
            ("Subtotal", "6.98", "subtotal", true), ("Total", "6.98", "total", true),
        ]
        let extraction = ReceiptExtraction(cloudReading(rows), text: "")
        XCTAssertEqual(extraction.items.map(\.name), ["Lemons", "Lemons"])
        XCTAssertEqual(extraction.items.map(\.cents), [349, 349])
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    /// Cloud vision's tidied name replaces a misread one; the price still comes from the row.
    func testItemTakesCloudVisionsTidiedName() {
        let reading = APIReceiptReading(merchant: "", category: "restaurant", purchaseDate: "", rows: [
            .init(text: "BBU Chicken Club", price: "15.00", kind: "item", taxed: true, name: "BBQ Chicken Club"),
            .init(text: "Fries", price: "4.00", kind: "item", taxed: true, name: ""),
            .init(text: "Total", price: "19.00", kind: "total", taxed: true, name: ""),
        ], expenseName: "")
        let extraction = ReceiptExtraction(reading, text: "")
        XCTAssertEqual(extraction.items.map(\.name), ["BBQ Chicken Club", "Fries"])
        XCTAssertEqual(extraction.items.map(\.cents), [1_500, 400])
    }

    func testRowsReadTrailingTaxLettersAndUnitPriceLines() {
        let untaxed = ReceiptRow("GREEK YOGURT 6.98 F")
        XCTAssertEqual(untaxed.taxedFlag, false)
        XCTAssertEqual(ReceiptRow("PAPER TOWELS 8.99 T").taxedFlag, true)
        XCTAssertNil(ReceiptRow("Brisket 36.00").taxedFlag)

        let unitLine = ReceiptRow("Hot Tea 2 x $3.25")
        XCTAssertEqual(unitLine.name, "Hot Tea")
        XCTAssertEqual(unitLine.quantity, 2)
        XCTAssertEqual(unitLine.amountCents, 650)
        XCTAssertFalse(unitLine.isQuantityDetail)
    }

    func testTiltedRightColumnPricesPairWithTheirLeftColumnNames() {
        let fragments = [
            ReceiptTextRecognizer.Fragment(text: "Burger", box: CGRect(x: 0.08, y: 0.80, width: 0.3, height: 0.02)),
            ReceiptTextRecognizer.Fragment(text: "16.00", box: CGRect(x: 0.78, y: 0.79, width: 0.12, height: 0.02)),
            ReceiptTextRecognizer.Fragment(text: "Fries", box: CGRect(x: 0.08, y: 0.74, width: 0.3, height: 0.02)),
            ReceiptTextRecognizer.Fragment(text: "5.00", box: CGRect(x: 0.78, y: 0.722, width: 0.12, height: 0.02)),
        ]
        XCTAssertEqual(ReceiptTextRecognizer.layoutRows(fragments), ["Burger  16.00", "Fries  5.00"])
    }

    func testOnDeviceTidiedNamesApplyOnlyWhenCredibleAndAligned() {
        XCTAssertTrue(ReceiptExtraction.needsTidying("BBU Chicken Club"))
        XCTAssertTrue(ReceiptExtraction.needsTidying("CHKN SNDWCH"))
        XCTAssertTrue(ReceiptExtraction.needsTidying("GREEK YOGURT"))
        XCTAssertFalse(ReceiptExtraction.needsTidying("16oz Ribeye"))
        XCTAssertFalse(ReceiptExtraction.needsTidying("Pulled Pork Sandwich"))

        var extraction = ReceiptExtraction(items: [
            ReceiptItem(name: "BBU Chicken Club", cents: 1_500),
            ReceiptItem(name: "CHKN SNDWCH", cents: 1_200),
            ReceiptItem(name: "GREEK YOGURT", cents: 698),
            ReceiptItem(name: "Fries", cents: 400),
        ])
        extraction.applyTidiedNames([
            (original: "BBU Chicken Club", tidied: "BBQ Chicken Club"),
            (original: "CHKN SNDWCH", tidied: "Chicken Sandwich"),
            // A mismatched name from another row is rejected.
            (original: "Fries", tidied: "BBQ Chicken Club"),
        ])
        extraction.titleCaseRemainingAllCapsNames()
        XCTAssertEqual(extraction.items.map(\.name), ["BBQ Chicken Club", "Chicken Sandwich", "Greek Yogurt", "Fries"])
    }

    func testSummaryOnlyLabelsStillReadAllItemsAndIgnoreSavingsSummaryTotals() {
        let rows = [
            "WEG GRK YOGURT  1.39 F",
            "COUPON  -0.40",
            "2.56",
            "SUBTOTAL  0.99",
            "TAX  0.00",
            "TOTAL  0.99",
            "SAVINGS SUMMARY",
            "DIGITAL COUPONS  0.40",
            "TOTAL  0.40",
        ].map(ReceiptRow.init)
        let labels = ReceiptLabels(merchant: "Wegmans", category: .groceries, purchaseDate: "2026-10-08", rows: [
            .init(row: 3, kind: .subtotal, taxed: true),
            .init(row: 4, kind: .tax, taxed: true),
            .init(row: 5, kind: .total, taxed: true),
        ], expenseName: "Wegmans Groceries")
        let extraction = ReceiptExtraction(rows: rows, labels: labels, text: "")
        XCTAssertEqual(extraction.items.map(\.name), ["WEG GRK YOGURT"])
        XCTAssertEqual(extraction.items.map(\.cents), [139])
        XCTAssertEqual(extraction.items.map(\.localOffsetCents), [-40])
        XCTAssertEqual(extraction.printedTotalCents, 99)
        XCTAssertTrue(extraction.issues.isEmpty, extraction.issues.joined(separator: " "))
    }

    func testNormalizedRightColumnPricesCleanEdgeNoiseAndMissingDecimals() {
        let fragments = [
            ReceiptTextRecognizer.Fragment(text: "MILK", box: CGRect(x: 0.26, y: 0.80, width: 0.20, height: 0.015)),
            ReceiptTextRecognizer.Fragment(text: "3.79 For", box: CGRect(x: 0.65, y: 0.805, width: 0.12, height: 0.015)),
            ReceiptTextRecognizer.Fragment(text: "EGGS", box: CGRect(x: 0.26, y: 0.77, width: 0.20, height: 0.015)),
            ReceiptTextRecognizer.Fragment(text: "2.795", box: CGRect(x: 0.65, y: 0.775, width: 0.12, height: 0.015)),
            ReceiptTextRecognizer.Fragment(text: "BREAD", box: CGRect(x: 0.26, y: 0.74, width: 0.20, height: 0.015)),
            ReceiptTextRecognizer.Fragment(text: "199 F", box: CGRect(x: 0.65, y: 0.745, width: 0.12, height: 0.015)),
        ]
        let rows = ReceiptTextRecognizer.layoutRows(fragments).map(ReceiptRow.init)
        XCTAssertEqual(rows.map(\.amountCents), [379, 279, 199])
        XCTAssertEqual(rows.map(\.taxedFlag), [false, false, false])
    }

    private func cloudReading(_ rows: [(String, String, String, Bool)]) -> APIReceiptReading {
        APIReceiptReading(merchant: "Smokehouse", category: "restaurant", purchaseDate: "2026-10-05",
                          rows: rows.map { .init(text: $0.0, price: $0.1, kind: $0.2, taxed: $0.3) }, expenseName: "")
    }
}
