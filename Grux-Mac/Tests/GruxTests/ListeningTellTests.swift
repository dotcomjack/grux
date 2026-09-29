import XCTest
@testable import Grux

/// The orb, the menu bar, the HUD and the focus card each used to reason
/// about the microphone from their own mix of flags, which is how the
/// sidebar could read LISTENING while the menu bar read IDLE. One resolver,
/// every combination enumerated here.
final class ListeningTellTests: XCTestCase {
    private func tell(_ mode: ListeningMode, muted: Bool = false,
                      speaking: Bool = false, thinking: Bool = false) -> ListeningTell {
        ListeningTell.resolve(mode: mode, micMuted: muted, isSpeaking: speaking, isThinking: thinking)
    }

    func test_alwaysOnAndUnmutedReadsArmed() {
        XCTAssertEqual(tell(.alwaysOn), .armed)
    }

    func test_waitingOnTheWakeWordIsStillArmed() {
        // The microphone is live either way. What differs is what Grux acts
        // on, and that is the Listening control's job to explain, not a
        // second word on the orb.
        XCTAssertEqual(tell(.wakeWord), .armed)
    }

    func test_listeningOffIsNotTheSameWordAsMuted() {
        XCTAssertEqual(tell(.off), .off)
        XCTAssertEqual(tell(.alwaysOn, muted: true), .muted)
        XCTAssertNotEqual(ListeningTell.off, ListeningTell.muted)
    }

    func test_muteBeatsTheConfiguredMode() {
        XCTAssertEqual(tell(.alwaysOn, muted: true), .muted)
        XCTAssertEqual(tell(.wakeWord, muted: true), .muted)
    }

    func test_offStaysOffEvenWhenTheMicIsAlsoMuted() {
        XCTAssertEqual(tell(.off, muted: true), .muted)
    }

    func test_speakingOutranksEverything() {
        XCTAssertEqual(tell(.off, muted: true, speaking: true, thinking: true), .speaking)
        XCTAssertEqual(tell(.alwaysOn, speaking: true), .speaking)
    }

    func test_thinkingOutranksMuteButNotSpeaking() {
        XCTAssertEqual(tell(.alwaysOn, muted: true, thinking: true), .thinking)
        XCTAssertEqual(tell(.alwaysOn, speaking: true, thinking: true), .speaking)
    }

    func test_everyTellCarriesAWordAndAnExplanation() {
        for t in ListeningTell.allCases {
            XCTAssertEqual(t.label, t.label.uppercased(), "\(t) must render uppercase")
            XCTAssertFalse(t.label.isEmpty)
            XCTAssertFalse(t.help.isEmpty, "\(t) needs one sentence of help")
            XCTAssertTrue(t.help.hasSuffix("."), "\(t) help should read as a sentence")
        }
    }

    func test_armedWearsTheListeningGlowRatherThanIdle() {
        // The bug this closes: always-on listening drove no wake listener, so
        // the orb fell through to idle while the microphone was live.
        XCTAssertEqual(ListeningTell.armed.orbState, .listening)
        XCTAssertEqual(ListeningTell.muted.orbState, .muted)
        XCTAssertEqual(ListeningTell.speaking.orbState, .speaking)
        XCTAssertEqual(ListeningTell.thinking.orbState, .thinking)
        XCTAssertEqual(ListeningTell.off.orbState, .idle)
    }

    func test_noTwoTellsShareAWord() {
        let words = Set(ListeningTell.allCases.map(\.label))
        XCTAssertEqual(words.count, ListeningTell.allCases.count)
    }
}
