import SwiftUI

// The same decision stream the ambient HUD carries, in the one place a person
// is already looking. It answers the question that made Grux feel broken:
// "did it hear me, and did it decide I was talking to it?"
//
// It is a rail, not a log. Nothing renders until Grux has decided something
// recently, and nothing renders at all when listening is off, so a person who
// never turns listening on never sees it.

/// Pure selection rules, so what the rail shows can be tested without a view.
enum VoiceLiveRailModel {
    /// How far back the rail looks. Older than this and the decision has
    /// stopped being "live" and belongs to the HUD's history instead.
    static let window: TimeInterval = 5 * 60
    static let collapsedCount = 1
    static let expandedCount = 6

    static func visible(events: [VoiceDecisionEvent],
                        tell: ListeningTell,
                        expanded: Bool,
                        now: Date = Date()) -> [VoiceDecisionEvent] {
        // Listening off means there is no stream. Muted is different: the
        // person muted a second ago and the last thing Grux did is exactly
        // what they want to see.
        guard tell != .off else { return [] }
        let live = events.filter { now.timeIntervalSince($0.at) <= window }
        return Array(live.suffix(expanded ? expandedCount : collapsedCount).reversed())
    }

    /// How many more there are behind the collapsed row.
    static func hiddenCount(events: [VoiceDecisionEvent], tell: ListeningTell, now: Date = Date()) -> Int {
        let all = visible(events: events, tell: tell, expanded: true, now: now).count
        return max(0, all - collapsedCount)
    }
}

struct VoiceLiveRail: View {
    @ObservedObject private var router = VoiceCommandRouter.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var speech = SpeechEngine.shared
    /// Changes only when hearing starts or stops, never at audio rate.
    @ObservedObject private var micHealth = MicHealth.shared
    @State private var expanded = false
    /// Re-renders the relative ages without each row owning a timer.
    @State private var tick = Date()

    private var tell: ListeningTell {
        ListeningTell.resolve(mode: state.config.listeningModeInEffect,
                              micMuted: state.micMuted,
                              isSpeaking: speech.isSpeaking || speech.isBuffering,
                              isThinking: state.isThinking,
                              notHearing: micHealth.notHearing)
    }

    private var rows: [VoiceDecisionEvent] {
        VoiceLiveRailModel.visible(events: router.events, tell: tell, expanded: expanded, now: tick)
    }

    var body: some View {
        let hidden = VoiceLiveRailModel.hiddenCount(events: router.events, tell: tell, now: tick)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row(for: $0) }
            }
            .padding(.horizontal, GruxSpacing.l)
            .padding(.vertical, GruxSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
            .overlay(alignment: .topTrailing) {
                if hidden > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Less" : "\(hidden) more")
                            .font(GruxTheme.Font.microCaps)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, GruxSpacing.l)
                    .padding(.vertical, GruxSpacing.s)
                }
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { tick = $0 }
        }
    }

    private func row(for event: VoiceDecisionEvent) -> some View {
        let tone = event.tone
        return HStack(spacing: 8) {
            Circle().fill(tone.color).frame(width: 5, height: 5)
            Text(event.heardLine)
                .font(.caption)
                .foregroundStyle(tone == .chatter ? GruxTheme.textTertiary : GruxTheme.textPrimary)
                .lineLimit(1)
            Text(event.actionLine)
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(tone.color)
                .lineLimit(1)
            if !event.latencyLine.isEmpty {
                Text(event.latencyLine)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
