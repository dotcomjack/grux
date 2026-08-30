import Foundation
import GruxAgentCore

// Jax Phase 2: the goal-pursuit engine. This is the part that lets Jax stop
// waiting to be asked: on a schedule (nightly + when idle), it reads the user's
// REAL goals, picks the single highest-leverage next move, and plans the work as
// a Claude Code terminal session (a swarm job, the ONLY sanctioned action
// mechanism). What happens to that plan depends on the autonomy mode:
//
//   SIMULATE (default, Phase 2 v1)  : log the plan, execute NOTHING.
//   OBSERVE                         : log + queue it to Jax HQ for a one-tap yes.
//   LIVE                            : dispatch it (still through the gate).
//
// HARD RULES baked in here:
//   * NO GUESSING / NO MAKING THINGS UP. The model is fed ONLY real roadmap
//     items + real signals; it is told to plan from those, never to invent
//     goals, progress, or results. SIMULATE never executes, so it can never
//     fabricate an outcome.
//   * The ONLY way Jax acts is by directing a Claude Code terminal session
//     (AgentService.startSwarm). No other side-effecting path.
//
// House style mirrors BriefingEngine / FoundryGovernor: @MainActor singleton,
// local-time cadence, Codable local persistence under ~/.grux/jax/, zero
// em/en dashes, dollars as $N.

// MARK: - Autonomy mode

enum AutonomyMode: String, Codable, CaseIterable {
    case simulate   // plan + log only, execute nothing (Phase 2 v1 default)
    case observe    // plan + queue for one-tap approval
    case live       // plan + dispatch (still gated)

    var label: String {
        switch self {
        case .simulate: return "Simulate"
        case .observe:  return "Observe"
        case .live:     return "Live"
        }
    }
}

@MainActor
final class AutonomyController: ObservableObject {
    static let shared = AutonomyController()

    // Default SIMULATE: Jax proves its judgment with zero real-world effect until
    // the user graduates it deliberately.
    @Published private(set) var mode: AutonomyMode = .simulate
    // Hard stop. When true, no cycle runs in any mode.
    @Published private(set) var killed = false

    private let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("jax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autonomy.json")
    }()

    private struct State: Codable { var mode: AutonomyMode; var killed: Bool }

    private init() {
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            mode = s.mode
            killed = s.killed
        }
    }

    func setMode(_ m: AutonomyMode) { mode = m; save() }
    func setKilled(_ k: Bool) { killed = k; save() }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(State(mode: mode, killed: killed)) {
            Persistence.write(data, to: url)
        }
    }
}

// MARK: - Planned action + run record

// Exactly the shape AgentService.startSwarm consumes, so a SIMULATE plan and a
// LIVE dispatch are the same object; only whether we run it differs.
struct PlannedSwarmAction: Codable, Equatable {
    var title: String
    var goal: String           // the instruction handed to the Claude Code worker
    var template: String       // SwarmTemplate rawValue
    var budgetUSD: Double
}

// One goal-pursuit cycle's outcome. In SIMULATE, executed is always false.
struct GoalPursuitRun: Codable, Identifiable {
    let id: UUID
    var date: Date
    var mode: String           // AutonomyMode rawValue at run time
    var domain: String         // product/code, comms, ops, ...
    var chosenGoal: String     // the real goal this advances (verbatim from source)
    var rationale: String      // one line, in the user's voice
    var action: PlannedSwarmAction?  // nil when nothing was worth doing this cycle
    var executed: Bool         // false in SIMULATE / OBSERVE-until-approved

    init(id: UUID = UUID(), date: Date = Date(), mode: String, domain: String,
         chosenGoal: String, rationale: String, action: PlannedSwarmAction?, executed: Bool) {
        self.id = id; self.date = date; self.mode = mode; self.domain = domain
        self.chosenGoal = chosenGoal; self.rationale = rationale
        self.action = action; self.executed = executed
    }
}

// MARK: - Engine

@MainActor
final class GoalPursuitEngine: ObservableObject {
    static let shared = GoalPursuitEngine()

    // Recent runs, newest first, for Jax HQ + the briefing.
    @Published private(set) var runs: [GoalPursuitRun] = []
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private let maxRuns = 200

    private let storeURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("jax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("goal-runs.json")
    }()

    // Last nightly fire, persisted so a relaunch inside the window does not
    // re-run a cycle already done today.
    private var lastNightlyAt: Date? {
        get { UserDefaults.standard.object(forKey: "jax.goalpursuit.lastNightly") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "jax.goalpursuit.lastNightly") }
    }

    private init() {
        load()
    }

    // MARK: Scheduler

    // Mirrors FoundryGovernor's cadence intent: one nightly cycle inside the
    // 2:00 AM to 6:00 AM local window. (Idle-opportunistic firing reuses the same
    // FoundryGovernor AC+idle signal and is wired as a fast-follow; nightly +
    // the on-demand fire trigger cover Phase 2 v1.)
    func start() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick() // catch-up on launch
    }

    func tick() {
        guard !isRunning, !AutonomyController.shared.killed else { return }
        let now = Date()
        guard BriefingWindow.dayPart(for: now) == .lateNight || isInNightlyWindow(now) else { return }
        if let last = lastNightlyAt, BriefingWindow.sameLocalDay(last, now) { return }
        lastNightlyAt = now
        Task { @MainActor in await self.runCycle(trigger: "nightly") }
    }

    private func isInNightlyWindow(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let h = cal.component(.hour, from: date)
        return h >= 2 && h < 6
    }

    // MARK: Run one cycle

    // On-demand entry (Home button / fire-jax-goalcycle). Always allowed unless
    // killed; does not touch the nightly dedupe stamp.
    @discardableResult
    func runNow() async -> GoalPursuitRun? {
        guard !AutonomyController.shared.killed else { return nil }
        return await runCycle(trigger: "manual")
    }

    @discardableResult
    private func runCycle(trigger: String) async -> GoalPursuitRun? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        let mode = AutonomyController.shared.mode
        WakeLog.shared.log("jax goal-pursuit: cycle start (\(trigger), mode \(mode.rawValue))")

        // 1. Gather REAL signals across the active domains. Nothing here is
        //    invented: every line comes from a live store.
        let signals = gatherSignals()
        guard !signals.isEmpty else {
            WakeLog.shared.log("jax goal-pursuit: no real goals/signals to act on; standing down")
            return nil
        }

        // 2. Ask the model (as Jax) to pick the single highest-leverage move and
        //    plan it as a Claude Code session. Grounded + no-fabrication prompt.
        let plan = await planNextMove(signals: signals)

        // 3. Record the run. In SIMULATE / OBSERVE we execute nothing; LIVE
        //    dispatches the planned swarm (the only action mechanism).
        var executed = false
        if mode == .live, let a = plan.action {
            await dispatchSwarm(a)
            executed = true
        } else if mode == .observe, let a = plan.action {
            queueForApproval(a, domain: plan.domain, rationale: plan.rationale)
        }

        let run = GoalPursuitRun(
            mode: mode.rawValue, domain: plan.domain, chosenGoal: plan.chosenGoal,
            rationale: plan.rationale, action: plan.action, executed: executed
        )
        runs.insert(run, at: 0)
        if runs.count > maxRuns { runs = Array(runs.prefix(maxRuns)) }
        save()

        // Cognition Map: record ONE honest decision trace for this cycle.
        // memoriesRetrieved = the real grounded signals the plan was built from
        // (the live-store lines, not invented). gateVerdict reflects what
        // actually happened: "dispatched" when LIVE executed, "queued" when
        // OBSERVE parked it for approval, else nil (SIMULATE / no action).
        // confidence is OMITTED (nil): no planner or ConfidenceGate produced a
        // real confidence score for a goal cycle, so we do NOT stamp a fabricated
        // percentage. The action-vs-no-action result is honest provenance and is
        // already surfaced as the gateVerdict + outcome, not laundered into a
        // confidence number. The Cognition Map shows this row's confidence as
        // "n/a" and excludes it from the avg-confidence rollup.
        CognitionTrace.shared.note(
            kind: .goalCycle,
            trigger: trigger,
            heuristicsFired: [],
            memoriesRetrieved: signals.map { "(\($0.domain)) \($0.line)" },
            gateVerdict: executed ? "dispatched" : ((mode == .observe && plan.action != nil) ? "queued" : nil),
            confidence: nil,
            mode: mode.rawValue,
            outcome: plan.action == nil ? "No action this cycle: \(plan.rationale)" : "Planned: \(plan.action!.title)"
        )

        WakeLog.shared.log("jax goal-pursuit: \(mode.rawValue) -> [\(plan.domain)] \(plan.chosenGoal) | \(plan.action == nil ? "no action" : "planned: \(plan.action!.title)")\(executed ? " (DISPATCHED)" : "")")
        return run
    }

    // MARK: Real-signal gathering (NO fabrication: live stores only)

    private struct Signal { let domain: String; let line: String }

    private func gatherSignals() -> [Signal] {
        var out: [Signal] = []

        // product/code: the real roadmap (in-progress first, then a few queued).
        let items = RoadmapStore.shared.items
        for it in items.filter({ $0.status == .inProgress }) {
            out.append(Signal(domain: "product/code", line: "[in progress] \(it.title)\(it.subtitle.isEmpty ? "" : ": \(it.subtitle)")\(it.notes.isEmpty ? "" : " (notes: \(it.notes))")"))
        }
        for it in items.filter({ $0.status == .notStarted }).prefix(5) {
            out.append(Signal(domain: "product/code", line: "[queued] \(it.title)\(it.subtitle.isEmpty ? "" : ": \(it.subtitle)")"))
        }

        // comms: real unread mail count (the second-brain domain).
        let unread = MailStore.shared.messages.filter { $0.isUnread }.count
        if unread > 0 {
            out.append(Signal(domain: "comms", line: "\(unread) unread email\(unread == 1 ? "" : "s") in the inbox that may need a reply"))
        }

        // ops: pending approvals already queued (real), if any.
        let pending = ApprovalQueue.shared.pendingCount
        if pending > 0 {
            out.append(Signal(domain: "ops", line: "\(pending) item\(pending == 1 ? "" : "s") already waiting in the Jax HQ approval queue"))
        }

        return out
    }

    // MARK: Plan the next move (model, grounded)

    private struct Plan { let domain: String; let chosenGoal: String; let rationale: String; let action: PlannedSwarmAction? }

    private func planNextMove(signals: [Signal]) async -> Plan {
        let signalBlock = signals.map { "- (\($0.domain)) \($0.line)" }.joined(separator: "\n")

        // Deterministic fallback (no API key): pick the first real in-progress
        // item and plan a single-worker advance. Still no fabrication: it only
        // names a real goal.
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user got the
        // deterministic pick every single cycle and never saw the planner run.
        // Resolved ONCE per cycle, before the prompt, never inside the fan-out.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            if let first = signals.first {
                return Plan(domain: first.domain, chosenGoal: first.line,
                            rationale: "Offline pick: advance the top real item on the board.",
                            action: PlannedSwarmAction(title: "Advance: \(first.line.prefix(50))",
                                                       goal: "Advance this goal one concrete step, then stop and report: \(first.line)",
                                                       template: "singleWorker", budgetUSD: 5))
            }
            return Plan(domain: "none", chosenGoal: "nothing actionable", rationale: "No real goals available.", action: nil)
        }

        let sys = """
        \(JaxProfile.shared.persona)

        RIGHT NOW you are running an autonomous GOAL-PURSUIT cycle as the user's second mind. You are deciding the single highest-leverage next move that advances their real goals, and planning it as a Claude Code terminal session (a swarm job), which is the ONLY way you are allowed to act.

        HARD RULES:
        - Use ONLY the real signals listed below. Do NOT invent goals, progress, facts, numbers, or results. If the signals do not justify an action, say so.
        - You are PLANNING, not reporting. Never claim anything is done.
        - The action, if any, is a Claude Code worker instruction: specific, scoped to one session, concretely advancing ONE real goal one step.
        - DO NOT REPEAT YOURSELF. The RECENT MOVES list shows what you already proposed in prior cycles. Treat those as already in flight. If the same goal is still the priority, propose the genuinely NEXT concrete step that builds ON the prior step (step 2, step 3), never the same step again. When a goal has had a few cycles of attention, or another domain is piling up (unread mail, a stale queue item), ROTATE to that instead. Across cycles you should show a sensible PROGRESSION and spread, not the same move every night.

        Return STRICT JSON, nothing else:
        {"domain":"product/code|comms|ops","chosenGoal":"<verbatim real goal you are advancing>","rationale":"<one line, your voice, why this is the move AND how it differs from the recent moves>","action":{"title":"<short>","goal":"<the exact instruction for the Claude Code worker>","template":"singleWorker|architectImplement|parallelTrio","budgetUSD":<number>} }
        If nothing is worth doing this cycle, return {"domain":"none","chosenGoal":"nothing actionable now","rationale":"<why>","action":null}.
        """
        let recentBlock: String = {
            let recent = runs.prefix(6)
            guard !recent.isEmpty else { return "RECENT MOVES: none yet, this is the first cycle." }
            let lines = recent.map { r -> String in
                "- [\(r.domain)] \(r.chosenGoal.prefix(60)) | proposed: \(r.action?.title ?? "no action")"
            }.joined(separator: "\n")
            return "RECENT MOVES you already proposed (do NOT repeat, advance or rotate past these):\n\(lines)"
        }()
        let user = "REAL SIGNALS (the only things you may act on):\n\(signalBlock)\n\n\(recentBlock)\n\nPick the one highest-leverage NEXT move that does not repeat a recent move, and return the JSON."

        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey, model: routing.modelId,
                system: sys, messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 600, temperature: 0.55,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete", feature: "jaxGoalPursuit"
            )
            if let p = Self.parsePlan(reply) {
                // POST grounding: the plan text (rationale + chosen goal + action) must not
                // assert a product price/size/SKU that contradicts the catalog. If it does,
                // drop the model plan and fall through to the deterministic real-signal pick
                // (which only names a verbatim real signal, never a fabricated number).
                let planText = "\(p.chosenGoal) \(p.rationale) \(p.action?.title ?? "") \(p.action?.goal ?? "")"
                let verdict = GroundingGate.vet(draft: planText, brief: signalBlock)
                if verdict.surfaceable {
                    return p
                } else {
                    WakeLog.shared.log("jax goal-pursuit: blocked ungrounded fact in plan, using deterministic pick. \(verdict.refusalLine)")
                }
            }
        } catch {
            WakeLog.shared.log("jax goal-pursuit: plan model call failed (\(error.localizedDescription)); using fallback")
        }
        // Fallback to the deterministic real pick on any parse/model failure.
        if let first = signals.first {
            return Plan(domain: first.domain, chosenGoal: first.line,
                        rationale: "Fallback pick after a model hiccup: advance the top real item.",
                        action: PlannedSwarmAction(title: "Advance: \(first.line.prefix(50))",
                                                   goal: "Advance this goal one concrete step, then stop and report: \(first.line)",
                                                   template: "singleWorker", budgetUSD: 5))
        }
        return Plan(domain: "none", chosenGoal: "nothing actionable", rationale: "No real goals available.", action: nil)
    }

    private nonisolated static func parsePlan(_ reply: String) -> Plan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let domain = (obj["domain"] as? String) ?? "product/code"
        let chosen = (obj["chosenGoal"] as? String) ?? ""
        let rationale = (obj["rationale"] as? String) ?? ""
        var action: PlannedSwarmAction? = nil
        if let a = obj["action"] as? [String: Any],
           let title = a["title"] as? String, let goal = a["goal"] as? String, !goal.isEmpty {
            let tmpl = (a["template"] as? String) ?? "singleWorker"
            let budgetRaw = (a["budgetUSD"] as? Double) ?? Double((a["budgetUSD"] as? Int) ?? 5)
            // Floor the budget: a model-returned 0 would make a LIVE swarm dispatch
            // a no-op / failure. SIMULATE does not execute, but the same plan is
            // what LIVE would run, so keep it sane.
            let budget = budgetRaw > 0 ? budgetRaw : 5
            action = PlannedSwarmAction(title: title, goal: goal, template: tmpl, budgetUSD: budget)
        }
        guard !chosen.isEmpty else { return nil }
        return Plan(domain: domain, chosenGoal: chosen, rationale: rationale, action: action)
    }

    // MARK: Mode-specific effects (only reached in OBSERVE / LIVE)

    private func queueForApproval(_ a: PlannedSwarmAction, domain: String, rationale: String) {
        let action = ProposedAction(
            kind: .other,
            summary: "Run a Claude Code session: \(a.title)",
            target: "claude-code-swarm",
            detail: ["goal": a.goal, "template": a.template, "domain": domain, "rationale": rationale]
        )
        // Route through the gate so even an OBSERVE-queued action obeys the
        // guardrails; queue it for the user's one-tap yes.
        ApprovalQueue.shared.enqueue(action, urgent: false, reason: "\(UserIdentity.assistantName) goal-pursuit (\(domain)): \(rationale)")
    }

    private func dispatchSwarm(_ a: PlannedSwarmAction) async {
        let template = SwarmTemplate(rawValue: a.template) ?? .singleWorker
        let slug = a.title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        let root = NSHomeDirectory() + "/Documents/Grux/swarms/jax-\(slug.isEmpty ? "goal" : slug)-\(String(UUID().uuidString.prefix(8)).lowercased())"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = await AgentService.shared.startSwarm(
            title: a.title, goal: a.goal, template: template, rootDir: root,
            budgetUSD: a.budgetUSD, maxParallelWorkers: 3
        )
    }

    // MARK: Persistence

    private func load() {
        runs = Persistence.load([GoalPursuitRun].self, from: storeURL, fallback: [])
    }
    private func save() {
        Persistence.save(runs, to: storeURL)
    }
}
