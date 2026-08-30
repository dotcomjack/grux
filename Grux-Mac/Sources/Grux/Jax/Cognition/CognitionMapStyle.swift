import SwiftUI

// CognitionMapStyle: view-layer glue for the Cognition Map. Holds the presentation
// extensions on the sibling CognitionTrace types (CognitionEvent.Kind, the gate
// verdict label), the confidence formatters/tints, and the small reusable chips
// and cards. It references the published CognitionTrace types; it does NOT redefine
// them. Zero em/en dashes, GruxTheme tokens only.

// MARK: - CognitionEvent.Kind presentation

extension CognitionEvent.Kind {
    var label: String {
        switch self {
        case .prompt:    return "PROMPT"
        case .directive: return "DIRECTIVE"
        case .task:      return "TASK"
        case .goalCycle: return "GOAL CYCLE"
        }
    }

    var icon: String {
        switch self {
        case .prompt:    return "bubble.left.fill"
        case .directive: return "arrow.turn.down.right"
        case .task:      return "checklist"
        case .goalCycle: return "moon.stars.fill"
        }
    }

    var tint: Color {
        switch self {
        case .prompt:    return GruxTheme.accentCo
        case .directive: return GruxTheme.accentPrimaryLight
        case .task:      return GruxTheme.warnAmber
        case .goalCycle: return GruxTheme.successMint
        }
    }
}

// MARK: - Confidence + verdict formatting

enum CognitionFormat {
    // Confidence is a real 0..1 score the trace computed (heuristic hits, memory
    // depth, gate clarity). Rendered as a whole-percent.
    static func pct(_ x: Double) -> String {
        let clamped = max(0, min(1, x))
        return "\(Int((clamped * 100).rounded()))%"
    }

    // Green = confident, amber = middling, rose = low (paused to clarify).
    static func confidenceTint(_ x: Double) -> Color {
        if x <= 0 { return GruxTheme.textTertiary }
        if x >= 0.66 { return GruxTheme.successMint }
        if x >= 0.40 { return GruxTheme.warnAmber }
        return GruxTheme.destructiveRose
    }

    // Map the persisted gate-verdict string to a short label + tint + icon. The
    // trace stores the verdict as one of: "proceed", "queued", "refused",
    // "clarify" (the pause-and-ask low-confidence path). Unknown strings pass
    // through verbatim so we never hide what really happened.
    static func verdict(_ raw: String) -> (label: String, tint: Color, icon: String) {
        switch raw.lowercased() {
        case "proceed", "allow", "allowed":
            return ("Proceeded", GruxTheme.successMint, "checkmark.circle.fill")
        case "queued", "queueforapproval", "approval":
            return ("Queued for approval", GruxTheme.warnAmber, "tray.and.arrow.down.fill")
        case "refused", "refuse", "blocked", "deny", "denied":
            return ("Refused (hard guardrail)", GruxTheme.destructiveRose, "hand.raised.fill")
        case "clarify", "paused", "ask", "pauseandask":
            return ("Paused to clarify", GruxTheme.warnAmber, "questionmark.bubble.fill")
        case "":
            return ("No gated action", GruxTheme.textTertiary, "minus.circle")
        default:
            return (raw, GruxTheme.textSecondary, "circle.fill")
        }
    }

    static func ms(_ seconds: Double) -> String {
        if seconds <= 0 { return "" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }
}

// MARK: - Confidence meter (a thin 0..1 bar)

struct CognitionConfidenceMeter: View {
    // Optional: nil means there is NO real confidence signal for this decision
    // (a plain chat-completion trace, or a goal cycle with no planner verdict).
    // The meter renders that honestly as "n/a" with no filled bar, rather than
    // inventing a percentage. A value is a real 0..1 ConfidenceGate score.
    let value: Double?
    var compact: Bool = false

    var body: some View {
        if let value = value {
            let clamped = max(0, min(1, value))
            let tint = CognitionFormat.confidenceTint(clamped)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                if !compact {
                    HStack(spacing: 4) {
                        Text("CONFIDENCE")
                            .font(GruxTheme.Font.microCaps).kerning(1.0)
                            .foregroundStyle(GruxTheme.textTertiary)
                        Spacer(minLength: 0)
                        Text(CognitionFormat.pct(clamped))
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(tint)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * clamped))
                    }
                }
                .frame(height: compact ? 4 : 6)
            }
        } else {
            // Honest "no signal" state. No bar, no number, no fabrication.
            HStack(spacing: 4) {
                Text("CONFIDENCE")
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer(minLength: 0)
                Text("n/a")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
    }
}

// MARK: - Kind chip

struct CognitionKindChip: View {
    let kind: CognitionEvent.Kind
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon).font(.system(size: 8, weight: .bold))
            Text(kind.label).font(GruxTheme.Font.microCaps).kerning(0.8)
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(kind.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(kind.tint.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Stat card (rollup tiles)

struct CognitionStatCard: View {
    let value: String
    let label: String
    let tint: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(label.uppercased())
                .font(GruxTheme.Font.microCaps).kerning(0.8)
                .foregroundStyle(GruxTheme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Pill list of fired heuristics / retrieved memories

struct CognitionTagFlow: View {
    let icon: String
    let title: String
    let items: [String]
    let tint: Color
    var cap: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(title.uppercased())
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
                Text("\(items.count)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint)
            }
            // Simple wrapping pill layout via a left-aligned flow.
            CognitionWrap(spacing: 5, lineSpacing: 5) {
                ForEach(Array(items.prefix(cap).enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(tint.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
                }
                if items.count > cap {
                    Text("+\(items.count - cap) more")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Lightweight wrapping layout (no external deps, macOS 14 Layout API)

struct CognitionWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
