import SwiftUI

/// A vendor name is true, and it is not the point.
///
/// The 3.0 design keeps vendor names and shrinks them: one size smaller,
/// collapsing to a small "ai" glyph that expands on hover. One component,
/// reused wherever a vendor shows, so there is one answer to how prominent a
/// supplier is rather than one answer per surface.
///
/// Deliberately small. It takes a name and renders it, and that is all.
struct VendorGlyph: View {
    let vendor: String
    @State private var hovering = false

    /// The collapsed glyph. Lowercase on purpose: it is a mark, not a word.
    static let collapsed = "ai"

    var body: some View {
        Text(hovering ? vendor : Self.collapsed)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(GruxTheme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            // A glyph nobody can read is worse than the word, so the name is
            // always available to VoiceOver and to a tooltip.
            .accessibilityLabel(vendor)
            .help(vendor)
    }
}
