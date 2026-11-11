import XCTest
@testable import Grux

/// D142 items 1 and 2 (sense pass 16, `logs/fr85/setup-1.png` beside
/// `yourGrux-1.png`): "Here's your Grux" said "7 things it sets up first" and
/// the next step, "Set up what you picked", listed nine (Today, Approvals and
/// Settings, which every Grux has, were added back), while Mailbox, which
/// "Needs 1 thing", appeared nowhere on it and showed no "1 left", so a
/// stranger read Mailbox as dropped.
@MainActor
final class SetupFirstScreenAgreesTests: XCTestCase {

    private let mailboxNeed = SetupOrder.Item(requirement: SetupRequirement.allCases[0], neededBy: ["mailbox"])

    private func plan() -> SetupOrder.Plan {
        SetupOrder.Plan(ready: ["home", "chat", "approvals", "tasks", "calendar", "notes", "commands", "settings"],
                        required: [mailboxNeed], optional: [], needsSignIn: ["agents"])
    }

    func testTheFirstScreenListsOnlyWhatHeresYourGruxListed() {
        let picked = ["home", "chat", "approvals", "tasks", "agents", "mailbox", "calendar", "notes", "commands", "settings"]
        let s = Setup.readySummary(plan(), signInExpired: true)
        XCTAssertEqual(s.working, ["chat", "tasks", "calendar", "notes", "commands"])
        XCTAssertEqual(s.next, ["mailbox"])
        // Every feature the person was shown is on this screen exactly once,
        // and nothing else is: working, waiting on the sign-in, or next.
        let onScreen = s.working + ["agents"] + s.next
        XCTAssertEqual(Set(onScreen), Set(YourGrux.shown(picked)))
        XCTAssertEqual(onScreen.count, YourGrux.shown(picked).count)
    }

    func testWithTheSignInGoodAgentsReadsWorking() {
        let s = Setup.readySummary(plan(), signInExpired: false)
        XCTAssertEqual(s.working, ["chat", "tasks", "calendar", "notes", "commands", "agents"])
        XCTAssertEqual(s.next, ["mailbox"])
    }

    func testOneFeatureNeedingTwoThingsIsNamedOnce() {
        let p = SetupOrder.Plan(ready: ["chat"], required: [
            SetupOrder.Item(requirement: SetupRequirement.allCases[0], neededBy: ["mailbox", "notes"]),
            SetupOrder.Item(requirement: SetupRequirement.allCases[1], neededBy: ["mailbox"]),
        ], optional: [])
        XCTAssertEqual(Setup.readySummary(p, signInExpired: false).next, ["mailbox", "notes"])
    }

    func testTheFirstScreenCountsWhatFollows() {
        // One at a time: Mailbox's screen follows, so the first screen says "1 left".
        let walk = SetupOrder.screens(for: plan(), oneAtATime: true, extrasAccepted: false)
        XCTAssertEqual(Setup.leftLine(walk, at: 0), "1 left")
        XCTAssertEqual(Setup.leftLine(walk, at: 1), "1 left")
        // The whole list: one screen follows.
        let all = SetupOrder.screens(for: plan(), oneAtATime: false, extrasAccepted: false)
        XCTAssertEqual(Setup.leftLine(all, at: 0), "1 left")
        // Nothing follows: no count.
        let none = SetupOrder.screens(for: SetupOrder.Plan(ready: ["chat"], required: [], optional: []),
                                      oneAtATime: true, extrasAccepted: false)
        XCTAssertNil(Setup.leftLine(none, at: 0))
        XCTAssertNil(Setup.leftLine(walk, at: 5))
    }

    func testTheScreenDrawsFromTheSummary() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/FirstRunScreens.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("Setup.readySummary("))
        XCTAssertTrue(src.contains("Setup.leftLine(screens, at: index)"))
        XCTAssertTrue(src.contains("Text(Setup.nextLead)"))
        XCTAssertFalse(src.contains("let ids = readyIds + "), "the old list added back what every Grux has")
    }
}
