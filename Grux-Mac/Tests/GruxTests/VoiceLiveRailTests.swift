import XCTest
@testable import Grux

/// The rail is the answer to "did Grux hear me, and did it think I was
/// talking to it?" It is a rail and not a log, so what it selects matters
/// more than how it draws.
final class VoiceLiveRailTests: XCTestCase {

    private func event(_ secondsAgo: TimeInterval, heard: String,
                       outcome: VoiceDecisionEvent.Outcome = .executed) -> VoiceDecisionEvent {
        // VoiceDecisionEvent stamps itself, so age is simulated by moving the
        // clock the selector is handed rather than the event.
        VoiceDecisionEvent(heard: heard, commandId: "tab:calendar", confidence: 0.94,
                           latencyMs: 480, provider: .jev, outcome: outcome)
    }

    func test_listeningOffShowsNoRailAtAll() {
        let e = [event(1, heard: "open my calendar")]
        XCTAssertTrue(VoiceLiveRailModel.visible(events: e, tell: .off, expanded: false).isEmpty)
        XCTAssertTrue(VoiceLiveRailModel.visible(events: e, tell: .off, expanded: true).isEmpty)
    }

    func test_mutedStillShowsTheLastThingGruxDid() {
        // Muting is a thing the person just did. Hiding the decision that
        // preceded it is exactly when they most want to see it.
        let e = [event(1, heard: "mute")]
        XCTAssertEqual(VoiceLiveRailModel.visible(events: e, tell: .muted, expanded: false).count, 1)
    }

    func test_collapsedShowsOneRowNewestFirst() {
        let e = [event(1, heard: "first"), event(1, heard: "second"), event(1, heard: "third")]
        let rows = VoiceLiveRailModel.visible(events: e, tell: .armed, expanded: false)
        XCTAssertEqual(rows.count, VoiceLiveRailModel.collapsedCount)
        XCTAssertEqual(rows.first?.heard, "third")
    }

    func test_expandedIsCappedAndStaysNewestFirst() {
        let e = (1...20).map { event(1, heard: "line \($0)") }
        let rows = VoiceLiveRailModel.visible(events: e, tell: .armed, expanded: true)
        XCTAssertEqual(rows.count, VoiceLiveRailModel.expandedCount)
        XCTAssertEqual(rows.first?.heard, "line 20")
        XCTAssertEqual(rows.last?.heard, "line 15")
    }

    func test_aStaleDecisionFallsOutOfTheRail() {
        let e = [event(1, heard: "an hour ago")]
        let later = Date().addingTimeInterval(VoiceLiveRailModel.window + 60)
        XCTAssertTrue(VoiceLiveRailModel.visible(events: e, tell: .armed, expanded: true, now: later).isEmpty,
                      "the rail is showing a decision that stopped being live")
    }

    func test_theMoreCountNeverPromisesRowsThatDoNotExist() {
        let two = [event(1, heard: "a"), event(1, heard: "b")]
        XCTAssertEqual(VoiceLiveRailModel.hiddenCount(events: two, tell: .armed), 1)
        let one = [event(1, heard: "a")]
        XCTAssertEqual(VoiceLiveRailModel.hiddenCount(events: one, tell: .armed), 0)
        XCTAssertEqual(VoiceLiveRailModel.hiddenCount(events: [], tell: .armed), 0)
    }

    func test_anEmptyStreamRendersNothingRatherThanAnEmptyBox() {
        XCTAssertTrue(VoiceLiveRailModel.visible(events: [], tell: .armed, expanded: false).isEmpty)
    }
}
