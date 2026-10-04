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

final class HUDPositionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 923)
    private let panel = CGSize(width: 700, height: 54)

    private func place(_ position: HUDPosition, reserved: CGFloat = 0, custom: CGPoint? = nil) -> CGPoint {
        HUDPlacement.origin(
            for: position, panelSize: panel, reservedWidth: reserved, custom: custom, in: screen
        )
    }

    func testBottomCentreSitsAboveTheBottomEdge() {
        let p = place(.bottomCentre)
        XCTAssertEqual(p.y, HUDPlacement.verticalInset, accuracy: 0.001)
        XCTAssertEqual(p.x, screen.midX - panel.width / 2, accuracy: 0.001)
    }

    func testTopCentreLeavesRoomForThePanelBelowTheTop() {
        let p = place(.topCentre)
        XCTAssertEqual(p.y, screen.maxY - panel.height - HUDPlacement.verticalInset, accuracy: 0.001)
        XCTAssertEqual(p.x, screen.midX - panel.width / 2, accuracy: 0.001)
    }

    /// The centred positions reserve a width so the row losing its cancel capsule
    /// at insert does not slide the HUD sideways mid-take.
    func testCentredPositionsCentreTheReservedWidthNotTheLiveOne() {
        let p = place(.bottomCentre, reserved: 900)
        XCTAssertEqual(p.x, screen.midX - 450, accuracy: 0.001)
    }

    func testAReservedWidthNarrowerThanThePanelIsIgnored() {
        let p = place(.bottomCentre, reserved: 100)
        XCTAssertEqual(p.x, screen.midX - panel.width / 2, accuracy: 0.001)
    }

    func testCornersSitAtTheHorizontalInset() {
        XCTAssertEqual(place(.bottomLeft).x, HUDPlacement.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(
            place(.bottomRight).x,
            screen.maxX - panel.width - HUDPlacement.horizontalInset,
            accuracy: 0.001
        )
    }

    func testCustomUsesTheDraggedAnchor() {
        let p = place(.custom, custom: CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(p.x, screen.width * 0.25, accuracy: 0.001)
        XCTAssertEqual(p.y, screen.height * 0.5, accuracy: 0.001)
    }

    /// Choosing "Where I drag it" before ever dragging must not drop the HUD in a
    /// corner — there is no anchor to honour, so the default is the honest answer.
    func testCustomWithoutAnAnchorFallsBackToTheDefault() {
        XCTAssertEqual(place(.custom).x, place(.bottomCentre).x, accuracy: 0.001)
        XCTAssertEqual(place(.custom).y, place(.bottomCentre).y, accuracy: 0.001)
    }

    /// A preset on a display too small for the panel still has to land on it.
    func testPresetsStayOnASmallDisplay() {
        let small = CGRect(x: 0, y: 0, width: 640, height: 400)
        let p = HUDPlacement.origin(
            for: .bottomRight, panelSize: panel, reservedWidth: 0, custom: nil, in: small
        )
        XCTAssertEqual(p.x, HUDPlacement.edgeInset, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(p.y, small.minY + HUDPlacement.edgeInset)
    }

    func testEveryPositionHasALabel() {
        for spot in HUDPosition.allCases {
            XCTAssertFalse(spot.label.isEmpty, "\(spot.rawValue) has no label")
        }
    }
}

extension HUDPositionTests {
    /// The corner positions have to hold the left edge still for the same reason
    /// the centred ones do: the row loses its cancel capsule at insert, and pinning
    /// the right edge would throw the left one sideways at that moment.
    func testBottomRightReservesWidthSoTheLeftEdgeHolds() {
        let reserved: CGFloat = 900
        let wide = HUDPlacement.origin(
            for: .bottomRight, panelSize: CGSize(width: 900, height: 54),
            reservedWidth: reserved, custom: nil, in: screen
        )
        let narrow = HUDPlacement.origin(
            for: .bottomRight, panelSize: CGSize(width: 854, height: 54),
            reservedWidth: reserved, custom: nil, in: screen
        )
        XCTAssertEqual(wide.x, narrow.x, accuracy: 0.001)
    }
}
