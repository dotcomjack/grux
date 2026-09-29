import XCTest
@testable import Grux

/// A listener that reports capturing while no audio arrives recovers on its
/// own, keeps trying for about a minute and a half, and says so while it does.
///
/// Measured 2026-09-21 on the running app: the ambient restart after Grux
/// spoke came up deaf at 11:42 AM and 1:08 PM and stayed deaf until relaunch,
/// and at 2:24 PM three starts running were deaf, each with Core Audio logging
/// that the voice processing IO would not start, while plain capture from the
/// same microphone worked.
final class DeafStartRecoveryTests: XCTestCase {

    func test_aStartThatHearsAudioIsLeftAlone() {
        XCTAssertEqual(AmbientListener.deafStartAction(heardSeconds: 2.0, attempt: 0), .hearing)
        XCTAssertEqual(AmbientListener.deafStartAction(heardSeconds: 0.1, attempt: 4), .hearing)
    }

    func test_aDeafStartRestartsLaterEachTimeThenGivesUp() {
        let delays = (0..<AmbientListener.maxDeafRestarts).map {
            AmbientListener.deafStartAction(heardSeconds: 0, attempt: $0)
        }
        XCTAssertEqual(delays, [.restart(afterSeconds: 1), .restart(afterSeconds: 2), .restart(afterSeconds: 10),
                                .restart(afterSeconds: 30), .restart(afterSeconds: 60)])
        XCTAssertEqual(AmbientListener.deafStartAction(heardSeconds: 0, attempt: AmbientListener.maxDeafRestarts), .giveUp)
    }

    /// The first deaf start is usually cured a second later, so the orb only
    /// says NOT HEARING from the second one in a row, and never flickers.
    func test_notHearingIsToldFromTheSecondDeafStart() {
        XCTAssertFalse(AmbientListener.tellsNotHearing(afterDeafAttempt: 0))
        XCTAssertTrue(AmbientListener.tellsNotHearing(afterDeafAttempt: 1))
        XCTAssertTrue(AmbientListener.tellsNotHearing(afterDeafAttempt: 4))
    }

    /// The check acts on its answer: a deaf start with voice processing marks
    /// the refusal, a deaf start restarts carrying its count, hearing clears
    /// the tell, and giving up is visible.
    func test_theTwoSecondCheckActsOnItsAnswer() throws {
        let src = try source()
        let check = try XCTUnwrap(src.components(separatedBy: "let action = Self.deafStartAction(heardSeconds: heard, attempt: deafAttempt)").dropFirst().first)
        let branch = String(check.prefix(2_200))
        XCTAssertTrue(branch.contains("if action != .hearing && vpio.enable {\n                VoiceProcessingRefusal.markRefused()"),
                      "a deaf start with voice processing does not stop the next one using it")
        XCTAssertTrue(branch.contains("MicHealth.shared.set(notHearing: false)"), "hearing does not clear NOT HEARING")
        XCTAssertTrue(branch.contains("self.restartAfterDeafStart(attempt: deafAttempt + 1, afterSeconds: delay)"),
                      "a deaf start no longer restarts")
        XCTAssertTrue(branch.contains("AmbientState.shared.error ="), "giving up is silent")
        let restart = try XCTUnwrap(src.components(separatedBy: "private func restartAfterDeafStart(attempt: Int, afterSeconds seconds: Double) {").dropFirst().first)
        XCTAssertTrue(restart.prefix(1_200).contains("try startEngine(deafAttempt: attempt)"),
                      "the restart starts a fresh count, so the bound never holds")
    }

    /// Every ambient start asks whether voice processing was refused a moment
    /// ago, or the restarts would walk straight back into the same deaf start.
    ///
    /// Matched WITHOUT the closing paren on purpose. It used to be included,
    /// which silently also asserted that `refusedRecently:` was the LAST
    /// argument in the call. That is not the invariant: adding
    /// `holdsMicWhileGruxSpeaks:` after it on 2026-09-23 failed this test
    /// while the refusal was still being consulted exactly as before. A test
    /// that fails on correct code teaches people to edit the test.
    func test_eachStartConsultsTheRefusal() throws {
        let src = try source()
        let body = try XCTUnwrap(src.components(separatedBy: "private func startEngine(deafAttempt: Int = 0) throws {").dropFirst().first)
        XCTAssertTrue(body.prefix(6_000).contains("refusedRecently: VoiceProcessingRefusal.isRecent()"),
                      "ambient no longer asks whether voice processing was just refused, so a restart walks back into the same deaf start")
        let voice = try String(contentsOf: root().appendingPathComponent("Sources/Grux/VoiceInput.swift"), encoding: .utf8)
        XCTAssertTrue(voice.contains("refusedRecently: VoiceProcessingRefusal.isRecent()"),
                      "the chat mic walks into the start ambient already found deaf")
    }

    private func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(contentsOf: root().appendingPathComponent("Sources/Grux/Ambient/AmbientListener.swift"), encoding: .utf8)
    }
}
