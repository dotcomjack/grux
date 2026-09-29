import XCTest
@testable import Grux

/// The HUD, the live rail and the notification banner render the same event.
/// This is the contract they share: what colour it is, what it says, and the
/// hard rule that no internal identifier reaches a person's eyes.
final class VoiceDecisionTellTests: XCTestCase {

    private func event(_ outcome: VoiceDecisionEvent.Outcome, id: String = "tab:calendar",
                       heard: String = "open my calendar", latencyMs: Int = 480) -> VoiceDecisionEvent {
        VoiceDecisionEvent(heard: heard, commandId: id, confidence: 0.94,
                           latencyMs: latencyMs, provider: .jev, outcome: outcome)
    }

    func test_chatterIsGreyAndCarriesNoStopwatch() {
        let e = event(.ignored, id: LocalDecisionProvider.notACommand, heard: "and then he said")
        XCTAssertEqual(e.tone, .chatter)
        XCTAssertEqual(e.latencyLine, "", "ignored chatter does not need a latency next to it")
        XCTAssertEqual(e.actionLine, "not for Grux")
    }

    func test_aDecisionCarriesItsLatency() {
        let e = event(.executed)
        XCTAssertEqual(e.tone, .decided)
        XCTAssertEqual(e.latencyLine, "480 ms")
    }

    func test_askedAndRefusedReadDifferentlyFromExecuted() {
        XCTAssertEqual(event(.askedFirst).tone, .asked)
        XCTAssertEqual(event(.refused).tone, .refused)
        XCTAssertTrue(event(.askedFirst).actionLine.hasPrefix("asked first: "))
        XCTAssertTrue(event(.refused).actionLine.hasPrefix("never by voice: "))
    }

    func test_everyToneHasItsOwnColour() {
        let tones: [VoiceDecisionEvent.Tone] = [.chatter, .decided, .asked, .refused]
        let colors = tones.map { "\($0.color)" }
        XCTAssertEqual(Set(colors).count, tones.count, "two tones render the same colour")
    }

    /// The rule Phase B's jargon test will enforce across the whole face,
    /// held here at the source so it can never reach a surface in the first
    /// place.
    func test_noInternalIdentifierReachesTheFace() {
        let cases: [(String, String)] = [
            ("tab:calendar", "opened "),
            ("macro:Morning Roundup", "ran Morning Roundup"),
            (VoiceCommandRouter.sayToChat, "sent to chat"),
            (LocalDecisionProvider.notACommand, "not for Grux"),
            ("mute", "muted"),
            ("unmute", "listening"),
        ]
        for (id, expectedPrefix) in cases {
            let line = VoiceDecisionEvent.plainAction(id)
            XCTAssertTrue(line.hasPrefix(expectedPrefix), "\(id) rendered as \(line)")
            XCTAssertFalse(line.contains(":"), "\(id) leaked a namespaced identifier as \(line)")
            XCTAssertFalse(line.contains("_"), "\(id) leaked an internal identifier as \(line)")
        }
    }

    @MainActor
    func test_aTabUsesTheSidebarsOwnLabelSoTwoSurfacesCannotDisagree() throws {
        let item = try XCTUnwrap(SidebarIA.groups.flatMap(\.items).first)
        XCTAssertEqual(VoiceDecisionEvent.plainAction("tab:\(item.key)"), "opened \(item.label)")
    }

    func test_aLongSentenceIsTrimmedRatherThanPushingTheLatencyOffTheEdge() {
        let long = String(repeating: "a very long thing said out loud ", count: 8)
        let e = event(.executed, heard: long)
        XCTAssertLessThanOrEqual(e.heardLine.count, 72)
        XCTAssertTrue(e.heardLine.hasSuffix("..."))
    }
}
