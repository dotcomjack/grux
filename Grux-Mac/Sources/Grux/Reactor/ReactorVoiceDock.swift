import SwiftUI

// The persistent bottom dock: a live mirrored waveform bar that reacts to
// the user's mic when listening and to Grux's TTS when speaking, with a single
// caption line above it streaming the latest spoken hint / reply. This is the
// literal hear/speak feedback loop, the highest-impact element of the Reactor.
struct ReactorVoiceDock: View {
    var reduceMotion: Bool = false
    @EnvironmentObject var state: AppState
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var voice = VoiceInput.shared
    @ObservedObject private var bus = ShellStateBus.shared
    @ObservedObject private var hints = OrbHintBus.shared

    private var accent: Color { bus.current.accent }

    private var caption: String {
        if let h = hints.latestHint?.message, !h.isEmpty { return h }
        if let last = state.chat.last(where: { $0.role == .assistant })?.content,
           !last.isEmpty { return last }
        let head = bus.current.headline
        return head.isEmpty ? "Talk to \(UserIdentity.assistantName)" : head
    }

    private var statusLabel: String {
        if speech.isSpeaking || speech.isBuffering { return "SPEAKING" }
        if voice.isRecording { return "LISTENING" }
        if state.isThinking { return "THINKING" }
        return state.micMuted ? "MUTED" : "IDLE"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.8), radius: 5)
                Text(statusLabel)
                    .font(GruxType.microCaps)
                    .foregroundStyle(accent)
                Text(caption)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .animation(.easeInOut(duration: 0.2), value: caption)
                Spacer(minLength: 0)
            }
            waveform
                .frame(height: 44)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(GruxTheme.iridescentRim.opacity(0.45), lineWidth: 1)
                )
        )
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let amp = ReactorSignals.amplitude(
                isSpeaking: speech.isSpeaking, isBuffering: speech.isBuffering,
                outputLevel: speech.outputLevel, isRecording: voice.isRecording,
                liveLevel: voice.liveLevel, t: t)
            Canvas { ctx, size in
                drawBars(ctx, size: size, amp: amp, t: reduceMotion ? 0 : t)
            }
        }
    }

    private func drawBars(_ ctx: GraphicsContext, size: CGSize, amp: Float, t: Double) {
        let barCount = 56
        let gap: CGFloat = 3
        let totalGap = gap * CGFloat(barCount - 1)
        let barW = max(1.5, (size.width - totalGap) / CGFloat(barCount))
        let midY = size.height / 2
        let a = Double(amp)

        for i in 0..<barCount {
            // Bell envelope so the center bars are tallest, plus a per-bar
            // travelling phase so the wave reads as moving energy, not noise.
            let x = CGFloat(i) * (barW + gap)
            let norm = Double(i) / Double(barCount - 1)
            let envelope = sin(norm * .pi)                       // 0 at edges, 1 center
            let travel = sin(t * 7 + norm * 12)                  // moving ripple
            let idle = 0.06 + 0.04 * sin(t * 2 + norm * 6)       // gentle resting shimmer
            let h = max(2.0, (idle + a * envelope * (0.55 + 0.45 * travel)) * Double(size.height))
            let rect = CGRect(x: x, y: midY - CGFloat(h) / 2, width: barW, height: CGFloat(h))
            let opacity = 0.45 + 0.5 * envelope
            ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                     with: .color(accent.opacity(opacity)))
        }
    }
}
