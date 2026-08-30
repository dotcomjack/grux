import XCTest
@testable import Grux

// Pure-logic coverage for CommandV2PhaseNotifier. The dispatcher's three
// fan-out side effects (UNUserNotification, encrypted phone push, Orb
// hint) all run through global singletons that we don't want to bring up
// in a unit test, so these tests target the pure decision functions:
//
//   • shouldFanOut(commandId:phaseIndex:), the milestone filter
//   • classifyPhase8(ascState:), the rejection/celebrate/pending router
//
// Together they cover the spec's "ONLY for ship-ios-app AND only when
// phaseIndex is in [2,4,5,8]" guard, plus the phase 8 sub-classification
// that determines which orb action fires.
@MainActor
final class CommandV2PhaseNotifierTests: XCTestCase {

    // MARK: - shouldFanOut filter

    func test_shouldFanOut_acceptsShipIOSAppMilestonePhases() {
        let n = CommandV2PhaseNotifier.shared
        for idx in [2, 4, 5, 8] {
            XCTAssertTrue(
                n.shouldFanOut(commandId: "ship-ios-app", phaseIndex: idx),
                "ship-ios-app phase \(idx) should fan out, it's a milestone"
            )
        }
    }

    func test_shouldFanOut_rejectsNonMilestonePhases() {
        let n = CommandV2PhaseNotifier.shared
        // Phases 1, 3, 6, 7, 9, 10, 11, 12 are non-milestone steps in the
        // ship-ios-app workflow (brainstorm, install, wait, check-status,
        // sub-branch routes, recover, celebrate-action). Notification
        // dispatch should silently drop these so the operator only sees
        // banners for the marquee moments.
        for idx in [1, 3, 6, 7, 9, 10, 11, 12, 0, -1, 99] {
            XCTAssertFalse(
                n.shouldFanOut(commandId: "ship-ios-app", phaseIndex: idx),
                "ship-ios-app phase \(idx) is not a milestone, should NOT fan out"
            )
        }
    }

    func test_shouldFanOut_rejectsOtherCommandIds() {
        let n = CommandV2PhaseNotifier.shared
        // Even on the milestone phase indices, non-ship-ios-app commands
        // must not trigger fan-out. Dispatcher is opt-in per workflow.
        for cmd in ["smoke-hello-world", "check-asc-status", "", "ship-mac-app"] {
            for idx in [2, 4, 5, 8] {
                XCTAssertFalse(
                    n.shouldFanOut(commandId: cmd, phaseIndex: idx),
                    "command '\(cmd)' phase \(idx) should NOT fan out, only ship-ios-app is wired"
                )
            }
        }
    }

    // MARK: - classifyPhase8 router

    func test_classifyPhase8_celebrateOnLiveStates() {
        // The three "we're live" ASC states. Each triggers the cinematic
        // StageController takeover via .celebrate.
        let live = ["READY_FOR_SALE", "PROCESSING_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE"]
        for s in live {
            XCTAssertEqual(
                CommandV2PhaseNotifier.classifyPhase8(ascState: s),
                .celebrate,
                "asc_state=\(s) should classify as celebrate"
            )
        }
    }

    func test_classifyPhase8_rejectionOnAppleBouncedStates() {
        // The four "Apple bounced" ASC states. Each triggers the orb alert.
        let rejected = ["REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED"]
        for s in rejected {
            XCTAssertEqual(
                CommandV2PhaseNotifier.classifyPhase8(ascState: s),
                .rejection,
                "asc_state=\(s) should classify as rejection"
            )
        }
    }

    func test_classifyPhase8_stillPendingOnUnknownOrMissingState() {
        // Default to silent, the wait loop will fire its own notification
        // when the next status check comes back. This guards against false
        // celebrations when the ASC state is missing or in transition.
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: nil), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: ""), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "WAITING_FOR_REVIEW"), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "IN_REVIEW"), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "UNKNOWN_STATE_FROM_FUTURE"), .stillPending)
    }

    func test_classifyPhase8_isCaseInsensitive() {
        // ASC payloads have historically inconsistent casing across Apple's
        // SDKs. Normalize on the way in so a lowercase response from a
        // stubbed test fixture still routes correctly.
        XCTAssertEqual(
            CommandV2PhaseNotifier.classifyPhase8(ascState: "ready_for_sale"),
            .celebrate
        )
        XCTAssertEqual(
            CommandV2PhaseNotifier.classifyPhase8(ascState: "Rejected"),
            .rejection
        )
    }

    // MARK: - handle() guard rails

    func test_handle_silentlyIgnoresMalformedUserInfo() {
        // The dispatcher must not crash on a notification with missing keys.
        // We post one with no userInfo at all and expect no exception.
        let n = CommandV2PhaseNotifier.shared
        let note = Notification(
            name: .gruxCommandV2PhaseTransitioned,
            object: nil,
            userInfo: nil
        )
        // No crash assertion, just call through. If this throws, XCTest fails.
        n.handle(note: note)
    }

    func test_handle_silentlyIgnoresMissingRunId() {
        // userInfo present but missing runId, must not fan out and must not crash.
        let n = CommandV2PhaseNotifier.shared
        let note = Notification(
            name: .gruxCommandV2PhaseTransitioned,
            object: nil,
            userInfo: [
                "commandId": "ship-ios-app",
                "toPhase": 2,
                "phaseName": "Build"
            ]
        )
        n.handle(note: note)
    }
}
