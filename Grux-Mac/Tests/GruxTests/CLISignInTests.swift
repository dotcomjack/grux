import XCTest
@testable import GruxSetupCore

/// D103 (sense pass 9, 2026-10-31): the app led Now with "Claude sign-in expired, Agents
/// cannot run until you sign in", while `grux next` named Mail server and `grux doctor`
/// opened "Nothing on this screen asks you for anything" and never mentioned it. Both read
/// the app's stored verdict now, through the one decision they share.
final class CLISignInTests: XCTestCase {
    private func feature(_ id: String, _ label: String, chosen: Bool = true,
                         requires: [String] = [], steps: [String] = []) -> SetupStatus.Feature {
        .init(id: id, label: label, tier: "labs", state: "needsSetup", chosen: chosen,
              missing: [], requires: requires, optional: [], steps: steps,
              optionalSteps: [], anyOf: [], dependsOn: [])
    }

    private func status(_ features: [SetupStatus.Feature]) -> SetupStatus {
        let caps: [SetupStatus.Capability] = [
            .init(id: "endpoint.imap", kind: "endpoint", label: "Mail server", satisfied: false,
                  selfAttested: false, remediation: "Set up Mail server."),
        ]
        return SetupStatus(schema: SetupStatus.supportedSchema, generatedAt: "", appVersion: "3.1.0",
                           capabilities: caps, features: features,
                           summary: .init(capabilities: caps.count, satisfied: 0, selfAttested: 0,
                                          featuresReady: 0, featuresNeedingSetup: 0,
                                          featuresChosen: features.filter(\.chosen).count))
    }

    private let agentStep = ClaudeSignIn.agentStep

    /// The Mini's shape: Mailbox and Agents on, no mail server, the sign-in expired.
    func testAnExpiredSignInComesFirst() {
        let s = status([feature("mailbox", "Mailbox", requires: ["endpoint.imap"]),
                        feature("agents", "Agents", steps: [agentStep, "step.terminal_sessions_explained"]),
                        feature("self.upgrade", "Self-Upgrade", chosen: false, steps: [agentStep])])
        XCTAssertEqual(NextStep.pick(s, signInExpired: true), .signIn(blocking: [s.features[1]]))
        XCTAssertFalse(NextStep.pick(s, signInExpired: true).isClear)
        guard case .unblock(let c, _, _) = NextStep.pick(s, signInExpired: false) else {
            return XCTFail("\(NextStep.pick(s, signInExpired: false))")
        }
        XCTAssertEqual(c.id, "endpoint.imap")
    }

    /// Wave 28 round 2 (P2): the app's Now leads with the expired sign-in whatever is
    /// chosen (Design Studio's subscription route and workflow agents set the verdict
    /// too), while `next` said "Nothing." when no chosen feature needed the CLI outright.
    /// The CLI now answers it whenever Now shows it, and names as unable to run only the
    /// chosen features that require the CLI: Chat lists it as optional and runs without
    /// it ("Chat and Agents cannot run" was read live on the Mini, wave 28 round 2).
    func testTheCLIAnswersTheSignInWheneverNowShowsIt() {
        let design = feature("design.studio", "Design Studio", requires: [])
        var withOptional = design; withOptional.optionalSteps = [agentStep]
        var chat = feature("chat", "Chat"); chat.optionalSteps = [agentStep]
        let s = status([feature("notes", "Notes"), withOptional, chat,
                        feature("agents", "Agents", chosen: false, steps: [agentStep])])
        XCTAssertEqual(NextStep.pick(s, signInExpired: true), .signIn(blocking: []))
        let both = status([chat, feature("agents", "Agents", steps: [agentStep])])
        XCTAssertEqual(NextStep.pick(both, signInExpired: true), .signIn(blocking: [both.features[1]]))
        let none = status([feature("notes", "Notes")])
        XCTAssertEqual(NextStep.pick(none, signInExpired: true), .signIn(blocking: []))
        XCTAssertTrue(NextStep.pick(none, signInExpired: false).isClear)
        let mail = status([feature("mailbox", "Mailbox", requires: ["endpoint.imap"])])
        XCTAssertEqual(NextStep.pick(mail, signInExpired: true), .signIn(blocking: []))
        // With no feature to name, the words say what the app's row says.
        let a = ClaudeSignIn.nextAnswer(blocking: [], list: { $0.joined(separator: " and ") })
        XCTAssertTrue(a.why.hasPrefix("The last agent run found Claude's sign-in expired, so agent runs cannot start until you sign in."), a.why)
        XCTAssertEqual(ClaudeSignIn.blockedPhrase([], list: { $0.joined() }), "agent runs cannot start")
        XCTAssertEqual(ClaudeSignIn.blockedPhrase(["Agents"], list: { $0.joined() }), "Agents cannot run")
    }

    /// An expired sign-in with nothing else missing is not "in order".
    func testAnExpiredSignInAloneIsNotClear() {
        let s = status([feature("agents", "Agents", steps: [agentStep])])
        XCTAssertEqual(NextStep.pick(s, signInExpired: true), .signIn(blocking: [s.features[0]]))
        XCTAssertTrue(NextStep.pick(s, signInExpired: false).isClear)
    }

    func testTheStoredVerdictIsReadAsTheAppWritesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("claude-sign-in.json")
        XCTAssertFalse(ClaudeSignIn.expired(at: url), "no file: no run has failed on the sign-in")
        for (body, want) in [(#"{"expired":true}"#, true), (#"{"expired":false}"#, false),
                             ("not json", false), ("{}", false)] {
            try body.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(ClaudeSignIn.expired(at: url), want, body)
        }
        XCTAssertTrue(ClaudeSignIn.defaultURL.path.hasSuffix("Library/Application Support/Grux/claude-sign-in.json"))
        XCTAssertEqual(ClaudeSignIn.agentStep, "step.agent_cli_installed")
    }

    /// Both commands ask the shared decision with the stored verdict.
    func testNextAndDoctorBothReadTheVerdict() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Next.swift", "Doctor.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent("Sources/GruxCLI/Commands/\(file)"), encoding: .utf8)
            XCTAssertTrue(src.contains("NextStep.pick(status, signInExpired: ClaudeSignIn.expired())"), file)
            XCTAssertTrue(src.contains("case .signIn("), file)
        }
    }

    /// Wave 28 round 1 (P2): `next` printed `claude auth login --claudeai`, and following
    /// it never cleared the stored verdict (only the app's Sign in or a later agent run
    /// that works rewrite it), so `next` repeated the step the person had just done. The
    /// command it prints now leads to the app's Sign in, and the words say what a Terminal
    /// sign-in does and does not clear.
    func testNextPointsAtTheDoorThatClearsIt() {
        let a = ClaudeSignIn.nextAnswer(blocking: ["Agents", "Jax Command"], list: { $0.joined(separator: " and ") })
        XCTAssertEqual(a.answer, "Sign in to Claude, in Grux.")
        XCTAssertEqual(a.command, "grux open agents")
        XCTAssertEqual(a.why, "The last agent run found Claude's sign-in expired, so Agents and Jax Command cannot run until you sign in. Sign in, at the top of Now, runs Claude's login and clears this once a call goes through. Signing in from Terminal with claude auth login --claudeai works too, and Grux clears this after the next agent run that works.")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let next = (try? String(contentsOf: root.appendingPathComponent("Sources/GruxCLI/Commands/Next.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(next.contains("ClaudeSignIn.nextAnswer("), "next words its own sign-in answer")
    }

    /// Wave 28 round 1 (P3): with the Claude CLI gone from this Mac, an old expired
    /// verdict made `next` print a sign-in command that cannot run. The missing CLI is the
    /// step, as the app's setup card already decides (`listsAgentSignIn`).
    func testAMissingCLIIsTheStepNotTheSignIn() {
        var s = status([feature("agents", "Agents", requires: [], steps: [agentStep])])
        s.capabilities.append(.init(id: agentStep, kind: "step", label: "Agent CLI installed",
                                    satisfied: false, selfAttested: false, remediation: "Install the Claude CLI."))
        XCTAssertNotEqual(NextStep.pick(s, signInExpired: true), .signIn(blocking: [s.features[0]]))
        s.capabilities[s.capabilities.count - 1].satisfied = true
        XCTAssertEqual(NextStep.pick(s, signInExpired: true), .signIn(blocking: [s.features[0]]))
    }

    /// The orb's pause caption has no button behind it, so it never says to click it.
    func testThePauseCaptionPromisesNoClick() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/AgentService.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("CLICK TO RESUME"))
        XCTAssertTrue(src.contains("AGENT PAUSED · RESUME IN AGENTS"))
    }
}
