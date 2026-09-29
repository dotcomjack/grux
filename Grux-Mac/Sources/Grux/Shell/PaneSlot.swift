import SwiftUI

/// The Command Panel's column container, for the pane and the panel alike.
/// It takes exactly the width the shell offers, never the width its surface
/// asks for, pins the surface to its top-leading corner, and clips to its
/// own bounds.
///
/// Why all three. A plain flexible frame reports its CHILD's width when the
/// child is wider than the offer, and SwiftUI centres an oversized child, so a
/// surface built for the classic sidebar's wide detail area spilled past BOTH
/// edges of the pane: measured at an 820pt window, Settings drew its search
/// field over the panel column and cut its toggles off at the window edge.
/// Taking the offer makes the shell's arithmetic hold whatever a surface
/// demands; the top-leading anchor means residual overflow can only run
/// toward the trailing edge; the clip means it never draws outside the pane.
///
/// This is the safety net, not the fix. Every surface is still meant to fit
/// the width it is offered, and PaneFitSweepTests fails when one does not.
struct PaneSlot: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: Self.taken(proposal.width, else: child.width),
                      height: Self.taken(proposal.height, else: child.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    /// The offered length when there is a finite one, the child's otherwise:
    /// an ideal-size pass (nil) or an unbounded one still learns what the
    /// surface would like.
    static func taken(_ offered: CGFloat?, else child: CGFloat) -> CGFloat {
        guard let offered, offered.isFinite else { return child }
        return offered
    }
}

extension View {
    /// Takes exactly the offered size and draws nowhere else: see `PaneSlot`.
    func containedInOffer() -> some View {
        PaneSlot { self }.clipped()
    }
}
