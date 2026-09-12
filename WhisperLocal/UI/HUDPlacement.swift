import CoreGraphics

/// Where a dragged HUD sits, and how it gets back to a point on screen.
///
/// Kept free of AppKit so it can be tested: the panel is only on screen for a few
/// seconds at a time, which makes this exactly the sort of arithmetic that is
/// miserable to check by hand.
enum HUDPlacement {
    /// The panel's left and bottom edges as fractions of the visible frame, so a
    /// position survives a resolution change or a move to a different display.
    /// Left and bottom because those are the two edges the user actually placed —
    /// the row still grows to the right from wherever they left it.
    static func anchor(forOrigin origin: CGPoint, in visibleFrame: CGRect) -> CGPoint? {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        return CGPoint(
            x: (origin.x - visibleFrame.minX) / visibleFrame.width,
            y: (origin.y - visibleFrame.minY) / visibleFrame.height
        )
    }

    /// Clamped so the panel always lands fully on screen — a display that shrinks
    /// under a saved anchor, or one swapped for a smaller one, must not strand the
    /// HUD off the edge with no way to drag it back.
    static func origin(forAnchor anchor: CGPoint, panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        clamp(
            CGPoint(
                x: visibleFrame.minX + anchor.x * visibleFrame.width,
                y: visibleFrame.minY + anchor.y * visibleFrame.height
            ),
            panelSize: panelSize,
            in: visibleFrame
        )
    }

    /// A panel wider than the screen has nowhere to go, and `max` winning over
    /// `min` here is what keeps its left edge on screen rather than its right.
    static func clamp(_ origin: CGPoint, panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX + edgeInset, min(origin.x, visibleFrame.maxX - panelSize.width - edgeInset)),
            y: max(visibleFrame.minY + edgeInset, min(origin.y, visibleFrame.maxY - panelSize.height - edgeInset))
        )
    }

    static let edgeInset: CGFloat = 8
    /// Where the HUD sits when nobody has moved it: clear of the Dock, which
    /// `visibleFrame` has already taken out.
    static let defaultBottomInset: CGFloat = 48
}
