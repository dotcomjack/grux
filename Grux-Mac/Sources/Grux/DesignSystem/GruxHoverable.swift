import SwiftUI
import AppKit

// Canonical hover affordance for ANY interactive element (plain button, tappable
// row / card / chip / tile, icon button, orb). Signals "this does something"
// with a pointing-hand cursor plus a subtle fill + accent rim + lift, matching
// the proven ReactorPanel / DocumentLibraryView treatment. Honors GruxTheme
// tokens and Reduce Motion (the cursor still changes; the scale animation is
// suppressed). Tint defaults to the live ThemeConfig accent so an accent change
// repaints hover automatically.
//
// Usage presets:
//   icon / utility button : .gruxHoverable(lift: 1, rimOnHover: 0, fillOnHover: 0.10)
//   list / table row       : .gruxHoverable(lift: 1, fillOnHover: 0.05, rimOnHover: 0.2)
//   card / tile            : .gruxHoverable(cornerRadius: GruxTheme.Radius.card)
//   segmented control      : .gruxHoverable(cornerRadius: 8, lift: 1, rimOnHover: 0.35)
//   destructive control    : .gruxHoverable(tint: GruxTheme.destructiveRose)
//
// Do NOT apply to native sidebar List rows or non-.plain native Buttons (they
// already get macOS hover/selection chrome). Scope to .plain buttons,
// .onTapGesture surfaces, chips, tiles, and the orbs.
struct GruxHoverable: ViewModifier {
    var cornerRadius: CGFloat = GruxTheme.Radius.chip
    var tint: Color = GruxTheme.accentPrimary
    var lift: CGFloat = 1.03            // scaleEffect on hover; pass 1 to disable
    var rimOnHover: Double = 0.45       // accent rim opacity at hover; 0 = no rim
    var fillOnHover: Double = 0.06      // white fill delta on hover
    var cursor: Bool = true             // push NSCursor.pointingHand

    @State private var hover = false
    // Balance push/pop even if the view disappears mid-hover (no stuck pointer).
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(hover ? fillOnHover : 0))
            )
            .overlay(
                rimOnHover > 0
                    ? RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(hover ? rimOnHover : 0), lineWidth: 1)
                    : nil
            )
            .scaleEffect((hover && lift != 1 && !GruxTheme.reduceMotion) ? lift : 1.0)
            .animation(GruxTheme.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: hover)
            .onHover { h in
                hover = h
                guard cursor else { return }
                if h { NSCursor.pointingHand.push(); pushed = true }
                else if pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    /// Apply the canonical Grux hover affordance to an interactive element:
    /// pointing-hand cursor + a subtle fill/rim/lift. Keep it next to the
    /// element's Button / .onTapGesture. See GruxHoverable for usage presets.
    func gruxHoverable(cornerRadius: CGFloat = GruxTheme.Radius.chip,
                       tint: Color = GruxTheme.accentPrimary,
                       lift: CGFloat = 1.03,
                       rimOnHover: Double = 0.45,
                       fillOnHover: Double = 0.06,
                       cursor: Bool = true) -> some View {
        modifier(GruxHoverable(cornerRadius: cornerRadius, tint: tint, lift: lift,
                               rimOnHover: rimOnHover, fillOnHover: fillOnHover, cursor: cursor))
    }
}
