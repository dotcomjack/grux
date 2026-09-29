import AppKit

enum FocusOverlaySide: String, Codable { case left, right }
enum FocusOverlayVerticalHalf: String, Codable { case top, bottom }

/// Where the focus card sits and how it moves between its two sizes. Pure
/// geometry so a test can pin it: the card keeps the corner nearest the
/// screen edge fixed when it collapses to the orb or expands back, so the
/// orb lands where the card's outer corner was instead of drifting to the
/// middle of an invisible box; a drag that ends near an edge settles onto the
/// inset; and nothing ever comes to rest off screen.
enum FocusOverlayPlacement {
    static let inset: CGFloat = 16
    static let snapThreshold: CGFloat = 36

    static func side(of frame: NSRect, in visible: NSRect) -> FocusOverlaySide {
        frame.midX < visible.midX ? .left : .right
    }

    static func verticalHalf(of frame: NSRect, in visible: NSRect) -> FocusOverlayVerticalHalf {
        frame.midY < visible.midY ? .bottom : .top
    }

    /// The frame for `size` that keeps the outer corner of `old` fixed, then
    /// pulled inside `visible`.
    static func frame(for size: NSSize, keepingAnchorOf old: NSRect, in visible: NSRect) -> NSRect {
        let s = side(of: old, in: visible)
        let v = verticalHalf(of: old, in: visible)
        let x = s == .right ? old.maxX - size.width : old.minX
        let y = v == .top ? old.maxY - size.height : old.minY
        return clamped(NSRect(x: x, y: y, width: size.width, height: size.height), in: visible)
    }

    static func clamped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX + inset), max(visible.minX + inset, visible.maxX - inset - f.width))
        f.origin.y = min(max(f.origin.y, visible.minY + inset), max(visible.minY + inset, visible.maxY - inset - f.height))
        return f
    }

    /// Each axis settles onto the inset when it stopped within the threshold
    /// of that edge; otherwise it stays where the person left it.
    static func snapped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var f = clamped(frame, in: visible)
        if abs(f.minX - (visible.minX + inset)) <= snapThreshold { f.origin.x = visible.minX + inset }
        else if abs(f.maxX - (visible.maxX - inset)) <= snapThreshold { f.origin.x = visible.maxX - inset - f.width }
        if abs(f.minY - (visible.minY + inset)) <= snapThreshold { f.origin.y = visible.minY + inset }
        else if abs(f.maxY - (visible.maxY - inset)) <= snapThreshold { f.origin.y = visible.maxY - inset - f.height }
        return f
    }

    /// The frame that puts a card of `size` in the named corner.
    static func frame(for size: NSSize, side: FocusOverlaySide, vertical: FocusOverlayVerticalHalf, in visible: NSRect) -> NSRect {
        let x = side == .right ? visible.maxX - inset - size.width : visible.minX + inset
        let y = vertical == .top ? visible.maxY - inset - size.height : visible.minY + inset
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
