import SwiftUI

// Full-screen cinematic view. Semi-transparent radial backdrop, giant orb,
// a single hero line of text, and a faint hint that a click dismisses.
// Animates in with a quick fade+scale, stays put while the StageController
// counts down, then the controller cross-fades out.
struct StageView: View {
    let message: String
    let state: GruxOrbState
    let onTap: () -> Void

    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: GruxSpacing.xl) {
                OrbView(state: state, level: 0)
                    .frame(width: 220, height: 220)
                    .scaleEffect(hasAppeared ? 1.0 : 0.85)
                    .shadow(color: state.primary.opacity(0.45), radius: 40)

                Text(message)
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .padding(.horizontal, 80)
                    .opacity(hasAppeared ? 1.0 : 0.0)

                Text("click anywhere to dismiss")
                    .font(.caption2.monospaced())
                    .kerning(1.8)
                    .foregroundStyle(.white.opacity(0.35))
                    .opacity(hasAppeared ? 1.0 : 0.0)
            }
        }
        .opacity(hasAppeared ? 1.0 : 0.0)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onAppear {
            // Appearance: decorative-motion opt-out skips the fade+scale in.
            if GruxTheme.reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(MotionTokens.easeOutSlow) { hasAppeared = true }
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            // Dim layer so whatever's behind the stage recedes.
            Color.black.opacity(0.55)

            // Soft radial wash in the current orb color to frame the hero.
            RadialGradient(
                colors: [
                    state.primary.opacity(0.35),
                    state.secondary.opacity(0.20),
                    .clear
                ],
                center: .center,
                startRadius: 60,
                endRadius: 720
            )
            .blur(radius: 40)
        }
    }
}
