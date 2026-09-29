import XCTest
@testable import Grux

/// A dry-run inject is dry for everything that acts outside Grux, not only the
/// router's own commands (review RV4). Words it hands to Chat run as a dry-run
/// turn, in which every tool except Grux's own-state tools records what it
/// would do. And a dry run leaves the listener as it found it: no chime, no
/// greeting, no armed window, no spent grace chunk (review RV10).
@MainActor
final class InjectDryRunTests: XCTestCase {

    // MARK: The rule, from the registry

    /// Every tool the model can call is either one that stays inside Grux or
    /// held. The inside list only ever holds tools the gate already waves
    /// through, so a gated, classified or self-gating tool can never run in a
    /// dry run, and a tool added tomorrow is held until somebody decides.
    func test_everyToolThatIsNotGruxsOwnStateIsHeldInADryRun() {
        let all = Set(ChatService.allTools().map(\.name))
        XCTAssertGreaterThan(all.count, 50, "control: the tool registry did not load, so this proves nothing")

        let strayInside = JaxToolGate.staysInsideGrux.subtracting(JaxToolGate.safeReadOnlyTools).sorted()
        XCTAssertTrue(strayInside.isEmpty, "a tool the gate stops runs in a dry run: \(strayInside)")
        let stale = JaxToolGate.staysInsideGrux.subtracting(all).sorted()
        XCTAssertTrue(stale.isEmpty, "the inside list names tools that do not exist: \(stale)")

        var held = 0
        for name in all.sorted() {
            let gated = JaxToolGate.knowinglyGated.contains(name) || JaxToolGate.selfGating.contains(name)
                || JaxToolGate.classify(name: name, input: [:]) != nil
            if gated { XCTAssertTrue(JaxToolGate.dryRunHolds(name), "\(name) is marked a side effect and runs in a dry run") }
            XCTAssertEqual(JaxToolGate.dryRunHolds(name), !JaxToolGate.staysInsideGrux.contains(name), name)
            if JaxToolGate.dryRunHolds(name) { held += 1 }
        }
        XCTAssertGreaterThan(held, 40, "control: almost nothing is held, so the rule is not being read")

        for name in ["open_app", "open_url", "play_on_youtube", "read_screen", "play_music_track",
                     "run_focus_check_now", "search_web", "run_macro", "control_screen", "create_note",
                     "shell_run", "compose_email", "slack_send", "start_workflow_v2", "a_tool_added_tomorrow"] {
            XCTAssertTrue(JaxToolGate.dryRunHolds(name), "\(name) acts outside Grux and runs in a dry run")
        }
        for name in ["add_task", "remember_fact", "list_tasks", "documents_list", "list_meetings"] {
            XCTAssertFalse(JaxToolGate.dryRunHolds(name), "\(name) only touches Grux and was held")
        }
    }

    /// Integrated review, P3: a read is not "inside Grux" because it only looks.
    /// These read another app's data, a folder macOS guards (Documents, a path
    /// the model names), the frontmost window, or reach a model or a memory
    /// server, and any of them can raise a macOS privacy prompt or spend money.
    func test_aReadThatReachesAnotherAppAPromptOrTheNetworkIsHeld() {
        for name in ["lookup_contact", "list_events", "fs_read", "fs_list", "get_current_activity",
                     "read_workday_log", "search_memory", "capture_memory", "compact_thread_now",
                     "summarize_meeting", "design_list_projects", "design_create_project",
                     "design_open_project", "design_restore_version", "design_system_list",
                     "design_system_activate"] {
            XCTAssertTrue(JaxToolGate.dryRunHolds(name), "\(name) reaches outside Grux and runs in a dry run")
        }
    }

    // MARK: The choke point

    private func pendingApprovals(mentioning marker: String) -> [UUID] {
        ApprovalQueue.shared.items
            .filter { $0.state == .pending && ($0.action.detail["__replay_input"] ?? "").contains(marker) }
            .map(\.id)
    }

    func test_aDryRunTurnRecordsAGatedToolInsteadOfQueueingOrRunningIt() async {
        let marker = "InjectDryRunTests-\(UUID().uuidString.prefix(8))"
        let input: [String: Any] = ["title": marker, "body": "held"]
        defer { for id in pendingApprovals(mentioning: marker) { ApprovalQueue.shared.skip(id) } }

        let dry = await JaxToolGate.$dryRun.withValue(true) {
            await ChatService.dispatchTool(name: "create_note", input: input)
        }
        XCTAssertTrue(dry.hasPrefix("dryrun: Nothing was done, because this is a dry run."), dry)
        let line = ToolReplyCopy.forPerson(tool: "create_note", input: input, result: dry)
        XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        XCTAssertEqual(pendingApprovals(mentioning: marker), [], "a dry-run turn queued a card")

        // Control: the same call outside a dry run reaches the gate and queues,
        // so the empty queue above is a finding and not a blind check.
        let real = await ChatService.dispatchTool(name: "create_note", input: input)
        XCTAssertTrue(real.hasPrefix("pending:"), real)
        XCTAssertEqual(pendingApprovals(mentioning: marker).count, 1)
    }

    func test_aDryRunTurnStillRunsGruxsOwnTools() async {
        let answer = await JaxToolGate.$dryRun.withValue(true) {
            await ChatService.dispatchTool(name: "list_tasks", input: [:])
        }
        XCTAssertFalse(answer.hasPrefix("dryrun:"), answer)
    }

    // MARK: What the person reads for a held write (integrated review, P1)

    /// A dry-run "take a note buy milk" reached the card, the note was held,
    /// and the card and Chat said `Saved your note "buy milk".` The held result
    /// now opens on its own status word and reads as held, never as done.
    func test_aHeldNoteOrEventOnTheCardNeverSaysItHappened() async {
        let savedChat = AppState.shared.chat
        let savedMemory = AppState.shared.config.memoryEnabled
        AppState.shared.config.memoryEnabled = false
        let marker = "InjectDryRunTests-\(UUID().uuidString.prefix(8))"
        defer {
            AppState.shared.chat = savedChat
            AppState.shared.config.memoryEnabled = savedMemory
            for id in pendingApprovals(mentioning: marker) { ApprovalQueue.shared.skip(id) }
        }
        for (tool, input) in [
            ("create_note", ["title": "buy milk \(marker)", "body": "buy milk"]),
            ("create_event", ["title": "Dentist \(marker)", "start": "2026-10-02T15:00:00"]),
        ] as [(String, [String: Any])] {
            let out = await JaxToolGate.$dryRun.withValue(true) {
                await PIMConfirmationController.runAndTell(name: tool, input: input, personAsked: true)
            }
            XCTAssertTrue(out.result.hasPrefix("dryrun:"), "\(tool): \(out.result)")
            for done in ["Saved", "Added", "to your calendar"] {
                XCTAssertFalse(out.reply.contains(done), "\(tool) reads as done: \(out.reply)")
            }
            XCTAssertTrue(out.reply.contains("because this is a dry run"), "\(tool): \(out.reply)")
            XCTAssertEqual(ToolReplyCopy.problems(in: out.reply), [], out.reply)
            XCTAssertEqual(AppState.shared.chat.last?.content, out.reply)
            XCTAssertEqual(PIMConfirmationController.endPhase(result: out.result, reply: out.reply),
                           .dryRun(out.reply), "\(tool): the card ends as done")
        }
        XCTAssertEqual(pendingApprovals(mentioning: marker), [], "a held write queued a card")
        // Control: the card's other end states are unchanged.
        XCTAssertEqual(PIMConfirmationController.endPhase(result: "ok: created note 'x'", reply: "Saved your note \"x\"."),
                       .done("Saved your note \"x\"."))
        XCTAssertEqual(PIMConfirmationController.endPhase(result: "error: nope", reply: "That did not go through: Nope."),
                       .failed("That did not go through: Nope."))
    }

    /// A held tool with no sentence of its own never reads its id with the
    /// underscores swapped for spaces ("Use open app.").
    func test_aHeldToolWithNoSentenceOfItsOwnReadsPlainly() {
        for name in ["open_app", "mcp_github_create_issue", "a_tool_added_tomorrow"] {
            let held = JaxToolGate.heldForDryRun(name: name, input: ["name": "Safari"])
            XCTAssertTrue(held.hasPrefix("dryrun:"), held)
            XCTAssertFalse(held.contains(name.replacingOccurrences(of: "_", with: " ")), held)
            XCTAssertTrue(held.contains("It would have done something outside Grux."), held)
            let line = ToolReplyCopy.forPerson(tool: name, input: [:], result: held)
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        }
    }

    // MARK: The router

    final class Box { var sent: [(text: String, dryRun: Bool)] = []; var logged: [String] = [] }

    private func router(reply: (age: TimeInterval, text: String)? = nil) -> (VoiceCommandRouter, Box) {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        let box = Box()
        r.recentReply = { reply }
        r.askFirst = { _ in XCTFail("nothing here should ask first") }
        r.sendToChat = { box.sent.append(($0, JaxToolGate.dryRun)) }
        r.log = { box.logged.append($0) }
        return (r, box)
    }

    func test_outsideGrux_dictationReachesChatAsADryRunTurn() async {
        let (r, box) = router()
        let dry = await r.consider(chunk: "hey grux what time is it", dryRun: .outsideGrux)
        await r.chatHandOff?.value
        XCTAssertEqual(dry?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(dry?.outcome, .executed)
        XCTAssertEqual(dry?.dryRun, true, "the result must say dry run, and now it is one")
        XCTAssertTrue(dry?.action.contains("dry run") == true, dry?.action ?? "")
        XCTAssertEqual(box.sent.map(\.dryRun), [true], "the words reached Chat as a real turn")

        let real = await r.consider(chunk: "hey grux what day is it", dryRun: .none)
        await r.chatHandOff?.value
        XCTAssertEqual(real?.dryRun, false)
        XCTAssertEqual(real?.action, "sent to chat")
        XCTAssertEqual(box.sent.map(\.dryRun), [true, false], "a real turn was run as a dry run")
    }

    /// A7's one grace chunk belongs to the person. A dry-run inject inside the
    /// follow-up window reads the window and leaves the grace unspent.
    func test_aDryRunDoesNotSpendTheGraceChunk() async {
        for mode in [VoiceCommandRouter.DryRun.outsideGrux, .everything] {
            let (r, box) = router(reply: (age: 20, text: "Here is your summary."))
            let injected = await r.consider(chunk: "the finder of lost things was on TV", dryRun: mode)
            await r.chatHandOff?.value
            XCTAssertEqual(injected?.outcome, .executed, "\(mode): the injected line is still decided as the grace chunk")
            let person = await r.consider(chunk: "yes send that one to my sister please", dryRun: .none)
            await r.chatHandOff?.value
            XCTAssertEqual(person?.outcome, .executed, "\(mode): the dry run spent the person's grace chunk")
            XCTAssertEqual(box.sent.last?.text, "yes send that one to my sister please", "\(mode)")
            XCTAssertFalse(box.logged.contains { $0.contains("follow-up window closed") }, "\(mode): \(box.logged)")
        }
    }

    // MARK: The listener

    private var savedListening: ListeningMode = .off
    private var savedAmbient: AmbientMode = .wake

    override func setUp() async throws {
        try await super.setUp()
        savedListening = AppState.shared.config.listeningMode
        savedAmbient = AppState.shared.config.ambientMode
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        AmbientListener.shared.wakeArmedUntil = .distantPast
    }

    override func tearDown() async throws {
        AppState.shared.config.listeningMode = savedListening
        AppState.shared.config.ambientMode = savedAmbient
        AmbientListener.shared.wakeArmedUntil = .distantPast
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try await super.tearDown()
    }

    /// What the listener said or played, from the silence log a test run
    /// always writes (a test run is always silent).
    private func sounds() -> [String] {
        guard let raw = try? String(contentsOf: AudioOutput.logURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap {
            guard let o = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] else { return nil }
            return "\(o["kind"] ?? ""):\(o["text"] ?? "")"
        }
    }

    /// The person's own "hey grux" armed the window for their next line. A
    /// dry-run chunk arriving inside it is decided and leaves it armed.
    func test_aDryRunDoesNotConsumeAPersonsArmedWakeWindow() async {
        AppState.shared.config.listeningMode = .wakeWord
        AppState.shared.config.ambientMode = .wake
        let armed = Date().addingTimeInterval(15)
        AmbientListener.shared.wakeArmedUntil = armed
        let route = await AmbientListener.shared.routeChunk("what time is it in Tokyo right now", dryRun: .everything)
        XCTAssertEqual(route.dryRun, true, route.stage)
        XCTAssertTrue(route.stage.hasPrefix("wake mode, armed"), "control: the chunk never reached the armed branch: \(route.stage)")
        XCTAssertEqual(AmbientListener.shared.wakeArmedUntil, armed, "a dry run used up the person's armed window")
    }

    func test_aDryRunWakeNeverChimesGreetsOrArms() async {
        AppState.shared.config.listeningMode = .wakeWord
        AppState.shared.config.ambientMode = .wake
        final class Count: @unchecked Sendable { var n = 0 }
        let wakes = Count()
        let observer = NotificationCenter.default.addObserver(forName: .gruxWakeDetected, object: nil, queue: nil) { _ in
            wakes.n += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let bare = await AmbientListener.shared.routeChunk("hey grux", dryRun: .outsideGrux)
        let garbled = await AmbientListener.shared.routeChunk("hey grux zzqx", dryRun: .everything)
        let withCommand = await AmbientListener.shared.routeChunk("hey grux what time is it", dryRun: .everything)
        XCTAssertEqual(bare.dryRun, true, bare.stage)
        XCTAssertEqual(garbled.dryRun, true, garbled.stage)
        XCTAssertEqual(withCommand.dryRun, true, withCommand.stage)
        XCTAssertLessThan(AmbientListener.shared.wakeArmedUntil, Date(), "a dry run armed the wake window")
        XCTAssertEqual(sounds(), [], "a dry run chimed or greeted")
        XCTAssertEqual(wakes.n, 0, "a dry run announced a wake")
        let result = AmbientInject.result(for: .init(text: "hey grux", dryRun: .outsideGrux), route: bare, wallMs: 1)
        XCTAssertEqual(result["dryRun"] as? Bool, true)

        // Control: the same bare wake for real does all three, so the empty
        // checks above are findings and not blind ones.
        _ = await AmbientListener.shared.routeChunk("hey grux", dryRun: .none)
        XCTAssertGreaterThan(AmbientListener.shared.wakeArmedUntil, Date())
        XCTAssertTrue(sounds().contains("chime:Tink"), "\(sounds())")
        XCTAssertTrue(sounds().contains { $0.hasPrefix("speech:") }, "\(sounds())")
        XCTAssertEqual(wakes.n, 1)
    }
}
