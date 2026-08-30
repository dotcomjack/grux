import Foundation
import AVFoundation

/// Speaks assistant replies out loud using AVSpeechSynthesizer.
/// Interrupts any in-flight speech when a new reply arrives.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let cleaned = Self.cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
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
        synth.speak(utt)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

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
        Task { @MainActor in
            self.isSpeaking = true
            // Pause the wake listener so Grux doesn't trigger on its own voice.
            WakeWordListener.shared.suspendForSpeaking()
            // Broadcast so ambient listener + anything else can drop the mic.
            NotificationCenter.default.post(name: .gruxSpeechDidStart, object: nil)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            WakeWordListener.shared.resumeAfterSpeaking()
            NotificationCenter.default.post(name: .gruxSpeechDidStop, object: nil)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            WakeWordListener.shared.resumeAfterSpeaking()
            NotificationCenter.default.post(name: .gruxSpeechDidStop, object: nil)
        }
    }
}
