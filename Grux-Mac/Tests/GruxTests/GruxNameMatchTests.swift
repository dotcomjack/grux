import XCTest
@testable import Grux

/// Who counts as saying "Grux". Measured live on 2026-09-21 during a meeting:
/// "great", "grab", "green", "grand", "grain" and "growth" were taken as Grux's
/// name, which forces a chunk into Chat, and Grux answered a meeting.
@MainActor
final class GruxNameMatchTests: XCTestCase {

    /// The words that actually fired, from the log, and their neighbours.
    func test_ordinaryWordsAreNotTheName() {
        for talk in ["We think we could grab just a little bit of time for intros",
                     "that's great, thanks everyone", "the group met on Friday", "green light on the launch",
                     "a grand opening", "whole grain", "growth is up this quarter", "gross margin",
                     "I grew up here", "so great to see you"] {
            XCTAssertFalse(AmbientListener.startsWithWake(talk), "\"\(talk)\" was taken as Grux's name")
            XCTAssertFalse(WakeWordListener.wouldTrigger(talk), "the wake word fires on \"\(talk)\"")
            XCTAssertEqual(AmbientListener.stripWakePrefix(talk), talk, "\"\(talk)\" lost words to a wake strip")
        }
    }

    func test_theNameAndItsKnownMishearingsStillCount() {
        for said in ["hey grux open my calendar", "Grux, what's next", "okay grooks read my mail", "hey groks",
                     "yo grux", "grux", "hey grew what time is it", "Hey Grox, play something"] {
            XCTAssertTrue(AmbientListener.startsWithWake(said), "\"\(said)\" no longer reaches Grux")
        }
        XCTAssertEqual(AmbientListener.stripWakePrefix("hey grux open my calendar"), "open my calendar")
        XCTAssertEqual(AmbientListener.stripWakePrefix("Grux, what's next"), "what's next")
        XCTAssertTrue(WakeWordListener.wouldTrigger("hey grux"))
        XCTAssertTrue(WakeWordListener.wouldTrigger("hey groks"))
    }

    /// Talking ABOUT Grux is not talking to it; a greeting mid-chunk still is.
    func test_aBareNameCountsOnlyAtTheStart() {
        XCTAssertFalse(AmbientListener.startsWithWake("I told grux about it yesterday"))
        XCTAssertTrue(AmbientListener.startsWithWake("so anyway hey grux open the calendar"))
        XCTAssertEqual(AmbientListener.stripWakePrefix("so anyway hey grux open the calendar"), "open the calendar")
    }
}

/// The follow-up loop: inside the window, "not for Grux" at 0.6 or more is
/// believed. Measured live: lines judged 0.65 and 0.77 went to Chat at 0.8.
@MainActor
final class FollowUpWindowBarTests: XCTestCase {
    private struct Says: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        let confidence: Double
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            DecisionResult(answers: ["intent": .choice(LocalDecisionProvider.notACommand, confidence: confidence, probabilities: [:])],
                           latencyMs: 1, inputTokens: 0, outputTokens: 0, provider: .jev)
        }
    }

    private func sent(at confidence: Double) async -> [String] {
        let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                               remote: { _ in Says(confidence: confidence) })
        let r = VoiceCommandRouter(engine: e, threshold: { 0.7 }, macros: { [] })
        r.recentReply = { (age: 20, text: "Here is your summary.") }
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        _ = await r.consider(chunk: "and so like for both of them you were amazing")
        await r.chatHandOff?.value
        return sent
    }

    func test_meetingTalkInsideTheWindowStaysOutOfChat() async {
        let at065 = await sent(at: 0.65)
        let at077 = await sent(at: 0.77)
        XCTAssertEqual(at065, [], "a line judged not for Grux at 0.65 went to Chat")
        XCTAssertEqual(at077, [], "a line judged not for Grux at 0.77 went to Chat")
    }

    func test_anUnsureLineInsideTheWindowStillReachesGrux() async {
        let at055 = await sent(at: 0.55)
        XCTAssertEqual(at055.count, 1, "a reply the provider is unsure about should still reach Grux")
    }
}
