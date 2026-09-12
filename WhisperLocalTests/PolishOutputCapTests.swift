import XCTest

/// The output cap is set from the input's length. Getting it wrong costs the
/// whole cleanup: the model stops mid-sentence and the take is pasted raw.
final class PolishOutputCapTests: XCTestCase {
    func testEnglishGetsRoomToSpare() {
        // ~4 characters per token, so half the characters is about double what
        // the cleaned text needs.
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: String(repeating: "a", count: 2000)), 1000)
    }

    func testKoreanGetsMoreThanHalfItsCharacters() {
        // Roughly a token per syllable: half would be less than the text needs.
        let korean = String(repeating: "가", count: 400)
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: korean), 800)
        XCTAssertGreaterThan(PolishOutput.maxOutputTokens(for: korean), korean.count)
    }

    func testMixedTextCountsEachScript() {
        let mixed = String(repeating: "가", count: 100) + String(repeating: "a", count: 400)
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: mixed), 100 * 2 + 400 / 2)
    }

    func testShortTakesKeepTheFloorAndLongOnesTheCeiling() {
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: "okay"), 256)
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: String(repeating: "한", count: 5000)), 4096)
    }
}
