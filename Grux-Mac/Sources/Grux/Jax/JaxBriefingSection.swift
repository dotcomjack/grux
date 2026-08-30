import SwiftUI

// JaxBriefingSection: today's voice-first briefing (BriefingEngine.shared.latest).
// Jax speaks a morning (7:00 AM) and night (9:00 PM) briefing in the configured
// voice; the transcript and the extracted items land here. The [read aloud] control
// re-speaks the latest transcript through Grux's SpeechEngine (same path the engine
// uses: the configured voice via config.elevenLabsVoiceId, system TTS fallback
// offline), so it can be heard again on demand without firing a fresh briefing.
struct JaxBriefingSection: View {
    let briefing: Briefing?
    let isSpeaking: Bool

    var body: some View {
        JaxSection(
            title: "Today's briefing",
            icon: briefing?.slot.icon ?? "sun.max.fill",
            tint: GruxTheme.accentCo,
            trailing: briefing == nil ? nil : AnyView(readAloudButton)
        ) {
            if let briefing = briefing {
                content(briefing)
            } else {
                JaxEmptyLine(icon: "waveform", text: "No briefing yet today. \(UserIdentity.assistantName) speaks one at \(ClockFormat.hourLabel(7)) and \(ClockFormat.hourLabel(21)).")
            }
        }
    }

    private func content(_ briefing: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: briefing.slot.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GruxTheme.accentCo)
                Text(briefing.slot.kicker)
                    .font(GruxTheme.Font.microCaps).kerning(1.2)
                    .foregroundStyle(GruxTheme.accentCo)
                Text("spoken \(JaxTime.clock(briefing.date))")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
            }

            // Transcript: what Jax said.
            if !briefing.spokenText.isEmpty {
                Text(briefing.spokenText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                            .fill(Color.black.opacity(0.20))
                    )
            }

            if !briefing.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MetaAdsEyebrow(text: "On the radar", tint: GruxTheme.textTertiary)
                    ForEach(briefing.items) { item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: BriefingItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(item.kind.label)
                .font(GruxTheme.Font.microCaps).kerning(0.6)
                .foregroundStyle(GruxTheme.textTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.05)))
        }
    }

    // [read aloud]: re-speak the latest transcript in the configured voice.
    private var readAloudButton: some View {
        Button {
            guard let text = briefing?.spokenText, !text.isEmpty else { return }
            SpeechEngine.shared.speakAfterCurrent(text, maxWaitSeconds: 90)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSpeaking ? "waveform" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(isSpeaking ? "Briefing" : "Read aloud")
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(GruxTheme.iridescent))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))
            .shadow(color: GruxTheme.violetGlow(strong: true), radius: 6)
        }
        .buttonStyle(.plain)
        .disabled(isSpeaking || (briefing?.spokenText.isEmpty ?? true))
        .help("Hear today's briefing again")
    }
}
