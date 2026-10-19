import XCTest
@testable import ReceiptDivider

final class CentsEntryTests: XCTestCase {
    /// Types each key at the end of the field, as `CentsField` applies it.
    private func type(_ keys: String, from text: String = "") -> (text: String, cents: Int) {
        let result = keys.reduce(text) { text, key in CentsEntry.sanitize(text + String(key)) ?? text }
        return (result, CentsEntry.cents(from: result))
    }

    func testFormatAlwaysShowsTwoDecimals() {
        XCTAssertEqual(CentsEntry.format(0), "0.00")
        XCTAssertEqual(CentsEntry.format(5), "0.05")
        XCTAssertEqual(CentsEntry.format(1_234), "12.34")
        XCTAssertEqual(CentsEntry.format(100_000), "1000.00")
        XCTAssertEqual(CentsEntry.format(-50), "0.00")
    }

    func testTypingStartsInTheDollarsPlace() {
        XCTAssertEqual(type("5").cents, 500)
        XCTAssertEqual(type("45").cents, 4_500)
        XCTAssertEqual(type("45.").cents, 4_500)
        XCTAssertEqual(type("45.2").cents, 4_520)
        XCTAssertEqual(type("45.24").cents, 4_524)
        XCTAssertEqual(type(".5").cents, 50)
    }

    func testEmptyFieldIsZero() {
        XCTAssertEqual(CentsEntry.cents(from: ""), 0)
        XCTAssertEqual(CentsEntry.cents(from: "."), 0)
    }

    func testRefusesASecondDecimalPointOrAThirdDecimal() {
        XCTAssertEqual(type("1.2.3").text, "1.23")
        XCTAssertEqual(type("1.234").text, "1.23")
        XCTAssertNil(CentsEntry.sanitize("1..2"))
        XCTAssertNil(CentsEntry.sanitize("12a"))
    }

    func testLeadingZerosAreTrimmed() {
        XCTAssertEqual(type("05").text, "5")
        XCTAssertEqual(type("0.5").text, "0.5")
        XCTAssertEqual(type("00").text, "0")
    }

    func testEditingAPrefilledAmount() {
        // Backspace at the end of $12.34.
        XCTAssertEqual(CentsEntry.sanitize("12.3").map(CentsEntry.cents(from:)), 1_230)
        // Inserting a digit before the decimal point.
        XCTAssertEqual(CentsEntry.sanitize("125.34").map(CentsEntry.cents(from:)), 12_534)
        // Deleting the decimal point.
        XCTAssertEqual(CentsEntry.sanitize("1234").map(CentsEntry.cents(from:)), 123_400)
        // Typing past the cents on a formatted amount is refused.
        XCTAssertNil(CentsEntry.sanitize("12.345"))
    }

    func testDollarDigitLimit() {
        XCTAssertEqual(type("12345678").text, "1234567")
        XCTAssertEqual(type("9999999.99").cents, 999_999_999)
    }

    func testPastedAmountsDropSymbols() {
        XCTAssertEqual(CentsEntry.sanitize("$1,234.56"), "1234.56")
        XCTAssertEqual(CentsEntry.sanitize(" 7 "), "7")
        XCTAssertNil(CentsEntry.sanitize("12.345"))
    }
}
