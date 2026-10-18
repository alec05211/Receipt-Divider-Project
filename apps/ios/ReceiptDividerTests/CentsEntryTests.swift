import XCTest
@testable import ReceiptDivider

final class CentsEntryTests: XCTestCase {
    /// Types each key at the end of the field, reformatting after every keystroke as `CentsField` does.
    private func type(_ keys: String, from cents: Int = 0) -> Int {
        keys.reduce(cents) { value, key in
            let text = CentsEntry.format(value)
            return CentsEntry.cents(editing: text, to: text + String(key))
        }
    }

    private func backspace(_ times: Int, from cents: Int) -> Int {
        (0..<times).reduce(cents) { value, _ in
            let text = CentsEntry.format(value)
            return CentsEntry.cents(editing: text, to: String(text.dropLast()))
        }
    }

    func testFormatAlwaysShowsTwoDecimals() {
        XCTAssertEqual(CentsEntry.format(0), "0.00")
        XCTAssertEqual(CentsEntry.format(5), "0.05")
        XCTAssertEqual(CentsEntry.format(1_234), "12.34")
        XCTAssertEqual(CentsEntry.format(100_000), "1000.00")
        XCTAssertEqual(CentsEntry.format(-50), "0.00")
    }

    func testDigitsShiftInFromTheRight() {
        XCTAssertEqual(type("1"), 1)
        XCTAssertEqual(type("12"), 12)
        XCTAssertEqual(type("123"), 123)
        XCTAssertEqual(type("1234"), 1_234)
    }

    func testLeadingZerosAreIgnored() {
        XCTAssertEqual(type("0"), 0)
        XCTAssertEqual(type("005"), 5)
        XCTAssertEqual(CentsEntry.cents(fromDigits: "000120"), 120)
    }

    func testBackspaceDropsTheLastDigit() {
        XCTAssertEqual(backspace(1, from: 1_234), 123)
        XCTAssertEqual(backspace(3, from: 1_234), 1)
        XCTAssertEqual(backspace(6, from: 1_234), 0)
        XCTAssertEqual(backspace(1, from: 0), 0)
    }

    func testPrefilledValueKeepsTakingDigits() {
        XCTAssertEqual(type("5", from: 1_234), 12_345)
        XCTAssertEqual(type("99", from: backspace(4, from: 1_234)), 99)
    }

    func testEditsAnywhereActAtTheEnd() {
        // A digit typed with the cursor before the decimal point still enters from the right.
        XCTAssertEqual(CentsEntry.cents(editing: "12.34", to: "125.34"), 12_345)
        // Deleting the decimal point drops the last digit, like backspace.
        XCTAssertEqual(CentsEntry.cents(editing: "12.34", to: "1234"), 123)
        // Deleting a selection drops as many digits as it held.
        XCTAssertEqual(CentsEntry.cents(editing: "12.34", to: "1"), 1)
    }

    func testReplacingEverythingStartsOver() {
        XCTAssertEqual(CentsEntry.cents(editing: "12.34", to: "7"), 7)
        XCTAssertEqual(CentsEntry.cents(editing: "12.34", to: ""), 0)
    }

    func testDigitsPastTheLimitAreIgnored() {
        XCTAssertEqual(type("1234567890"), 123_456_789)
        XCTAssertEqual(type("5", from: 999_999_999), 999_999_999)
    }

    func testPastedAmountWithDecimalPointIsReadAsWritten() {
        XCTAssertEqual(CentsEntry.cents(editing: "0.00", to: "0.0012.5"), 1_250)
        XCTAssertEqual(CentsEntry.cents(editing: "0.00", to: "$1,234.56"), 123_456)
        XCTAssertEqual(CentsEntry.cents(editing: "3.00", to: "3.00.99"), 99)
        // A pasted run of digits enters like typing.
        XCTAssertEqual(CentsEntry.cents(editing: "0.00", to: "0.001234"), 1_234)
    }

    func testParseAmount() {
        XCTAssertEqual(CentsEntry.parseAmount("7"), 700)
        XCTAssertEqual(CentsEntry.parseAmount(".5"), 50)
        XCTAssertEqual(CentsEntry.parseAmount("12.345"), 1_234)
        XCTAssertNil(CentsEntry.parseAmount("."))
        XCTAssertNil(CentsEntry.parseAmount("1.2.3"))
        XCTAssertNil(CentsEntry.parseAmount("123456789.00"))
    }
}
