import Foundation

// Takes a single transcribed 10 s chunk - mic-only audio plus WhisperKit's
// per-word timestamps - and returns a list of speaker-attributed sub-utterances
// by running voice-embedding classification on overlapping 1 s sub-windows of
// the mic audio and grouping consecutive same-cluster words.
//
// Intended use from MeetingCaptureService.transcribeChunk:
//
//    let subs = SpeakerSegmenter.segment(
//        micSamples: mic,
//        words: result.words,
//        diarizer: self.diarizer
//    )
//    for sub in subs { append utterance with sub.text + sub.speakerLabel }
//
// Falls back gracefully to a single-cluster-for-the-whole-chunk result when
// word timestamps are missing (e.g. if the WhisperKit model variant doesn't
// expose alignment weights) - caller still gets a labeled utterance, just
// without the mid-chunk split.
@MainActor
enum SpeakerSegmenter {

    static let subWindowSeconds: Double = 1.0
    static let subWindowSamples: Int = Int(Double(SpeakerEmbedder.sampleRate) * subWindowSeconds)
    static let minWordsPerUtterance: Int = 1

    fileprivate struct WindowAssignment {
        let speakerId: UUID?
        let label: String?
        let profileId: UUID?
        let confidence: Float
    }

    struct SubUtterance {
        let text: String
        let startT: Double                  // seconds from chunk start
        let endT: Double
        let speakerId: UUID?
        let speakerLabel: String?
        let speakerProfileId: UUID?
        let speakerConfidence: Float        // 0..1 - diarizer's cosine sim
    }

    static func segment(
        micSamples: [Float],
        words: [MeetingTranscriber.WordStamp],
        diarizer: SpeakerDiarizer
    ) -> [SubUtterance] {
        guard !words.isEmpty else { return [] }

        // Build a sub-window → assignment map up front so each word costs O(1).
        let chunkDuration = Double(micSamples.count) / Double(SpeakerEmbedder.sampleRate)
        let nWindows = max(1, Int((chunkDuration / subWindowSeconds).rounded(.up)))

        var windows: [WindowAssignment] = []
        windows.reserveCapacity(nWindows)
        for w in 0..<nWindows {
            let start = w * subWindowSamples
            let end = min(micSamples.count, start + subWindowSamples)
            guard end - start >= Int(SpeakerEmbedder.sampleRate) / 2 else {
                // <0.5 s of audio → skip (inherits neighbor below)
                windows.append(WindowAssignment(speakerId: nil, label: nil, profileId: nil, confidence: 0))
                continue
            }
            let slice = Array(micSamples[start..<end])
            if let assign = diarizer.assign(samples: slice) {
                windows.append(WindowAssignment(
                    speakerId: assign.speakerId,
                    label: assign.label,
                    profileId: assign.matchedProfile?.id,
                    confidence: assign.confidence
                ))
            } else {
                windows.append(WindowAssignment(speakerId: nil, label: nil, profileId: nil, confidence: 0))
            }
        }

        // Inherit pass: replace silent windows with their nearest labeled
        // neighbor so a word that falls in a "silent" sub-window doesn't end
        // up unlabeled. Scan forward then backward.
        var inherited = windows
        var last: WindowAssignment? = nil
        for i in 0..<inherited.count {
            if inherited[i].speakerId == nil, let l = last { inherited[i] = l }
            if inherited[i].speakerId != nil { last = inherited[i] }
        }
        last = nil
        for i in (0..<inherited.count).reversed() {
            if inherited[i].speakerId == nil, let l = last { inherited[i] = l }
            if inherited[i].speakerId != nil { last = inherited[i] }
        }

        // Assign each word to the sub-window holding >50 % of its duration.
        // Consecutive same-speaker words merge into one SubUtterance.
        var result: [SubUtterance] = []
        var current: (words: [MeetingTranscriber.WordStamp], win: WindowAssignment)?

        func windowIndex(for word: MeetingTranscriber.WordStamp) -> Int {
            let mid = Double(word.start + word.end) * 0.5
            let idx = Int(mid / subWindowSeconds)
            return max(0, min(inherited.count - 1, idx))
        }

        for word in words {
            let widx = windowIndex(for: word)
            let win = inherited[widx]
            if let cur = current, cur.win.speakerId == win.speakerId {
                current?.words.append(word)
            } else {
                if let cur = current, cur.words.count >= minWordsPerUtterance {
                    result.append(flush(cur.words, win: cur.win))
                }
                current = (words: [word], win: win)
            }
        }
        if let cur = current, cur.words.count >= minWordsPerUtterance {
            result.append(flush(cur.words, win: cur.win))
        }
        return result
    }

    private static func flush(_ words: [MeetingTranscriber.WordStamp], win: WindowAssignment) -> SubUtterance {
        // Use word.text for the join; WhisperKit preserves leading spacing
        // in the word string, so trimming here would eat legitimate spaces
        // between words. Instead, join raw then collapse whitespace runs.
        let joined = words.map { $0.text }.joined(separator: " ")
        let collapsed = joined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return SubUtterance(
            text: collapsed,
            startT: Double(words.first?.start ?? 0),
            endT: Double(words.last?.end ?? 0),
            speakerId: win.speakerId,
            speakerLabel: win.label,
            speakerProfileId: win.profileId,
            speakerConfidence: win.confidence
        )
    }
}

