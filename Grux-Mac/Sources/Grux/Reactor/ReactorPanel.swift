import SwiftUI
import AppKit

// One holographic telemetry panel for the Reactor deck: a glass card with HUD
// corner brackets, a kicker label, a big live value, a sub-line, and an optional
// pacing micro-bar. Static (no per-frame work) so six of them cost nothing; the
// only motion is a cheap hover lift. Every value is passed in from a real store
// by ReactorView, so a panel is honest-empty (dimmed) when its store has nothing.
struct ReactorPanel: View {
    let icon: String
    let title: String
    let value: String
    let sub: String
    let tint: Color
    var pacing: Double? = nil      // optional 0...1 micro-bar
    var dim: Bool = false
    var onTap: (() -> Void)? = nil

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(dim ? GruxTheme.textTertiary : tint)
                Text(title)
                    .font(GruxType.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(dim ? GruxTheme.textTertiary : GruxTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let p = pacing, !dim {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(tint.opacity(0.9))
                            .frame(width: max(3, g.size.width * CGFloat(min(1, max(0, p)))))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
            }
        }
        .padding(11)
        .frame(width: 196, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(hover ? 0.10 : 0.04))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(GruxTheme.iridescentRim.opacity(hover ? 0.7 : 0.4), lineWidth: 1)
        )
        .overlay(CornerBrackets(tint: dim ? GruxTheme.textTertiary : tint).opacity(0.8))
        .shadow(color: tint.opacity(hover ? 0.35 : 0.0), radius: 12)
        .scaleEffect(hover ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { hovering in
            hover = hovering
            if onTap != nil {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .help(onTap == nil ? "" : "Open \(title.capitalized)")
    }
}

// Four L-shaped HUD corner marks drawn in one Canvas, the classic targeting
// reticle tell that makes a plain card read as an instrument readout.
private struct CornerBrackets: View {
    let tint: Color
    var len: CGFloat = 9
    var inset: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let c = ctx
            func bracket(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: p.x + dx * len, y: p.y))
                path.addLine(to: p)
                path.addLine(to: CGPoint(x: p.x, y: p.y + dy * len))
                c.stroke(path, with: .color(tint.opacity(0.85)), lineWidth: 1.2)
            }
            bracket(CGPoint(x: inset, y: inset), 1, 1)
            bracket(CGPoint(x: size.width - inset, y: inset), -1, 1)
            bracket(CGPoint(x: inset, y: size.height - inset), 1, -1)
            bracket(CGPoint(x: size.width - inset, y: size.height - inset), -1, -1)
        }
        .allowsHitTesting(false)
    }
}
