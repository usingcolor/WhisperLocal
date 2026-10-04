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

/// Where the HUD sits. Presets for people who want it in one place, and `custom`
/// for the position they dragged it to.
enum HUDPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomCentre
    case topCentre
    case bottomLeft
    case bottomRight
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCentre: return "Bottom centre"
        case .topCentre: return "Top centre"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .custom: return "Where I drag it"
        }
    }
}

extension HUDPlacement {
    /// Clear of the Dock at the bottom and the menu bar at the top — `visibleFrame`
    /// has already taken both out, so this is breathing room rather than clearance.
    static let verticalInset: CGFloat = 48
    /// Nearer the edge than the vertical inset, because a HUD pinned to a corner
    /// reads as pinned; 48 there would look like it had missed.
    static let horizontalInset: CGFloat = 24

    static func origin(
        for position: HUDPosition,
        panelSize: CGSize,
        reservedWidth: CGFloat,
        custom: CGPoint?,
        in visibleFrame: CGRect
    ) -> CGPoint {
        switch position {
        case .custom:
            // Selected before anything was ever dragged: the default is a better
            // answer than the top-left corner an absent anchor would give.
            guard let custom else {
                return origin(
                    for: .bottomCentre, panelSize: panelSize,
                    reservedWidth: reservedWidth, custom: nil, in: visibleFrame
                )
            }
            return origin(forAnchor: custom, panelSize: panelSize, in: visibleFrame)

        case .bottomCentre, .topCentre:
            // Centre the reserved width, not this phase's: the row still loses the
            // cancel capsule at insert, and centring the live width would shift the
            // HUD at that moment.
            let reserved = max(reservedWidth, panelSize.width)
            let x = visibleFrame.midX - reserved / 2
            let y = position == .topCentre
                ? visibleFrame.maxY - panelSize.height - verticalInset
                : visibleFrame.minY + verticalInset
            return clamp(CGPoint(x: x, y: y), panelSize: panelSize, in: visibleFrame)

        case .bottomLeft:
            return clamp(
                CGPoint(x: visibleFrame.minX + horizontalInset, y: visibleFrame.minY + verticalInset),
                panelSize: panelSize, in: visibleFrame
            )

        case .bottomRight:
            // The reserved width again, for the same reason the centred positions
            // use it: the row loses its cancel capsule at insert, and measuring
            // from the live width would pin the right edge and throw the left one
            // 46pt sideways at that moment. Reserving holds the left edge still and
            // lets the row shrink away from the screen edge instead.
            let reserved = max(reservedWidth, panelSize.width)
            return clamp(
                CGPoint(
                    x: visibleFrame.maxX - reserved - horizontalInset,
                    y: visibleFrame.minY + verticalInset
                ),
                panelSize: panelSize, in: visibleFrame
            )
        }
    }
}
