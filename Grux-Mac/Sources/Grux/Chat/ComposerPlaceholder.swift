import SwiftUI

/// The one line that tells a person the thing that is new about 3.0. It is
/// honest about the microphone, because inviting someone to speak to a Mac
/// that is not listening is a lie they only discover by trying.
enum ComposerPlaceholder {
    static func text(for tell: ListeningTell) -> String {
        switch tell {
        case .armed, .speaking, .thinking:
            return "Ask me anything, or just say it out loud"
        case .muted:
            return "Ask me anything. Your microphone is muted"
        case .off:
            return "Ask me anything. Turn on listening in Tuning to just say it"
        case .notHearing:
            return "Ask me anything. Grux can't hear your microphone right now"
        case .waiting:
            return "Ask me anything. Allow listening to just say it"
        }
    }
}

/// Whether the composer may send, for the Send button and the Return key
/// alike. Return once skipped the readiness the button checks, so a person
/// with no model attached pressed Return and got a provider error for a turn
/// that could never succeed (PR 34 review).
enum ChatComposerSend {
    static func allowed(draft: String, hasImage: Bool, readiness: ChatReadiness) -> Bool {
        guard readiness.canSend else { return false }
        return hasImage || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the composer says when Return was held back by readiness: the
    /// reason, in the readiness notice's own words. Nil when chat can send.
    /// What VoiceOver reads for the voice chip: its state in words, and who
    /// speaks, which the chip shows only on hover.
    static func voiceChipLabel(state: String, vendor: String) -> String {
        "Grux's voice, \(state.lowercased()), by \(vendor)"
    }

    static func refusal(_ readiness: ChatReadiness) -> String? {
        readiness.canSend ? nil : "Not sent: \(readiness.headline.prefix(1).lowercased() + readiness.headline.dropFirst())."
    }
}

/// What Grux's voice is doing, which is a state, unlike the vendor that
/// produces it. Replaces the chip that read ELEVEN LABS or SYSTEM TTS.
///
/// It names the REPLIES, never just "VOICE": beside "MIC MUTED" with the
/// microphone declined, "VOICE ON" read as voice input being on (W4 pass 2,
/// screen 86). It is Grux reading its replies aloud, which needs no microphone,
/// and every state still names its noun: the reply.
struct VoiceStateChip: Equatable {
    let label: String
    let icon: String
    let accent: Color

    static func resolve(speakRepliesAloud: Bool, muted: Bool, isSpeaking: Bool) -> VoiceStateChip {
        if !speakRepliesAloud {
            return VoiceStateChip(label: "REPLIES SILENT", icon: "speaker.slash",
                                  accent: GruxTheme.textTertiary)
        }
        if muted {
            return VoiceStateChip(label: "REPLIES MUTED", icon: "speaker.slash.fill",
                                  accent: GruxTheme.destructiveRose)
        }
        if isSpeaking {
            return VoiceStateChip(label: "SPEAKING REPLY", icon: "speaker.wave.2.fill",
                                  accent: GruxTheme.accentCo)
        }
        return VoiceStateChip(label: "REPLIES ALOUD", icon: "speaker.wave.2",
                              accent: GruxTheme.accentCo)
    }
}
