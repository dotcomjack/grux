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
struct OrbView: View {
    let state: GruxOrbState
    var level: Float = 0 // 0..1 - audio level (for speaking) or mic RMS

    @State private var phase: Double = 0
    @State private var pulse: Double = 0

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
                .scaleEffect(1.0 + 0.08 * sin(phase * 1.5))
                .blur(radius: 6)

            // Core gradient
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            state.primary,
                            state.secondary,
                            state.primary.opacity(0.6),
                            state.secondary.opacity(0.8),
                            state.primary
                        ],
                        center: .center
                    )
                )
                .rotationEffect(.degrees(phase * 18))
                .mask(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white, .white.opacity(0.9), .white.opacity(0.35), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                )
                .scaleEffect(1.0 + Double(level) * 0.12 + 0.02 * sin(phase * 3))

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
                Circle()
                    .stroke(state.primary.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(1.0 + pulse * 0.6)
                    .opacity(1.0 - pulse)
                Circle()
                    .stroke(state.secondary.opacity(0.4), lineWidth: 1)
                    .scaleEffect(1.0 + (pulse - 0.35).magnitude * 0.9)
                    .opacity(max(0, 0.7 - pulse))
            }
        }
        .onAppear { startAnimating() }
        .onChange(of: state) { _, _ in startAnimating() }
        .animation(MotionTokens.gated(MotionTokens.crossfade), value: state)
    }

    private func startAnimating() {
        // Appearance: decorative-motion opt-out. Freeze the rotation and
        // pulse at rest; state colors still swap, just without the crossfade.
        guard !GruxTheme.reduceMotion else {
            phase = 0
            pulse = 0
            return
        }
        withAnimation(.linear(duration: MotionTokens.orbRotationPeriod).repeatForever(autoreverses: false)) {
            phase = 2 * .pi
        }
        withAnimation(.easeOut(duration: MotionTokens.orbPulsePeriod).repeatForever(autoreverses: false)) {
            pulse = 1
        }
    }
}

/// Status pill shown beside the orb with the text label and a subtle glow.
struct OrbStatusPill: View {
    let state: GruxOrbState
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.primary)
                .frame(width: 6, height: 6)
                .shadow(color: state.primary.opacity(0.8), radius: 4)
            Text(state.label.uppercased())
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
