import XCTest
@testable import Grux

/// Operator row D-replycopy (2026-09-28): Chat showed the person two lines
/// written for the model, from a headless snapshot of the installed build:
/// `(no documents matched)` and `pending: 'create_note' is waiting in the Jax
/// HQ approval queue for the user's one-tap approval. Nothing was sent or
/// changed.` Both came from the PIM card, which pasted the raw tool result
/// into Chat. Every line a tool result can become for a person is checked here.
@MainActor
final class ToolReplyCopyTests: XCTestCase {

    /// Result shapes each tool the PIM card and Approvals can run returns,
    /// copied from the formatters and from live wake.log lines.
    private let corpus: [(tool: String, input: [String: Any], result: String)] = [
        ("create_note", ["title": "Groceries"],
         "pending: 'create_note' is waiting in the Jax HQ approval queue for the user's one-tap approval. Nothing was sent or changed."),
        ("create_event", ["title": "Lunch with Sarah", "start": "2026-10-02T13:00:00"],
         "pending: 'create_event' is waiting in the Jax HQ approval queue for the user's one-tap approval. Nothing was sent or changed."),
        ("shell_run", ["command": "mkdir -p /tmp/grux-loop-shell"],
         "pending: 'shell_run' is waiting in the Jax HQ approval queue for the user's one-tap approval. Nothing was sent or changed."),
        ("compose_email", ["to": "sam@example.com"],
         "pending: this email is waiting in the Jax HQ approval queue for the user's one-tap approval (would send as Grux to sam@example.com). Nothing has been sent."),
        ("create_note", ["title": "x"],
         "refused: posting outside the house list is off for the user. Nothing was sent or changed."),
        ("documents_list", ["query": "release notes"], "(no documents matched)"),
        ("documents_list", [:], "(no documents matched)"),
        ("documents_list", ["query": "plan"],
         "- id=7F3C6E1A-0000-4000-8000-000000000001 · Launch plan · Sep 27 3:04 PM · Markdown · starred\n  → first line of the plan\n- id=7F3C6E1A-0000-4000-8000-000000000002 · Plan B · Sep 26 9:10 AM · PDF"),
        ("add_task", ["title": "Loop probe label the cables"], "ok: added 'Loop probe label the cables' (NEXT)"),
        ("add_task", ["title": "Call Sam's dentist", "project": "Home"], "ok: added 'Call Sam's dentist' (NOW) in Home"),
        ("complete_task", ["match": "label the cables"], "ok: completed 'Loop probe label the cables'"),
        ("remove_task", ["match": "label the cables"], "ok: removed 'Loop probe label the cables'"),
        ("focus_on_task", ["match": "cables"], "ok: focused on 'Loop probe label the cables' (now NOW)"),
        ("complete_task", ["match": "nothing like it"], "error: no active task matched 'nothing like it'"),
        ("remove_task", ["match": ""], "error: empty match"),
        ("remember_fact", ["fact": "my dentist is Dr. Lee"], "ok: saved fact 'my dentist is Dr. Lee'"),
        ("create_note", ["title": "Groceries"],
         "ok: created note 'Groceries' id=7F3C6E1A-0000-4000-8000-000000000003 (pinned)"),
        ("create_event", ["title": "Dentist"],
         "ok: created 'Dentist' Tue Sep 29 3:00 PM to 4:00 PM in calendar 'Home' id=ABC123:DEF"),
        ("create_event", ["title": "Dentist"],
         "error: calendar access is off for Grux. macOS will not ask again, so the user has to turn it on in System Settings > Privacy & Security > Calendars."),
        ("create_event", ["title": "Dentist"],
         "error: calendar access not granted. The user can enable it in System Settings > Privacy & Security > Calendars, or open the Calendar tab in Grux to trigger the prompt."),
        ("list_tasks", [:], "(no active tasks)"),
        ("create_note", [:], "error: note needs a title or body"),
        // The gate's and compose_email's own lines since RV14.
        ("create_note", ["title": "Groceries"], JaxToolGate.pendingResult(goesOutAs: nil)),
        ("slack_send", ["channel": "#general"], JaxToolGate.pendingResult(goesOutAs: "Grux")),
        ("compose_email", ["to": "sam@example.com"],
         EmailTool.pendingResult(recipients: ["sam@example.com"], fromName: "Grux")),
        // RV14: a file name or a snake_case word of the person's own stays.
        ("fs_read", ["path": "~/Documents/my_notes.txt"], "error: could not open my_notes.txt"),
        ("documents_read", ["document": "q3_plan"], "error: no document matched 'q3_plan'"),
    ]

    func test_everyLineAPersonCanReadFromAToolResultIsClean() {
        for entry in corpus {
            let line = ToolReplyCopy.forPerson(tool: entry.tool, input: entry.input, result: entry.result)
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], "\(entry.tool): \(entry.result) -> \(line)")
            XCTAssertFalse(line.isEmpty)
        }
    }

    func test_theTwoLinesFromTheSnapshotReadAsTheRowAsks() {
        XCTAssertEqual(ToolReplyCopy.forPerson(tool: "documents_list", input: ["query": "release notes"],
                                               result: "(no documents matched)"),
                       "I did not find a doc about release notes.")
        XCTAssertEqual(ToolReplyCopy.forPerson(tool: "create_note", input: ["title": "Groceries"],
                                               result: "pending: 'create_note' is waiting in the Jax HQ approval queue for the user's one-tap approval. Nothing was sent or changed."),
                       "Your note is waiting for your OK in Approvals. Nothing is saved until you tap it.")
    }

    func test_resultsSayWhatHappenedInPlainWords() {
        func say(_ tool: String, _ input: [String: Any], _ result: String) -> String {
            ToolReplyCopy.forPerson(tool: tool, input: input, result: result)
        }
        XCTAssertEqual(say("add_task", [:], "ok: added 'Call Sam's dentist' (NOW) in Home"),
                       "Added \"Call Sam's dentist\" to your tasks.")
        XCTAssertEqual(say("complete_task", [:], "ok: completed 'Label the cables'"), "Checked off \"Label the cables\".")
        XCTAssertEqual(say("focus_on_task", [:], "ok: focused on 'Label the cables' (now NOW)"),
                       "\"Label the cables\" is your focus now.")
        XCTAssertEqual(say("complete_task", [:], "error: no active task matched 'cables'"),
                       "I did not find a task called \"cables\".")
        XCTAssertEqual(say("create_event", [:], "ok: created 'Dentist' Tue Sep 29 3:00 PM to 4:00 PM in calendar 'Home' id=ABC"),
                       "Added \"Dentist\" to your calendar, Tue Sep 29 3:00 PM to 4:00 PM, in Home.")
        let docs = say("documents_list", ["query": "plan"],
                       "- id=AAA · Launch plan · Sep 27 3:04 PM · Markdown\n  → preview\n- id=BBB · Plan B · Sep 26 9:10 AM · PDF")
        XCTAssertEqual(docs, "I found 2 docs:\n- Launch plan, updated Sep 27 3:04 PM\n- Plan B, updated Sep 26 9:10 AM")
    }

    /// The guard has to bite, or a clean corpus proves nothing.
    func test_theGuardNamesEachThingAPersonShouldNotRead() {
        XCTAssertFalse(ToolReplyCopy.problems(in: "Waiting for the user's OK.").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "I ran create_note for you.").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "It is in Jax HQ.").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "(no documents matched)").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "pending: waiting").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "ok: added 'x' (NEXT)").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "Saved id=123").isEmpty)
        XCTAssertEqual(ToolReplyCopy.problems(in: "Your note is waiting for your OK in Approvals."), [])
    }

    /// Integrated review, P3: a tool id with its underscores read as spaces is
    /// still a tool id. MCP ids are caught by their naming pattern, so this
    /// holds with no server connected.
    func test_theGuardNamesAToolIdWrittenWithSpaces() {
        XCTAssertEqual(ToolReplyCopy.problems(in: "Use open app."), ["names a tool id"])
        XCTAssertEqual(ToolReplyCopy.problems(in: "It would have done this: Use mcp github create issue."),
                       ["names a tool id"])
        XCTAssertEqual(ToolReplyCopy.problems(in: "I ran mcp_github_create_issue for you."), ["names a tool id"])
        XCTAssertEqual(ToolReplyCopy.problems(in: "It would have done something outside Grux."), [])
        XCTAssertEqual(ToolReplyCopy.problems(in: "I opened Safari for you."), [])
    }

    /// Integrated review, P1: what a held write reads as, per kind.
    func test_aHeldWriteReadsAsHeldForEachKind() {
        func say(_ tool: String, _ input: [String: Any] = [:]) -> String {
            ToolReplyCopy.forPerson(tool: tool, input: input,
                                    result: "dryrun: Nothing was done, because this is a dry run. It would have done this: x")
        }
        XCTAssertEqual(say("create_note", ["title": "buy milk"]), "Nothing was saved, because this is a dry run.")
        XCTAssertEqual(say("create_event", ["title": "Dentist"]), "Nothing went on your calendar, because this is a dry run.")
        XCTAssertEqual(say("compose_email"), "Nothing was sent, because this is a dry run.")
        XCTAssertEqual(say("open_app"), "Nothing was opened, because this is a dry run.")
        XCTAssertEqual(say("shell_run"), "Nothing was run, because this is a dry run.")
        XCTAssertEqual(say("mcp_github_create_issue"), "Nothing was done, because this is a dry run.")
        XCTAssertEqual(ToolReplyCopy.replacingEcho(
            reply: "dryrun: Nothing was done, because this is a dry run.",
            results: [("create_note", [:], "dryrun: Nothing was done, because this is a dry run.")]),
                       "Nothing was saved, because this is a dry run.")
        XCTAssertEqual(ToolReplyCopy.problems(in: "dryrun: Nothing was done."), ["opens with 'dryrun:'"])
    }

    /// RV14: only a registered tool id reads as "that". A file name, a path or
    /// an ordinary snake_case word in the person's content reaches them as is.
    func test_onlyRegisteredToolIdsAreTranslated() {
        func say(_ tool: String, _ result: String) -> String {
            ToolReplyCopy.forPerson(tool: tool, input: [:], result: result)
        }
        XCTAssertEqual(say("fs_read", "error: could not open my_notes.txt"),
                       "That did not go through: Could not open my_notes.txt.")
        XCTAssertEqual(say("fs_list", "ok: saved grocery_list in ~/Documents/work_files"),
                       "Saved grocery_list in ~/Documents/work_files")
        XCTAssertEqual(say("create_note", "refused: 'create_note' is off for the user. Nothing was sent or changed."),
                       "I did not do that. That is off for you. Nothing was sent or changed.")
        XCTAssertEqual(say("fs_list", "error: create_note needs a title"), "That did not go through: That needs a title.")
        XCTAssertEqual(ToolReplyCopy.problems(in: "I opened my_notes.txt and grocery_list for you."), [])
        XCTAssertEqual(ToolReplyCopy.problems(in: "I ran create_note for you."), ["names a tool id"])
    }

    /// RV14: what the model hears for a waiting call uses the person's names,
    /// so a model that repeats it still reads right; only the status word it
    /// opens on is left for the translator.
    func test_theModelFacingPendingLinesUseThePersonsNames() {
        for line in [JaxToolGate.pendingResult(goesOutAs: nil), JaxToolGate.pendingResult(goesOutAs: "Grux"),
                     EmailTool.pendingResult(recipients: ["sam@example.com"], fromName: "Grux")] {
            XCTAssertTrue(line.hasPrefix("pending:"), line)
            XCTAssertEqual(ToolReplyCopy.problems(in: line), ["opens with 'pending:'"], line)
            XCTAssertTrue(line.contains("Approvals"), line)
        }
    }

    /// A local model that answers with the tool result it was handed.
    func test_aReplyThatEchoesAToolResultReachesThePersonTranslated() {
        let results: [(tool: String, input: [String: Any], result: String)] = [
            ("documents_list", ["query": "release notes"], "(no documents matched)"),
        ]
        XCTAssertEqual(ToolReplyCopy.replacingEcho(reply: "(no documents matched)", results: results),
                       "I did not find a doc about release notes.")
        XCTAssertEqual(ToolReplyCopy.replacingEcho(reply: "I looked and found nothing on that.", results: results),
                       "I looked and found nothing on that.", "a reply in the model's own words stays")
        XCTAssertEqual(ToolReplyCopy.replacingEcho(reply: "(no documents matched)", results: []),
                       "(no documents matched)", "no tool ran, nothing to translate")
    }

    // MARK: - The doors

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    /// Every door that puts a tool result in front of a person without a model
    /// in between lands the person's line, checked by what reaches Chat and
    /// not by how the source is spelled (RV24). The PIM card: its own run and a
    /// superseded card's detached run share `runAndTell`.
    func test_thePIMCardLandsThePersonsLineInChat() async {
        let savedChat = AppState.shared.chat
        let savedMemory = AppState.shared.config.memoryEnabled
        AppState.shared.config.memoryEnabled = false
        defer {
            AppState.shared.chat = savedChat
            AppState.shared.config.memoryEnabled = savedMemory
        }
        for entry in corpus {
            let raw = entry.result
            let out = await PIMConfirmationController.runAndTell(
                name: entry.tool, input: entry.input, personAsked: false, via: { _, _ in raw })
            XCTAssertEqual(out.result, raw)
            XCTAssertEqual(AppState.shared.chat.last?.content, out.reply, "\(entry.tool): Chat did not get the card's line")
            XCTAssertEqual(ToolReplyCopy.problems(in: out.reply), [], "\(entry.tool): \(raw) -> \(out.reply)")
        }
    }

    /// An approval answered from Chat runs the real tool and tells Chat the
    /// person's line, never the raw result.
    func test_anApprovalAnsweredFromChatLandsThePersonsLine() async {
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        let queued = queue.enqueue(ProposedAction(
            kind: .other, summary: "Run tool 'remove_task' (unclassified side effect).", target: "remove_task",
            detail: ["tool": "remove_task", "__replay_tool": "remove_task",
                     "__replay_input": "{\"match\":\"\"}",
                     ApprovalQueue.askedInKey: ApprovalQueue.askedInChat]))
        let result = await queue.approveAndExecute(queued.id)
        XCTAssertEqual(result, "error: empty match", "control: the approval did not run the tool")
        XCTAssertEqual(told.count, 1)
        XCTAssertFalse(told.joined().contains(result), "Chat was told the raw result")
        XCTAssertEqual(told.flatMap { ToolReplyCopy.problems(in: $0) }, [], told.joined())
    }

    private func tempQueue() -> ApprovalQueue {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replycopy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = ApprovalQueue(storeURL: dir.appendingPathComponent("approvals.json"))
        queue.judgeRisk = nil
        return queue
    }

    /// Skipping a gated note: the queue's own summary is the gate's
    /// `Run tool 'create_note' (unclassified side effect).`
    func test_aSkippedNoteIsNamedAsTheNote() {
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        let queued = queue.enqueue(ProposedAction(
            kind: .other, summary: "Run tool 'create_note' (unclassified side effect).", target: "create_note",
            detail: ["tool": "create_note", "__replay_tool": "create_note",
                     "__replay_input": "{\"title\":\"Groceries\"}",
                     ApprovalQueue.askedInKey: ApprovalQueue.askedInChat]))
        queue.skip(queued.id)
        XCTAssertEqual(told, ["Skipped your note \"Groceries\" in Approvals. Nothing was run."])
        XCTAssertEqual(told.flatMap { ToolReplyCopy.problems(in: $0) }, [])
    }

    // MARK: - Workflow gates (review RV13)

    /// Chat showed `Awaiting user approval to continue past phase
    /// rejection-recover Reply 'approve'`, and the build gate told the person
    /// not to auto-approve "on the user's behalf". A step id reads like a log.
    private var workflowIds: Set<String> {
        var ids: Set<String> = ["dryRun"]
        for def in CommandV2Engine.builtinDefinitions {
            ids.insert(def.id)
            for phase in def.phases { ids.insert(phase.id) }
        }
        // A one-word id ("publish", "translate") is also a plain word.
        return ids.filter { $0.contains("-") || $0.contains("_") || $0 == "dryRun" }
    }

    /// Every question a waiting workflow posts to Chat, live and dry, as the
    /// person reads it: the run's name, the reason, and the words that answer.
    ///
    /// Final sweep: with no project the run was named `localize {project}` and
    /// the dry gate read `since unknown (dry run: no project) shipped`, so both
    /// are checked with the parameter and without it. A dry question says it is
    /// a dry run, the walkthrough's included; a live one never does.
    func test_everyWorkflowGateQuestionReadsAsPlainWords() {
        let engine = CommandV2Engine()
        engine.load()
        var checked = 0
        for params: [String: JSONValue] in [["project": .string("Tracker")], [:]] {
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                for dry in [false, true] {
                    var run = CommandV2Run(definitionId: def.id,
                                           displayName: CommandV2Engine.runName(def.displayName, params: params),
                                           currentPhaseId: phase.id, parameters: params)
                    run.dryRun = dry
                    guard let reason = CommandV2Engine.waitingReason(at: phase, in: run) else { continue }
                    run.status = .waitingForApproval
                    run.blockingReason = reason
                    let question = engine.gateQuestion(for: run)
                    XCTAssertEqual(ToolReplyCopy.problems(in: question, internalNames: workflowIds), [],
                                   "\(def.id) at \(phase.id): \(question)")
                    XCTAssertNil(question.range(of: Self.statusAside, options: .regularExpression),
                                 "\(def.id) at \(phase.id) puts a status in parentheses: \(question)")
                    XCTAssertEqual(question.contains(CommandV2Executor.dryRunGateNote), dry,
                                   "\(def.id) at \(phase.id), dry \(dry): \(question)")
                    if let accepted = engine.acceptedReplies(for: run), !accepted.isEmpty {
                        XCTAssertTrue(accepted.contains { question.lowercased().contains($0) },
                                      "\(def.id) at \(phase.id) names no word that answers it: \(question)")
                    }
                    checked += 1
                }
            }
        }
        }
        XCTAssertEqual(checked, 28, "seven gates, each live and dry, with and without a project")
    }

    /// What the Workflows list shows for a run: its name, the step it is on,
    /// and why it stopped. It showed `phase: await-blocker-resolution` and
    /// `canceled by user`. Every built-in run name, with and without its
    /// parameter, and every step name is checked.
    func test_whatTheWorkflowsListShowsReadsAsPlainWords() {
        func check(_ line: String, _ what: String) {
            XCTAssertEqual(ToolReplyCopy.problems(in: line, internalNames: workflowIds), [], "\(what): \(line)")
            XCTAssertNil(line.range(of: Self.statusAside, options: .regularExpression),
                         "\(what) puts something in parentheses: \(line)")
            XCTAssertNil(line.range(of: #"(?i)\buser\b"#, options: .regularExpression), "\(what): \(line)")
        }
        var checked = 0
        var steps = 0
        for def in CommandV2Engine.builtinDefinitions {
            for params: [String: JSONValue] in [["project": .string("Tracker")], [:],
                                                ["project": .string(CommandV2Engine.unspecifiedParameter)]] {
                check(CommandV2Engine.runName(def.displayName, params: params), "\(def.id) run name")
                checked += 1
            }
            for phase in def.phases {
                let run = CommandV2Run(definitionId: def.id, displayName: def.displayName, currentPhaseId: phase.id)
                let line = CommandV2Engine.stepLine(for: run, in: def)
                XCTAssertTrue(line.hasSuffix(phase.displayName), "\(def.id) at \(phase.id) does not show its step: \(line)")
                check(line, "\(def.id) at \(phase.id)")
                checked += 1
                steps += 1
            }
        }
        // Review of e125705: every step of every built-in workflow, not a sample.
        XCTAssertEqual(steps, CommandV2Engine.builtinDefinitions.map(\.phases.count).reduce(0, +))
        check(CommandV2Engine.canceledReason, "a canceled run")
        for def in CommandV2Engine.builtinDefinitions where def.category == .ship {
            for phase in def.phases {
                let running = CommandV2Run(definitionId: def.id,
                                           displayName: CommandV2Engine.runName(def.displayName, params: [:]),
                                           currentPhaseId: phase.id)
                let message = CommandV2Engine.alreadyRunningMessage(running, in: def)
                check(message, "\(def.id) already running at \(phase.id)")
                let name = running.displayName.prefix(1).uppercased() + running.displayName.dropFirst()
                XCTAssertEqual(message, "\(name) is already running, on this step: \(phase.displayName).")
                XCTAssertEqual(message.first.map { String($0) }, message.first.map { String($0).uppercased() },
                               "a sentence starts with a capital: \(message)")
            }
        }
        let ship = try? XCTUnwrap(CommandV2Engine.builtinDefinitions.first { $0.id == "ship-ios-app" })
        if let ship {
            let running = CommandV2Run(definitionId: ship.id, displayName: "ship the iOS app",
                                       currentPhaseId: "brainstorm-approval-gate")
            let step = ship.phases.first { $0.id == "brainstorm-approval-gate" }?.displayName ?? ""
            XCTAssertEqual(CommandV2Engine.alreadyRunningMessage(running, in: ship),
                           "Ship the iOS app is already running, on this step: \(step).")
        }
        XCTAssertGreaterThan(checked, 60)
    }

    /// Review of e125705: step names passed the list test only because the
    /// guard had no rule for what made them read like an engine's log.
    func test_theGuardNamesAnAcronymASpacedHyphenAndEngineWords() {
        for line in ["Query ASC", "Fetch TestFlight feedback from ASC", "Grant TCC access", "Use the MCP server",
                     "Open the PIM card", "Still pending - wait another 24h", "Claude Design - marketing screenshots",
                     "Branch on review state", "Spawn fix swarm against TestFlight feedback",
                     "Swarm: incorporate week-later feedback", "Echo via builtin",
                     "Write idea + dedup against prior captures", "Confirm spec before launching build swarm"] {
            XCTAssertFalse(ToolReplyCopy.problems(in: line).isEmpty, line)
        }
        for line in ["Check App Store Connect status", "App Store Connect, ASC for short, says it is ready.",
                     "I found 2 docs:\n- Launch plan\n- Plan B", "Work in your week-later feedback",
                     "Wait 24h for Apple review", "Ship or hold"] {
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        }
    }

    /// Every notification Grux builds for a workflow: the ship-ios-app
    /// milestone banner (it said "ship-ios-app run is at the Walkthrough
    /// milestone."), and a schedule's fire and start-failure notices (they
    /// said "Running workflow → smoke-hello-world" and "Could not start
    /// workflow 'smoke-hello-world'."). Each is built by the function the app
    /// calls, for every built-in workflow and step, with and without a project.
    func test_everyWorkflowNotificationReadsAsPlainWords() {
        let ids = workflowIds
        func check(_ line: String, _ what: String) {
            XCTAssertEqual(ToolReplyCopy.problems(in: line, internalNames: ids), [], "\(what): \(line)")
            XCTAssertNil(line.range(of: Self.statusAside, options: .regularExpression),
                         "\(what) puts something in parentheses: \(line)")
            XCTAssertNil(line.range(of: #"(?i)\buser\b|\x{2192}"#, options: .regularExpression), "\(what): \(line)")
        }
        var checked = 0
        for def in CommandV2Engine.builtinDefinitions {
            for params: [String: JSONValue] in [["project": .string("Tracker")], [:]] {
                let runName = CommandV2Engine.runName(def.displayName, params: params)
                for (i, phase) in def.phases.enumerated() {
                    let env = NotificationManager.phaseTransitionEnvelope(
                        commandId: def.id, runId: UUID().uuidString, runName: runName,
                        phaseName: phase.displayName, phaseIndex: i + 1, totalPhases: def.phases.count,
                        step: def.mainPathStep(of: phase.id))
                    check(env.title, "\(def.id) at \(phase.id), title")
                    check(env.body, "\(def.id) at \(phase.id), body")
                    // Re-review of 90236d0: "reached" before an imperative step
                    // name ("reached Build it with a team of agents") reads
                    // oddly. The step is named after a colon, whatever it says.
                    let name = runName.prefix(1).uppercased() + runName.dropFirst()
                    XCTAssertEqual(env.body, "\(name) is now on this step: \(phase.displayName).")
                    checked += 1
                }
            }
            let action = UserCronAction.runCommand(definitionId: def.id)
            for notice in [UserCronScheduler.fireNotice(jobTitle: "Morning", action: action, workflowName: def.displayName),
                           UserCronScheduler.startFailedNotice(jobTitle: "Morning", workflowName: def.displayName)] {
                check(notice.title, "\(def.id) schedule title")
                check(notice.body, "\(def.id) schedule body")
                checked += 1
            }
        }
        let gone = UserCronScheduler.startFailedNotice(jobTitle: "Morning", workflowName: nil)
        check(gone.body, "a workflow this Mac does not have")
        let prompt = UserCronScheduler.fireNotice(jobTitle: "Morning", action: .agentPrompt("summarize my inbox"),
                                                  workflowName: nil)
        check(prompt.body, "a scheduled prompt")
        XCTAssertGreaterThan(checked, 100)

        // The orb's milestone hints and the App Store rejection banner, which
        // a person sees as surely as a notification (they said "Building app…
        // phase 2/12", "Walkthrough required - tap to approve" and "State:
        // REJECTED. Open Empire dashboard.").
        let shown = ids.union(["Empire dashboard"])
        func checkShown(_ line: String, _ what: String) {
            XCTAssertEqual(ToolReplyCopy.problems(in: line, internalNames: shown), [], "\(what): \(line)")
            XCTAssertNil(line.range(of: Self.statusAside, options: .regularExpression), "\(what): \(line)")
            XCTAssertNil(line.range(of: #"\b[A-Z]{2,}_[A-Z_]+\b|\bREJECTED\b|(?i)\bphase\b"#, options: .regularExpression),
                         "\(what) shows a raw state or says phase: \(line)")
        }
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                for state in [nil, "READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE", "PROCESSING_FOR_DISTRIBUTION",
                              "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "WAITING_FOR_REVIEW"] {
                    guard let hint = CommandV2PhaseNotifier.orbHint(phaseId: phase.id, phaseName: phase.displayName,
                                                                   step: def.mainPathStep(of: phase.id), ascState: state)
                    else { continue }
                    checkShown(hint.message, "\(def.id) orb at \(phase.id), \(state ?? "no state")")
                    checked += 1
                }
            }
        }
        for state in ["REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED"] {
            let n = ASCStateMonitor.rejectionNotice(projectName: "Tracker", state: state)
            for line in [n.spoken, n.title, n.body] { checkShown(line, "rejection banner for \(state)") }
        }
        XCTAssertEqual(CommandV2PhaseNotifier.orbHint(phaseId: "walkthrough", phaseName: "Walkthrough", step: (n: 9, total: 13),
                                                      ascState: nil)?.message, "Step 9 of 13: Walkthrough")

        let walkthrough = NotificationManager.phaseTransitionEnvelope(
            commandId: "ship-ios-app", runId: "r", runName: "ship the iOS app",
            phaseName: "Walkthrough", phaseIndex: 9, totalPhases: 14, step: (n: 9, total: 13))
        XCTAssertEqual(walkthrough.body, "Ship the iOS app is now on this step: Walkthrough.")
        XCTAssertEqual(walkthrough.title, "Step 9 of 13: Walkthrough")
    }

    /// Re-review of 90236d0: the banner said "Step 2 of 17" for ship-ios-app,
    /// counting branch and retry phases no person moves through. The count
    /// is the main path: the longest run of non-branch steps from the first
    /// to the natural end, never looping back.
    func test_stepCountsFollowTheStepsAPersonMovesThrough() throws {
        let ship = try XCTUnwrap(CommandV2Engine.builtinDefinitions.first { $0.id == "ship-ios-app" })
        let path = ["brainstorm", "brainstorm-approval-gate", "register-asc-app", "build", "convention-audit",
                    "install", "screenshots-capture", "screenshots-design", "walkthrough", "publish",
                    "wait-for-review", "check-status", "celebrate"]
        for (i, id) in path.enumerated() {
            let step = ship.mainPathStep(of: id)
            XCTAssertEqual(step?.n, i + 1, id)
            XCTAssertEqual(step?.total, path.count, id)
        }
        for detour in ["decide-next", "still-pending-or-rejected", "still-pending", "rejection-recover"] {
            XCTAssertNil(ship.mainPathStep(of: detour), "\(detour) is a branch or a retry, not a step")
        }
        let localize = try XCTUnwrap(CommandV2Engine.builtinDefinitions.first { $0.id == "localize-app" })
        XCTAssertNil(localize.mainPathStep(of: "defer-localization"), "the skip path is off the main path")
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                if case .branch = phase.action { XCTAssertNil(def.mainPathStep(of: phase.id), "\(def.id) \(phase.id)") }
                if let step = def.mainPathStep(of: phase.id) {
                    XCTAssertLessThanOrEqual(step.n, step.total)
                    XCTAssertLessThan(step.total, def.phases.count + 1)
                }
            }
            XCTAssertNotNil(def.phases.first.flatMap { def.mainPathStep(of: $0.id) }, "\(def.id) has no main path")
        }
    }

    /// Re-review of 90236d0: names the guard cannot judge, reworded by hand,
    /// and one step that had two names.
    func test_stepNamesThatReadAsNotesToTheAuthorAreGone() {
        let names = CommandV2Engine.builtinDefinitions.flatMap { $0.phases.map(\.displayName) }
        for old in ["Defer localization on skip", "Narrate the triage digest", "Stash a value", "Sad path",
                    "Publish to App Store"] {
            XCTAssertFalse(names.contains(old), old)
        }
        let publish = Set(CommandV2Engine.builtinDefinitions.flatMap { $0.phases.filter { $0.id == "publish" }.map(\.displayName) })
        XCTAssertEqual(publish.count, 1, "one step, one name: \(publish)")
    }

    /// SWEEP-10: every line a built-in workflow speaks, live and dry, with and
    /// without a project, through the same guard: a dry line is led by the
    /// dry-run note, and no line says "unknown" or uses a spaced hyphen.
    func test_everyWorkflowSpeechLineReadsAsPlainWords() {
        var checked = 0
        for def in CommandV2Engine.builtinDefinitions {
            for params: [String: JSONValue] in [["project": .string("Tracker")], [:]] {
                for dry in [false, true] {
                    var run = CommandV2Run(definitionId: def.id,
                                           displayName: CommandV2Engine.runName(def.displayName, params: params),
                                           currentPhaseId: def.phases.first?.id ?? "", parameters: params)
                    run.dryRun = dry
                    for phase in def.phases {
                        for line in CommandV2Executor.spokenLines(for: phase.action, in: run, definition: def) {
                            let what = "\(def.id) at \(phase.id), dry \(dry)"
                            XCTAssertEqual(ToolReplyCopy.problems(in: line, internalNames: workflowIds), [], "\(what): \(line)")
                            XCTAssertNil(line.range(of: #"(?i)\bunknown\b"#, options: .regularExpression), "\(what): \(line)")
                            XCTAssertFalse(line.contains("(dry run"), "\(what): \(line)")
                            if dry { XCTAssertTrue(line.hasPrefix("Dry run"), "\(what) says it as if it happened: \(line)") }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 60)
    }

    /// A parameter nobody filled reads as a gap in the sentence, never as the
    /// placeholder's own name.
    func test_theGuardNamesAnUnfilledPlaceholder() {
        XCTAssertFalse(ToolReplyCopy.problems(in: "localize {project}: It has been a week.").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "It has been a week since ${param.project} shipped.").isEmpty)
        XCTAssertEqual(ToolReplyCopy.problems(in: "localize your project: It has been a week."), [])
    }

    func test_whatAStoppedOrWaitingWorkflowSaysIsPlainWords() {
        var checked = 0
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                let stop = CommandV2Engine.dryRunStopMessage(at: phase)
                XCTAssertEqual(ToolReplyCopy.problems(in: stop, internalNames: workflowIds), [], "\(phase.id): \(stop)")
                if let followup = phase.scheduledFollowup {
                    let wait = CommandV2Engine.scheduledWaitReason(until: Date(), next: followup.nextPhaseId)
                    XCTAssertEqual(ToolReplyCopy.problems(in: wait, internalNames: workflowIds), [], "\(phase.id): \(wait)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    /// A status tucked into parentheses anywhere in a gate's question.
    private static let statusAside = #"\([^)]*\)"#

    /// The gate guard bites on the two lines the review quoted.
    func test_theGateGuardNamesTheOldLines() {
        XCTAssertNotNil("Resolve the App Store Connect blocker (Safari is open at the right page) - accept any pending agreement."
            .range(of: Self.statusAside, options: .regularExpression))
        XCTAssertFalse(ToolReplyCopy.problems(in: "Awaiting user approval to continue past phase rejection-recover",
                                              internalNames: workflowIds).isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "Do NOT auto-approve on the user's behalf.").isEmpty)
        XCTAssertFalse(ToolReplyCopy.problems(in: "seed it with a dryRun.<key> parameter", internalNames: workflowIds).isEmpty)
        XCTAssertEqual(ToolReplyCopy.problems(in: "Ready to send it to the App Store? Reply ship it to go.",
                                              internalNames: workflowIds), [])
    }

    /// RV24: an item with no replay is skipped through the same translator. Its
    /// summary can be the gate's fallback, which names the tool by id.
    func test_aSkippedRequestWithNoReplayIsNamedPlainly() {
        for (summary, expected) in [
            ("Run tool 'create_note' (unclassified side effect).", "Skipped your note in Approvals. Nothing was run."),
            ("Run tool 'agent_swarm_start' (unclassified side effect).", "Skipped that request in Approvals. Nothing was run."),
            ("Post a Slack message to #general.", "Skipped in Approvals: Post a Slack message to #general. Nothing was run."),
            ("Send the user's draft to the Jax HQ approval queue", "Skipped in Approvals: Send your draft to Approvals. Nothing was run."),
        ] {
            let queue = tempQueue()
            var told: [String] = []
            queue.tellChat = { told.append($0) }
            let queued = queue.enqueue(ProposedAction(
                kind: .other, summary: summary, target: "x",
                detail: [ApprovalQueue.askedInKey: ApprovalQueue.askedInChat]))
            queue.skip(queued.id)
            XCTAssertEqual(told, [expected], summary)
            XCTAssertEqual(told.flatMap { ToolReplyCopy.problems(in: $0) }, [], summary)
        }
    }
}
