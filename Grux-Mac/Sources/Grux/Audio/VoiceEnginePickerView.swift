import SwiftUI

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
    }

    static func effectiveTTS(useElevenLabs: Bool, hasKey: Bool, offline: Bool) -> EffectiveTTS {
        guard useElevenLabs else { return .system(fallbackReason: nil) }
        if offline { return .system(fallbackReason: "offline mode forces the on-device voice") }
        if !hasKey { return .system(fallbackReason: "no ElevenLabs API key saved") }
        return .elevenLabs
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
        title: "Dictation (push-to-talk + wake word)",
        modelName: "openai_whisper-large-v3_turbo",
        detail: "Whisper large-v3 (turbo), the free open-source OpenAI model running 100% on device via WhisperKit on the Neural Engine. Big accuracy jump over medium.en on accents, fast speech, and unusual proper nouns like product and brand names; the turbo decoder keeps push-to-talk snappy. Nothing is sent to the cloud."
    )

    static let ambient = WhisperDeployment(
        id: "ambient",
        title: "Ambient + meetings (continuous)",
        modelName: "openai_whisper-small.en",
        detail: "English-only small model. Picked for low-latency continuous chunking; meeting transcription shares this same loaded instance so only one extra model lives in memory."
    )

    static let all: [WhisperDeployment] = [.dictation, .ambient]
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
            offline: state.offlineMode
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
                        Text(dep.modelName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
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
            Text("Model choice is fixed in code, not a setting: each workload is tuned to its own accuracy/latency trade-off, and a picker here would silently re-download multi-hundred-MB models. Both run fully on device; nothing you say is sent to the cloud for transcription.")
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
