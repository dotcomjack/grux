import XCTest
@testable import Grux

/// D115 item 4 (sense pass 10, `fr55/yourGrux-1.png`, `fr55/setup-1.png`,
/// `settings-sessions-1.png`): with the Claude CLI installed and the last
/// agent run having found its sign-in expired, "Here's your Grux" said Agents
/// "Ready", "Set up what you picked" listed Agents under "Already working",
/// and Settings, Sessions showed the CLI path with no word about the sign-in,
/// while the sidebar said "Claude sign-in expired". All three now ask the one
/// rule the setup card already used (`CapabilitySetupCard.listsAgentSignIn`).
@MainActor
final class AgentSignInReadinessTests: XCTestCase {

    private func rows(_ ids: [String]) -> [FeatureRow] {
        ids.compactMap { FeatureRegistry.row(id: $0) }
    }

    // MARK: - Set up what you picked

    func test_anExpiredSignInKeepsAgentsOutOfAlreadyWorking() {
        let plan = SetupOrder.plan(features: rows(["agents", "notes"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in true }, signInExpired: true)
        XCTAssertFalse(plan.ready.contains("agents"), "Agents is called working with the sign-in expired")
        XCTAssertEqual(plan.needsSignIn, ["agents"])
        XCTAssertEqual(plan.ready, ["notes"], "a feature that never runs the agent is unaffected")
    }

    func test_aSignInThatWorksLeavesAgentsWorking() {
        let plan = SetupOrder.plan(features: rows(["agents"]), listening: false,
                                   listeningStarted: false, satisfied: { _ in true }, signInExpired: false)
        XCTAssertEqual(plan.ready, ["agents"])
        XCTAssertEqual(plan.needsSignIn, [])
    }

    /// With the CLI not installed, installing it is the item, and the sign-in
    /// comes after that (the card and `grux next` decide the same).
    func test_aMissingCLIIsAskedNotTheSignIn() {
        let plan = SetupOrder.plan(features: rows(["agents"]), listening: false, listeningStarted: false,
                                   satisfied: { $0 != .stepAgentCliInstalled }, signInExpired: true)
        XCTAssertEqual(plan.needsSignIn, [])
        XCTAssertEqual(plan.required.map(\.requirement), [.stepAgentCliInstalled])
    }

    /// The ready screen is shown when the only thing waiting is the sign-in.
    func test_theReadyScreenShowsWhenOnlyTheSignInWaits() {
        let plan = SetupOrder.Plan(ready: [], required: [], optional: [], needsSignIn: ["agents"])
        let screens = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: false, decisionsKey: false)
        XCTAssertEqual(screens.first, .ready([]))
    }

    func test_theSetupScreenSaysWhatIsWaitingAndWhy() {
        XCTAssertEqual(Setup.needsSignInLead, "Still needs a Claude sign-in:")
        XCTAssertEqual(Setup.needsSignInNote(["Agents"]), CapabilitySetupCard.agentSignInRemediation)
    }

    /// W32-P3 item 2: the note under the list said "Agents cannot run" when
    /// the list held only Jax Command or Self-Upgrade. One feature is named
    /// as its own setup card names it; several are "these".
    func test_theNoteNamesWhatTheListHolds() {
        XCTAssertEqual(Setup.needsSignInNote(["Jax Command"]),
                       CapabilitySetupCard.agentSignInRemediation(featureLabel: "Jax Command"))
        let both = Setup.needsSignInNote(["Agents", "Self-Upgrade"])
        XCTAssertEqual(both, "What these hand to Claude cannot run until you sign in. "
                       + "Sign in opens Claude's login in Terminal, and it finishes in your browser.")
        XCTAssertFalse(Setup.needsSignInNote(["Self-Upgrade", "Jax Command"]).contains("Agents"))
    }

    // MARK: - Here's your Grux

    func test_heresYourGruxDoesNotCallAgentsReadyWithTheSignInExpired() {
        XCTAssertEqual(YourGrux.status("agents", satisfied: { _ in true }, signInExpired: true),
                       "Needs a Claude sign-in")
        XCTAssertFalse(YourGrux.isReady("agents", satisfied: { _ in true }, signInExpired: true))
        XCTAssertEqual(YourGrux.status("agents", satisfied: { _ in true }, signInExpired: false), "Ready")
        XCTAssertTrue(YourGrux.isReady("agents", satisfied: { _ in true }, signInExpired: false))
    }

    /// Counted as one more thing beside anything else missing, as the card counts it.
    func test_theSignInIsCountedBesideOtherGaps() {
        XCTAssertEqual(YourGrux.status("jax.command", satisfied: { $0 != .stepCorpusSourcesConfirmed },
                                       signInExpired: true), "Needs 2 things")
        XCTAssertEqual(YourGrux.status("agents", satisfied: { $0 != .stepAgentCliInstalled },
                                       signInExpired: true), "Needs 1 thing",
                       "a missing CLI is the one thing, not the CLI and the sign-in")
        XCTAssertEqual(YourGrux.status("calendar", satisfied: { _ in true }, signInExpired: true), "Ready")
    }

    // MARK: - Settings, Sessions

    func test_sessionsSaysTheSignInExpiredUnderTheCLI() {
        XCTAssertEqual(TerminalSessionsSettingsView.signInLine(binaryFound: true, expired: true),
                       "Expired. The last agent run found Claude's sign-in expired, so sessions cannot start until you sign in.")
        XCTAssertEqual(TerminalSessionsSettingsView.signInLine(binaryFound: true, expired: false),
                       "No agent run has found a problem with it.")
        XCTAssertNil(TerminalSessionsSettingsView.signInLine(binaryFound: false, expired: true),
                     "with no CLI the pane already says to install one")
    }

    // MARK: - The live screens read the stored verdict

    func test_theLiveScreensAskTheStoredVerdict() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let firstRun = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        XCTAssertTrue(firstRun.contains("signInExpired: ClaudeSignInState.shared.expired"),
                      "the first-run screens must pass the stored sign-in verdict")
        let sessions = try source("Sources/Grux/Settings/TerminalSessionsSettingsView.swift")
        XCTAssertTrue(sessions.contains("expired: claudeSignIn.expired"),
                      "Sessions must read the stored sign-in verdict")
    }
}
