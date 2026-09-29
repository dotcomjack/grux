import XCTest
@testable import Grux

/// A person answers a waiting workflow in Chat, or with the gate's own words
/// on its Workflows card.
///
/// Before this, nothing in Chat reached a waiting run (the gate prompts say
/// "reply in chat", and the reply went to the model), and the card's only
/// button sent "approved (UI)", which no branch reads: a TestFlight triage
/// answered from the card always held, and a localize gate always translated.
@MainActor
final class WorkflowGateAnswerTests: XCTestCase {

    private var engine: CommandV2Engine!
    private var savedChat: [ChatMessage] = []
    private var savedOffline = false
    private var savedRecovery: ChatRecovery?
    private var relay: NSObjectProtocol?

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        savedChat = AppState.shared.chat
        savedOffline = AppState.shared.offlineMode
        savedRecovery = AppState.shared.chatRecovery
        AppState.shared.chat = []
        // The app puts each gate's question in Chat through this observer
        // (GruxApp); a test run has no app, so it installs the same relay.
        relay = NotificationCenter.default.addObserver(forName: .gruxCommandV2GateWaiting, object: nil, queue: nil) { note in
            guard let question = note.userInfo?["question"] as? String else { return }
            MainActor.assumeIsolated { ChatService.postGateQuestion(question) }
        }
        engine = CommandV2Engine()
        engine.load()
        await cancelEveryActiveRun()
    }

    override func tearDown() async throws {
        await cancelEveryActiveRun()
        if let relay { NotificationCenter.default.removeObserver(relay) }
        relay = nil
        AppState.shared.chat = savedChat
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chatRecovery = savedRecovery
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        engine = nil
        try await super.tearDown()
    }

    private func project() -> String { "GateApp\(UUID().uuidString.prefix(6))" }

    private func startAtGate(_ id: String, _ phase: String, file: StaticString = #filePath, line: UInt = #line) async throws -> UUID {
        guard case .success(let runId) = await engine.start(
            definitionId: id, params: ["project": .string(project())], dryRun: true
        ) else { XCTFail("start \(id)", file: file, line: line); throw CancellationError() }
        let run = try await settle(runId)
        XCTAssertEqual(run.currentPhaseId, phase, file: file, line: line)
        XCTAssertEqual(run.status, .waitingForApproval, file: file, line: line)
        return runId
    }

    /// Waits until the run finishes, or waits at a gate (at `phase` when given).
    @discardableResult
    private func settle(_ runId: UUID, at phase: String? = nil) async throws -> CommandV2Run {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let run = engine.run(id: runId) ?? engine.recentRuns.first { $0.id == runId }
            if let run, run.status.isTerminal
                || (run.status == .waitingForApproval && (phase == nil || run.currentPhaseId == phase)) {
                return run
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("run \(runId.uuidString.prefix(8)) did not settle")
        throw CancellationError()
    }

    /// Runs left waiting by any earlier test are on disk and load with the
    /// engine; each test starts with none waiting.
    private func cancelEveryActiveRun() async {
        for run in engine.activeRuns { await engine.cancel(run.id) }
    }

    // MARK: - What a waiting run accepts

    func test_triageGateAcceptsItsOwnWords() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let run = try XCTUnwrap(engine.run(id: id))
        XCTAssertEqual(engine.acceptedReplies(for: run), ["fix", "ship", "hold"])
        XCTAssertEqual(engine.buttonReplies(for: run), ["fix", "ship", "hold"],
                       "the workflow branches on the reply, so each word gets its own button")
    }

    func test_aGateOfSynonymsGetsOneButton() async throws {
        let id = try await startAtGate("ship-ios-app", "brainstorm-approval-gate")
        let run = try XCTUnwrap(engine.run(id: id))
        XCTAssertEqual(engine.acceptedReplies(for: run)?.first, "go")
        XCTAssertEqual(engine.buttonReplies(for: run), ["go"])
    }

    func test_aRunThatIsNotWaitingAcceptsNothing() async throws {
        guard case .success(let id) = await engine.start(definitionId: "smoke-hello-world", dryRun: true)
        else { return XCTFail("start") }
        let run = try await settle(id)
        XCTAssertEqual(engine.acceptedReplies(for: run), [])
        XCTAssertEqual(engine.gateAnswer(for: "yes"), .none)
    }

    // MARK: - Chat answers the gate

    func test_aChatFixReachesTheFixSwarmNotTheModel() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        let reply = ChatService.shared.answerWaitingWorkflow("Fix.", from: .person, engine: engine)
        XCTAssertNotNil(reply, "a gate word in Chat answers the gate")
        let run = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(run.phaseHistory.map(\.phaseId).suffix(2), ["decide-action", "fix-swarm"])
    }

    func test_ordinaryChatIsNotTakenAsAnAnswer() async throws {
        _ = try await startAtGate("testflight-feedback", "triage-gate")
        XCTAssertEqual(engine.gateAnswer(for: "what is the weather tomorrow"), .none)
        XCTAssertEqual(engine.gateAnswer(for: "fix the login screen please"), .none,
                       "only the word itself answers; a sentence containing it is chat")
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("thanks", from: .person, engine: engine))
    }

    func test_twoRunsWaitingOnTheSameWordAreNotGuessed() async throws {
        let a = try await startAtGate("testflight-feedback", "triage-gate")
        let b = try await startAtGate("testflight-feedback", "triage-gate")
        guard case .ambiguous(let ids) = engine.gateAnswer(for: "ship") else {
            return XCTFail("two waiting runs must not be answered on a guess")
        }
        XCTAssertEqual(Set(ids), [a, b])
        XCTAssertTrue(ChatService.shared.answerWaitingWorkflow("ship", from: .person, engine: engine)?.contains("did not pick") == true)
        XCTAssertEqual(engine.run(id: a)?.status, .waitingForApproval)
        XCTAssertEqual(engine.run(id: b)?.status, .waitingForApproval)
    }

    func test_aFreeTextGateTakesTheNextMessageButOnlyForAWhile() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        _ = ChatService.shared.answerWaitingWorkflow("yes", from: .person, engine: engine)
        var run = try await settle(id, at: "collect-feedback")
        XCTAssertEqual(run.currentPhaseId, "collect-feedback")
        XCTAssertNil(engine.acceptedReplies(for: run), "a free-text gate takes any words")

        // Long after the question, a message is ordinary chat, and the gate
        // asks again instead of becoming a dead end the card still points at.
        let asked = try XCTUnwrap(run.gateAskedAt)
        let later = asked.addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)
        XCTAssertEqual(engine.gateAnswer(for: "remind me to buy milk", sentAt: later), .stale([id]))
        let reposted = expectation(forNotification: .gruxCommandV2GateWaiting, object: nil) { note in
            note.object as? UUID == id
        }
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("remind me to buy milk", from: .person,
                                                              sentAt: later, engine: engine),
                     "the lapsed gate does not take the message; it goes on as chat")
        await fulfillment(of: [reposted], timeout: 5)
        run = try XCTUnwrap(engine.run(id: id))
        XCTAssertEqual(run.currentPhaseId, "collect-feedback")
        XCTAssertEqual(run.status, .waitingForApproval)
        XCTAssertNil(run.state["user_dictation"])
        XCTAssertGreaterThan(try XCTUnwrap(run.gateAskedAt), asked, "asking again restarts the window")

        XCTAssertNotNil(ChatService.shared.answerWaitingWorkflow("The icon is too dark.", from: .person, engine: engine),
                        "the reply after the question is asked again answers it")
        run = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(run.state["user_dictation"], .string("The icon is too dark."))
    }

    /// Integrated review, P2: after a lapse "remind me to buy milk" asked the
    /// gate again and went on as chat, the model answered it, and the person's
    /// "thanks" then became the final thoughts. A free-text gate takes a message
    /// only while its question is still Grux's latest line in Chat.
    func test_aLapsedFreeTextGateTakesNeitherTheNextMessageNorTheOneAfter() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        _ = ChatService.shared.answerWaitingWorkflow("yes", from: .person, engine: engine)
        let run = try await settle(id, at: "collect-feedback")
        XCTAssertEqual(AppState.shared.chat.last?.content,
                       DashSanitizer.stripDashesOnly(engine.gateQuestion(for: run)),
                       "control: the question did not reach Chat, so this proves nothing")
        let later = try XCTUnwrap(run.gateAskedAt).addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)

        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("remind me to buy milk", from: .person,
                                                              sentAt: later, engine: engine))
        // The model answers that message as chat.
        AppState.shared.appendChat(ChatMessage(role: .assistant, content: "Added \"buy milk\" to your tasks."))
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("thanks", from: .person, engine: engine),
                     "Grux said something else after the question, so the gate does not take the message")
        try await assertStaysWaiting(id, at: "collect-feedback")
        XCTAssertNil(engine.run(id: id)?.state["user_dictation"])

        // Control: the Workflows card's "Answer in Chat" asks the question
        // again on demand, and with nothing said after it the next message is
        // the answer.
        engine.askAgainInChat(id)
        XCTAssertEqual(AppState.shared.chat.last?.content,
                       DashSanitizer.stripDashesOnly(engine.gateQuestion(for: try XCTUnwrap(engine.run(id: id)))))
        XCTAssertNotNil(ChatService.shared.answerWaitingWorkflow("The icon is too dark.", from: .person, engine: engine))
        let done = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(done.state["user_dictation"], .string("The icon is too dark."))
    }

    /// Follow-up review P2: on a real turn the question was asked again before the
    /// turn's own reply was posted, so it was never Grux's latest line and the next
    /// message could not answer it. It is now asked after the reply, and the
    /// once-per-window limit still holds.
    func test_aLapsedGateIsAskedAgainAfterTheReplySoTheNextMessageAnswersIt() async throws {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        XCTAssertFalse(ChatReadiness.current().canSend, "control: the turn must get a reply without a model")
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        _ = ChatService.shared.answerWaitingWorkflow("yes", from: .person, engine: engine)
        var run = try await settle(id, at: "collect-feedback")
        run.gateAskedAt = Date().addingTimeInterval(-(CommandV2Engine.freeTextGateWindow + 60))
        engine.upsert(run)
        let question = DashSanitizer.stripDashesOnly(engine.gateQuestion(for: run))

        await ChatService.shared.send(userText: "what is the capital of France", initiator: .person, workflows: engine)
        let chat = AppState.shared.chat
        XCTAssertEqual(chat.last?.content, question, "the question is not Grux's latest line after the turn")
        let beforeLast = try XCTUnwrap(chat.dropLast().last)
        XCTAssertEqual(beforeLast.role, .assistant, "control: the turn posted no reply of its own")
        XCTAssertNotEqual(beforeLast.content, question)

        // The throttle holds: Grux says something else, the next message is chat,
        // and the question is not posted again inside the window.
        AppState.shared.appendChat(ChatMessage(role: .assistant, content: "Something else."))
        await ChatService.shared.send(userText: "never mind", initiator: .person, workflows: engine)
        XCTAssertEqual(AppState.shared.chat.filter { $0.content == question }.count, 2,
                       "the question was posted again inside the window")
        try await assertStaysWaiting(id, at: "collect-feedback")

        // With the question asked again last, the person's next message answers it.
        engine.askAgainInChat(id)
        await ChatService.shared.send(userText: "The icon is too dark.", initiator: .person, workflows: engine)
        let done = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(done.state["user_dictation"], .string("The icon is too dark."))
    }

    /// Round-3 review P3: a re-ask queued during a turn ran at the end of the turn even
    /// when the person had answered on the card mid-turn and the run had moved on to a
    /// second gate, which had already asked its own question: a double ask.
    func test_aReaskQueuedDuringATurnIsDroppedWhenTheRunMovedOn() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        let queue = GateReaskQueue()
        queue.add([id], engine: engine)
        // Mid-turn the person answers on the card; the run asks at its next gate.
        let answered = await engine.resume(id, userReply: "yes")
        XCTAssertTrue(answered)
        let moved = try await settle(id, at: "collect-feedback")
        final class Count: @unchecked Sendable { var n = 0 }
        let asks = Count()
        let counter = NotificationCenter.default.addObserver(forName: .gruxCommandV2GateWaiting, object: nil, queue: nil) { note in
            if note.object as? UUID == id { asks.n += 1 }
        }
        defer { NotificationCenter.default.removeObserver(counter) }

        queue.flush(engine)
        XCTAssertEqual(asks.n, 0, "the end of the turn asked the new gate again")
        XCTAssertEqual(engine.run(id: id)?.gateAskedAt, moved.gateAskedAt)

        // Control: a queued re-ask whose gate did not change still asks.
        let same = GateReaskQueue()
        same.add([id], engine: engine)
        same.flush(engine)
        XCTAssertEqual(asks.n, 1)
    }

    /// Integrated review follow-up: a stale gate asked again on every message,
    /// so chatting past a buried question re-posted it each time. It asks
    /// again at most once per window per run; between, messages are chat.
    func test_threeMessagesAfterALapseAskTheGateAgainOnce() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        _ = ChatService.shared.answerWaitingWorkflow("yes", from: .person, engine: engine)
        let run = try await settle(id, at: "collect-feedback")
        let later = try XCTUnwrap(run.gateAskedAt).addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)
        final class Count: @unchecked Sendable { var n = 0 }
        let asks = Count()
        let counter = NotificationCenter.default.addObserver(forName: .gruxCommandV2GateWaiting, object: nil, queue: nil) { note in
            if note.object as? UUID == id { asks.n += 1 }
        }
        defer { NotificationCenter.default.removeObserver(counter) }

        for (i, message) in ["remind me to buy milk", "thanks", "what is the weather tomorrow"].enumerated() {
            let sent = i == 0 ? later : Date()
            XCTAssertNil(ChatService.shared.answerWaitingWorkflow(message, from: .person, sentAt: sent, engine: engine), message)
            AppState.shared.appendChat(ChatMessage(role: .assistant, content: "Reply \(i) to other chat."))
        }
        XCTAssertEqual(asks.n, 1, "three messages after a lapse asked the gate again \(asks.n) times")
        try await assertStaysWaiting(id, at: "collect-feedback")
        XCTAssertNil(engine.run(id: id)?.state["user_dictation"])

        // A window after that one re-ask, the next message asks once more.
        var aged = try XCTUnwrap(engine.run(id: id))
        aged.gateReaskedAt = try XCTUnwrap(aged.gateReaskedAt, "the re-ask was not recorded")
            .addingTimeInterval(-(CommandV2Engine.freeTextGateWindow + 1))
        engine.upsert(aged)
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("ok", from: .person, engine: engine))
        XCTAssertEqual(asks.n, 2, "a window later the gate was not asked again")
    }

    /// The run is still at `phase`, waiting, with no new answer recorded, for
    /// the whole of a short window (polled, so a late resume is caught).
    private func assertStaysWaiting(_ runId: UUID, at phase: String,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let answered = engine.run(id: runId)?.state["user_reply_text"]
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            let run = try XCTUnwrap(engine.run(id: runId), "the run stopped waiting", file: file, line: line)
            XCTAssertEqual(run.status, .waitingForApproval, run.lastError ?? "", file: file, line: line)
            XCTAssertEqual(run.currentPhaseId, phase, file: file, line: line)
            XCTAssertEqual(run.state["user_reply_text"], answered, "an answer was recorded", file: file, line: line)
            if run.status != .waitingForApproval || run.currentPhaseId != phase { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
    }

    /// An agent's line after the window lapses neither asks the gate again
    /// nor answers it.
    func test_anAgentLineAfterAFreeTextGateLapsesNeitherReasksNorAnswers() async throws {
        let id = try await startAtGate("localize-app", "ask-final-thoughts")
        _ = ChatService.shared.answerWaitingWorkflow("yes", from: .person, engine: engine)
        let run = try await settle(id, at: "collect-feedback")
        let asked = try XCTUnwrap(run.gateAskedAt)
        let later = asked.addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)

        let reposted = expectation(forNotification: .gruxCommandV2GateWaiting, object: nil) { note in
            note.object as? UUID == id
        }
        reposted.isInverted = true
        XCTAssertNil(ChatService.shared.answerWaitingWorkflow("The icon is too dark.", from: .agent,
                                                              sentAt: later, engine: engine))
        await fulfillment(of: [reposted], timeout: 0.5)
        let after = try XCTUnwrap(engine.run(id: id))
        XCTAssertEqual(after.currentPhaseId, "collect-feedback")
        XCTAssertEqual(after.status, .waitingForApproval)
        XCTAssertEqual(after.gateAskedAt, asked)
        XCTAssertNil(after.state["user_dictation"])
    }

    // MARK: - A dry-run turn (review RV4)

    /// A live run whose gate asks "Go on?" and whose next step reaches outside
    /// (harmlessly: with no macro name it fails before it runs anything).
    private func startLiveAtGate() async throws -> UUID {
        let def = CommandV2Definition(
            id: "dryturn-live-\(UUID().uuidString.prefix(6))", displayName: "Live check", voiceTriggers: [],
            description: "test", category: .system,
            phases: [
                .init(id: "ask", displayName: "Ask", action: .userApprovalGate(prompt: "Go on?", expectedReplies: ["go"])),
                .init(id: "reach", displayName: "Reach outside", action: .builtin(name: "v1.runMacro", args: [:])),
            ])
        engine.register(def)
        guard case .success(let id) = await engine.start(definitionId: def.id, dryRun: false) else {
            XCTFail("start"); throw CancellationError()
        }
        let run = try await settle(id, at: "ask")
        XCTAssertFalse(run.isDryRun, "control: the run must be live")
        return id
    }

    /// A dry-run inject that reaches Chat with a gate word must not move a
    /// live waiting run: answering it drives a workflow, which acts outside Grux.
    func test_aDryRunTurnDoesNotAnswerALiveWaitingWorkflow() async throws {
        let id = try await startLiveAtGate()
        let reply = JaxToolGate.$dryRun.withValue(true) {
            ChatService.shared.answerWaitingWorkflow("go", from: .person, engine: engine)
        }
        XCTAssertTrue(reply?.contains("dry run") == true, reply ?? "nil")
        try await assertStaysWaiting(id, at: "ask")
    }

    /// Integrated review, P3: a run that is itself a dry run only records what
    /// it would do, so a dry-run turn may answer its gate.
    func test_aDryRunTurnAnswersTheGateOfARunThatIsItselfADryRun() async throws {
        let id = try await startAtGate("testflight-feedback", "triage-gate")
        XCTAssertTrue(try XCTUnwrap(engine.run(id: id)).isDryRun, "control: the run must be a dry run")
        let reply = JaxToolGate.$dryRun.withValue(true) {
            ChatService.shared.answerWaitingWorkflow("Fix.", from: .person, engine: engine)
        }
        XCTAssertEqual(reply?.hasPrefix("Got it."), true, reply ?? "nil")
        let run = try await settle(id, at: "never: this run ends")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(run.state["user_reply"], .string("fix"))
    }

    /// Integrated review, P2: a dry-run turn with a listed word for a lapsed
    /// gate asked it again, which re-armed a live gate for thirty minutes.
    func test_aDryRunTurnNeverAsksALapsedGateAgain() async throws {
        let id = try await startLiveAtGate()
        let asked = try XCTUnwrap(engine.run(id: id)?.gateAskedAt)
        let later = asked.addingTimeInterval(CommandV2Engine.freeTextGateWindow + 60)
        XCTAssertEqual(engine.gateAnswer(for: "go", sentAt: later), .stale([id]), "control: the gate has lapsed")
        let reposted = expectation(forNotification: .gruxCommandV2GateWaiting, object: nil) { note in
            note.object as? UUID == id
        }
        reposted.isInverted = true
        let reply = JaxToolGate.$dryRun.withValue(true) {
            ChatService.shared.answerWaitingWorkflow("go", from: .person, sentAt: later, engine: engine)
        }
        XCTAssertNil(reply)
        await fulfillment(of: [reposted], timeout: 1)
        XCTAssertEqual(engine.run(id: id)?.gateAskedAt, asked, "a dry-run turn asked the gate again")
        try await assertStaysWaiting(id, at: "ask")
    }

    /// Nor may it start one: the fast path is the same act as the tool the
    /// model would call, and that tool is held.
    func test_aDryRunTurnDoesNotStartAWorkflow() async throws {
        let def = try XCTUnwrap(engine.definition(id: "smoke-hello-world"))
        let before = engine.activeRuns.count + engine.recentRuns.count
        let started = await JaxToolGate.$dryRun.withValue(true) {
            await ChatService.shared.startWorkflow(def, params: [:], engine: engine)
        }
        let reply = try XCTUnwrap(started)
        XCTAssertTrue(reply.contains("dry run"), reply)
        XCTAssertTrue(ToolReplyCopy.problems(in: reply).isEmpty, "\(ToolReplyCopy.problems(in: reply))")
        XCTAssertEqual(engine.activeRuns.count + engine.recentRuns.count, before, "a dry-run turn started a run")
    }

    // MARK: - The question reaches Chat

    func test_aGateAnnouncesItsQuestionWithTheWordsThatAnswerIt() async throws {
        let posted = expectation(forNotification: .gruxCommandV2GateWaiting, object: nil) { note in
            (note.userInfo?["question"] as? String)?.contains("Reply fix to have me fix it first") == true
        }
        _ = try await startAtGate("testflight-feedback", "triage-gate")
        await fulfillment(of: [posted], timeout: 5)
    }

    func test_theRunIsNamedForItsProject() async throws {
        guard case .success(let id) = await engine.start(
            definitionId: "testflight-feedback", params: ["project": .string("Tracker")], dryRun: true
        ) else { return XCTFail("start") }
        let run = try await settle(id)
        XCTAssertEqual(run.displayName, "TestFlight feedback for Tracker")
        XCTAssertTrue(engine.gateQuestion(for: run).hasPrefix("TestFlight feedback for Tracker: "))
        XCTAssertEqual(CommandV2Engine.runName("localize {project}", params: [:]), "localize your project")
    }

    func test_aPauseWithoutItsOwnQuestionNamesTheWords() async throws {
        let id = try await startAtGate("ship-ios-app", "brainstorm-approval-gate")
        await engine.resume(id, userReply: "go")
        let run = try await settle(id, at: "walkthrough")
        XCTAssertEqual(run.currentPhaseId, "walkthrough")
        XCTAssertTrue(engine.gateQuestion(for: run).contains("Reply ship it"), engine.gateQuestion(for: run))
    }

    // MARK: - What Chat says when a message starts a workflow

    /// Review of e125705: a second ship run for the same app said the run's
    /// name twice and began a sentence in lower case ("Couldn't start ship the
    /// iOS app. ship the iOS app is already running, at the step ..."). One
    /// sentence, capitalized.
    func test_aSecondShipRunSaysOnceThatTheFirstIsRunning() async throws {
        let p = project()
        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        defer { try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL) }
        let def = try XCTUnwrap(engine.definition(id: "ship-ios-app"))
        let first = await ChatService.shared.startWorkflow(def, params: ["project": .string(p)], engine: engine)
        XCTAssertNotNil(first)
        let running = try XCTUnwrap(engine.activeRuns.first { $0.parameters["project"]?.stringValue == p })
        _ = try await settle(running.id)
        let second = await ChatService.shared.startWorkflow(def, params: ["project": .string(p)], engine: engine)
        XCTAssertNil(second, "the failure is already in Chat")
        let step = try XCTUnwrap(def.phases.first { $0.id == "brainstorm-approval-gate" }).displayName
        XCTAssertEqual(AppState.shared.chat.last?.content, "Ship the iOS app is already running, on this step: \(step).")
    }

    /// "localize Tracker" used to answer "Started localize {project}.": Chat
    /// named the definition, whose placeholder no run fills.
    func test_chatNamesTheWorkflowItStartedForItsProject() async throws {
        let p = project()
        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        defer { try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL) }
        for id in ["localize-app", "testflight-feedback"] {
            let def = try XCTUnwrap(engine.definition(id: id))
            let started = await ChatService.shared.startWorkflow(def, params: ["project": .string(p)], engine: engine)
            let reply = try XCTUnwrap(started)
            XCTAssertFalse(reply.contains("{"), reply)
            XCTAssertTrue(reply.contains(p), reply)
        }
    }

    /// A dry run of a ship workflow must not read like a real submission.
    func test_chatSaysWhenTheRunItStartedIsADryRun() async throws {
        let def = try XCTUnwrap(engine.definition(id: "smoke-hello-world"))
        let started = await ChatService.shared.startWorkflow(def, params: [:], engine: engine)
        let real = try XCTUnwrap(started)
        XCTAssertFalse(real.contains("dry run"), real)
        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        defer { try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL) }
        let startedDry = await ChatService.shared.startWorkflow(def, params: [:], engine: engine)
        let rehearsal = try XCTUnwrap(startedDry)
        XCTAssertTrue(rehearsal.contains("dry run"), rehearsal)
    }
}
