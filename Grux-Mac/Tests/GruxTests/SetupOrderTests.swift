import XCTest
@testable import Grux

/// P-F-1, Task F3: setup in an order with real logic, and a one-at-a-time mode
/// where no screen asks for more than one decision.
@MainActor
final class SetupOrderTests: XCTestCase {

    private func rows(_ ids: [String]) -> [FeatureRow] {
        ids.compactMap { FeatureRegistry.row(id: $0) }
    }

    // MARK: - Rule 1: what needs nothing is done

    func test_whatNeedsNothingIsShownDone_notAsked() {
        let plan = SetupOrder.plan(features: rows(["notes", "tasks", "calendar"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in false })
        XCTAssertEqual(plan.ready, ["notes", "tasks"])
        XCTAssertEqual(plan.required.map(\.requirement), [.permCalendar])
    }

    func test_somethingAlreadySatisfiedIsNeverAsked() {
        let plan = SetupOrder.plan(features: rows(["calendar", "contacts"]), listening: false, listeningStarted: false,
                                   satisfied: { $0 == .permCalendar })
        XCTAssertEqual(plan.ready, ["calendar"])
        XCTAssertEqual(plan.required.map(\.requirement), [.permContacts])
    }

    func test_theModelGateIsNeverAskedTwice() {
        let plan = SetupOrder.plan(features: rows(["chat", "research", "design.studio"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in false })
        let asked = Set(plan.required.map(\.requirement) + plan.optional.map(\.requirement))
        XCTAssertFalse(asked.contains(.keyAnthropic), "the model key has its own screen")
        XCTAssertFalse(asked.contains(.endpointOllama), "the local model has its own screen")
        XCTAssertTrue(plan.ready.contains("chat"), "chat needs only the model gate")
        XCTAssertEqual(plan.required.map(\.requirement), [.keyBrave])
    }

    // MARK: - Rules 2 and 3

    /// Mail and Jax HQ both need the mail server, so one screen unlocks two
    /// features and comes first even though it costs more than the key.
    func test_whatUnlocksTheMostComesFirst_thenWhatIsCheapest() {
        let plan = SetupOrder.plan(features: rows(["mailbox", "jax.hq", "creative", "calendar"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in false })
        XCTAssertEqual(plan.required.map(\.requirement), [.endpointImap, .keyReplicate, .permCalendar])
        XCTAssertEqual(plan.required.first?.neededBy, ["mailbox", "jax.hq"])
    }

    func test_theCostLadderIsToggleThenPasteThenElsewhereThenPermission() {
        XCTAssertLessThan(SetupOrder.cost(of: .stepYoutubeTranscriptsEnabled), SetupOrder.cost(of: .keyBrave))
        XCTAssertLessThan(SetupOrder.cost(of: .keyBrave), SetupOrder.cost(of: .endpointImap))
        XCTAssertLessThan(SetupOrder.cost(of: .endpointMicrosoftGraph), SetupOrder.cost(of: .permCalendar))
        XCTAssertEqual(SetupOrder.cost(of: .stepAgentCliInstalled), .elsewhere, "installing a CLI is not a toggle")
        for r in SetupRequirement.allCases where r.rawValue.hasPrefix("perm.") {
            XCTAssertEqual(SetupOrder.cost(of: r), .permission, r.rawValue)
        }
    }

    /// The red-proof the plan asks for, kept as a test: the same fixture in the
    /// other rule order comes out in a different order, so the precedence is
    /// doing work rather than agreeing by accident.
    func test_swappingTheRulesChangesTheOrder() {
        let items = [
            SetupOrder.Item(requirement: .permCalendar, neededBy: ["calendar", "home"]),
            SetupOrder.Item(requirement: .keyReplicate, neededBy: ["creative"]),
        ]
        XCTAssertEqual(SetupOrder.sorted(items).map(\.requirement), [.permCalendar, .keyReplicate])
        XCTAssertEqual(SetupOrder.sorted(items, rules: [.cheapest, .mostFeatures]).map(\.requirement),
                       [.keyReplicate, .permCalendar])
    }

    func test_aStepNeverComesBeforeThePermissionItNeeds() throws {
        // The first look is a toggle and Screen Recording is a permission, so
        // cost alone would put the look first, and it cannot capture a frame.
        let plan = SetupOrder.plan(features: rows(["focus"]), listening: false, listeningStarted: false,
                                   satisfied: { _ in false })
        let order = plan.required.map(\.requirement)
        let look = try XCTUnwrap(order.firstIndex(of: .stepFirstFrameReviewed))
        let screen = try XCTUnwrap(order.firstIndex(of: .permScreenRecording))
        XCTAssertLessThan(screen, look)
    }

    // MARK: - Listening

    func test_listeningIsInThePlanUntilItHasStarted() {
        let off = SetupOrder.plan(features: rows(["notes"]), listening: true, listeningStarted: false,
                                  satisfied: { _ in true })
        XCTAssertEqual(off.required.map(\.requirement), [.permMicrophone],
                       "a granted microphone is not consent to listen")
        XCTAssertEqual(off.required.first?.neededBy, [SetupOrder.listeningId])
        let on = SetupOrder.plan(features: rows(["notes"]), listening: true, listeningStarted: true,
                                 satisfied: { _ in true })
        XCTAssertTrue(on.required.isEmpty)
        XCTAssertTrue(on.ready.contains(SetupOrder.listeningId))
    }

    // MARK: - Rule 4: optional, once, at the end

    func test_optionalIsOfferedOnce_neverDuplicatesARequiredItem_andNeverAsksWhatIsDone() {
        let plan = SetupOrder.plan(features: rows(["chat", "calendar", "home"]), listening: false,
                                   listeningStarted: false, satisfied: { $0 == .keySlack })
        let optional = plan.optional.map(\.requirement)
        XCTAssertEqual(optional.count, Set(optional).count, "an optional item is offered twice")
        XCTAssertFalse(optional.contains(.permCalendar), "calendar is required and was offered again as optional")
        XCTAssertFalse(optional.contains(.keySlack), "a satisfied capability was offered")
        XCTAssertFalse(optional.contains(.keyAnthropic), "the model gate leaked into the extras")
        XCTAssertTrue(optional.contains(.keyNotion))
    }

    // MARK: - End to end

    /// The plan the first-run visuals draw, from a real answer on a Mac with
    /// nothing granted. One grant serves listening and Meetings, so the
    /// microphone leads even though it is a permission; then the two toggles,
    /// the mail server, and the remaining permissions last.
    func test_aRealAnswer_endToEnd_onACleanMac() {
        let ids = IntentToFeatures.keyless(answer: "Run my inbox and transcribe my meetings")
        let plan = SetupOrder.plan(features: rows(ids), listening: true, listeningStarted: false,
                                   satisfied: { _ in false })
        XCTAssertEqual(plan.ready, ["home", "chat", "approvals", "tasks", "notes", "settings"])
        XCTAssertEqual(plan.required.map(\.requirement),
                       [.permMicrophone, .stepRecordingConsentAcknowledged, .stepSpeechModelDownloaded,
                        .endpointImap, .permCalendar, .permSystemAudio])
        XCTAssertEqual(plan.required.first?.neededBy, ["meetings", SetupOrder.listeningId])
        let screens = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: false)
        XCTAssertEqual(screens.first { $0.decisions > 0 }?.remaining, 7)
        XCTAssertEqual(plan.optional.count, 15)
    }

    // MARK: - One at a time

    func test_oneAtATime_noScreenAsksForMoreThanOneDecision_andWhatRemainsIsAlwaysShown() {
        let plan = SetupOrder.plan(features: rows(["mailbox", "calendar", "contacts", "focus", "meetings", "chat"]),
                                   listening: true, listeningStarted: false, satisfied: { _ in false })
        XCTAssertGreaterThan(plan.required.count, 3)
        XCTAssertFalse(plan.optional.isEmpty)
        for extras in [false, true] {
            let screens = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: extras)
            XCTAssertFalse(screens.isEmpty)
            for screen in screens {
                XCTAssertLessThanOrEqual(screen.decisions, 1, "\(screen) asks for more than one decision")
            }
            let asking = screens.filter { $0.decisions > 0 }
            XCTAssertEqual(asking.map(\.remaining), Array((1...asking.count).reversed()),
                           "the count of what remains is missing or wrong")
        }
    }

    func test_oneAtATime_theExtrasAreOneDecisionToSkipWhole() {
        let plan = SetupOrder.plan(features: rows(["chat"]), listening: false, listeningStarted: false,
                                   satisfied: { _ in false })
        let skipped = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: false)
        XCTAssertEqual(skipped.filter { $0.decisions > 0 }.count, 1, "the extras should be one skippable offer")
        let taken = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: true)
        XCTAssertEqual(taken.filter { $0.decisions > 0 }.count, 1 + plan.optional.count)
    }

    func test_listMode_showsTheWholePlanAtOnce() {
        let plan = SetupOrder.plan(features: rows(["mailbox", "calendar", "contacts"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in false })
        let screens = SetupOrder.screens(for: plan, oneAtATime: false, extrasAccepted: false)
        XCTAssertTrue(screens.contains { $0.decisions == plan.required.count })
    }

    func test_theReadyScreenAsksNothing() {
        let plan = SetupOrder.plan(features: rows(["notes", "calendar"]), listening: false, listeningStarted: false,
                                   satisfied: { _ in false })
        let screens = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: false)
        guard case .ready(let ids)? = screens.first else { return XCTFail("the plan does not open on what is done") }
        XCTAssertEqual(ids, ["notes"])
        XCTAssertEqual(screens.first?.decisions, 0)
    }
}
