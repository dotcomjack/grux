import XCTest
@testable import Grux

final class SpeakerSegmenterTests: XCTestCase {

    // Reuse the SpeakerDiarizerTests synthesizer inline, tests shouldn't
    // share helpers across files until we know which stay.
    private func synthVoice(f0: Float, formants: [Float], durationSeconds: Float = 2.0) -> [Float] {
        let sr: Float = 16_000
        let n = Int(sr * durationSeconds)
        var out = [Float](repeating: 0, count: n)
        for k in 1...15 {
            let freq = f0 * Float(k)
            guard freq < sr / 2 else { break }
            for i in 0..<n {
                out[i] += (1.0 / Float(k)) * sinf(2 * .pi * freq * Float(i) / sr)
            }
        }
        for f in formants {
            for i in 0..<n {
                out[i] += 0.6 * sinf(2 * .pi * f * Float(i) / sr)
            }
        }
        for i in 0..<n {
            let t = Float(i) / sr
            let env = 0.4 + 0.6 * max(0, sinf(.pi * t / durationSeconds))
            out[i] *= env
        }
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for i in 0..<n { out[i] = 0.8 * out[i] / peak }
        }
        return out
    }

    // Assemble an alternating-speaker 10s chunk: first 5 s voice A, last 5 s
    // voice B. Word timestamps point each word at its source half.
    @MainActor
    func test_segmenter_splitsByMidChunkSpeakerChange() {
        let voiceA = synthVoice(f0: 110, formants: [500, 1100, 2400], durationSeconds: 5.0)
        let voiceB = synthVoice(f0: 220, formants: [850, 1900, 3200], durationSeconds: 5.0)
        let chunk = voiceA + voiceB

        // Fake WhisperKit word stamps: 6 words at 0.5 s cadence, first 5
        // fall in voice A's half, last 5 fall in voice B's half.
        let words: [MeetingTranscriber.WordStamp] = [
            .init(text: "hello",   start: 0.3, end: 0.7, probability: 0.95),
            .init(text: "everyone", start: 1.0, end: 1.5, probability: 0.95),
            .init(text: "welcome", start: 2.2, end: 2.7, probability: 0.95),
            .init(text: "back",    start: 3.1, end: 3.5, probability: 0.95),
            .init(text: "hi",      start: 5.3, end: 5.6, probability: 0.95),
            .init(text: "thanks",  start: 6.4, end: 6.9, probability: 0.95),
            .init(text: "for",     start: 7.2, end: 7.5, probability: 0.95),
            .init(text: "having",  start: 8.0, end: 8.4, probability: 0.95),
            .init(text: "me",      start: 8.8, end: 9.1, probability: 0.95)
        ]

        let diarizer = SpeakerDiarizer()
        let subs = SpeakerSegmenter.segment(
            micSamples: chunk,
            words: words,
            diarizer: diarizer
        )

        XCTAssertGreaterThanOrEqual(subs.count, 2,
            "Expected at least two SubUtterances for two speakers, got \(subs.count)")
        // First sub should contain voice-A's words.
        let firstText = subs[0].text.lowercased()
        XCTAssertTrue(firstText.contains("hello") || firstText.contains("welcome"),
            "First sub should contain voice-A words, got '\(firstText)'")
        // Last sub should contain voice-B's words.
        let lastText = subs.last!.text.lowercased()
        XCTAssertTrue(lastText.contains("thanks") || lastText.contains("having"),
            "Last sub should contain voice-B words, got '\(lastText)'")
        // And the two ends should have different speakerIds.
        XCTAssertNotEqual(subs.first!.speakerId, subs.last!.speakerId,
            "First and last subs must resolve to distinct clusters")
    }

    @MainActor
    func test_segmenter_emptyWordsReturnsEmpty() {
        let diarizer = SpeakerDiarizer()
        let chunk = synthVoice(f0: 130, formants: [700, 1200, 2500], durationSeconds: 2.0)
        let subs = SpeakerSegmenter.segment(
            micSamples: chunk,
            words: [],
            diarizer: diarizer
        )
        XCTAssertTrue(subs.isEmpty)
    }

    @MainActor
    func test_segmenter_singleSpeakerOneUtterance() {
        let voice = synthVoice(f0: 130, formants: [700, 1200, 2500], durationSeconds: 5.0)
        let words: [MeetingTranscriber.WordStamp] = [
            .init(text: "this",   start: 0.4, end: 0.7, probability: 0.95),
            .init(text: "is",     start: 0.9, end: 1.1, probability: 0.95),
            .init(text: "me",     start: 1.4, end: 1.8, probability: 0.95),
            .init(text: "talking", start: 2.2, end: 2.7, probability: 0.95),
            .init(text: "alone",  start: 3.1, end: 3.5, probability: 0.95)
        ]
        let diarizer = SpeakerDiarizer()
        let subs = SpeakerSegmenter.segment(
            micSamples: voice,
            words: words,
            diarizer: diarizer
        )
        XCTAssertEqual(subs.count, 1,
            "Single speaker should collapse to one SubUtterance, got \(subs.count)")
        XCTAssertTrue(subs[0].text.contains("this"))
        XCTAssertTrue(subs[0].text.contains("alone"))
    }
}

final class SpeakerNameDetectorTests: XCTestCase {

    func test_detect_myNameIs() {
        let hint = SpeakerNameDetector.detect(in: "Hi all, my name is Sarah and I work in design.")
        XCTAssertEqual(hint?.name, "Sarah")
    }

    func test_detect_iAm() {
        let hint = SpeakerNameDetector.detect(in: "Cool, I am Marcus, nice to meet you.")
        XCTAssertEqual(hint?.name, "Marcus")
    }

    func test_detect_imContraction() {
        let hint = SpeakerNameDetector.detect(in: "I'm Priya, joining from the NYC office.")
        XCTAssertEqual(hint?.name, "Priya")
    }

    func test_detect_speakingSuffix() {
        let hint = SpeakerNameDetector.detect(in: "Alex speaking, how can I help?")
        XCTAssertEqual(hint?.name, "Alex")
    }

    func test_detect_blacklistedWordsIgnored() {
        XCTAssertNil(SpeakerNameDetector.detect(in: "I'm tired, let's wrap up."))
        XCTAssertNil(SpeakerNameDetector.detect(in: "I am sorry to cut in."))
    }

    func test_detect_noSelfIntroReturnsNil() {
        XCTAssertNil(SpeakerNameDetector.detect(in: "The quarterly numbers look strong across the board."))
    }

    func test_detect_canonicalizesCase() {
        // Transcribed text is all-lowercase from some STT engines.
        let hint = SpeakerNameDetector.detect(in: "call me Dana, i prefer it casual.")
        XCTAssertEqual(hint?.name, "Dana")
    }
}
