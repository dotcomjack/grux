import Foundation
import WhisperKit

// Thin wrapper that transcribes a single [Float] 16 kHz mono chunk via
// WhisperKit and returns cleaned text + a confidence signal. Reuses
// AmbientListener's WhisperKit instance (small.en) - we deliberately DO NOT
// load a second model; AmbientListener is paused for the duration of meeting
// capture so there's no contention.
@MainActor
final class MeetingTranscriber {
    private let whisperKit: WhisperKit

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    // A single word's audio-aligned timing. Used for sub-chunk diarization
    // so the speaker assignment can flip mid-utterance if a different voice
    // takes over.
    struct WordStamp: Equatable {
        let text: String
        let start: Float   // seconds from chunk start
        let end: Float
        let probability: Float
    }

    struct Result {
        let text: String
        let confidence: Float   // mean of segment avgLogprob → normalized to 0..1
        let words: [WordStamp]  // empty when WhisperKit didn't produce word timings
    }

    func transcribe(chunk samples: [Float]) async -> Result? {
        guard samples.count >= 16000 / 2 else { return nil }   // need ≥0.5s
        let promptTokens = WhisperVocab.buildPromptTokens(tokenizer: whisperKit.tokenizer)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            // v2 diarization: per-word timestamps drive sub-chunk speaker
            // assignment so a 10 s chunk with two speakers produces two (or
            // more) labeled utterances instead of one "mixed" blob.
            wordTimestamps: true,
            promptTokens: promptTokens
        )

        do {
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            var kept: [String] = []
            var logprobs: [Float] = []
            var words: [WordStamp] = []
            for r in results {
                for seg in r.segments {
                    let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let segDur = Float(seg.end - seg.start)
                    // Mirror AmbientListener's confidence gate - keeps out
                    // Whisper hallucinations on silence / music / typing.
                    let isShort = segDur < 1.0
                    let noSpeechMax: Float = isShort ? 0.3 : 0.6
                    let logprobMin: Float = isShort ? -0.6 : -1.0
                    if seg.noSpeechProb > noSpeechMax || seg.avgLogprob < logprobMin {
                        continue
                    }
                    kept.append(trimmed)
                    logprobs.append(seg.avgLogprob)
                    if let wts = seg.words {
                        for w in wts {
                            let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            words.append(WordStamp(
                                text: text,
                                start: w.start,
                                end: w.end,
                                probability: w.probability
                            ))
                        }
                    }
                }
            }
            let raw = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return nil }
            // Confidence: mean avgLogprob mapped from [-2, 0] → [0, 1].
            let avgLog = logprobs.isEmpty ? Float(-0.8) : logprobs.reduce(0, +) / Float(logprobs.count)
            let conf = max(0, min(1, (avgLog + 2) / 2))
            return Result(text: raw, confidence: conf, words: words)
        } catch {
            WakeLog.shared.log("meeting-transcriber: transcribe error \(error.localizedDescription)")
            return nil
        }
    }
}
