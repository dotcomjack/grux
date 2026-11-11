import SwiftUI
import GruxShellCore

// MARK: - Pure engine-selection logic (testable, no UI)

/// Mirrors the gating SpeechEngine.speak() applies at runtime (SpeechEngine.swift,
/// the `useEL` check): ElevenLabs only plays when the toggle is on AND a key is
/// present AND we are not in offline mode. Kept as a pure function so the
/// Settings readout can never drift from a hand-written copy of that logic,
/// and so it is unit-testable without touching AppState or the keychain.
enum VoiceEngineLogic {

    enum EffectiveTTS: Equatable {
        case elevenLabs
        /// System AVSpeechSynthesizer voice. `reason` is non-nil when the user
        /// picked ElevenLabs but runtime conditions force the fallback.
        case system(fallbackReason: String?)
        /// `~/.grux/SILENT` or `~/.grux/HEADLESS` is present (`AudioOutput.silencedBy`), so
        /// no voice plays whatever the engine (D115 item 3). Asked first, because the
        /// Voice pane said "Active: system voice" in green on a Mac that spoke nothing.
        case silenced(by: [String])
    }

    /// `silencedBy` has no default on purpose: every readout passes `AudioOutput.silencedBy`
    /// (`VoiceSilencedReadoutTests`), so none can promise a voice the facade holds back.
    static func effectiveTTS(useElevenLabs: Bool, hasKey: Bool, offline: Bool, wouldAskForMic: Bool, silencedBy: [String]) -> EffectiveTTS {
        if !silencedBy.isEmpty { return .silenced(by: silencedBy) }
        guard useElevenLabs else { return .system(fallbackReason: nil) }
        if offline { return .system(fallbackReason: "offline mode forces the on-device voice") }
        if !hasKey { return .system(fallbackReason: "no ElevenLabs API key saved") }
        if wouldAskForMic { return .system(fallbackReason: Self.micReason) }
        return .elevenLabs
    }

    /// The engine plays the macOS voice until the microphone question is answered
    /// (`SpeechEngine.speaksWithElevenLabs`).
    static let micReason = "the microphone question is not answered yet"

    /// The Voice pane's status line while silenced, naming the files through
    /// `ShellSilence.note` as every refusal does.
    static func silencedLine(_ files: [String]) -> String {
        "Silent\(ShellSilence.note(files)): Grux speaks nothing aloud and logs each reply it would have read."
    }

    /// The Spoken replies switch. It was "(Jarvis-grade)" (D200 item 9).
    static let elevenToggleLabel = "Use ElevenLabs voice"

    /// Who speaks Grux's replies, for the chat's voice chip, from the same gate the
    /// speech engine plays through. The chip said "by ElevenLabs" from the switch alone,
    /// and the switch defaults on, so a fresh Mac with no key read ElevenLabs while the
    /// macOS voice spoke (D200 item 9).
    static func vendor(useElevenLabs: Bool, hasKey: Bool, offline: Bool, wouldAskForMic: Bool, silencedBy: [String]) -> String {
        switch effectiveTTS(useElevenLabs: useElevenLabs, hasKey: hasKey, offline: offline,
                            wouldAskForMic: wouldAskForMic, silencedBy: silencedBy) {
        case .elevenLabs: return "ElevenLabs"
        case .system: return "macOS"
        case .silenced: return "nobody, Grux is silenced on this Mac"
        }
    }

    /// The ElevenLabs section's caption: whether a voice picked there is the one speaking.
    /// Silence is left to the status row above it; this line is about the choices here.
    static func elevenSectionCaption(useElevenLabs: Bool, hasKey: Bool, offline: Bool, wouldAskForMic: Bool) -> String {
        if SpeechEngine.speaksWithElevenLabs(choice: useElevenLabs, hasKey: hasKey, offline: offline,
                                             wouldAskForMic: wouldAskForMic) {
            return "Grux speaks your replies with the voice and model chosen here. Each reply is sent to ElevenLabs to be spoken."
        }
        if !hasKey {
            return useElevenLabs
                ? "None of these voices is in use: Grux speaks with the macOS voice until an ElevenLabs API key is saved here."
                : "None of these voices is in use: Grux speaks with the macOS voice. To use one, save an ElevenLabs API key here and turn on \(elevenToggleLabel) above."
        }
        if !useElevenLabs {
            return "None of these voices is in use: \(elevenToggleLabel) is off above, so Grux speaks with the macOS voice."
        }
        if offline {
            return "None of these voices is in use while offline mode is on: Grux speaks with the macOS voice."
        }
        return "None of these voices is in use yet: Grux speaks with the macOS voice until macOS has asked about the microphone, the first time you dictate or allow listening."
    }

    /// Human label for the known ElevenLabs model ids (same set the Voice tab
    /// model picker offers). Unknown ids pass through verbatim.
    static func elevenModelLabel(_ id: String) -> String {
        switch id {
        case "eleven_turbo_v2_5": return "Turbo v2.5"
        case "eleven_multilingual_v2": return "Multilingual v2"
        case "eleven_flash_v2_5": return "Flash v2.5"
        default: return id
        }
    }
}

// MARK: - Whisper deployment descriptors (read-only)

/// The STT side has NO config seam today: both Whisper model names are
/// `private let` constants chosen deliberately per workload, so this view
/// renders them read-only instead of inventing a config field that nothing
/// consumes. The strings below mirror the source of truth:
///   - VoiceInput.swift `modelName` (dictation, medium.en)
///   - AmbientListener.swift `modelName` (ambient, small.en; MeetingTranscriber
///     borrows this same instance via AmbientListener.sharedWhisperKit())
/// If either constant ever changes, update the matching entry here.
struct WhisperDeployment: Identifiable {
    let id: String
    let title: String
    let modelName: String
    let detail: String

    static let dictation = WhisperDeployment(
        id: "dictation",
        title: "Dictation (push to talk)",
        modelName: "openai_whisper-large-v3_turbo",
        detail: "Turns what you say into text on this Mac with OpenAI's free Whisper model, its large turbo version: good with accents, fast speech and names. It downloads once and then stays on this Mac."
    )

    static let ambient = WhisperDeployment(
        id: "ambient",
        title: "Ambient listening and meetings",
        modelName: "openai_whisper-small.en",
        detail: "Whisper's smaller English model, quick enough to keep up with a whole conversation. Meetings use the same copy as ambient listening, so only one is loaded."
    )

    static let all: [WhisperDeployment] = [.dictation, .ambient]

    /// The line under both rows. It was a developer's reasons ("fixed in code", "latency",
    /// "multi-hundred-MB"), D200 item 8. The wake word is NOT Whisper: it is Apple's
    /// recogniser with `requiresOnDeviceRecognition = false` (`WakeWord.swift`), so it
    /// can send audio to Apple, and saying otherwise is the mistake `MicConsent` warns of.
    static let footer = "Dictation and ambient listening are transcribed by Whisper on this Mac, not sent anywhere for that. The wake word is different: it uses Apple's speech recognition, which can send what it hears to Apple. Grux picks each model, so there is nothing to set here."
}

// MARK: - Settings sections

/// Self-contained Settings content consolidating the speech engine choices in
/// one place: spoken-output engine (ElevenLabs cloud vs system AVSpeech) and
/// the on-device Whisper STT models. Designed to be embedded inside the Voice
/// tab's existing Form; the body is a Group of Sections so it splices into the
/// Form like the hand-written sections around it.
struct VoiceEnginePickerView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var voiceInput = VoiceInput.shared
    @ObservedObject private var ambient = AmbientState.shared
    @ObservedObject private var speech = SpeechEngine.shared

    var body: some View {
        Group {
            ttsSection
            sttSection
        }
    }

    // MARK: TTS engine

    private var ttsEngineBinding: Binding<Bool> {
        Binding(
            get: { state.config.useElevenLabs },
            set: { new in
                state.config.useElevenLabs = new
                state.saveConfig()
            }
        )
    }

    private var ttsSection: some View {
        Section("Speech output engine") {
            Picker("Engine", selection: ttsEngineBinding) {
                Text("ElevenLabs (cloud)").tag(true)
                Text("System voice (on device)").tag(false)
            }
            .pickerStyle(.segmented)

            ttsStatusRow

            Text("ElevenLabs streams a studio-grade voice over the network. The system voice is Apple's on-device synthesizer: free, private, and the automatic fallback whenever ElevenLabs is unavailable. Voice, model, and API key live in the ElevenLabs section below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ttsStatusRow: some View {
        let effective = VoiceEngineLogic.effectiveTTS(
            useElevenLabs: state.config.useElevenLabs,
            hasKey: !state.elevenLabsKey.isEmpty,
            offline: state.offlineMode,
            wouldAskForMic: AudioOutput.outputWouldAskForMic,
            silencedBy: AudioOutput.silencedBy
        )
        HStack(spacing: 6) {
            switch effective {
            case .elevenLabs:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Active: ElevenLabs, \(selectedElevenVoiceName) (\(VoiceEngineLogic.elevenModelLabel(state.config.elevenLabsModelId)))")
                    .font(.caption)
            case .system(let reason):
                Circle()
                    .fill(reason == nil ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                if let reason {
                    Text("Active: system voice (\(reason))").font(.caption)
                } else {
                    Text("Active: system voice").font(.caption)
                }
            case .silenced(let files):
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text(VoiceEngineLogic.silencedLine(files)).font(.caption)
            }
            Spacer()
            if speech.isSpeaking {
                Label("speaking", systemImage: "waveform")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Resolve the configured voice id to a friendly name. Featured voices
    /// cover the curated set; for library voices fall back to the engine's
    /// last-announced name rather than re-fetching the catalog here.
    private var selectedElevenVoiceName: String {
        FeaturedVoices.all.first(where: { $0.voiceId == state.config.elevenLabsVoiceId })?.name
            ?? speech.currentVoiceName
    }

    // MARK: STT models (read-only)

    private var sttSection: some View {
        Section("Speech input (Whisper, on device)") {
            ForEach(WhisperDeployment.all) { dep in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sttReady(for: dep) ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(dep.title).font(.callout)
                        Spacer()
                    }
                    Text(dep.detail)
                        .font(.caption).foregroundStyle(.secondary)
                    if dep.id == WhisperDeployment.dictation.id,
                       !voiceInput.whisperReady, !voiceInput.whisperStatus.isEmpty {
                        Text(voiceInput.whisperStatus)
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            Text(WhisperDeployment.footer)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sttReady(for dep: WhisperDeployment) -> Bool {
        switch dep.id {
        case WhisperDeployment.dictation.id: return voiceInput.whisperReady
        case WhisperDeployment.ambient.id: return ambient.whisperReady
        default: return false
        }
    }
}
