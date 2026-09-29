import XCTest
@testable import Grux

/// A dry run walks a workflow end to end and reaches nothing outside the run.
///
/// Six of the eight built-in workflows act on App Store Connect, devices,
/// TestFlight or the App Store. A dry run executes only control flow, state and
/// speech, records what every other phase would have done, collapses waits, and
/// takes Apple's answers from `dryRun.<key>` parameters. These tests drive each
/// workflow through the real engine, including its approval gates, with every
/// sound silenced into the suite's own `silenced.jsonl`.
@MainActor
final class WorkflowDryRunTests: XCTestCase {

    private var engine: CommandV2Engine!

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        engine = CommandV2Engine()
        engine.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func start(_ id: String, _ params: [String: JSONValue] = [:], dryRun: Bool = true) async throws -> UUID {
        switch await engine.start(definitionId: id, params: params, dryRun: dryRun) {
        case .success(let runId): return runId
        case .failure(let err): XCTFail("start \(id): \(err.localizedDescription)"); throw err
        }
    }

    private func current(_ runId: UUID) -> CommandV2Run? {
        engine.run(id: runId) ?? engine.recentRuns.first { $0.id == runId }
    }

    /// Waits until the run finishes or stops at a gate.
    @discardableResult
    private func settle(_ runId: UUID, file: StaticString = #filePath, line: UInt = #line) async throws -> CommandV2Run {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let run = current(runId), run.status.isTerminal || run.status == .waitingForApproval {
                return run
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let run = try XCTUnwrap(current(runId), file: file, line: line)
        XCTFail("run stuck in \(run.status.rawValue) at \(run.currentPhaseId)", file: file, line: line)
        return run
    }

    private func approve(_ runId: UUID, _ reply: String) async throws -> CommandV2Run {
        await engine.resume(runId, userReply: reply)
        return try await settle(runId)
    }

    private func phases(_ run: CommandV2Run) -> [String] { run.phaseHistory.map(\.phaseId) }

    private func log(_ run: CommandV2Run, _ phaseId: String) -> String {
        run.phaseHistory.last { $0.phaseId == phaseId }?.log ?? ""
    }

    private func silencedSpeech() throws -> [String] {
        guard FileManager.default.fileExists(atPath: AudioOutput.logURL.path) else { return [] }
        return try String(contentsOf: AudioOutput.logURL, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
            .filter { $0["kind"] == "speech" }
            .compactMap { $0["text"] }
    }

    private func project() -> String { "DryRunApp\(UUID().uuidString.prefix(6))" }

    // MARK: - What a dry run may execute

    func test_onlyPhasesThatChangeNothingOutsideTheRunExecute() {
        let outside: [CommandV2Action] = [
            .shell(command: "echo hi", captureOutput: true),
            .iosTool(name: "ios_check_asc_status", input: [:]),
            .claudeAgent(systemPrompt: "p", tools: [], maxTokens: nil),
            .claudeAgentSwarm(prompts: ["a"], sharedTools: []),
            .builtin(name: "capture-idea", args: [:]),
            .builtin(name: "verify-ios-project-ready", args: [:]),
            .builtin(name: "convention-audit", args: [:]),
            .builtin(name: "v1.runMacro", args: [:])
        ]
        for action in outside {
            XCTAssertFalse(CommandV2Executor.changesNothingOutside(action), action.summary)
        }
        let inside: [CommandV2Action] = [
            .noop, .speak(text: "t", audioCueAfter: nil),
            .setState(key: "k", valueExpr: .literal(.string("v"))),
            .branch(condition: .stateEquals(key: "a", value: "b"), ifTrue: "x", ifFalse: "y"),
            .userApprovalGate(prompt: "p", expectedReplies: nil),
            .builtin(name: "log", args: [:]), .builtin(name: "echo", args: [:])
        ]
        for action in inside {
            XCTAssertTrue(CommandV2Executor.changesNothingOutside(action), action.summary)
        }
    }

    // MARK: - Nothing outside, whoever is listening (REVIEW-2)

    private actor Sends {
        var count = 0
        func add() { count += 1 }
    }

    /// Every built-in workflow run dry, its gates answered, with a webhook
    /// endpoint subscribed to every workflow event: no delivery, and every
    /// run note the engine posts says it is a dry run, so any listener can
    /// tell. Webhooks once went out for every dry-run step.
    func test_aDryRunOfEveryWorkflowReachesNoWebhookAndEveryNoteSaysItIsDry() async throws {
        let sends = Sends()
        // Counted where every delivery is recorded, sent or refused (the stub
        // endpoint has no signing secret, so none is actually sent).
        let manager = WebhookManager(sender: { _ in return (200, Data()) },
                                     sleeper: { _ in }, auditSink: { _ in await sends.add() })
        let config = WebhookConfig(name: "Stub", url: "https://example.com/grux-hook", events: Set(WebhookEvent.allCases))
        WebhookStore.shared.upsert(config)
        defer { WebhookStore.shared.delete(id: config.id) }
        await manager.start()
        var notes: [Notification] = []
        let names: [Notification.Name] = [.gruxCommandV2RunStarted, .gruxCommandV2PhaseTransitioned,
                                          .gruxCommandV2GateWaiting, .gruxCommandV2RunFinished]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notes.append($0) }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }

        for def in CommandV2Engine.builtinDefinitions {
            let id = try await start(def.id, ["project": .string(project())])
            var run = try await settle(id)
            var answers = 0
            while run.status == .waitingForApproval, answers < 6 {
                answers += 1
                run = try await approve(id, engine.acceptedReplies(for: run)?.first ?? "It reads well.")
            }
            if !run.status.isTerminal { await engine.cancel(id) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let sent = await sends.count
        XCTAssertEqual(sent, 0, "a dry run delivered \(sent) webhooks")
        XCTAssertGreaterThan(notes.count, 20, "control: the runs posted their notes")
        let unflagged = notes.filter { ($0.userInfo?["isDryRun"] as? Bool) != true }
        XCTAssertEqual(unflagged.map(\.name.rawValue), [], "a dry run's note does not say it is a dry run")
        await manager.stop()
    }

    /// Reach paths a dry run keeps on purpose (lead's ruling, 2026-09-28):
    /// Grux talking to its own person on devices and services the person set
    /// up, never an action on anyone else's system. A dry run sounds like the
    /// real run would; every line leads with "Dry run" and silent mode still
    /// governs speech. File, what reaches it, and why it stays.
    static let reviewedDryRunReach: [(file: String, reach: String, reason: String)] = [
        ("SpeechEngine.swift", "ElevenLabs",
         "the person's own configured cloud voice speaking to them: own person, own service, not an outside action"),
        ("SpeechEngine.swift", "TTSBroadcaster",
         "the same speech streamed to the person's paired phone: own person, own device, not an outside action"),
        ("PhoneChatBridge.swift", "$chat",
         "Chat, the gate question included, mirrored to the person's paired phone: own person, own device, not an outside action"),
        ("AppState.swift", "autoTitleIfNeeded",
         "Chat's own title and compaction model calls on that thread: Grux processing its own content, not an outside action"),
    ]

    /// The reviewed reach paths still exist where they say, so the list is
    /// read against the code rather than left to go stale.
    func test_theReviewedDryRunReachPathsAreWhereTheListSays() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for entry in Self.reviewedDryRunReach {
            let file = try XCTUnwrap(files.first { $0.lastPathComponent == entry.file }, "\(entry.file) is gone")
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains(entry.reach), "\(entry.file) no longer has \(entry.reach): review the entry again")
            XCTAssertFalse(entry.reason.isEmpty)
        }
    }

    /// Every listener to a workflow run's notes in Sources reads the dry-run
    /// flag, or is a reviewed in-app listener that reaches nothing outside
    /// Grux, so a new listener cannot quietly act on a dry run.
    func test_everyListenerToAWorkflowRunReadsTheDryRunFlagOrIsReviewedInApp() throws {
        let reviewedInApp: [String: String] = [
            "ShellStateAdapters.swift": "the orb's status line, in the app",
            // Lead's ruling, 2026-09-28: a dry run's gate question in Chat, and
            // Grux's own model call to title or compact that thread, is Grux
            // processing its own content. The dry-run rule is about acting
            // outside Grux (posting, shipping, writing to third parties).
            "GruxApp.swift": "posts the gate's question to Chat; Chat titling or compacting it is Grux's own content",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let listens = try NSRegularExpression(pattern:
            #"(forName:|publisher\(for:)\s*\.gruxCommandV2(RunStarted|RunFinished|PhaseTransitioned|GateWaiting)"#)
        var listeners: [String] = []
        var unguarded: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard listens.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            listeners.append(file.lastPathComponent)
            if !text.contains("isDryRun"), reviewedInApp[file.lastPathComponent] == nil {
                unguarded.append(file.lastPathComponent)
            }
        }
        XCTAssertGreaterThanOrEqual(listeners.count, 4, "control: the sweep found the listeners: \(listeners.sorted())")
        XCTAssertEqual(unguarded.sorted(), [], "a listener to workflow runs never reads the dry-run flag")
    }

    // MARK: - Doors

    func test_theSentinelMakesEveryStartADryRun() async throws {
        // smoke-hello-world touches nothing outside, so this stays safe even
        // if the sentinel check ever regresses.
        let live = try await settle(try await start("smoke-hello-world", dryRun: false))
        XCTAssertFalse(live.isDryRun)

        try Data().write(to: CommandV2Engine.dryRunSentinelURL)
        let run = try await settle(try await start("smoke-hello-world", ["dryRun.color": .string("red")], dryRun: false))
        XCTAssertTrue(run.isDryRun, "a start that did not ask for a dry run is still dry while the sentinel exists")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.state["color"], .string("teal"), "the run's own setState still executes")
    }

    func test_aRunSavedBeforeTheFieldExistedDecodesAsLive() throws {
        let saved = try JSONEncoder().encode(CommandV2Run(definitionId: "x", displayName: "x", currentPhaseId: "p"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "dryRun")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CommandV2Run.self, from: old)
        XCTAssertFalse(decoded.isDryRun)
    }

    // MARK: - The two local workflows

    func test_smokeHelloWorld_takesTheTealBranch() async throws {
        let run = try await settle(try await start("smoke-hello-world"))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(phases(run), ["greet", "stash", "echo", "decide", "celebrate"])
        XCTAssertEqual(run.state["last_echo"], .string("smoke world says hi"))
        XCTAssertTrue(try silencedSpeech().contains {
            $0.hasPrefix(CommandV2Executor.dryRunSpeechLead) && $0.hasSuffix("Commands V2 smoke test starting.")
        })
    }

    // The Workflows drill-in showed `setState color = string("teal")`: a state
    // value printed as its Swift case (SWEEP-4, live 2026-09-28). Any value in
    // a log reads as what it holds.
    func test_aStateWriteLogsTheValueNotItsSwiftCase() async throws {
        let run = try await settle(try await start("smoke-hello-world"))
        XCTAssertEqual(log(run, "stash"), "Noted for later: teal.")
        XCTAssertEqual("\(JSONValue.array([.string("ja"), .int(2), .bool(true), .null]))", #"["ja",2,true,null]"#)
        XCTAssertEqual("\(JSONValue.object(["b": .double(1.5), "a": .string("x")]))", #"{"a":"x","b":1.5}"#)
        XCTAssertEqual("\(JSONValue.int(7))", "7")
    }

    func test_captureIdea_dryRunWritesNoIdea() async throws {
        let ideas = Persistence.gruxDir.appendingPathComponent("ideas")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: ideas.path)) ?? []
        let run = try await settle(try await start("capture-idea", ["content": .string("a dry idea")]))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(log(run, "capture"), "Dry run, so \"Save the idea, skipping repeats\" did not run. A real run would do it.")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: ideas.path)) ?? [], before)
    }

    // Its whole spoken line is a value the skipped capture phase sets, so the
    // dry run said the one word "unknown" (live sweep 1, 2026-09-27).
    func test_captureIdea_dryRunSaysWhyItHasNothingToReport() async throws {
        _ = try await settle(try await start("capture-idea", ["content": .string("a dry idea")]))
        let spoken = try silencedSpeech()
        XCTAssertFalse(spoken.contains("unknown"), "\(spoken)")
        XCTAssertTrue(spoken.contains("Dry run of capture idea: the step that would say how it went was skipped."), "\(spoken)")
    }

    /// SWEEP-10: a dry line never says "unknown" and never states an outcome
    /// as if it happened. A line that needs a value only a skipped step would
    /// set says the step was skipped; any other dry line is led by the dry-run
    /// note and said as what a real run would say.
    func test_aLineWithOnlyMissingValuesIsExplained_aLineWithWordsIsNot() async throws {
        let dry = try await settle(try await start("capture-idea", ["content": .string("a dry idea")]))
        let def = try XCTUnwrap(engine.definition(id: "capture-idea"))
        XCTAssertEqual(CommandV2Executor.speechText("${state.idea_spoken_message}", in: dry, definition: def),
                       "Dry run of capture idea: the step that would say how it went was skipped.")
        XCTAssertEqual(CommandV2Executor.speechText("Saved: ${state.idea_spoken_message}", in: dry, definition: def),
                       "Dry run of capture idea: the step that would say how it went was skipped.")
        XCTAssertEqual(CommandV2Executor.speechText("${param.content}", in: dry, definition: def),
                       CommandV2Executor.dryRunSpeechLead + " a dry idea")
        var live = dry
        live.dryRun = false
        XCTAssertEqual(CommandV2Executor.speechText("${state.idea_spoken_message}", in: live, definition: def), "")
    }

    // MARK: - The six that face Apple

    func test_checkASCStatus_speaksTheSeededAnswer() async throws {
        let p = project()
        let run = try await settle(try await start("check-asc-status", [
            "project": .string(p), "dryRun.asc_state": .string("WAITING_FOR_REVIEW")
        ]))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(log(run, "query"), "Dry run, so \"Ask App Store Connect\" did not run. A real run would do it.")
        let spoken = try silencedSpeech()
        XCTAssertTrue(spoken.contains { $0.hasSuffix("Apple says: WAITING_FOR_REVIEW.") }, spoken.joined(separator: " | "))
    }

    func test_generateMarketingScreenshots_recordsEveryOutsidePhase() async throws {
        let run = try await settle(try await start("generate-marketing-screenshots", ["project": .string(project())]))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(phases(run), ["screenshots-capture", "screenshots-design", "speak-done"])
        XCTAssertEqual(log(run, "screenshots-capture"), "Dry run, so \"Capture raw simulator frames\" did not run. A real run would do it.")
        XCTAssertEqual(log(run, "screenshots-design"), "Dry run, so no agent started for \"Design the marketing screenshots\". A real run would start one.")
    }

    func test_shipExistingIOSApp_healthyAccount_runsToTheEndWithoutWaiting() async throws {
        let run = try await settle(try await start("ship-existing-ios-app", [
            "project": .string(project()), "dryRun.account_health_ok": .string("true")
        ]))
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertFalse(phases(run).contains("open-account-blocker"))
        XCTAssertEqual(phases(run).suffix(3), ["publish", "wait-for-review", "check-status"])
        XCTAssertTrue(log(run, "wait-for-review").contains(
            "Dry run, so there was no wait. A real run would wait 24 hours, then go on to check App Store Connect status."),
                      log(run, "wait-for-review"))
        for phase in run.phaseHistory {
            XCTAssertNotEqual(phase.outcome, .failure, phase.phaseId)
        }
    }

    func test_shipExistingIOSApp_blockedAccount_stopsAtTheGateAndTheLoopGuardEndsIt() async throws {
        let id = try await start("ship-existing-ios-app", ["project": .string(project())])
        var run = try await settle(id)
        XCTAssertEqual(run.status, .waitingForApproval)
        XCTAssertEqual(run.currentPhaseId, "await-blocker-resolution")
        run = try await approve(id, "done")
        XCTAssertEqual(run.currentPhaseId, "await-blocker-resolution", "the account is still unhealthy, so it asks again")
        run = try await approve(id, "done")
        run = try await approve(id, "done")
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.lastError, CommandV2Engine.dryRunStopMessage(at: try XCTUnwrap(
            engine.definition(id: "ship-existing-ios-app")?.phases.first { $0.id == run.currentPhaseId })))
    }

    // The blocker gate says Safari is open at the page, but the dry
    // run only recorded opening it (A25, live 2026-09-27). A dry-run gate says
    // up front that nothing before it happened; a real gate keeps its words.
    func test_aDryRunGateSaysTheStepsBeforeItWereOnlyRecorded() async throws {
        let name = project()
        let id = try await start("ship-existing-ios-app", ["project": .string(name)])
        let run = try await settle(id)
        XCTAssertEqual(run.currentPhaseId, "await-blocker-resolution")
        XCTAssertEqual(log(run, "open-account-blocker"),
                       "Dry run, so \"Open the App Store Connect page that needs you in Safari\" did not run. A real run would do it.")
        let reason = try XCTUnwrap(run.blockingReason)
        XCTAssertTrue(reason.hasPrefix(CommandV2Executor.dryRunGateNote), reason)
        XCTAssertTrue(reason.hasSuffix("App Store Connect needs you before I can publish. Safari is open at the page: "
                                       + "accept any agreement waiting there, then reply done and I will check again."), reason)
        XCTAssertTrue(try silencedSpeech().contains { $0.hasPrefix(CommandV2Executor.dryRunGateNote) })

        var live = run
        live.dryRun = false
        XCTAssertEqual(CommandV2Executor.gatePrompt("Approve ${param.project}?", in: live), "Approve \(name)?")
        XCTAssertEqual(CommandV2Executor.gatePrompt("Approve?", in: run), CommandV2Executor.dryRunGateNote + " Approve?")
    }

    func test_shipIOSApp_throughBothGatesToCelebrate() async throws {
        let id = try await start("ship-ios-app", [
            "project": .string(project()), "dryRun.asc_state": .string("READY_FOR_SALE")
        ])
        var run = try await settle(id)
        XCTAssertEqual(run.currentPhaseId, "brainstorm-approval-gate")
        run = try await approve(id, "looks good")
        XCTAssertEqual(run.currentPhaseId, "walkthrough")
        run = try await approve(id, "ship it")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).suffix(4), ["wait-for-review", "check-status", "decide-next", "celebrate"])
        XCTAssertEqual(log(run, "publish"), "Dry run, so \"Publish to the App Store\" did not run. A real run would do it.")
    }

    /// Final sweep, 2026-09-28: `go` at the plan, then `looks good` at the
    /// walkthrough, and the walkthrough did not take `looks good`. Ruled by
    /// design (RV2, RV3): a gate takes the words it lists, and its question
    /// names them. Each answer goes the way Chat sends it, with the word the
    /// question names: the gate it answers is found by the words, then
    /// resumed. A dry run says so at every gate.
    func test_shipIOSApp_theWordsEachQuestionNamesCarryItToCelebrate() async throws {
        let id = try await start("ship-ios-app", [
            "project": .string(project()), "dryRun.asc_state": .string("READY_FOR_SALE")
        ])
        for other in engine.activeRuns where other.id != id { await engine.cancel(other.id) }
        var run = try await settle(id)
        for (gate, said) in [("brainstorm-approval-gate", "go"), ("walkthrough", "ship it")] {
            XCTAssertEqual(run.currentPhaseId, gate)
            XCTAssertTrue(run.blockingReason?.hasPrefix(CommandV2Executor.dryRunGateNote) == true,
                          "\(gate) does not say it is a dry run: \(run.blockingReason ?? "")")
            XCTAssertTrue(Self.namedReplies(in: engine.gateQuestion(for: run)).contains(said),
                          "\(gate) does not name \(said): \(engine.gateQuestion(for: run))")
            XCTAssertEqual(engine.gateAnswer(for: said), .resume(runId: id, reply: said), "\(said) at \(gate)")
            let taken = await engine.resume(id, userReply: said)
            XCTAssertTrue(taken, "\(said) did not answer \(gate)")
            run = try await settle(id)
        }
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).last, "celebrate")
        XCTAssertEqual(log(run, "publish"), "Dry run, so \"Publish to the App Store\" did not run. A real run would do it.")
    }

    /// The reply words a gate's question tells the person to use: each
    /// "X to ..." or "X and ..." clause after "reply", or the bare list the
    /// engine appends.
    /// A clause longer than two words ("cancel the run in Workflows to
    /// stop") is an instruction, not a reply word.
    static func namedReplies(in question: String) -> Set<String> {
        var named: Set<String> = []
        var rest = question[...]
        while let r = rest.range(of: "Reply ", options: .caseInsensitive) {
            let tail = rest[r.upperBound...]
            let sentence = tail.prefix { $0 != "." && $0 != "?" }
            rest = tail.dropFirst(sentence.count)
            for clause in sentence.replacingOccurrences(of: ", or ", with: ", ")
                .replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", ") {
                let cut = [" to ", " and ", " when "].compactMap { clause.range(of: $0)?.lowerBound }.min()
                let word = (cut.map { String(clause[..<$0]) } ?? clause)
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if !word.isEmpty, word.split(separator: " ").count <= 2 { named.insert(word) }
            }
        }
        return named
    }

    /// Every answer a line offers after "reply", word or instruction, quotes
    /// dropped: "Reply 'ship it' when ready, or tell me what to adjust" offers
    /// "ship it" and "tell me what".
    static func replyClauses(in line: String) -> [String] {
        var out: [String] = []
        var rest = line[...]
        while let r = rest.range(of: "Reply ", options: .caseInsensitive) {
            let tail = rest[r.upperBound...]
            let sentence = tail.prefix { $0 != "." && $0 != "?" }
            rest = tail.dropFirst(sentence.count)
            for clause in sentence.replacingOccurrences(of: ", or ", with: ", ")
                .replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", ") {
                let cut = [" to ", " and ", " when "].compactMap { clause.range(of: $0)?.lowerBound }.min()
                let word = (cut.map { String(clause[..<$0]) } ?? clause)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))).lowercased()
                if !word.isEmpty { out.append(word) }
            }
        }
        return out
    }

    /// A person is never told one word and required another. Every word any
    /// built-in gate's question names answers it, live and dry. The
    /// walkthrough, the last stop before Apple, takes exactly the words it
    /// names and nothing looser: `looks good` there is ordinary chat.
    func test_everyGateTakesEveryWordItsQuestionNames_andTheWalkthroughNoOther() async throws {
        var checked = 0
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                for dry in [false, true] {
                    var run = CommandV2Run(definitionId: def.id, displayName: def.displayName,
                                           currentPhaseId: phase.id, parameters: ["project": .string("Tracker")])
                    run.dryRun = dry
                    guard let reason = CommandV2Engine.waitingReason(at: phase, in: run) else { continue }
                    run.status = .waitingForApproval
                    run.blockingReason = reason
                    let question = engine.gateQuestion(for: run)
                    guard let accepted = engine.acceptedReplies(for: run) else { continue }
                    let named = Self.namedReplies(in: question)
                    XCTAssertFalse(named.isEmpty, "\(def.id) at \(phase.id) names no reply: \(question)")
                    for word in named {
                        XCTAssertTrue(accepted.contains(word),
                                      "\(def.id) at \(phase.id) tells you \(word) and does not take it: \(question)")
                    }
                    if case .walkthrough(let points) = phase.action {
                        XCTAssertEqual(Set(accepted), named, "the walkthrough takes a word it does not name: \(question)")
                        XCTAssertFalse(accepted.contains("looks good"))
                        // Review of e125705: the spoken line offered "tell me
                        // what to adjust", which the gate does not take. What
                        // is said and what is written offer the same answers.
                        // Re-review of 90236d0: "this build" said twice in one line.
                        for line in points.map({ "\($0.title): \($0.body)" }) {
                            XCTAssertLessThanOrEqual(line.components(separatedBy: "this build").count - 1, 1, line)
                        }
                        for line in points.map({ "\($0.title): \($0.body)" }) + [question] {
                            let offered = Self.replyClauses(in: line)
                            XCTAssertFalse(offered.isEmpty, "the walkthrough says no reply: \(line)")
                            for clause in offered where !accepted.contains(clause) {
                                XCTAssertTrue(clause.hasPrefix("cancel the run"),
                                              "the walkthrough offers \"\(clause)\", which it does not take: \(line)")
                            }
                        }
                    }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 12, "six gates that take words, each live and dry")
    }

    /// SWEEP-10, reproduced the way the sweep did it: a ship run started with
    /// no project and Apple's answer seeded READY_FOR_SALE, answered go and
    /// ship it. It spoke "unknown is in Apple's review queue. I'll check back
    /// tomorrow.", "Also, good news - unknown is approved on the App Store.
    /// You shipped anotha one." and "Anotha one!", and ship-existing spoke the
    /// same review-queue line. Every line a dry run says is led by the
    /// dry-run note, names "your project" for a missing project, and never
    /// says "unknown" or uses a spaced hyphen; the celebration cue stays quiet.
    func test_aDryShipRunSaysNothingItDidNotDo() async throws {
        let ship = try await start("ship-ios-app", ["dryRun.asc_state": .string("READY_FOR_SALE")])
        _ = try await settle(ship)
        _ = try await approve(ship, "go")
        let shipped = try await approve(ship, "ship it")
        XCTAssertEqual(shipped.status, .completed, shipped.lastError ?? "")
        let existing = try await settle(try await start("ship-existing-ios-app", [
            "project": .string(project()), "dryRun.account_health_ok": .bool(true)]))
        XCTAssertEqual(existing.status, .completed, existing.lastError ?? "")

        let spoken = try silencedSpeech()
        XCTAssertTrue(spoken.contains { $0.contains("review queue") }, "the review-queue line was not reached: \(spoken)")
        XCTAssertTrue(spoken.contains { $0.contains("approved on the App Store") }, "the celebrate line was not reached: \(spoken)")
        for line in spoken {
            XCTAssertTrue(line.hasPrefix("Dry run"), "said as if it happened: \(line)")
            XCTAssertNil(line.range(of: #"(?i)\bunknown\b"#, options: .regularExpression), line)
            XCTAssertNil(line.range(of: #"(?<=\S)[ \t]+-[ \t]+(?=\S)"#, options: .regularExpression), line)
            XCTAssertFalse(line.contains("Anotha one!"), "the celebration cue spoke in a dry run")
        }
        XCTAssertTrue(spoken.contains { $0.contains("your project") }, "a missing project is not named plainly: \(spoken)")
        // The run record a person can open in Workflows says the same.
        for run in [shipped, existing] {
            for rec in run.phaseHistory {
                XCTAssertFalse(rec.log.contains("(dry run: no project)"), "\(rec.phaseId): \(rec.log)")
                XCTAssertFalse(rec.log.contains("unknown is"), "\(rec.phaseId): \(rec.log)")
            }
        }
    }

    /// SWEEP-11: a gate's phase log, which the Workflows drill-in shows,
    /// began "awaiting user approval - ".
    func test_aGateLogSaysItWaitsForYourAnswer() async throws {
        let run = try await settle(try await start("ship-ios-app", ["project": .string(project())]))
        XCTAssertEqual(run.currentPhaseId, "brainstorm-approval-gate")
        let gateLog = log(run, "brainstorm-approval-gate")
        XCTAssertTrue(gateLog.hasPrefix("Waiting for your answer. "), gateLog)
        XCTAssertNil(gateLog.range(of: #"(?i)\buser\b"#, options: .regularExpression), gateLog)
    }

    func test_shipIOSApp_withoutAnAnswerFromApple_stopsInsteadOfSpinning() async throws {
        let id = try await start("ship-ios-app", ["project": .string(project())])
        _ = try await settle(id)
        _ = try await approve(id, "go")
        let run = try await approve(id, "ship it")
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.lastError?.hasPrefix("The dry run stopped here") == true, run.lastError ?? "")
        // SWEEP-12: the run record is the person's too, so it says why in
        // words; how a tester seeds the answer is in the engine's comments.
        let last = run.phaseHistory.last?.log ?? ""
        XCTAssertTrue(last.hasSuffix(PhaseLogCopy.dryRunStoppedHere), last)
        XCTAssertFalse(last.contains("dryRun."), last)
    }

    func test_localizeApp_aSpokenNoGoesStraightToTranslation() async throws {
        let id = try await start("localize-app", ["project": .string(project())])
        var run = try await settle(id)
        XCTAssertEqual(run.currentPhaseId, "ask-final-thoughts", "the week-long wait is collapsed")
        run = try await approve(id, "No.")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).suffix(3), ["incorporate-feedback", "translate", "celebrate-localized"])
        let translate = engine.dryRunInput(run: id, phase: "translate") ?? ""
        XCTAssertTrue(translate.contains(#"locales=["ja","de","fr","es","zh-Hans"]"#), "a list argument reads as a list: \(translate)")
    }

    func test_localizeApp_aSpokenYesTakesTheFeedbackPass() async throws {
        let app = project()
        let id = try await start("localize-app", ["project": .string(app)])
        _ = try await settle(id)
        var run = try await approve(id, "Yes.")
        XCTAssertEqual(run.state["user_reply"], .string("yes"))
        XCTAssertEqual(run.status, .waitingForApproval, "a yes asks for the thoughts before any agent runs")
        XCTAssertEqual(run.currentPhaseId, "collect-feedback")
        XCTAssertFalse(phases(run).contains("swarm-feedback-pass"), phases(run).joined(separator: ","))
        run = try await approve(id, "The onboarding copy is too long. Cut it to one screen.")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        let pass = engine.dryRunInput(run: id, phase: "swarm-feedback-pass") ?? ""
        XCTAssertTrue(pass.contains("feedback on \(app): The onboarding copy is too long. Cut it to one screen."),
                      "the agent gets the words said, as said: \(pass)")
        XCTAssertEqual(phases(run).suffix(2), ["translate", "celebrate-localized"])
    }

    func test_localizeApp_skipDefersWithoutLocalizing() async throws {
        let id = try await start("localize-app", ["project": .string(project())])
        _ = try await settle(id)
        let run = try await approve(id, "Skip.")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertFalse(phases(run).contains("translate"), "skip defers the pass: \(phases(run).joined(separator: ","))")
        XCTAssertFalse(phases(run).contains("celebrate-localized"))
        let spoken = try silencedSpeech()
        XCTAssertTrue(spoken.contains { $0.contains("stays in English") }, spoken.joined(separator: " | "))
    }

    func test_testflightFeedback_holdEndsTheRun() async throws {
        let id = try await start("testflight-feedback", [
            "project": .string(project()), "dryRun.tf_crash_count": .int(2),
            "dryRun.tf_comment_count": .int(5), "dryRun.tf_top_issue": .string("login crash")
        ])
        var run = try await settle(id)
        XCTAssertEqual(run.currentPhaseId, "triage-gate")
        XCTAssertTrue(try silencedSpeech().contains { $0.hasSuffix("TestFlight: 2 crashes, 5 tester comments. Top issue: login crash.") })
        run = try await approve(id, "Hold")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).suffix(3), ["decide-action", "decide-ship-or-hold", "hold"])
    }

    // A line made of values only a skipped phase would set says the step was
    // skipped (SWEEP-10: it said "unknown crashes, unknown tester comments").
    func test_testflightFeedback_unseededSpeechNamesWhatADryRunCannotKnow() async throws {
        let p = project()
        let id = try await start("testflight-feedback", ["project": .string(p)])
        _ = try await settle(id)
        let spoken = try silencedSpeech()
        XCTAssertFalse(spoken.contains { $0.contains("unknown") }, spoken.joined(separator: " | "))
        XCTAssertTrue(spoken.contains("Dry run of TestFlight feedback for \(p): the step that would say how it went was skipped."),
                      spoken.joined(separator: " | "))
    }

    func test_onlyADryRunNamesAMissingValue() async throws {
        let dry = try await settle(try await start("generate-marketing-screenshots", ["project": .string(project())]))
        let template = "Raw simulator frames live at ${state.screenshots_dir}."
        // SWEEP-11: the Workflows drill-in shows these logs to the person.
        // Review of 12eda8a: "live at not known in a dry run" read oddly. A
        // sentence that needs a value only a real run has is said whole.
        XCTAssertEqual(CommandV2Executor.interpolate(template, in: dry),
                       "In a real run, this names the folder with the raw simulator frames.")
        XCTAssertEqual(CommandV2Executor.interpolate("First line. Top issue: ${state.tf_top_issue}. Last line.", in: dry),
                       "First line. In a real run, this names a value an earlier step sets. Last line.")
        // Review of d6cd37d: a "." inside a URL, a version or a decimal is not
        // the end of a sentence.
        XCTAssertEqual(CommandV2Executor.interpolate(
            "See https://example.com/v1.2/raw.txt for 2.5x frames at ${state.screenshots_dir} today. Next.", in: dry),
            "In a real run, this names the folder with the raw simulator frames. Next.")
        var live = dry
        live.dryRun = false
        XCTAssertEqual(CommandV2Executor.interpolate(template, in: live), "Raw simulator frames live at .")
    }

    func test_testflightFeedback_fixTakesTheFixSwarm() async throws {
        let id = try await start("testflight-feedback", ["project": .string(project())])
        _ = try await settle(id)
        let run = try await approve(id, " fix ")
        XCTAssertTrue(phases(run).contains("fix-swarm"), phases(run).joined(separator: ","))
    }

    // MARK: - A branch arm ends where it says, not in the next arm

    func test_testflightFeedback_fixEndsAfterTheFixSwarm() async throws {
        let id = try await start("testflight-feedback", ["project": .string(project())])
        _ = try await settle(id)
        let run = try await approve(id, "fix")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).suffix(2), ["decide-action", "fix-swarm"], phases(run).joined(separator: ","))
        XCTAssertFalse(phases(run).contains("trigger-asc-submit"), "a fix reply must never submit to the App Store")
        XCTAssertFalse(try silencedSpeech().contains { $0.contains("Holding ") })
    }

    func test_testflightFeedback_shipSubmitsAndDoesNotAlsoHold() async throws {
        let id = try await start("testflight-feedback", ["project": .string(project())])
        _ = try await settle(id)
        let run = try await approve(id, "ship")
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        XCTAssertEqual(phases(run).suffix(3), ["decide-action", "decide-ship-or-hold", "trigger-asc-submit"],
                       phases(run).joined(separator: ","))
        XCTAssertFalse(try silencedSpeech().contains { $0.contains("Holding ") })
    }

    func test_shipIOSApp_aRejectionGoesBackToReviewInsteadOfCelebrating() async throws {
        let id = try await start("ship-ios-app", [
            "project": .string(project()), "dryRun.asc_state": .string("REJECTED")
        ])
        _ = try await settle(id)
        _ = try await approve(id, "go")
        var run = try await approve(id, "ship it")
        XCTAssertEqual(run.status, .waitingForApproval, run.lastError ?? "")
        XCTAssertEqual(run.currentPhaseId, "rejection-recover")
        run = try await approve(id, "approve")
        XCTAssertFalse(phases(run).contains("celebrate"), phases(run).joined(separator: ","))
        XCTAssertEqual(phases(run).filter { $0 == "wait-for-review" }.count, 2,
                       "after the fix it waits for Apple's review again")
        XCTAssertEqual(run.currentPhaseId, "rejection-recover", "still rejected, so it asks about the fix again")
    }

    func test_everyBuiltinDefinitionSaysWhereEachBranchArmEnds() {
        for def in CommandV2Engine.builtinDefinitions {
            XCTAssertEqual(def.structuralProblems(), [], def.id)
        }
    }

    func test_aPhaseThatFallsIntoABranchArmIsRefused() async throws {
        let def = CommandV2Definition(
            id: "fall-through-\(UUID().uuidString.prefix(6))", displayName: "f", voiceTriggers: [],
            description: "d", category: .system,
            phases: [
                .init(id: "decide", displayName: "d", action: .branch(
                    condition: .stateEquals(key: "a", value: "b"), ifTrue: "yes", ifFalse: "no")),
                .init(id: "yes", displayName: "y", action: .noop),
                .init(id: "no", displayName: "n", action: .noop)
            ]
        )
        XCTAssertEqual(def.structuralProblems(),
                       ["phase yes falls through into no, which a branch jumps to; say .endRun or .continueAt(\"no\")"])
        engine.register(def)
        switch await engine.start(definitionId: def.id, dryRun: true) {
        case .success: XCTFail("a definition whose branch arms run into each other must not start")
        case .failure(let err): XCTAssertTrue(err.localizedDescription.contains("falls through"), err.localizedDescription)
        }

        let fixed = CommandV2Definition(
            id: def.id, displayName: "f", voiceTriggers: [], description: "d", category: .system,
            phases: [
                def.phases[0],
                .init(id: "yes", displayName: "y", action: .noop, after: .endRun),
                .init(id: "no", displayName: "n", action: .noop)
            ]
        )
        XCTAssertEqual(fixed.structuralProblems(), [])
        engine.register(fixed)
        let run = try await settle(try await start(def.id))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(phases(run), ["decide", "no"])
    }

    func test_structuralProblemsNameUnknownTargets() {
        let def = CommandV2Definition(
            id: "x", displayName: "x", voiceTriggers: [], description: "d", category: .system,
            phases: [
                .init(id: "decide", displayName: "d", action: .branch(
                    condition: .stateEquals(key: "a", value: "b"), ifTrue: "nowhere", ifFalse: "end")),
                .init(id: "end", displayName: "e", action: .noop, after: .continueAt("gone"))
            ]
        )
        XCTAssertEqual(def.structuralProblems(), [
            "phase decide branches to unknown phase nowhere",
            "phase end continues at unknown phase gone"
        ])
    }

    // MARK: - Cancel

    func test_cancelAtAGateEndsTheDryRun() async throws {
        let id = try await start("localize-app", ["project": .string(project())])
        _ = try await settle(id)
        await engine.cancel(id)
        XCTAssertEqual(current(id)?.status, .canceled)
        XCTAssertNil(engine.run(id: id))
    }
}
