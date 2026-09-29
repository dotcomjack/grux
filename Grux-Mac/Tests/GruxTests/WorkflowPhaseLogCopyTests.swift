import XCTest
@testable import Grux

/// SWEEP-12: the run record a person opens in Workflows showed an agent step as
/// its raw prompt cut at 120 characters ("...names the folder with the r",
/// "...(returns 403 F", "IMPORTANT - pre-flight + post-upload verification").
/// A person never sees prompt text. This walks every built-in workflow dry,
/// down every answer its gates take and every answer from Apple a dry run can
/// be seeded with, and reads every line of every phase log it records.
@MainActor
final class WorkflowPhaseLogCopyTests: XCTestCase {

    private var engine: CommandV2Engine!
    private var liveProject: URL?

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        engine = CommandV2Engine()
        engine.load()
    }

    override func tearDown() async throws {
        CommandV2Executor.iosToolStubForTests = nil
        CommandV2Executor.agentStubForTests = nil
        if let liveProject { try? FileManager.default.removeItem(at: liveProject) }
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        engine = nil
        try await super.tearDown()
    }

    /// The starts a dry run can take: a project, and each answer from Apple or
    /// the account a skipped phase would have read.
    private func scenarios() -> [(String, [String: JSONValue])] {
        let p: JSONValue = .string("DryRunApp\(UUID().uuidString.prefix(6))")
        var out: [(String, [String: JSONValue])] = []
        for def in CommandV2Engine.builtinDefinitions {
            out.append((def.id, ["project": p]))
        }
        out.append(("smoke-hello-world", ["dryRun.color": .string("red")]))
        out.append(("smoke-hello-world", ["dryRun.color": .string("teal")]))
        for state in ["READY_FOR_SALE", "REJECTED", "WAITING_FOR_REVIEW"] {
            out.append(("ship-ios-app", ["project": p, "dryRun.asc_state": .string(state)]))
            out.append(("check-asc-status", ["project": p, "dryRun.asc_state": .string(state)]))
        }
        for ok in ["true", "false"] {
            out.append(("ship-existing-ios-app", ["project": p, "dryRun.account_health_ok": .string(ok)]))
        }
        out.append(("testflight-feedback", ["project": p, "dryRun.tf_crash_count": .int(2),
                                            "dryRun.tf_comment_count": .int(5),
                                            "dryRun.tf_top_issue": .string("login crash")]))
        return out
    }

    private func current(_ id: UUID) -> CommandV2Run? {
        engine.run(id: id) ?? engine.recentRuns.first { $0.id == id }
    }

    private func settle(_ id: UUID) async throws -> CommandV2Run {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let run = current(id), run.status.isTerminal || run.status == .waitingForApproval
                || run.status == .waitingScheduled { return run }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(current(id))
    }

    /// Starts `defId` dry, answers its gates with `answers` in order, and
    /// cancels the run where it stopped (one run of a workflow at a time).
    private func walk(_ defId: String, _ params: [String: JSONValue], _ answers: [String],
                      dryRun: Bool = true) async throws -> CommandV2Run? {
        switch await engine.start(definitionId: defId, params: params, dryRun: dryRun) {
        case .failure(let err):
            XCTFail("\(defId) did not start: \(err.localizedDescription)")
            return nil
        case .success(let id):
            var run = try await wake(try await settle(id))
            for answer in answers where run.status == .waitingForApproval {
                await engine.resume(id, userReply: answer)
                run = try await wake(try await settle(id))
            }
            if !run.status.isTerminal { await engine.cancel(id) }
            return run
        }
    }

    /// A real run waiting on the clock (a day for Apple, a week after
    /// launch) is woken the way its timer would, at most three times, so a
    /// check that keeps finding the app in review ends.
    private func wake(_ run: CommandV2Run) async throws -> CommandV2Run {
        var run = run
        var wakes = 0
        while run.status == .waitingScheduled, wakes < 3 {
            wakes += 1
            await engine.handleScheduledWake(runId: run.id, phase: run.currentPhaseId)
            run = try await settle(run.id)
        }
        return run
    }

    /// The words the gate a run waits at takes (the engine's own list), or a
    /// sentence for a gate that takes any words.
    private func replies(_ run: CommandV2Run) -> [String] {
        guard let words = engine.acceptedReplies(for: run) else { return ["It reads well, ship it when you are ready."] }
        return words.isEmpty ? ["yes"] : words
    }

    /// Every run a scenario can reach: each gate answered with each of its
    /// words, following a word only when it leads somewhere a word before it
    /// did not.
    private func runs(_ defId: String, _ params: [String: JSONValue], dryRun: Bool = true) async throws
        -> [(run: CommandV2Run, answers: [String])] {
        var out: [(run: CommandV2Run, answers: [String])] = []
        var queue: [[String]] = [[]]
        while let answers = queue.first, out.count < 40 {
            queue.removeFirst()
            guard let run = try await walk(defId, params, answers, dryRun: dryRun) else { continue }
            out.append((run, answers))
            guard run.status == .waitingForApproval, answers.count < 5 else { continue }
            var seen: Set<[String]> = []
            for word in replies(run) {
                guard let next = try await walk(defId, params, answers + [word], dryRun: dryRun) else { continue }
                let path = next.phaseHistory.map(\.phaseId) + [next.currentPhaseId, next.status.rawValue]
                if seen.insert(path).inserted { queue.append(answers + [word]) }
            }
        }
        return out
    }

    /// Every 40-character run of text from an agent prompt, so a log that
    /// shows any of a prompt is caught wherever it was cut.
    private func promptWindows() -> Set<String> {
        var prompts: [String] = []
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases {
                switch phase.action {
                case .claudeAgent(let prompt, _, _): prompts.append(prompt)
                case .claudeAgentSwarm(let list, _): prompts.append(contentsOf: list)
                default: break
                }
            }
        }
        var windows: Set<String> = []
        for prompt in prompts {
            let chars = Array(prompt)
            guard chars.count >= 40 else { continue }
            for i in 0...(chars.count - 40) { windows.insert(String(chars[i..<(i + 40)])) }
        }
        return windows
    }

    /// The ids a person never reads: every workflow's, step's, builtin's and
    /// tool's. Compound ones only ("check-status", "ios_publish_to_appstore"),
    /// since a one-word id ("hold", "publish") is also an ordinary word.
    private func internalNames() -> Set<String> {
        var names: Set<String> = []
        for def in CommandV2Engine.builtinDefinitions {
            names.insert(def.id)
            for phase in def.phases {
                names.insert(phase.id)
                switch phase.action {
                case .builtin(let name, _), .iosTool(let name, _): names.insert(name)
                default: break
                }
            }
        }
        return names.filter { $0.contains("-") || $0.contains("_") || $0.contains(".") }
    }

    /// What is wrong with one line of a phase log, as person copy.
    private func problems(_ line: String, prompts: Set<String>, names: Set<String>) -> [String] {
        var found = ToolReplyCopy.problems(in: line, internalNames: names)
        let chars = Array(line)
        if chars.count >= 40,
           (0...(chars.count - 40)).contains(where: { prompts.contains(String(chars[$0..<($0 + 40)])) }) {
            found.append("shows agent prompt text")
        }
        // A sentence a person reads ends as a sentence, not wherever a count
        // of characters ran out.
        if let last = line.trimmingCharacters(in: .whitespaces).last, !".!?\"”)".contains(last) {
            found.append("does not end as a sentence (cut mid-word?)")
        }
        return found
    }

    func test_everyPhaseLogAPersonCanOpenReadsAsPersonCopy() async throws {
        let prompts = promptWindows()
        let names = internalNames()
        XCTAssertFalse(prompts.isEmpty, "control: the built-in workflows have agent prompts to look for")
        // Control: each check fires on the lines SWEEP-12 found.
        XCTAssertFalse(problems("dry run: would start a Claude agent: Use the superpowers:brainstorming skill on X. Open the project's CLAUDE.md and README.md if they",
                                prompts: prompts, names: names).isEmpty, "control: a cut prompt is caught")
        XCTAssertFalse(problems("dry run: would call ios_check_asc_status(project=X)", prompts: prompts, names: names).isEmpty,
                       "control: a tool id is caught")
        XCTAssertFalse(problems("[dry run: would wait 86400s, then continue at check-status]", prompts: prompts, names: names).isEmpty,
                       "control: a step id is caught")
        var visited: Set<String> = []
        var bad: [String] = []
        for (defId, params) in scenarios() {
            for (run, _) in try await runs(defId, params) {
                for rec in run.phaseHistory {
                    visited.insert("\(defId)/\(rec.phaseId)")
                    for line in rec.log.split(separator: "\n").map(String.init)
                    where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        let found = problems(line, prompts: prompts, names: names)
                        if !found.isEmpty {
                            bad.append("\(defId)/\(rec.phaseId): \(found.joined(separator: ", ")): \(line.prefix(160))")
                        }
                    }
                }
            }
        }
        // The walk reached every phase that acts outside the run, so every
        // line that stands in for one was read.
        var unreached: [String] = []
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases where !CommandV2Executor.changesNothingOutside(phase.action)
                && !visited.contains("\(def.id)/\(phase.id)") {
                unreached.append("\(def.id)/\(phase.id)")
            }
        }
        XCTAssertEqual(unreached, [], "phases no dry walk reached, so their lines went unread")
        let unique = Array(Set(bad)).sorted()
        XCTAssertEqual(unique, [], "\(unique.count) phase log lines a person can open are not person copy:\n"
                       + unique.joined(separator: "\n"))
    }

    // MARK: - Real runs (review of 66ea148, ruled in scope)

    private enum Answer { case finished, failed, timedOut }

    /// The tool and agent layers answer as `mode` says for the step
    /// `phase` (every step when nil) and as finished for the rest. A tool
    /// reports the Apple and account answers the scenario seeds.
    private func stubOutsideSteps(_ mode: Answer, at phase: String?, seeds: [String: JSONValue]) {
        func answer(_ run: CommandV2Run) -> Answer { phase == nil || run.currentPhaseId == phase ? mode : .finished }
        var state: [String: JSONValue] = [:]
        for (k, v) in seeds where k.hasPrefix(CommandV2Engine.dryRunStatePrefix) {
            state[String(k.dropFirst(CommandV2Engine.dryRunStatePrefix.count))] = v
        }
        let updates = state
        CommandV2Executor.iosToolStubForTests = { name, _, run in
            switch answer(run) {
            case .finished: return IOSDispatcherV2Result(text: "[\(name) exit 0] ok", success: true, stateUpdates: updates)
            case .failed: return IOSDispatcherV2Result(text: "[\(name) exit 1] error: HTTP 403 from ASC", success: false, stateUpdates: [:])
            case .timedOut: return IOSDispatcherV2Result(text: "\(name): timed out after 600s", success: false, stateUpdates: [:])
            }
        }
        CommandV2Executor.agentStubForTests = { prompts, run in
            switch answer(run) {
            case .finished:
                return .init(text: "Done. Wrote the files.", success: true, costUSD: 0.4213, durationSec: 64,
                             workerCount: prompts.count, pausedForAuth: false)
            case .failed:
                return .init(text: "error: build failed in ContentView.swift", success: false, costUSD: 0.12,
                             durationSec: 30, workerCount: prompts.count, pausedForAuth: false)
            case .timedOut:
                return .init(text: "worker timed out after 1800s", success: false, costUSD: 0.9,
                             durationSec: 1800, workerCount: prompts.count, pausedForAuth: false)
            }
        }
    }

    /// A project folder a real run can build and audit, so its own checks
    /// run for real and write only here.
    private func makeLiveProject() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRunApp\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "name: LiveRunApp\n".write(to: dir.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        liveProject = dir
        return dir.path
    }

    func test_everyPhaseLogOfARealRunLeadsWithPersonCopy() async throws {
        let prompts = promptWindows()
        let names = internalNames()
        let project: JSONValue = .string(try makeLiveProject())
        var bad: [String] = []
        var visited: Set<String> = []
        var failedLines = 0
        func read(_ defId: String, _ run: CommandV2Run) {
            for rec in run.phaseHistory {
                visited.insert("\(defId)/\(rec.phaseId)")
                for line in rec.log.split(separator: "\n").map(String.init)
                where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let found = problems(line, prompts: prompts, names: names)
                    if !found.isEmpty { bad.append("\(defId)/\(rec.phaseId): \(found.joined(separator: ", ")): \(line.prefix(160))") }
                }
            }
        }
        // Every path a finished tool and agent layer leads to, and the step
        // each path reaches first.
        var pathTo: [String: (defId: String, params: [String: JSONValue], answers: [String])] = [:]
        var scenarios = scenarios().map { ($0.0, $0.1.merging(["project": project]) { $1 }) }
        // An empty idea fails before Grux asks the idea memory service
        // anything; a real idea would reach that service, so no test saves one.
        scenarios.append(("capture-idea", ["content": .string("")]))
        for (defId, params) in scenarios {
            stubOutsideSteps(.finished, at: nil, seeds: params)
            for (run, answers) in try await runs(defId, params, dryRun: false) {
                read(defId, run)
                for rec in run.phaseHistory where pathTo["\(defId)/\(rec.phaseId)"] == nil {
                    pathTo["\(defId)/\(rec.phaseId)"] = (defId, params, answers)
                }
            }
        }
        // Each outside step failing, then timing out, on the path that
        // reaches it.
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases where !CommandV2Executor.changesNothingOutside(phase.action) {
                guard let path = pathTo["\(def.id)/\(phase.id)"] else { continue }
                for mode in [Answer.failed, .timedOut] {
                    stubOutsideSteps(mode, at: phase.id, seeds: path.params)
                    if let run = try await walk(path.defId, path.params, path.answers, dryRun: false) {
                        read(def.id, run)
                        if run.phaseHistory.contains(where: { $0.phaseId == phase.id && $0.outcome == .failure }) { failedLines += 1 }
                    }
                }
            }
        }
        var unreached: [String] = []
        for def in CommandV2Engine.builtinDefinitions {
            for phase in def.phases where !CommandV2Executor.changesNothingOutside(phase.action)
                && !visited.contains("\(def.id)/\(phase.id)") {
                unreached.append("\(def.id)/\(phase.id)")
            }
        }
        XCTAssertEqual(unreached, [], "phases no real walk reached, so their lines went unread")
        XCTAssertGreaterThan(failedLines, 20, "control: the failing and timed-out steps really failed")
        let unique = Array(Set(bad)).sorted()
        XCTAssertEqual(unique, [], "\(unique.count) lines of a real run's record are not person copy:\n" + unique.joined(separator: "\n"))
    }

    /// The raw output a person debugging a failed step needs is kept, under
    /// the record's details, never as the step's line.
    func test_aFailedRealStepKeepsItsRawOutputAsDetails() async throws {
        let project: JSONValue = .string(try makeLiveProject())
        let params: [String: JSONValue] = ["project": project, "dryRun.asc_state": .string("WAITING_FOR_REVIEW")]
        stubOutsideSteps(.failed, at: "query", seeds: params)
        let failed = try await walk("check-asc-status", params, [], dryRun: false)
        let run = try XCTUnwrap(failed)
        let rec = try XCTUnwrap(run.phaseHistory.last { $0.phaseId == "query" })
        XCTAssertEqual(rec.outcome, .failure)
        XCTAssertEqual(rec.log, "Could not finish \"Ask App Store Connect\". The details say why.")
        XCTAssertEqual(rec.details, "[ios_check_asc_status exit 1] error: HTTP 403 from ASC")
        stubOutsideSteps(.finished, at: nil, seeds: params)
        let finished = try await walk("check-asc-status", params, [], dryRun: false)
        let ok = try XCTUnwrap(finished)
        XCTAssertEqual(ok.phaseHistory.last { $0.phaseId == "query" }?.log,
                       "Finished \"Ask App Store Connect\". Apple says the app is waiting for review.")
    }

    /// A run record saved before details existed still opens.
    func test_aRecordSavedBeforeDetailsDecodes() throws {
        let json = #"{"phaseId":"p","startedAt":0,"outcome":"success","log":"Done."}"#
        let rec = try JSONDecoder().decode(CommandV2Run.PhaseRecord.self, from: Data(json.utf8))
        XCTAssertNil(rec.details)
        XCTAssertEqual(rec.log, "Done.")
    }

    /// Review of 66ea148, P3: a value that is not plain text was written as
    /// raw JSON.
    func test_aNotedValueThatIsNotTextReadsAsASentence() {
        XCTAssertEqual(PhaseLogCopy.noted(.string("teal")), "Noted for later: teal.")
        XCTAssertEqual(PhaseLogCopy.noted(.bool(true)), "Noted for later: yes.")
        XCTAssertEqual(PhaseLogCopy.noted(.int(3)), "Noted for later: 3.")
        XCTAssertEqual(PhaseLogCopy.noted(.array([.string("ja"), .string("de")])), "Noted 2 items for later.")
        XCTAssertEqual(PhaseLogCopy.noted(.object(["a": .int(1)])), "Noted some details for later.")
        XCTAssertEqual(PhaseLogCopy.noted(.null), "Noted that there is nothing here yet.")
    }

    // MARK: - The run record's own words

    /// Review of 940943e, P3: an unreadable status read "Apple says the app is
    /// unknown.", and DEVELOPER_REJECTED read "developer rejected".
    func test_appleStatesReadInWords() {
        let step = "Ask App Store Connect"
        XCTAssertEqual(PhaseLogCopy.tool(step: step, ok: true, raw: "", appleState: "UNKNOWN"),
                       "Finished \"Ask App Store Connect\", but Apple's status for the app could not be read.")
        XCTAssertEqual(PhaseLogCopy.tool(step: step, ok: true, raw: "", appleState: ""),
                       "Finished \"Ask App Store Connect\", but Apple's status for the app could not be read.")
        XCTAssertEqual(PhaseLogCopy.tool(step: step, ok: true, raw: "", appleState: "DEVELOPER_REJECTED"),
                       "Finished \"Ask App Store Connect\". Apple says the app is taken out of review.")
        XCTAssertEqual(PhaseLogCopy.stateWords("INVALID_BINARY"), "held back because Apple could not use the uploaded build")
        XCTAssertEqual(PhaseLogCopy.stateWords("WAITING_FOR_REVIEW"), "waiting for review")
        XCTAssertEqual(PhaseLogCopy.tool(step: step, ok: true, raw: ""), "Finished \"Ask App Store Connect\".")
    }

    /// The Workflows drill-in titled each step with its id ("brainstorm-approval-gate"),
    /// showed its outcome as "(success)" and headed the list "PHASE HISTORY".
    /// Every built-in step's title, every status and the headers read as person
    /// copy, and the view uses them.
    func test_theRunRecordTitlesEachStepWithItsNameNotItsId() throws {
        let names = internalNames()
        var bad: [String] = []
        for def in CommandV2Engine.builtinDefinitions {
            let ids = def.phases.map(\.id)
            for phase in def.phases {
                let title = PhaseLogCopy.stepTitle(phase.id, in: def)
                // A title equal to any step id, or holding a compound id
                // ("decide-ship-or-hold"). A one-word id ("hold") inside a
                // sentence ("Ship or hold") is the English word, not the id.
                // Case matters: "Celebrate" is the step's name, "celebrate" its id.
                for id in ids where title == id
                    || ((id.contains("-") || id.contains("_"))
                        && title.range(of: #"(?<![\w-])"# + NSRegularExpression.escapedPattern(for: id) + #"(?![\w-])"#,
                                       options: .regularExpression) != nil) {
                    bad.append("\(def.id)/\(phase.id): the title \"\(title)\" contains the id \(id)")
                }
                let found = ToolReplyCopy.problems(in: title, internalNames: names)
                if !found.isEmpty { bad.append("\(def.id)/\(phase.id): \(found.joined(separator: ", ")): \(title)") }
            }
        }
        XCTAssertEqual(bad, [], bad.joined(separator: "\n"))
        let gone = PhaseLogCopy.stepTitle("no-such-step", in: CommandV2Engine.builtinDefinitions.first)
        XCTAssertFalse(gone.contains("no-such-step"), "a step that is gone shows its id: \(gone)")
        XCTAssertFalse(PhaseLogCopy.stepTitle("greet", in: nil).contains("greet"), "a workflow that is gone shows the id")
        let outcomes: [CommandV2Run.PhaseRecord.Outcome] = [.running, .success, .failure, .skipped, .branched, .scheduled, .paused]
        for outcome in outcomes {
            let word = PhaseLogCopy.status(outcome)
            XCTAssertFalse(word.hasPrefix("("), "\(outcome.rawValue): \(word)")
            XCTAssertNotEqual(word, outcome.rawValue, "the status is the engine's own word: \(word)")
            XCTAssertEqual(ToolReplyCopy.problems(in: word, internalNames: names), [], word)
        }
        for header in [PhaseLogCopy.stepsHeader, PhaseLogCopy.detailsLabel] {
            XCTAssertEqual(ToolReplyCopy.problems(in: header), [], header)
            XCTAssertNil(header.range(of: #"(?i)\bphase|\bstate\b"#, options: .regularExpression), header)
        }
        // The view draws these, not the id, the raw outcome or the old headers,
        // and keeps the raw state in a section that starts closed.
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/CommandsV2/CommandsV2View.swift"), encoding: .utf8)
        for needed in ["PhaseLogCopy.stepTitle(rec.phaseId", "PhaseLogCopy.status(rec.outcome)", "PhaseLogCopy.stepsHeader",
                       "DisclosureGroup(isExpanded:", "PhaseLogCopy.detailsLabel"] {
            XCTAssertTrue(view.contains(needed), "the run record does not use \(needed)")
        }
        for gone in ["Text(rec.phaseId)", "outcome.rawValue", "\"PHASE HISTORY\"", "\"STATE\"", " phases\")"] {
            XCTAssertFalse(view.contains(gone), "the run record still draws \(gone)")
        }
        XCTAssertTrue(view.contains("@State private var openDetails: Set<UUID> = []"), "the Details section does not start closed")

        // Each workflow card's kind: a person word, never the stored value.
        for category in CommandV2Definition.Category.allCases {
            let word = PhaseLogCopy.category(category)
            XCTAssertNotEqual(word.lowercased(), category.rawValue.lowercased(), "the card shows the raw kind \(category.rawValue)")
            XCTAssertEqual(ToolReplyCopy.problems(in: word, internalNames: names), [], word)
        }
        for def in CommandV2Engine.builtinDefinitions {
            XCTAssertNotEqual(PhaseLogCopy.category(def.category), def.category.rawValue, "\(def.id)'s card shows a raw kind")
        }
        XCTAssertTrue(view.contains("PhaseLogCopy.category(def.category)"), "the card does not use the kind's person word")
        // Each card's title: a person title, never an unfilled placeholder.
        for def in CommandV2Engine.builtinDefinitions {
            let title = PhaseLogCopy.cardTitle(def)
            XCTAssertFalse(title.contains("{") || title.contains("}"), "\(def.id)'s card title shows a placeholder: \(title)")
            XCTAssertEqual(ToolReplyCopy.problems(in: title), [], title)
        }
        XCTAssertTrue(view.contains("Text(PhaseLogCopy.cardTitle(def))"), "the card does not draw its person title")
        XCTAssertFalse(view.contains("Text(def.displayName)"), "a card still draws the definition's raw name")
        XCTAssertFalse(view.contains("category.rawValue"), "a card still draws its raw kind")
    }
}
