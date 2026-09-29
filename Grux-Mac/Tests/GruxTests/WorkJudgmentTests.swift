import XCTest
@testable import Grux

/// Phase R, P-R-6: task priority, meeting moments, approvals risk, project
/// attribution and whether an agent job is worth starting, each a question on
/// the decision engine with the existing logic as its floor.
///
/// The rules every judgment here is held to:
/// - ONE provider call per judged event (acceptance criterion 1). Where one
///   event carries two judgments (a new task, a LIVE agent job) they share it.
/// - A keyless install behaves exactly as it does today (criterion 5): nothing
///   is asked, nothing is recorded, nothing changes.
/// - The provider may only RAISE: a flag, a higher priority, a filled blank, a
///   hold. It never lowers, approves, replaces or invents.
///
/// Every engine here is built with a stub provider; nothing reaches the
/// Keychain, the network or the operator's state.
@MainActor
final class WorkJudgmentTests: XCTestCase {

    /// Answers each question it is asked with whatever `script` returns for its
    /// wire name, and records every call.
    final class Scripted: DecisionProvider, @unchecked Sendable {
        let kind: DecisionProviderKind = .jev
        var calls: [(state: String, questions: [String: DecisionQuestion])] = []
        var fail = false
        var script: (String) -> DecisionAnswer?
        init(_ script: @escaping (String) -> DecisionAnswer? = { _ in nil }) { self.script = script }
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            calls.append((state, questions))
            if fail { throw JevDecisionProvider.Failure.http(503) }
            var out: [String: DecisionAnswer] = [:]
            for name in questions.keys { if let a = script(name) { out[name] = a } }
            return DecisionResult(answers: out, latencyMs: 380, inputTokens: 590, outputTokens: 20, provider: .jev)
        }
    }

    private func engine(key: String = "k", _ provider: Scripted, ledger: DecisionLedger? = nil) -> DecisionEngine {
        DecisionEngine(keyLookup: { key }, ledger: ledger ?? DecisionLedger(storeURL: nil), remote: { _ in provider })
    }

    private func tempURL(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pr6-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private let projects = [
        ProjectAttribution.Option(name: "Harbor Bakery Site", description: "tasks already in it: Draft the catering page copy"),
        ProjectAttribution.Option(name: "Trailhead iOS", description: "local project at ~/Projects/trailhead-ios"),
    ]

    // MARK: - approvals.risk

    private var queuedDelete: PendingApproval {
        PendingApproval(action: ProposedAction(kind: .other, summary: "Run tool 'files_delete' (unclassified side effect).",
                                               target: "files_delete",
                                               detail: ["tool": "files_delete", "__replay_tool": "files_delete",
                                                        "__replay_input": "{\"path\":\"~/Documents/Old\"}"]),
                        // Not urgent, as the gate queues a residual action: an urgent
                        // enqueue posts a real banner, which the test host cannot.
                        urgent: false, reason: "Not clearly routine and reversible. Pausing for your call.")
    }

    func test_risk_keylessAsksNothingAndQueuesExactlyAsBefore() async throws {
        let provider = Scripted { _ in .score(2, confidence: 1) }
        let ledger = DecisionLedger(storeURL: nil)
        let keyless = engine(key: "", provider, ledger: ledger)
        let direct = await ApprovalRiskJudgment.judge(queuedDelete, engine: keyless, threshold: 0.70)
        XCTAssertNil(direct)

        let url = tempURL("approvals.json")
        let queue = ApprovalQueue(storeURL: url)
        queue.judgeRisk = { await ApprovalRiskJudgment.judge($0, engine: keyless, threshold: 0.70) }
        let item = queue.enqueue(queuedDelete)
        await queue.waitForRiskJudgments()

        XCTAssertEqual(provider.calls.count, 0, "a keyless install paid for a risk judgment")
        XCTAssertEqual(ledger.recent.count, 0, "a keyless install recorded a decision it never made")
        XCTAssertEqual(queue.items, [item], "a keyless install changed the queued item")
        let stored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(stored.contains("\"risk\""), "a keyless install wrote a new field into approvals.json")
    }

    func test_risk_aHighRiskItemIsFlaggedOnceAndNothingElseMoves() async {
        let provider = Scripted { _ in .score(1.99, confidence: 0.99) }
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider, ledger: ledger)
        let queue = ApprovalQueue(storeURL: tempURL("approvals.json"))
        queue.judgeRisk = { await ApprovalRiskJudgment.judge($0, engine: e, threshold: 0.70) }
        let before = queue.enqueue(queuedDelete)
        await queue.waitForRiskJudgments()
        await queue.waitForRiskJudgments()

        let after = queue.items.first
        XCTAssertEqual(after?.risk?.raised, true)
        XCTAssertEqual(provider.calls.count, 1, "one call per new item")
        XCTAssertEqual(ledger.recent.map(\.surface), [ApprovalRiskJudgment.surface])
        // RAISE ONLY: the judgment added a flag and moved nothing.
        XCTAssertEqual(after?.state, .pending)
        XCTAssertEqual(after?.urgent, before.urgent)
        XCTAssertEqual(after?.reason, before.reason)
        XCTAssertEqual(after?.action, before.action)
        // The item's own tool input is on the state; the replay bookkeeping key is not.
        let state = provider.calls.first?.state ?? ""
        XCTAssertTrue(state.contains("Input: {\"path\":\"~/Documents/Old\"}"), state)
        XCTAssertFalse(state.contains("__replay_tool"), state)
    }

    func test_risk_neverFlagsALowOrUnsureAnswer() async {
        for (score, confidence) in [(0.05, 0.99), (1.9, 0.50), (1.0, 0.99)] {
            let e = engine(Scripted { _ in .score(score, confidence: confidence) })
            let risk = await ApprovalRiskJudgment.judge(queuedDelete, engine: e, threshold: 0.70)
            XCTAssertEqual(risk?.raised, false, "score \(score) at \(confidence) raised a flag")
        }
    }

    func test_risk_aFailingProviderStoresNothing() async {
        let provider = Scripted { _ in .score(2, confidence: 1) }
        provider.fail = true
        let risk = await ApprovalRiskJudgment.judge(queuedDelete, engine: engine(provider), threshold: 0.70)
        XCTAssertNil(risk, "the on-device fallback's 0 at 0 was stored as a judgment")
        XCTAssertEqual(provider.calls.count, 1, "one attempt, never a retry loop")
    }

    func test_risk_anItemThatArrivesJudgedIsNotAskedAgain() async {
        var asked = 0
        let queue = ApprovalQueue(storeURL: tempURL("approvals.json"))
        queue.judgeRisk = { _ in asked += 1; return nil }
        var item = queuedDelete
        item.risk = ApprovalRisk(score: 2, confidence: 0.98, raised: true)
        queue.enqueue(item)
        queue.enqueue(queuedDelete)
        await queue.waitForRiskJudgments()
        XCTAssertEqual(asked, 1, "an item whose event already asked its risk paid for a second call")
    }

    func test_risk_roundTripsAndAnUnjudgedItemCarriesNoRiskKey() throws {
        var judged = queuedDelete
        judged.risk = ApprovalRisk(score: 1.99, confidence: 0.99, raised: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(PendingApproval.self, from: try enc.encode(judged))
        XCTAssertEqual(back.risk, judged.risk, "a stored judgment did not survive a relaunch")
        let unjudged = String(data: try enc.encode(queuedDelete), encoding: .utf8) ?? ""
        XCTAssertFalse(unjudged.contains("\"risk\""), unjudged)
        XCTAssertNil(try dec.decode(PendingApproval.self, from: Data(unjudged.utf8)).risk)
    }

    // MARK: - agent.worthStarting

    private let plan = AgentWorthJudgment.state(
        title: "Reply to unread emails", goal: "Reply to the 12 unread emails in the inbox", budgetUSD: 5,
        rationale: "The inbox is piling up.", signals: ["(comms) 12 unread emails in the inbox"], running: [])
    private var heldItem: PendingApproval {
        GoalPursuitEngine.approvalItem(PlannedSwarmAction(title: "Reply to unread emails", goal: "Reply to the 12 unread emails",
                                                          template: "singleWorker", budgetUSD: 5),
                                       domain: "comms", rationale: GoalPursuitEngine.heldPrefix + "The inbox is piling up.")
    }

    func test_worth_keylessStartsTheJobAsToday() async {
        let provider = Scripted { _ in .noul(0.01) }
        let ledger = DecisionLedger(storeURL: nil)
        let verdict = await AgentWorthJudgment.judge(state: plan, heldItem: heldItem,
                                                     engine: engine(key: "", provider, ledger: ledger), threshold: 0.70)
        XCTAssertEqual(verdict, .start, "a keyless install held a job LIVE mode has always started")
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
    }

    func test_worth_aClearNoHoldsInOneCallWithTheHeldItemsRisk() async throws {
        let provider = Scripted { name in
            name.hasSuffix("__worth") ? .noul(0.2) : name.hasSuffix("__risk") ? .score(1.99, confidence: 0.98) : nil
        }
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider, ledger: ledger)
        let verdict = await AgentWorthJudgment.judge(state: plan, heldItem: heldItem, engine: e, threshold: 0.70)

        XCTAssertTrue(verdict.hold)
        XCTAssertEqual(verdict.risk?.raised, true)
        XCTAssertEqual(provider.calls.count, 1, "the held item's risk opened a second round trip")
        XCTAssertEqual(e.batchViolations, [])
        XCTAssertEqual(ledger.recent.map(\.surface), ["agent.worthStarting+approvals.risk"])
        let call = try XCTUnwrap(provider.calls.first)
        XCTAssertEqual(call.state, plan, "another gate's context leaked into the shared state")
        guard case .score(let riskInstructions, _)? = call.questions["approvals_risk__risk"] else {
            return XCTFail("the risk question is not on the call")
        }
        XCTAssertTrue(riskInstructions.hasPrefix(ApprovalRiskJudgment.state(for: heldItem)),
                      "the risk question lost the held item's own state")
    }

    func test_worth_anythingShortOfAClearNoStarts() async {
        for p in [0.86, 0.5, 0.36] {
            let e = engine(Scripted { $0.hasSuffix("__worth") ? .noul(p) : nil })
            let verdict = await AgentWorthJudgment.judge(state: plan, heldItem: heldItem, engine: e, threshold: 0.70)
            XCTAssertFalse(verdict.hold, "p \(p) held a job")
        }
        // A provider failure falls back on device, where a yes/no is 0.5,
        // "cannot judge". Even a threshold that 0.5 would clear holds nothing.
        let failing = Scripted { _ in .noul(0) }
        failing.fail = true
        let verdict = await AgentWorthJudgment.judge(state: plan, heldItem: heldItem, engine: engine(failing), threshold: 0.50)
        XCTAssertEqual(verdict, .start, "the on-device 0.5 held a job")
    }

    func test_worth_theHeldItemIsTheOneObserveQueues() {
        let a = PlannedSwarmAction(title: "Advance: map cache", goal: "g", template: "singleWorker", budgetUSD: 5)
        let item = GoalPursuitEngine.approvalItem(a, domain: "product/code", rationale: "r")
        XCTAssertEqual(item.action.summary, "Run a Claude Code session: Advance: map cache")
        XCTAssertEqual(item.action.target, "claude-code-swarm")
        XCTAssertEqual(item.action.detail, ["goal": "g", "template": "singleWorker", "domain": "product/code", "rationale": "r"])
        XCTAssertFalse(item.urgent)
        XCTAssertEqual(item.reason, "\(UserIdentity.assistantName) goal-pursuit (product/code): r")
        XCTAssertEqual(AgentWorthJudgment.dollars(5), "$5")
        XCTAssertEqual(AgentWorthJudgment.dollars(2.5), "$2.50")
    }

    // MARK: - meeting.moment

    private let transcript = """
    [00:05] Me: Okay, so the main thing today is the spring menu launch.
    [00:14] Them: I think we go with Northside Print, they were cheaper.
    [00:22] Me: Agreed, let's go with Northside.
    [00:31] Them: Great. I'll send them the final PDF by Wednesday.
    """
    private let items = ["Use Northside Print for the menus", "Send the final PDF by Wednesday", "Order new aprons"]

    func test_moment_keylessLabelsNothing() async {
        let provider = Scripted { _ in .choice("decision", confidence: 1, probabilities: [:]) }
        let ledger = DecisionLedger(storeURL: nil)
        let out = await MeetingMomentJudgment.judge(items: items, transcript: transcript,
                                                    engine: engine(key: "", provider, ledger: ledger), threshold: 0.70)
        XCTAssertNil(out)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
    }

    func test_moment_oneCallLabelsEveryItemItCanPlace() async throws {
        let picks: [String: DecisionAnswer] = [
            "item_0": .choice("decision", confidence: 1.0, probabilities: [:]),
            "item_1": .choice("action_item", confidence: 0.54, probabilities: [:]),
            "item_2": .choice("not_said", confidence: 1.0, probabilities: [:]),
        ]
        let provider = Scripted { picks[$0] }
        let ledger = DecisionLedger(storeURL: nil)
        let out = await MeetingMomentJudgment.judge(items: items, transcript: transcript,
                                                    engine: engine(provider, ledger: ledger), threshold: 0.70)
        XCTAssertEqual(provider.calls.count, 1, "one call per summary, not one per item")
        XCTAssertEqual(ledger.recent.map(\.surface), [MeetingMomentJudgment.surface])
        XCTAssertEqual(out, [items[0]: .decision, items[2]: .notSaid], "a below-threshold label was kept")
        XCTAssertEqual(provider.calls.first?.state, "Meeting transcript:\n" + transcript)
    }

    func test_moment_aClippedTranscriptNeverSaysNotInTranscript() async {
        let long = String(repeating: "[00:01] Them: nothing settled yet.\n", count: 2_000)
        let provider = Scripted { _ in .choice("not_said", confidence: 1, probabilities: [:]) }
        let out = await MeetingMomentJudgment.judge(items: items, transcript: long, engine: engine(provider), threshold: 0.70)
        XCTAssertNil(out, "an item from the left-out middle was flagged as not in the transcript")
        let sent = provider.calls.first?.state ?? ""
        XCTAssertLessThan(sent.count, MeetingMomentJudgment.maxTranscriptCharacters + 200)
        XCTAssertTrue(sent.contains("left out"))
    }

    func test_moment_aResummaryReplacesTheLabelsAndLegacyRecordsDecode() throws {
        var rec = MeetingRecord(summary: "old", actionItems: ["a"])
        rec.actionItemMoments = ["a": .decision]
        MeetingSummarizer.Summary(tldr: "new", actionItems: ["b"]).apply(to: &rec)
        XCTAssertEqual(rec.summary, "new")
        XCTAssertEqual(rec.actionItems, ["b"])
        XCTAssertNil(rec.actionItemMoments, "a keyless re-summary kept a label from the old list")

        // On disk a keyless record is byte for byte what it was: no new key.
        let enc = JSONEncoder()
        let json = String(data: try enc.encode(rec), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("actionItemMoments"))
        let back = try JSONDecoder().decode(MeetingRecord.self, from: try enc.encode(rec))
        XCTAssertNil(back.actionItemMoments)
    }

    // MARK: - task.priority + project.attribution

    private func task(_ title: String, priority: TaskPriority = .next, project: String = "") -> FocusTask {
        FocusTask(title: title, project: project, priority: priority)
    }

    func test_task_keylessLeavesEveryTaskAsItWasMade() async {
        let provider = Scripted { _ in .score(2, confidence: 1) }
        let ledger = DecisionLedger(storeURL: nil)
        let raise = await TaskJudgments.judge(task("Pay the tax, due tomorrow", priority: .later), options: projects,
                                              nowAllowed: true, engine: engine(key: "", provider, ledger: ledger),
                                              threshold: 0.70)
        XCTAssertEqual(raise, .none)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
    }

    func test_task_priorityAndProjectShareOneCall() async throws {
        let provider = Scripted { name in
            name.hasSuffix("__urgency") ? .score(1.99, confidence: 0.99)
                : .choice("Trailhead iOS", confidence: 0.96, probabilities: [:])
        }
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider, ledger: ledger)
        let raise = await TaskJudgments.judge(task("Fix the Trailhead offline crash before tomorrow's release", priority: .later),
                                              options: projects, nowAllowed: true, engine: e, threshold: 0.70)
        XCTAssertEqual(raise, TaskJudgments.Raise(priority: .now, project: "Trailhead iOS"))
        XCTAssertEqual(provider.calls.count, 1, "a new task paid for two round trips")
        XCTAssertEqual(e.batchViolations, [])
        XCTAssertEqual(ledger.recent.map(\.surface), ["task.priority+project.attribution"])
        XCTAssertEqual(provider.calls.first?.questions.keys.sorted(),
                       ["project_attribution__project", "task_priority__urgency"])
    }

    func test_task_neverLowersAndNowIsCappedByFocus() async {
        // A floor of now has nothing to raise and a stated project nothing to
        // fill: nothing is asked at all.
        let never = Scripted { _ in .score(0, confidence: 1) }
        let full = await TaskJudgments.judge(task("x", priority: .now, project: "Harbor Bakery Site"), options: projects,
                                             nowAllowed: true, engine: engine(never), threshold: 0.70)
        XCTAssertEqual(full, .none)
        XCTAssertEqual(never.calls.count, 0, "paid for a question with no room above the floor")

        // A confident "later" never lowers a next.
        let low = TaskJudgments.raisedPriority(floor: .next, answer: .score(0, confidence: 1), provider: .jev,
                                                     threshold: 0.70, nowAllowed: true)
        XCTAssertNil(low)
        // "now" while something else holds focus raises to next at most.
        XCTAssertEqual(TaskJudgments.raisedPriority(floor: .later, answer: .score(2, confidence: 1), provider: .jev,
                                                    threshold: 0.70, nowAllowed: false), .next)
        // Unsure, or on device, raises nothing.
        XCTAssertNil(TaskJudgments.raisedPriority(floor: .later, answer: .score(2, confidence: 0.5), provider: .jev,
                                                  threshold: 0.70, nowAllowed: true))
        XCTAssertNil(TaskJudgments.raisedPriority(floor: .later, answer: .score(2, confidence: 1), provider: .local,
                                                  threshold: 0.70, nowAllowed: true))
    }

    func test_project_neverReplacesOrInvents() async {
        let invents = Scripted { _ in .choice("Brand New Venture", confidence: 0.99, probabilities: [:]) }
        let raise = await TaskJudgments.judge(task("Plan the launch party", priority: .now), options: projects,
                                              nowAllowed: true, engine: engine(invents), threshold: 0.70)
        XCTAssertNil(raise.project, "a project that does not exist was filed")

        let stated = Scripted { _ in .choice("Trailhead iOS", confidence: 0.99, probabilities: [:]) }
        _ = await TaskJudgments.judge(task("Fix the map", priority: .now, project: "Harbor Bakery Site"), options: projects,
                                      nowAllowed: true, engine: engine(stated), threshold: 0.70)
        XCTAssertEqual(stated.calls.count, 0, "a project the creator gave was put up for judgment")

        XCTAssertNil(ProjectAttribution.chosen(.choice("none", confidence: 1, probabilities: [:]), provider: .jev,
                                               options: projects, threshold: 0.70))
        XCTAssertNil(ProjectAttribution.chosen(.choice("Trailhead iOS", confidence: 0.69, probabilities: [:]),
                                               provider: .jev, options: projects, threshold: 0.70))
        XCTAssertNil(ProjectAttribution.chosen(.choice("Trailhead iOS", confidence: 1, probabilities: [:]),
                                               provider: .local, options: projects, threshold: 0.70))
    }

    func test_project_optionsAreOnlyProjectsThatExist() {
        var a = task("Draft the catering page copy", project: "Harbor Bakery Site")
        a.createdAt = Date(timeIntervalSince1970: 200)
        var b = task("Fix the hours on the contact page", project: " harbor bakery site ")
        b.createdAt = Date(timeIntervalSince1970: 100)
        let c = task("Loose task")
        let d = task("Odd", project: "None")
        let known = [KnownProjects.Entry(name: "Trailhead iOS", description: "local project at ~/Projects/trailhead-ios"),
                     KnownProjects.Entry(name: "HARBOR BAKERY SITE", description: "dup"),
                     KnownProjects.Entry(name: "Garden Planner", description: "")]
        let options = ProjectAttribution.options(tasks: [b, c, a, d], known: known)
        XCTAssertEqual(options.map(\.name), ["Harbor Bakery Site", "Trailhead iOS", "Garden Planner"])
        XCTAssertEqual(options.first?.description,
                       "tasks already in it: Draft the catering page copy; Fix the hours on the contact page")
        XCTAssertEqual(options.last?.description, "a project on this Mac")
        let many = (0..<50).map { KnownProjects.Entry(name: "P\($0)", description: "") }
        XCTAssertEqual(ProjectAttribution.options(tasks: [], known: many).count, ProjectAttribution.maxOptions)
    }

    // MARK: - The task observer: once per new task, never per change

    private func observer(_ list: @escaping () -> [FocusTask], _ e: DecisionEngine) -> (TaskJudgments, () -> [(UUID, TaskPriority)], () -> [(UUID, String)]) {
        var priorities: [(UUID, TaskPriority)] = []
        var projectsSet: [(UUID, String)] = []
        let j = TaskJudgments()
        j.engine = { e }
        j.threshold = { 0.70 }
        j.projectOptions = { self.projects }
        j.tasks = list
        j.focusedTaskId = { nil }
        j.setPriority = { priorities.append(($0, $1)) }
        j.setProject = { projectsSet.append(($0, $1)) }
        return (j, { priorities }, { projectsSet })
    }

    func test_observer_judgesEachNewTaskOnceAndOnlyOverWhatItWasJudgedAgainst() async {
        let provider = Scripted { name in
            name.hasSuffix("__urgency") ? .score(1.0, confidence: 0.99)
                : .choice("Harbor Bakery Site", confidence: 0.95, probabilities: [:])
        }
        let list = [task("Pick a font for the bakery menu", priority: .later)]
        let (j, priorities, filed) = observer({ list }, engine(provider))
        j.consider(list)
        j.consider(list)
        await j.waitForJudgments()
        XCTAssertEqual(provider.calls.count, 1, "a task was judged again on a later change")
        XCTAssertEqual(priorities().map(\.1), [.next])
        XCTAssertEqual(filed().map(\.1), ["Harbor Bakery Site"])

        // A task the person re-prioritised while the call was out keeps their
        // choice, even when the judgment would still be a raise over it.
        let urgent = Scripted { $0.hasSuffix("urgency") ? .score(2, confidence: 0.99) : nil }
        var demoted = [task("Renew the bakery domain", priority: .next, project: "Harbor Bakery Site")]
        let (j2, priorities2, _) = observer({ demoted }, engine(urgent))
        j2.consider(demoted)
        demoted[0].priority = .later
        await j2.waitForJudgments()
        XCTAssertEqual(urgent.calls.count, 1)
        XCTAssertEqual(priorities2().count, 0, "the judgment overrode a priority the person set meanwhile")
    }

    func test_observer_aBulkLoadAndSubtasksAreNotPaidFor() async {
        let provider = Scripted { _ in .score(2, confidence: 1) }
        let bulk = (0..<(TaskJudgments.maxJudgedPerChange + 1)).map { task("restored \($0)", priority: .later) }
        let (j, _, _) = observer({ bulk }, engine(provider))
        j.consider(bulk)
        var sub = task("a sub-task", priority: .later)
        sub.parentId = UUID()
        j.consider([sub])
        await j.waitForJudgments()
        XCTAssertEqual(provider.calls.count, 0, "a restore or a sub-task was judged")
    }

    // MARK: - project.attribution for logged decisions

    private func decision(_ summary: String, project: String? = nil) -> DecisionRecord {
        DecisionRecord(id: UUID().uuidString, timestamp: Date(), dayKey: "2026-09-21", summary: summary, rationale: "",
                       alternatives: [], context: "", transcriptExcerpt: "", project: project, source: "ambient_transcript")
    }

    func test_decisions_keylessComeBackUntouched() async {
        let provider = Scripted { _ in .choice("Trailhead iOS", confidence: 1, probabilities: [:]) }
        let ledger = DecisionLedger(storeURL: nil)
        let records = [decision("Use offline map packs")]
        let out = await DecisionLog.attributeProjects(records, options: projects,
                                                      engine: engine(key: "", provider, ledger: ledger), threshold: 0.70)
        XCTAssertEqual(out, records)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0, "a keyless install recorded a decision it never made")
    }

    func test_decisions_oneCallFillsOnlyTheBlanks() async throws {
        let picks: [String: DecisionAnswer] = [
            "d0": .choice("Trailhead iOS", confidence: 0.96, probabilities: [:]),
            "d2": .choice("Made Up Co", confidence: 0.99, probabilities: [:]),
        ]
        let provider = Scripted { picks[$0] }
        let records = [decision("Use offline map packs"), decision("Switch the menu layout", project: "Bakery"),
                       decision("Take Friday off")]
        let out = await DecisionLog.attributeProjects(records, options: projects, engine: engine(provider), threshold: 0.70)
        XCTAssertEqual(provider.calls.count, 1, "one call per extraction pass")
        XCTAssertEqual(provider.calls.first?.questions.keys.sorted(), ["d0", "d2"], "a tagged record was put up for judgment")
        XCTAssertEqual(out.map(\.project), ["Trailhead iOS", "Bakery", nil])
        guard case .choice(let instructions, _)? = provider.calls.first?.questions["d0"] else { return XCTFail("no d0") }
        XCTAssertTrue(instructions.hasPrefix("The decision: Use offline map packs."), instructions)
    }
}
