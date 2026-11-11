import XCTest
@testable import Grux

/// D146 item 14 (sense pass 17, `logs/fr90/setup-1.png` beside
/// `yourGrux-1.png` and `modelKey-1.png`): "Set up what you picked" listed
/// Listening under "Set up next" as if it were a feature, though "Here's your
/// Grux" never showed it, and with a model found Connect a model offered
/// "Skip for now" beside "Use the model on this Mac", two buttons that leave
/// chat on the same model.
@MainActor
final class FirstRunOneWayPastTests: XCTestCase {

    private let mic = SetupRequirement.permMicrophone

    func testListeningIsAChoiceNotAPickedFeature() {
        let p = SetupOrder.Plan(ready: ["chat", "commands"], required: [
            SetupOrder.Item(requirement: SetupRequirement.allCases[0], neededBy: ["mailbox"]),
            SetupOrder.Item(requirement: mic, neededBy: [SetupOrder.listeningId]),
        ], optional: [])
        let s = Setup.readySummary(p, signInExpired: false)
        XCTAssertEqual(s.next, ["mailbox"], "only features the person was shown")
        XCTAssertTrue(s.asksListening)
        XCTAssertEqual(Setup.listeningNext, "One more choice: whether Grux listens for your voice, and when.",
                       "W45-FIX P3: no \u{201C}Then\u{201D}, the microphone may be asked first when Meetings shares it")
    }

    func testListeningSharedWithAPickedFeatureStillNamesTheFeature() {
        let p = SetupOrder.Plan(ready: ["chat"], required: [
            SetupOrder.Item(requirement: mic, neededBy: ["meetings", SetupOrder.listeningId]),
        ], optional: [])
        let s = Setup.readySummary(p, signInExpired: false)
        XCTAssertEqual(s.next, ["meetings"])
        XCTAssertTrue(s.asksListening)
    }

    func testNoListeningLineWhenListeningIsAlreadyOn() {
        // listeningStarted puts it among ready, which this screen hides as well.
        let p = SetupOrder.Plan(ready: ["chat", SetupOrder.listeningId], required: [], optional: [])
        let s = Setup.readySummary(p, signInExpired: false)
        XCTAssertFalse(s.asksListening)
        XCTAssertEqual(s.working, ["chat"])
        XCTAssertEqual(s.next, [])
    }

    func testSkipShowsOnlyWhenNothingWasFound() {
        XCTAssertTrue(ModelGate.offersSkip(.none, localFailed: false))
        XCTAssertFalse(ModelGate.offersSkip(.found("qwen3.5:4b"), localFailed: false))
        // W45-FIX P3: the found model failed to connect; Skip is the way past again.
        XCTAssertTrue(ModelGate.offersSkip(.found("qwen3.5:4b"), localFailed: true))
        XCTAssertTrue(ModelGate.offersSkip(.none, localFailed: true))
    }

    func testTheScreensDrawBehindTheRules() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding")
        let model = try String(contentsOf: dir.appendingPathComponent("OnboardingView.swift"), encoding: .utf8)
        let rule = try XCTUnwrap(model.range(of: "if ModelGate.offersSkip(probe, localFailed: localError != nil) {"))
        let skip = try XCTUnwrap(model.range(of: "Button(ModelGate.skip)"))
        XCTAssertTrue(rule.lowerBound < skip.lowerBound)
        let setup = try String(contentsOf: dir.appendingPathComponent("FirstRunScreens.swift"), encoding: .utf8)
        XCTAssertTrue(setup.contains("if summary.asksListening {"))
        XCTAssertTrue(setup.contains("Text(Setup.listeningNext)"))
    }
}
