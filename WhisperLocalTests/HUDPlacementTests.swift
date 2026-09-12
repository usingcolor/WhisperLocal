import CoreGraphics
import XCTest

final class HUDPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)
    private let panel = CGSize(width: 640, height: 76)

    func testAnchorRoundTripsBackToTheSameOrigin() {
        let origin = CGPoint(x: 300, y: 120)
        let anchor = HUDPlacement.anchor(forOrigin: origin, in: screen)
        let back = HUDPlacement.origin(forAnchor: try! XCTUnwrap(anchor), panelSize: panel, in: screen)
        XCTAssertEqual(back.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(back.y, origin.y, accuracy: 0.001)
    }

    /// The anchor is a fraction, so the same drag lands in the same relative spot
    /// on a display of a different size rather than at the same pixel.
    func testAnchorScalesToADifferentDisplay() {
        let anchor = try! XCTUnwrap(HUDPlacement.anchor(forOrigin: CGPoint(x: 756, y: 450), in: screen))
        let larger = CGRect(x: 0, y: 0, width: 3024, height: 1800)
        let placed = HUDPlacement.origin(forAnchor: anchor, panelSize: panel, in: larger)
        XCTAssertEqual(placed.x, 1512, accuracy: 0.001)
        XCTAssertEqual(placed.y, 900, accuracy: 0.001)
    }

    /// A saved anchor from a big display must not strand the HUD off the edge of a
    /// small one, where there would be no way to drag it back.
    func testAnchorFromALargerDisplayIsPulledBackOnScreen() {
        let anchor = CGPoint(x: 0.95, y: 0.98)
        let placed = HUDPlacement.origin(forAnchor: anchor, panelSize: panel, in: screen)
        XCTAssertEqual(placed.x, screen.maxX - panel.width - HUDPlacement.edgeInset, accuracy: 0.001)
        XCTAssertEqual(placed.y, screen.maxY - panel.height - HUDPlacement.edgeInset, accuracy: 0.001)
    }

    func testOriginIsNeverPushedPastTheLeftOrBottomEdge() {
        let placed = HUDPlacement.origin(forAnchor: CGPoint(x: -0.5, y: -0.5), panelSize: panel, in: screen)
        XCTAssertEqual(placed.x, HUDPlacement.edgeInset, accuracy: 0.001)
        XCTAssertEqual(placed.y, HUDPlacement.edgeInset, accuracy: 0.001)
    }

    /// A row wider than the screen has nowhere to fit. Keeping its left edge on
    /// screen shows the status text; keeping the right edge would show the end of
    /// the row and hide what the HUD is for.
    func testARowWiderThanTheScreenKeepsItsLeftEdgeVisible() {
        let tooWide = CGSize(width: 2000, height: 76)
        let placed = HUDPlacement.clamp(CGPoint(x: 400, y: 48), panelSize: tooWide, in: screen)
        XCTAssertEqual(placed.x, HUDPlacement.edgeInset, accuracy: 0.001)
    }

    /// A screen with no area is what `visibleFrame` reports for a display being
    /// torn down; dividing by it would store NaN and lose the position for good.
    func testAnchorRefusesAnEmptyScreen() {
        XCTAssertNil(HUDPlacement.anchor(forOrigin: .zero, in: .zero))
        XCTAssertNil(HUDPlacement.anchor(forOrigin: .zero, in: CGRect(x: 0, y: 0, width: 1512, height: 0)))
    }

    /// An origin offset screen (a second display to the left of the main one) has a
    /// negative minX, and the anchor has to be relative to it, not to zero.
    func testAnchorIsRelativeToAnOffsetScreen() {
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let anchor = try! XCTUnwrap(HUDPlacement.anchor(forOrigin: CGPoint(x: -960, y: 108), in: secondary))
        XCTAssertEqual(anchor.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(anchor.y, 0.1, accuracy: 0.001)
    }
}
