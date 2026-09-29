import Foundation
import WhisperKit

/// The one door to Whisper, so a short clip is heard like a long one.
///
/// WhisperKit stops seeking `windowClipTime` (1.0 s by default) before the end of the
/// audio, which keeps it from inventing words over a trailing tail. On audio no longer than
/// that its decode loop never runs a single window, so the answer is empty whatever was
/// said. Measured 2026-09-27: a 0.9 s recording of "open Today" transcribed to nothing, and
/// the same words with half a second of silence after them came back as "Open today.".
/// A quick "mute" or "yes" is that short.
enum WhisperDecode {

    /// Silence added past the end clip, so the window that runs holds the whole clip.
    private static let margin = 0.5

    static func transcribe(_ kit: WhisperKit, _ samples: [Float],
                           options: DecodingOptions) async throws -> [TranscriptionResult] {
        try await kit.transcribe(audioArray: padded(samples, options: options),
                                 decodeOptions: options)
    }

    /// `samples` with trailing silence when they would not fill one decode window.
    /// Empty stays empty: silence alone is where Whisper invents words.
    static func padded(_ samples: [Float], options: DecodingOptions) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let clip = Int(Double(options.windowClipTime) * Double(WhisperKit.sampleRate))
        guard samples.count <= clip else { return samples }
        let target = clip + Int(margin * Double(WhisperKit.sampleRate))
        return samples + [Float](repeating: 0, count: target - samples.count)
    }
}
