import XCTest

final class FocusedWindowTitleTests: XCTestCase {
    func testKeepsOneTrimmedLine() {
        XCTAssertEqual(
            FocusedWindowTitle.clean("  QuillMate draft\n — Overleaf\t "),
            "QuillMate draft — Overleaf"
        )
    }

    func testDropsAnEmptyTitle() {
        XCTAssertNil(FocusedWindowTitle.clean(" \n\t "))
    }

    func testCapsALongTitle() {
        let title = FocusedWindowTitle.clean(String(repeating: "a", count: 500))
        XCTAssertEqual(title?.count, FocusedWindowTitle.maxLength)
        XCTAssertEqual(title?.last, "…")
    }
}
