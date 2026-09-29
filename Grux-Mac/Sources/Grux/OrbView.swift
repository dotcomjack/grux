import SwiftUI

enum GruxOrbState: Equatable, Hashable, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking
    case muted     // The user tapped the orb - mic is explicitly off until they tap again.

    // Colors route through OrbGlowMap (GruxTheme.swift), the single static
    // table that also carries each state's glow-border hue, so the orb and
    // any glow surface mirroring it can never disagree.
    var primary: Color { OrbGlowMap.entry(for: self).primary }
    var secondary: Color { OrbGlowMap.entry(for: self).secondary }
    var label: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .muted: return "muted"
        }
    }
}

/// Animated gradient orb that visualizes Grux's current state.
/// Three layers: soft outer halo, gradient core, inner highlight pulse.
///
/// The halo, highlight and rim are SwiftUI and never move. The turning core and
/// the pulse rings are Core Animation (`OrbLayers.swift`), so an orb left on
/// screen all day costs the main thread nothing per frame.
struct OrbView: View {
    let state: GruxOrbState
    var level: Float = 0 // 0..1 - audio level (for speaking) or mic RMS

    var body: some View {
        ZStack {
            // Outer halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [state.primary.opacity(0.45), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 110
                    )
                )
                .blur(radius: 6)

            // Core gradient, turning on the render server.
            GeometryReader { geo in
                OrbCoreLayer(spec: Self.coreSpec(for: state, diameter: min(geo.size.width, geo.size.height)))
            }
            .scaleEffect(1.0 + Double(level) * 0.12)

            // Inner highlight
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 28, height: 28)
                .offset(x: -10, y: -14)
                .blur(radius: 8)

            // Soft rim
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .clear, .white.opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .blendMode(.overlay)

            // Muted overlay - a clear "mic off" mark so the user sees the tap registered.
            if state == .muted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }

            // Pulse rings when listening/speaking
            if state == .listening || state == .speaking {
                OrbRingsLayer(rings: Self.rings(for: state))
                    .allowsHitTesting(false)
            }
        }
        .animation(MotionTokens.gated(MotionTokens.crossfade), value: state)
    }

    /// The SwiftUI core ran 0 to 113 degrees per `orbRotationPeriod` (phase * 18
    /// with phase 0 to 2 pi). Same angular speed, one seamless full turn.
    static var turnSeconds: Double { MotionTokens.orbRotationPeriod * 360 / (2 * .pi * 18) }

    static func coreSpec(for state: GruxOrbState, diameter: CGFloat) -> OrbCoreSpec {
        let p = NSColor.orb(state.primary), s = NSColor.orb(state.secondary)
        // The mask's endRadius was a fixed 80 points whatever the orb's size,
        // so the fraction of the orb's radius depends on the diameter.
        let radius = max(diameter / 2, 1)
        return OrbCoreSpec(
            colors: [p, s, p.withAlphaComponent(p.alphaComponent * 0.6),
                     s.withAlphaComponent(s.alphaComponent * 0.8), p],
            maskStops: [(1, 0), (0.9, 1.0 / 3), (0.35, 2.0 / 3), (0, 1)],
            maskRadius: 80 / radius,
            turnSeconds: turnSeconds)
    }

    /// The two rings the SwiftUI version drew, at the poses its animation
    /// actually interpolated between (it interpolated the modifier values, so
    /// the second ring's `abs` never folded).
    static func rings(for state: GruxOrbState) -> [OrbRingSpec] {
        let p = NSColor.orb(state.primary), s = NSColor.orb(state.secondary)
        let period = MotionTokens.orbPulsePeriod
        return [
            OrbRingSpec(color: p.withAlphaComponent(p.alphaComponent * 0.5), lineWidth: 1.5,
                        scale: 1.0...1.6, opacity: (1, 0), seconds: period, easeInOut: false),
            OrbRingSpec(color: s.withAlphaComponent(s.alphaComponent * 0.4), lineWidth: 1,
                        scale: 1.315...1.585, opacity: (0.7, 0), seconds: period, easeInOut: false),
        ]
    }
}

/// Status pill shown beside the orb with the text label and a subtle glow.
struct OrbStatusPill: View {
    let state: GruxOrbState
    /// Overrides the word without changing the glow, so a surface can show
    /// ARMED on a listening orb. Nil keeps the state's own label.
    var label: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.primary)
                .frame(width: 6, height: 6)
                .shadow(color: state.primary.opacity(0.8), radius: 4)
            Text((label ?? state.label).uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(1.2)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial).overlay(
                Capsule().stroke(state.primary.opacity(0.35), lineWidth: 0.8)
            )
        )
    }
}
