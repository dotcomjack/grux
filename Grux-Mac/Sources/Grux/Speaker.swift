import Foundation
import AVFoundation

/// Speaks assistant replies out loud with the system voice.
/// Interrupts any in-flight speech when a new reply arrives.
///
/// BEFORE THE MICROPHONE QUESTION THE VOICE PLAYS OUTSIDE GRUX. On a Mac whose
/// output device also has inputs, any sound Grux plays in its own process raises
/// the microphone prompt while the person has not been asked
/// (`AudioOutput.outputWouldAskForMic`): the first spoken reply did, with no mic
/// control pressed (W4 build 11, 2026-10-14). Until then the synthesizer writes the
/// reply to a file and `AudioOutput.playDetached` plays it. Afterwards it speaks
/// in process, as it always did.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking = false

    /// The utterance spoken in process; delegate calls for any other are ignored
    /// (`write` reports through the delegate too).
    private var spoken: AVSpeechUtterance?
    /// The detached reply; a file from an older one is dropped.
    private var detached = UUID()
    private var stopDetached: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let cleaned = Self.cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        // SpeechEngine is the only caller and already asked; this is the backstop.
        guard AudioOutput.permit(.speech, source: "Speaker.speak", text: cleaned) else { return }
        let utt = AVSpeechUtterance(string: cleaned)
        // Prefer a premium/enhanced US voice if available for a more natural read.
        utt.voice = Self.preferredVoice()
        // Scale by the user's Voice tab speed setting. Default 1.5 → 1.545×.
        let speedMult = Float(AppState.shared.config.voicePlaybackRate) * 1.03
        utt.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * speedMult,
                           AVSpeechUtteranceMinimumSpeechRate),
                       AVSpeechUtteranceMaximumSpeechRate)
        utt.pitchMultiplier = 1.0
        utt.volume = 1.0
        WakeLog.shared.log("speaking: \(cleaned.prefix(80))")
        play(utt)
    }

    /// Internal for the test that proves a reply before the microphone question
    /// plays outside Grux.
    func play(_ utt: AVSpeechUtterance) {
        stop()
        if AudioOutput.outputWouldAskForMic {
            playDetached(utt)
        } else {
            spoken = utt
            synth.speak(utt)
        }
    }

    func stop() {
        spoken = nil
        synth.stopSpeaking(at: .immediate)
        detached = UUID()
        stopDetached?()
        stopDetached = nil
        ended()
    }

    // MARK: - Detached

    private func playDetached(_ utt: AVSpeechUtterance) {
        let id = UUID()
        detached = id
        began()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grux-speech-\(id.uuidString).caf")
        let file = SpeechFile(url: url)
        let volume = utt.volume
        synth.write(utt) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // An empty buffer marks the end of synthesis; more than one can arrive.
            guard pcm.frameLength == 0 else { file.append(pcm); return }
            guard file.finish() else { return }
            Task { @MainActor in self?.playFile(url, volume: volume, for: id) }
        }
    }

    private func playFile(_ url: URL, volume: Float, for id: UUID) {
        guard id == detached else { try? FileManager.default.removeItem(at: url); return }
        stopDetached = AudioOutput.playDetached(url, volume) { [weak self] in
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                guard let self, id == self.detached else { return }
                self.stopDetached = nil
                self.ended()
            }
        }
        if stopDetached == nil {
            try? FileManager.default.removeItem(at: url)
            ended()
        }
    }

    private func began() {
        isSpeaking = true
        // Pause the wake listener so Grux doesn't trigger on its own voice.
        WakeWordListener.shared.suspendForSpeaking()
        // Broadcast so ambient listener + anything else can drop the mic.
        NotificationCenter.default.post(name: .gruxSpeechDidStart, object: nil)
    }

    private func ended() {
        guard isSpeaking else { return }
        isSpeaking = false
        WakeWordListener.shared.resumeAfterSpeaking()
        NotificationCenter.default.post(name: .gruxSpeechDidStop, object: nil)
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let premium = all.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = all.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Strip markdown syntax and the assistant's error prefix so the TTS reads
    /// clean prose.
    private static func cleanForSpeech(_ s: String) -> String {
        var out = s
        if out.hasPrefix("⚠️") { out.removeFirst(1) }
        out = out.replacingOccurrences(of: "**", with: "")
                 .replacingOccurrences(of: "`", with: "")
                 .replacingOccurrences(of: "```", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.spoken { self.began() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.spoken { self.spoken = nil; self.ended() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.spoken { self.spoken = nil; self.ended() } }
    }
}

/// The synthesizer's buffers, written to a file on the synthesizer's thread as they
/// arrive.
private final class SpeechFile: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?

    init(url: URL) { self.url = url }

    func append(_ pcm: AVAudioPCMBuffer) {
        guard !finished else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try? file?.write(from: pcm)
    }

    private var finished = false

    /// Releases the file, which finishes it. True only the first time.
    func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        file = nil
        return true
    }
}
