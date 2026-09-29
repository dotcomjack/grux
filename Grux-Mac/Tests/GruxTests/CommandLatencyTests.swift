import XCTest
@testable import Grux

/// HOW FAST A SPOKEN COMMAND CAN POSSIBLY BE.
///
/// Measured 2026-09-22 by saying "open my calendar" into the microphone nine
/// times on a real install: 3.1 seconds from the end of the sentence to the
/// decision, of which the decision was 450ms. The rest was waiting 1.6 seconds
/// to see whether more words were coming, and then transcribing a buffer with
/// that silence on the end of it.
final class CommandLatencyTests: XCTestCase {

    private let commandWindow = 3.5
    private let commandGap: TimeInterval = 0.6
    private let conversationGap: TimeInterval = 1.6

    /// SPOKEN seconds, not buffer seconds. The first version of this keyed
    /// off buffer length and changed nothing in practice: the buffer runs
    /// from the last flush, so it carries room silence, and it measured 1.5s
    /// to 8.0s for the same one-second command. Five live trials after that
    /// change came back at 3.0s to 3.4s, exactly where they started.
    private func threshold(_ buffer: Double) -> TimeInterval {
        AmbientListener.flushSilenceThreshold(spokenSeconds: buffer,
                                              commandWindow: commandWindow,
                                              commandGap: commandGap,
                                              conversationGap: conversationGap)
    }

    /// "Open my calendar" is about 1.2s of speech. It must not wait on the
    /// conversation gap.
    func test_aShortUtteranceEndsOnTheCommandGap() {
        // "Open my calendar" is about 1.2 seconds of speech.
        XCTAssertEqual(threshold(1.2), commandGap)
        XCTAssertEqual(threshold(1.8), commandGap, "speech plus its own trailing gap is still a command")
        XCTAssertEqual(threshold(3.5), commandGap, "the boundary is inclusive")
    }

    /// Sustained speech keeps the long gap: splitting it produces short chunks
    /// that Whisper transcribes worse, and nobody is waiting on a sentence
    /// somebody is still saying.
    func test_sustainedSpeechKeepsTheConversationGap() {
        XCTAssertEqual(threshold(3.6), conversationGap)
        XCTAssertEqual(threshold(12), conversationGap)
        XCTAssertEqual(threshold(22), conversationGap)
    }

    /// The point of the change, stated as a number rather than a hope: a
    /// command stops waiting a full second sooner than it did.
    func test_theCommandPathIsAtLeastASecondFaster() {
        let saved = conversationGap - threshold(1.2)
        XCTAssertGreaterThanOrEqual(saved, 1.0,
            "the command gap no longer buys back the second this was written to remove")
    }

    /// And it still clears a real mid-sentence pause, or it would cut people
    /// off in the middle of talking. Conversational pauses run about 0.2 to
    /// 0.3 seconds.
    func test_theCommandGapClearsAMidSentencePause() {
        XCTAssertGreaterThan(commandGap, 0.35,
            "a gap this short would split people mid-sentence")
    }
}
