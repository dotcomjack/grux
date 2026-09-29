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
        }
    }
}

/// What Grux's voice is doing, which is a state, unlike the vendor that
/// produces it. Replaces the chip that read ELEVEN LABS or SYSTEM TTS.
struct VoiceStateChip: Equatable {
    let label: String
    let icon: String
    let accent: Color

    static func resolve(speakRepliesAloud: Bool, muted: Bool, isSpeaking: Bool) -> VoiceStateChip {
        if !speakRepliesAloud {
            return VoiceStateChip(label: "VOICE OFF", icon: "speaker.slash",
                                  accent: GruxTheme.textTertiary)
        }
        if muted {
            return VoiceStateChip(label: "MUTED", icon: "speaker.slash.fill",
                                  accent: GruxTheme.destructiveRose)
        }
        if isSpeaking {
            return VoiceStateChip(label: "SPEAKING", icon: "speaker.wave.2.fill",
                                  accent: GruxTheme.accentCo)
        }
        return VoiceStateChip(label: "WILL SPEAK", icon: "speaker.wave.2",
                              accent: GruxTheme.accentCo)
    }
}
