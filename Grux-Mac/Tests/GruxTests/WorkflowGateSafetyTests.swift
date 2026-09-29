import XCTest
@testable import Grux

/// Who and what may move a workflow past a gate that waits on the person.
///
/// Review findings, 2026-09-28:
/// - RV1: Chat answered a waiting gate before it looked at who was talking, so
///   a swarm's inject-chat line or an MCP `grux_ask` saying "ship" at the
///   TestFlight triage gate went on to the App Store submit with no person.
/// - RV2: a listed word ("no", "ok", "go") answered a gate at any age, so a
///   "no" typed days later to something else sent localize into translation.
/// - RV3: `resume` never checked the reply, so a blind `fire-v2-approve`
///   stored "approved (cli" and a gate that branches on the word fell through.
/// - RV15: dry run was decided only at start, so a live run saved before the
///   dry-run file existed went on to reach Apple after a relaunch.
@MainActor
final class WorkflowGateSafetyTests: XCTestCase {

    private var engine: CommandV2Engine!
    private var savedOffline = false
    private var savedChat: [ChatMessage] = []
    private var savedRecovery: ChatRecovery?

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        savedOffline = AppState.shared.offlineMode
        savedChat = AppState.shared.chat
        savedRecovery = AppState.shared.chatRecovery
        engine = CommandV2Engine()
        engine.load()
        await cancelEveryActiveRun()
    }

    override func tearDown() async throws {
        await cancelEveryActiveRun()
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chat = savedChat
        AppState.shared.chatRecovery = savedRecovery
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func project() -> String { "SafeApp\(UUID().uuidString.prefix(6))" }

    private func cancelEveryActiveRun() async {
        for run in engine.activeRuns { await engine.cancel(run.id) }
    }

    private func current(_ runId: UUID) -> CommandV2Run? {
        engine.run(id: runId) ?? engine.recentRuns.first { $0.id == runId }
    }

    /// Waits until the run finishes, or waits at a gate (at `phase` when given).
    @discardableResult
    private func settle(_ runId: UUID, at phase: String? = nil, in which: CommandV2Engine? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> CommandV2Run {
        let eng = which ?? engine!
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let run = eng.run(id: runId) ?? eng.recentRuns.first { $0.id == runId }
            if let run, run.status.isTerminal
                || (run.status == .waitingForApproval && (phase == nil || run.currentPhaseId == phase)) {
                return run
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("run \(runId.uuidString.prefix(8)) did not settle", file: file, line: line)
        throw CancellationError()
    }

    private func startAtGate(_ id: String, _ phase: String, file: StaticString = #filePath, line: UInt = #line) async throws -> UUID {
        guard case .success(let runId) = await engine.start(
            definitionId: id, params: ["project": .string(project())], dryRun: true
        ) else { XCTFail("start \(id)", file: file, line: line); throw CancellationError() }
        let run = try await settle(runId, at: phase, file: file, line: line)
        XCTAssertEqual(run.currentPhaseId, phase, file: file, line: line)
        XCTAssertEqual(run.status, .waitingForApproval, file: file, line: line)
        return runId
    }

    /// The run is still at `phase`, waiting, with no answer recorded, for the
    /// whole of a short window. Polled until the deadline, so a resume that
    /// lands late is caught rather than slept past.
    private func assertStillWaiting(_ runId: UUID, at phase: String,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            let run = try XCTUnwrap(current(runId), file: file, line: line)
            XCTAssertEqual(run.status, .waitingForApproval, run.lastError ?? "", file: file, line: line)
            XCTAssertEqual(run.currentPhaseId, phase, file: file, line: line)
            XCTAssertNil(run.state["user_reply"], "an answer was recorded", file: file, line: line)
            if run.status != .waitingForApproval || run.currentPhaseId != phase { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
    }

    /// Chat with no model to talk to, so a turn that is not a gate answer is
    /// refused locally and never reaches a provider.
    private func chatWithNoModel() {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.chat = []
        AppState.shared.chatRecovery = nil
        XCTAssertFalse(ChatReadiness.current().canSend, "control: chat must not be able to reach a model here")
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - RV1: only the person answers a gate

    /// Control: the person's own Chat turn still answers, through the same
    /// `send` the agent doors use.
    func test_thePersonsOwnChatTurnAnswersTheGate() async throws {
        chatWithNoModel()
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        await ChatService.shared.send(userText: "hold", initiator: .person, workflows: engine)
        let run = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(run.state["user_reply"], .string("hold"))
    }

    /// Swarm agents report through ~/.grux/inject-chat.
    func test_aSwarmLineFromInjectChatNeverAnswersAGate() async throws {
        XCTAssertTrue(try source("GruxApp.swift").contains("ChatService.shared.send(userText: trimmed, initiator: .agent)"),
                      "the inject-chat door says its words are an agent's")
        chatWithNoModel()
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        await ChatService.shared.send(userText: "ship", initiator: .agent, workflows: engine)
        try await assertStillWaiting(id, at: "triage-gate")
    }

    /// Another program asking Grux a question over MCP.
    func test_anMCPAskNeverAnswersAGate() async throws {
        XCTAssertTrue(try source("Onboarding/GruxControlTools+Ask.swift")
                        .contains("ChatService.shared.send(userText: question, initiator: .agent)"),
                      "grux_ask says its words are an agent's")
        chatWithNoModel()
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        await ChatService.shared.send(userText: "fix", initiator: .agent, workflows: engine)
        try await assertStillWaiting(id, at: "triage-gate")
    }

    /// A PIM card an agent raised hands its words to Chat as the agent's.
    func test_aCardAnAgentRaisedNeverAnswersAGate() async throws {
        let card = try source("Voice/PIMConfirmationCard.swift")
        XCTAssertEqual(card.components(separatedBy: "initiator: personAsked ? .person : .agent").count - 1, 2,
                       "both of the card's hand-offs to Chat keep who asked")
        chatWithNoModel()
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        await ChatService.shared.send(userText: "no", initiator: .agent, workflows: engine)
        try await assertStillWaiting(id, at: "ask-final-thoughts")
    }

    /// The one place a Chat message can resume a gate refuses an agent itself,
    /// whatever door the words came through.
    func test_theGateAnswerItselfRefusesAnAgent() async throws {
        let id = try await startAtGate("ship-ios-app", "brainstorm-approval-gate")
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("go", from: .agent, engine: engine))
        try await assertStillWaiting(id, at: "brainstorm-approval-gate")
    }

    /// Every call into Chat either says who is talking or sits in a file that
    /// only ever carries the person's own words. A new door has to be sorted
    /// here, so an automation cannot fall into `.person` by default.
    func test_everyDoorIntoChatSaysWhoIsTalking() throws {
        let personDoors: Set<String> = [
            "ChatView.swift", "Shell/CommandPanelRoot.swift", "Ambient/AmbientListener.swift",
            "Decisions/VoiceCommandRouter.swift", "iPhone/PhoneChatBridge.swift", "Onboarding/OnboardingModel.swift",
        ]
        let root = sources.path + "/"
        var undeclared: [String] = []
        var calls = 0
        let files = FileManager.default.enumerator(atPath: sources.path)?.compactMap { $0 as? String } ?? []
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: root + relative, encoding: .utf8)
            let found = Self.chatSendCalls(in: text)
            calls += found.count
            if !personDoors.contains(relative) {
                undeclared += found.filter { !$0.contains("initiator:") }.map { "\(relative): \($0)" }
            }
        }
        XCTAssertGreaterThanOrEqual(calls, 12, "control: the sweep must find the known doors")
        XCTAssertEqual(undeclared, [], "a door into Chat outside the person's own surfaces must say who is talking")

        // The sweep bites.
        let fake = "Timer.scheduledTimer { _ in Task { await ChatService.shared.send(userText: line) } }"
        XCTAssertEqual(Self.chatSendCalls(in: fake).filter { !$0.contains("initiator:") }.count, 1)
    }

    /// The argument list of every `ChatService.shared.send(` call in `text`.
    private static func chatSendCalls(in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "ChatService.shared.send(") {
            var depth = 1
            var idx = start.upperBound
            while idx < rest.endIndex, depth > 0 {
                if rest[idx] == "(" { depth += 1 } else if rest[idx] == ")" { depth -= 1 }
                idx = rest.index(after: idx)
            }
            out.append(String(rest[start.lowerBound..<idx]))
            rest = rest[idx...]
        }
        return out
    }

    // MARK: - RV2: a listed word answers only a question just asked

    func test_aNoTypedDaysLaterDoesNotSendLocalizeIntoTranslation() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        let days = Date().addingTimeInterval(3 * 24 * 3600)
        XCTAssertEqual(engine.gateAnswer(for: "no", sentAt: days), .stale([id]))
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("no", from: .person, sentAt: days, engine: engine),
                     "an old gate does not take an unrelated word")
        try await assertStillWaiting(id, at: "ask-final-thoughts")
    }

    func test_anOldGateIsAskedAgainAndTheNextReplyAnswersIt() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let asked = try XCTUnwrap(engine.run(id: id)?.gateAskedAt, "the gate records when it asked")
        let reposted = expectation(forNotification: .gruxCommandV2GateWaiting, object: nil) { note in
            note.object as? UUID == id
        }
        let later = asked.addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("hold", from: .person, sentAt: later, engine: engine))
        await fulfillment(of: [reposted], timeout: 5)
        let reasked = try XCTUnwrap(engine.run(id: id)?.gateAskedAt)
        XCTAssertGreaterThan(reasked, asked, "asking again restarts the window")
        try await assertStillWaiting(id, at: "triage-gate")

        XCTAssertNotNil(ChatService.shared.answerWaitingWorkflow("hold", from: .person, engine: engine),
                        "right after the question is asked again, the word answers it")
        let run = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
    }

    func test_aMessageSentBeforeTheQuestionIsNotItsAnswer() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let asked = engine.run(id: id)?.gateAskedAt ?? Date()
        XCTAssertEqual(engine.gateAnswer(for: "ship", sentAt: asked.addingTimeInterval(-5)), .none)
    }

    func test_aGateSavedBeforeItRecordedWhenItAskedIsAskedAgain() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        var saved = try XCTUnwrap(engine.run(id: id))
        saved.gateAskedAt = nil
        engine.upsert(saved)
        XCTAssertEqual(engine.gateAnswer(for: "ship"), .stale([id]))
    }

    // MARK: - RV3: resume takes only an answer the gate asked for

    func test_resumeRefusesAWordTheGateDidNotAskFor() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let resumed = await engine.resume(id, userReply: "approved (CLI)")
        XCTAssertFalse(resumed)
        try await assertStillWaiting(id, at: "triage-gate")
    }

    func test_aBlindApproveNeverAnswersAGateThatBranchesOnTheWord() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let resumed = await engine.resume(id, userReply: nil)
        XCTAssertFalse(resumed, "fix, ship and hold are choices, not an OK")
        try await assertStillWaiting(id, at: "triage-gate")
    }

    func test_aBlindApproveTakesTheGatesOwnApproveWordAndRecordsIt() async throws {
        let id = try await startAtGate("ship-ios-app", "brainstorm-approval-gate")
        let resumed = await engine.resume(id, userReply: nil)
        XCTAssertTrue(resumed)
        let run = try await settle(id, at: "walkthrough")
        XCTAssertEqual(run.state["user_reply"], .string("go"), "the word it used, never a placeholder")
        let gateLog = run.phaseHistory.last { $0.phaseId == "brainstorm-approval-gate" }?.log ?? ""
        XCTAssertTrue(gateLog.hasSuffix("No reply came with it, so this took the step's own word, \"go\"."), gateLog)
    }

    /// Integrated review, P3: final thoughts offers a choice (yes, no, skip),
    /// and a blind approve is not a choice, so it leaves the gate waiting.
    func test_aBlindApproveAtFinalThoughtsLeavesTheChoiceWaiting() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        let run = try XCTUnwrap(engine.run(id: id))
        XCTAssertTrue(engine.acceptedReplies(for: run)?.contains("yes") == true,
                      "control: the gate lists an approve word, so only the choice rule refuses it")
        let resumed = await engine.resume(id, userReply: nil)
        XCTAssertFalse(resumed, "yes, no and skip are choices, not an OK")
        try await assertStillWaiting(id, at: "ask-final-thoughts")
    }

    func test_aBlindApproveNeverAnswersAQuestionThatWantsWords() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        let answered = await engine.resume(id, userReply: "yes")
        XCTAssertTrue(answered)
        _ = try await settle(id, at: "collect-feedback")
        let resumed = await engine.resume(id, userReply: nil)
        XCTAssertFalse(resumed)
        let run = try XCTUnwrap(current(id))
        XCTAssertEqual(run.currentPhaseId, "collect-feedback")
        XCTAssertEqual(run.status, .waitingForApproval)
    }

    func test_theApproveFileNoLongerInventsAReply() throws {
        let triggers = try source("Triggers/AppTriggers.swift")
        XCTAssertFalse(triggers.contains("approved (CLI)"), "a blind approve names no reply and lets the gate pick")
    }

    // MARK: - RV15: dry run belongs to the run and survives a relaunch

    private func outsideDefinition(_ id: String, first: CommandV2Definition.Phase) -> CommandV2Definition {
        CommandV2Definition(
            id: id, displayName: id, voiceTriggers: [], description: "test", category: .system,
            phases: [
                first,
                // Outside the run, and harmless: with no macro name it fails
                // before it runs anything.
                .init(id: "reach", displayName: "Reach outside", action: .builtin(name: "v1.runMacro", args: [:]))
            ])
    }

    private func relaunched(with def: CommandV2Definition) -> CommandV2Engine {
        let next = CommandV2Engine()
        next.register(def)
        next.load()
        return next
    }

    func test_aLiveRunSavedBeforeDryRunsWereOnIsRefusedAtResume() async throws {
        let def = outsideDefinition("rv15-gate-\(UUID().uuidString.prefix(6))", first: .init(
            id: "ask", displayName: "Ask", action: .userApprovalGate(prompt: "Go on?", expectedReplies: ["go"])))
        engine.register(def)
        guard case .success(let id) = await engine.start(definitionId: def.id, dryRun: false) else { return XCTFail("start") }
        let waiting = try await settle(id, at: "ask")
        XCTAssertFalse(waiting.isDryRun)

        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        let next = relaunched(with: def)
        await next.resume(id, userReply: "go")
        let run = try await settle(id, in: next)
        XCTAssertFalse(run.phaseHistory.contains { $0.phaseId == "reach" }, "a live run went on to reach outside under dry run")
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.lastError?.contains("dry run") == true, run.lastError ?? "no reason recorded")
    }

    func test_aLiveRunWaitingOnTheClockIsRefusedWhenItWakesUnderDryRun() async throws {
        let def = outsideDefinition("rv15-wait-\(UUID().uuidString.prefix(6))", first: .init(
            id: "wait", displayName: "Wait", action: .noop,
            scheduledFollowup: .init(nextPhaseId: "reach", interval: 3600)))
        engine.register(def)
        guard case .success(let id) = await engine.start(definitionId: def.id, dryRun: false) else { return XCTFail("start") }
        let deadline = Date().addingTimeInterval(10)
        while engine.run(id: id)?.status != .waitingScheduled, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(engine.run(id: id)?.status, .waitingScheduled)

        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        let next = relaunched(with: def)
        await next.handleScheduledWake(runId: id, phase: "reach")
        let run = try await settle(id, in: next)
        XCTAssertFalse(run.phaseHistory.contains { $0.phaseId == "reach" }, "a live run went on to reach outside under dry run")
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.lastError?.contains("dry run") == true, run.lastError ?? "no reason recorded")
    }

    func test_aRunStartedDryStaysDryAfterARelaunch() async throws {
        let def = outsideDefinition("rv15-dry-\(UUID().uuidString.prefix(6))", first: .init(
            id: "ask", displayName: "Ask", action: .userApprovalGate(prompt: "Go on?", expectedReplies: ["go"])))
        engine.register(def)
        guard case .success(let id) = await engine.start(definitionId: def.id, dryRun: true) else { return XCTFail("start") }
        _ = try await settle(id, at: "ask")

        let next = relaunched(with: def)
        await next.resume(id, userReply: "go")
        let run = try await settle(id, in: next)
        XCTAssertTrue(run.isDryRun)
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(run.phaseHistory.last { $0.phaseId == "reach" }?.log, "Dry run, so \"Reach outside\" did not run. A real run would do it.")
    }
}
