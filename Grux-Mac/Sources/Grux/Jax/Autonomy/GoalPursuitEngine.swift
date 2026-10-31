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
        let dir = Persistence.gruxDir.appendingPathComponent("jax")
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
        let dir = Persistence.gruxDir.appendingPathComponent("jax")
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
        //    dispatches the planned swarm (the only action mechanism), unless
        //    the worth judgment holds it, which queues it exactly as OBSERVE
        //    would (P-R-6, `agent.worthStarting`). A hold never starts anything.
        var executed = false
        var held = false
        if mode == .live, let a = plan.action {
            let heldRationale = Self.heldPrefix + plan.rationale
            let verdict = await AgentWorthJudgment.judge(
                state: AgentWorthJudgment.state(
                    title: a.title, goal: a.goal, budgetUSD: a.budgetUSD, rationale: plan.rationale,
                    signals: signals.map { "(\($0.domain)) \($0.line)" },
                    running: AgentService.shared.jobs.filter { !$0.isTerminal }.map {
                        AgentWorthJudgment.runningLine(title: $0.title, startedAt: $0.startedAt ?? $0.createdAt)
                    }),
                heldItem: Self.approvalItem(a, domain: plan.domain, rationale: heldRationale),
                engine: DecisionEngine.shared,
                threshold: AppState.shared.config.listeningThreshold)
            if verdict.hold {
                queueForApproval(a, domain: plan.domain, rationale: heldRationale, risk: verdict.risk)
                held = true
            } else {
                await dispatchSwarm(a)
                executed = true
            }
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
            gateVerdict: executed ? "dispatched" : (((mode == .observe || held) && plan.action != nil) ? "queued" : nil),
            confidence: nil,
            mode: mode.rawValue,
            outcome: plan.action == nil ? "No action this cycle: \(plan.rationale)" : "Planned: \(plan.action!.title)"
        )

        WakeLog.shared.log("jax goal-pursuit: \(mode.rawValue) -> [\(plan.domain)] \(plan.chosenGoal) | \(plan.action == nil ? "no action" : "planned: \(plan.action!.title)")\(executed ? " (DISPATCHED)" : "")\(held ? " (HELD for approval)" : "")")
        return run
    }

    // MARK: Real-signal gathering (NO fabrication: live stores only)

    struct Signal: Equatable {
        let domain: String
        let line: String
        /// What waits for the person's own answer (the approval queue): a
        /// worker may never be planned against it (D77).
        var answeredByPerson = false

        /// The approval queue as a signal, the one `gatherSignals` reads.
        static func approvalQueue(pending: Int) -> Signal {
            Signal(domain: "ops", line: "\(pending) item\(pending == 1 ? "" : "s") already waiting in the Jax HQ approval queue",
                   answeredByPerson: true)
        }
    }

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
            out.append(.approvalQueue(pending: pending))
        }

        return out
    }

    // MARK: Plan the next move (model, grounded)

    struct Plan: Equatable {
        let domain: String
        let chosenGoal: String
        let rationale: String
        let action: PlannedSwarmAction?
        /// The 1-based number of the real signal the model said it advances, when it gave one.
        var signalNumber: Int? = nil
    }

    /// A model plan held to the real signals: the goal it advances is one of
    /// them, word for word, and it names no command, id, flag or item that no
    /// signal names. `.failure` carries the plain reason it was refused.
    /// D73: the planner once filled a card with `run_approval_runner
    /// --queue-id=hq-01 --item-ids=item-8492,...` and "2 items currently
    /// stuck"; the catalog check below never looks at commands or ids.
    nonisolated static func grounded(_ p: Plan, signals: [Signal]) -> Result<Plan, PlanRefusal> {
        var plan = p
        // A plan that starts nothing advances no signal, whatever domain it
        // names (wave 18 review: "nothing actionable now" under "ops"), and
        // its card headline is the fixed line, never the model's words.
        if p.action == nil {
            plan = Plan(domain: "none", chosenGoal: noActionGoal, rationale: p.rationale, action: nil)
        } else {
            let verbatim = signals.firstIndex(where: { sameWords($0.line, p.chosenGoal) })
            let signal: Signal
            if let n = p.signalNumber, n >= 1, n <= signals.count {
                // A number and a word-for-word goal naming different signals:
                // the model does not know what it advances.
                if verbatim != nil, !sameWords(signals[n - 1].line, p.chosenGoal) {
                    return .failure(PlanRefusal(reason: "its signal number and its goal name different signals"))
                }
                signal = signals[n - 1]
            } else if let v = verbatim {
                signal = signals[v]
            } else {
                return .failure(PlanRefusal(reason: "the goal it chose is not one of the real signals"))
            }
            plan = Plan(domain: signal.domain, chosenGoal: signal.line, rationale: p.rationale,
                        action: p.action, signalNumber: p.signalNumber)
        }
        let known = Set(signals.flatMap { words($0.line) })
        // What waits, by kind, from the two signals Grux counts itself (the
        // approval queue and unread mail); a roadmap line's words count nothing.
        var waiting: [String: Double] = [:]
        for s in signals where s.domain == "ops" || s.domain == "comms" {
            for c in counts(in: words(s.line)) { waiting[c.kind] = max(waiting[c.kind] ?? 0, c.number) }
        }
        var invented: [String] = []
        for text in [plan.rationale, plan.action?.title ?? "", plan.action?.goal ?? ""] {
            let said = words(text)
            for w in said where !known.contains(w) && !invented.contains(w) {
                if looksLikeAnIdentifier(w) || looksLikeAFile(w) { invented.append(w) }
            }
            // A plan may take on part of what waits ("the top 3 emails"); a
            // count above it is made up ("2 stuck" while 1 waits).
            for c in counts(in: said) where c.number > (waiting[c.kind] ?? 0) {
                let shown = "\(c.number.formatted()) \(c.kind)"
                if !invented.contains(shown) { invented.append(shown) }
            }
            if let path = rawPath(in: text), !invented.contains(path) { invented.append(path) }
        }
        guard invented.isEmpty else {
            return .failure(PlanRefusal(reason: "it names \(invented.joined(separator: ", ")), which no signal names"))
        }
        return .success(plan)
    }

    /// Lowercased words, split at spaces and commas, outer punctuation trimmed,
    /// so `v3.2:` and `v3.2.` are the word `v3.2`.
    nonisolated static func words(_ text: String) -> [String] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "-_=$"))
        return text.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }

    /// A command, flag, key=value, snake_case name or letters-with-digits id
    /// (`hq-01`, `Q4`); a plain number or a dollar amount is not one.
    nonisolated static func looksLikeAnIdentifier(_ w: String) -> Bool {
        if w.hasPrefix("--") || w.contains("_") || w.contains("=") { return true }
        // A number joined to a word shapes the work: "2-step", "3-sentence".
        let halves = w.split(separator: "-", maxSplits: 1)
        if halves.count == 2, halves[0].allSatisfy(\.isNumber), halves[1].allSatisfy(\.isLetter) { return false }
        // A time or an ordinal: "5pm", "10am", "2nd", "24h".
        let digits = w.prefix(while: \.isNumber)
        if !digits.isEmpty, ["am", "pm", "st", "nd", "rd", "th", "h"].contains(String(w.dropFirst(digits.count))) { return false }
        return w.rangeOfCharacter(from: .decimalDigits) != nil && w.rangeOfCharacter(from: .letters) != nil
    }

    /// A count of one kind of thing a signal counts: queue items or mail.
    /// "3 approvals are stuck" is (3, queue); "5 bullet points" and "3
    /// tasks" count nothing a signal counts.
    struct Count: Hashable { let number: Double; let kind: String }

    nonisolated static let countedKinds: [String: String] = [
        "item": "queue", "items": "queue", "approval": "queue", "approvals": "queue",
        "request": "queue", "requests": "queue",
        "email": "mail", "emails": "mail", "mail": "mail", "mails": "mail", "message": "mail",
        "messages": "mail", "reply": "mail", "replies": "mail", "thread": "mail", "threads": "mail",
    ]

    nonisolated static let numberWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// Every number followed by a counted kind, directly or after one word
    /// ("3 stuck approvals", "4 unread emails").
    nonisolated static func counts(in said: [String]) -> [Count] {
        var out: [Count] = []
        for (i, w) in said.enumerated() {
            guard let n = numberWords[w] ?? (w.first?.isNumber == true ? Double(w) : nil) else { continue }
            for k in [i + 1, i + 2] where k < said.count {
                if let kind = countedKinds[said[k]] { out.append(Count(number: n, kind: kind)); break }
            }
        }
        return out
    }

    /// A path written from the root or home (`/etc/hosts`, `~/.grux`), read
    /// from the raw text because `words` trims the leading mark.
    nonisolated static func rawPath(in text: String) -> String? {
        for token in text.components(separatedBy: .whitespacesAndNewlines) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`([{,;:"))
            if (t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./")) && t.count > 2,
               t.dropFirst().contains(where: \.isLetter) {
                return t.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}'\""))
            }
        }
        return nil
    }

    /// A path or a file name: `scripts/approve.sh`, `src/queue/runner`,
    /// `readme.md`. "and/or" and "e.g" are not.
    nonisolated static func looksLikeAFile(_ w: String) -> Bool {
        let parts = w.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 3 { return true }
        // Two words joined by a slash are a path unless both are short plain
        // words ("and/or", "on/off", "read/write").
        // Two plain words ("approve/reject") or two numbers ("24/7") are not
        // a path; a known folder name or anything else is.
        if parts.count == 2 {
            if parts.contains(where: { ["scripts", "src", "bin", "lib", "tests", "docs", "sources"].contains(String($0)) }) {
                return true
            }
            if parts.allSatisfy({ $0.allSatisfy(\.isLetter) }) || parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return false
            }
            return true
        }
        guard let last = parts.last else { return false }
        // A stem and an extension of two to seven letters: `x.sh`,
        // `backup.tar.gz`, `data.sqlite`. "e.g" and "i.e" have one.
        let pieces = last.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 2, pieces.allSatisfy({ !$0.isEmpty }), let ext = pieces.last else { return false }
        return (2...7).contains(ext.count) && ext.allSatisfy(\.isLetter)
    }

    /// approve, approval, approvals, approving, approved, pre-approve.
    nonisolated static func namesApprovals(_ text: String) -> Bool {
        words(text).contains { $0.contains("approv") }
    }

    /// The words that name the person's queue: approv..., queue..., and the
    /// pane's own name, HQ (wave 19 P3 item 2). Words here are letter runs,
    /// every other character a break, so "Jax-HQ", "HQ's", "HQ\u{2014}then",
    /// "jax_hq" and "queue's" read as "hq" and "queue"; "JaxHQ" and "HQs"
    /// hold "hq" (wave 23 review).
    nonisolated static func queueWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.contains("approv") || $0.contains("queue") || $0.contains("hq") })
    }

    /// A worker reaches into the queue when it uses a queue word the signal
    /// it advances does not: "Build the approvals inbox" may say "approvals",
    /// but not "approve" or "queue" (wave 19 P3 item 3). Grux's own status
    /// tag on a roadmap line ("[queued] ...") is not the item's words, or
    /// every queued item would lend its worker "queued" (wave 23 review): it
    /// is dropped from the signal, and from the worker only where the worker
    /// quotes the signal ("[queued] Ship ..."), so a worker's own "[queued]
    /// items" still counts.
    nonisolated static func reachesIntoTheQueue(_ worker: String, signal: String) -> Bool {
        var item = signal, quoted = worker
        for tag in ["[queued]", "[in progress]"] where signal.hasPrefix(tag) {
            item = String(signal.dropFirst(tag.count))
            let head = String(item.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace }))
            guard !head.isEmpty else { continue }
            // Any case, a colon or a dash, any spacing: "[Queued]: Ship", "[queued] - Ship".
            let pattern = NSRegularExpression.escapedPattern(for: tag) + #"[\s:\-\x{2013}\x{2014}]*(?="#
                + NSRegularExpression.escapedPattern(for: head) + ")"
            quoted = quoted.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return !queueWords(quoted).isSubset(of: queueWords(item))
    }

    private nonisolated static func sameWords(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        return !wa.isEmpty && wa == wb
    }

    struct PlanRefusal: Error, Equatable { let reason: String }

    /// What a card says when the model's plan was refused. It never repeats
    /// what the plan made up; wake.log carries the names.
    /// The headline of a cycle that starts nothing.
    nonisolated static let noActionGoal = "nothing actionable now"

    /// What a card says when the model found nothing worth doing and its
    /// reason named something no signal names.
    static let declinedRationale = "The model found nothing worth starting this cycle."

    /// What a cycle on the approval queue says: the person answers it, so
    /// the move is to ask them and nothing starts (D77).
    static let yoursToAnswerRationale = "What waits in Approvals is yours to answer, not a worker's. Answer it there when you have a minute."

    /// What a card says when the plan's worker also spoke of Approvals: the
    /// same item advances, worded from the item alone.
    static let approvalWordsSetAsideRationale = "The model's plan also reached into Approvals, which are yours, so this advances the same item without it."

    static let setAsideRationale = "The model's plan did not stick to the real signals, so this advances the top real item instead."

    private func planNextMove(signals: [Signal]) async -> Plan {
        let signalBlock = signals.enumerated().map { "\($0.offset + 1). (\($0.element.domain)) \($0.element.line)" }.joined(separator: "\n")

        // Deterministic fallback (no API key): pick the first real in-progress
        // item and plan a single-worker advance. Still no fabrication: it only
        // names a real goal.
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user got the
        // deterministic pick every single cycle and never saw the planner run.
        // Resolved ONCE per cycle, before the prompt, never inside the fan-out.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            return Self.deterministicPick(signals, rationale: "Offline pick: advance the top real item on the board.")
        }

        let sys = """
        \(JaxProfile.shared.persona)

        RIGHT NOW you are running an autonomous GOAL-PURSUIT cycle as the user's second mind. You are deciding the single highest-leverage next move that advances their real goals, and planning it as a Claude Code terminal session (a swarm job), which is the ONLY way you are allowed to act.

        HARD RULES:
        - Use ONLY the real signals listed below. Do NOT invent goals, progress, facts, numbers, or results. If the signals do not justify an action, say so.
        - Never name a command, script, flag, file, queue id or item id that the signals do not name. Describe the step in plain words; the worker finds the real names itself. A plan that names one is thrown away.
        - You are PLANNING, not reporting. Never claim anything is done.
        - Items waiting in the approval queue are the user's to approve or refuse. A worker can never answer them, so never plan one for that signal, and never mention approvals or the queue in a worker's title or goal: a plan whose worker does is set aside.
        - The action, if any, is a Claude Code worker instruction: specific, scoped to one session, concretely advancing ONE real goal one step.
        - DO NOT REPEAT YOURSELF. The RECENT MOVES list shows what you already proposed in prior cycles. Treat those as already in flight. If the same goal is still the priority, propose the genuinely NEXT concrete step that builds ON the prior step (step 2, step 3), never the same step again. When a goal has had a few cycles of attention, or another domain is piling up (unread mail, a stale queue item), ROTATE to that instead. Across cycles you should show a sensible PROGRESSION and spread, not the same move every night.

        Return STRICT JSON, nothing else:
        {"signal":<the number of the real signal you are advancing>,"domain":"product/code|comms|ops","chosenGoal":"<that signal, verbatim>","rationale":"<one line, your voice, why this is the move AND how it differs from the recent moves>","action":{"title":"<short>","goal":"<the exact instruction for the Claude Code worker>","template":"singleWorker|architectImplement|parallelTrio","budgetUSD":<number>} }
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
            if let parsed = Self.parsePlan(reply) {
                return Self.settle(parsed, signals: signals, signalBlock: signalBlock)
            }
        } catch {
            WakeLog.shared.log("jax goal-pursuit: plan model call failed (\(error.localizedDescription)); using fallback")
        }
        // Fallback to the deterministic real pick on any parse/model failure.
        return Self.deterministicPick(signals, rationale: "Fallback pick after a model hiccup: advance the top real item.")
    }

    /// The plan a cycle keeps from a parsed model reply: grounded in the real
    /// signals and the catalog, or the deterministic pick in its place.
    static func settle(_ parsed: Plan, signals: [Signal], signalBlock: String) -> Plan {
        let p: Plan
        switch grounded(parsed, signals: signals) {
        case .success(let g):
            // What waits for the person's answer never takes a worker, whatever
            // the model planned for it (D77).
            if g.action != nil, let mine = signals.first(where: { $0.answeredByPerson && $0.line == g.chosenGoal }) {
                WakeLog.shared.log("jax goal-pursuit: plan on the approval queue, asking the person instead of starting a worker")
                return askThePerson(mine)
            }
            // Nor does a worker tagged to another signal and told to work the
            // queue: it may use a queue word only when the signal it advances
            // uses that same word (wave 19 review and P3 items 2, 3). The plan
            // keeps its own signal and only its worker's words go: the plain
            // step names nothing the signal does not, so a correct plan that
            // copied "do not touch the approval queue" still advances what it
            // chose (wave 19 P3).
            if let action = g.action, signals.contains(where: \.answeredByPerson),
               reachesIntoTheQueue("\(action.title) \(action.goal)", signal: g.chosenGoal) {
                guard let own = signals.first(where: { !$0.answeredByPerson && $0.line == g.chosenGoal }) else {
                    WakeLog.shared.log("jax goal-pursuit: a worker on another signal spoke of the approval queue; using deterministic pick")
                    return deterministicPick(signals, rationale: setAsideRationale)
                }
                WakeLog.shared.log("jax goal-pursuit: a worker on another signal spoke of the approval queue; advancing its own signal in plain words")
                return advance(own, rationale: approvalWordsSetAsideRationale)
            }
            p = g
        case .failure(let refusal):
            // A refused plan that started nothing stays a plan that starts
            // nothing: the pick in its place would start the worker the
            // model declined (wave 18 review).
            if parsed.action == nil {
                WakeLog.shared.log("jax goal-pursuit: no-action plan refused, \(refusal.reason); starting nothing")
                return Plan(domain: "none", chosenGoal: noActionGoal, rationale: declinedRationale, action: nil)
            }
            WakeLog.shared.log("jax goal-pursuit: plan refused, \(refusal.reason); using deterministic pick")
            return deterministicPick(signals, rationale: setAsideRationale)
        }
        // POST grounding: the plan text (rationale + chosen goal + action) must not
        // assert a product price/size/SKU that contradicts the catalog. If it does,
        // drop the model plan and fall through to the deterministic real-signal pick
        // (which only names a verbatim real signal, never a fabricated number).
        let planText = "\(p.chosenGoal) \(p.rationale) \(p.action?.title ?? "") \(p.action?.goal ?? "")"
        let verdict = GroundingGate.vet(draft: planText, brief: signalBlock)
        if verdict.surfaceable { return p }
        if p.action == nil {
            WakeLog.shared.log("jax goal-pursuit: blocked ungrounded fact in a no-action plan, starting nothing. \(verdict.refusalLine)")
            return Plan(domain: "none", chosenGoal: noActionGoal, rationale: declinedRationale, action: nil)
        }
        WakeLog.shared.log("jax goal-pursuit: blocked ungrounded fact in plan, using deterministic pick. \(verdict.refusalLine)")
        return deterministicPick(signals, rationale: "Fallback pick after a model hiccup: advance the top real item.")
    }

    /// The pick that needs no model: the first real signal, quoted, advanced
    /// one step. It names nothing the signal does not.
    /// Never the approval queue, which is the person's to answer (D77): with
    /// only that, the move is to ask them.
    private static func deterministicPick(_ signals: [Signal], rationale: String) -> Plan {
        guard let first = signals.first(where: { !$0.answeredByPerson }) else {
            if let mine = signals.first { return askThePerson(mine) }
            return Plan(domain: "none", chosenGoal: "nothing actionable", rationale: "No real goals available.", action: nil)
        }
        return advance(first, rationale: rationale)
    }

    /// One plain step on `signal`, worded only from the signal itself.
    private static func advance(_ signal: Signal, rationale: String) -> Plan {
        Plan(domain: signal.domain, chosenGoal: signal.line, rationale: rationale,
             action: PlannedSwarmAction(title: "Advance: \(signal.line.prefix(50))",
                                        goal: "Advance this goal one concrete step, then stop and report: \(signal.line)",
                                        template: "singleWorker", budgetUSD: 5))
    }

    /// A cycle on what waits for the person: headlined on that signal, it
    /// starts nothing and says where they answer it.
    private static func askThePerson(_ signal: Signal) -> Plan {
        Plan(domain: signal.domain, chosenGoal: signal.line, rationale: yoursToAnswerRationale, action: nil)
    }

    nonisolated static func parsePlan(_ reply: String) -> Plan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let domain = (obj["domain"] as? String) ?? "product/code"
        let chosen = (obj["chosenGoal"] as? String) ?? ""
        let rationale = (obj["rationale"] as? String) ?? ""
        var action: PlannedSwarmAction? = nil
        if let a = obj["action"] as? [String: Any],
           let title = a["title"] as? String, let goal = a["goal"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tmpl = (a["template"] as? String) ?? "singleWorker"
            let budgetRaw = (a["budgetUSD"] as? Double) ?? Double((a["budgetUSD"] as? Int) ?? 5)
            // Floor the budget: a model-returned 0 would make a LIVE swarm dispatch
            // a no-op / failure. SIMULATE does not execute, but the same plan is
            // what LIVE would run, so keep it sane.
            let budget = budgetRaw > 0 ? budgetRaw : 5
            action = PlannedSwarmAction(title: title, goal: goal, template: tmpl, budgetUSD: budget)
        }
        // A decline with no goal is still a decline (W18-P3): it used to fail
        // the parse, and the fallback started the worker the model declined.
        // Any spelling with no usable action ("none", false, {}, an empty
        // title or goal) declines too (W19-P3 item 4): reading it as no plan
        // pays for the worker the model turned down.
        if chosen.isEmpty, action == nil {
            return Plan(domain: domain, chosenGoal: noActionGoal, rationale: rationale, action: nil)
        }
        guard !chosen.isEmpty else { return nil }
        let number = (obj["signal"] as? Int) ?? (obj["signal"] as? Double).flatMap { Int(exactly: $0) }
        return Plan(domain: domain, chosenGoal: chosen, rationale: rationale, action: action, signalNumber: number)
    }

    // MARK: Mode-specific effects (only reached in OBSERVE / LIVE)

    /// What a held LIVE plan's rationale opens with, so the card says why a
    /// plan that would have run is waiting instead.
    static let heldPrefix = "Held before starting: judged not worth running unattended. "

    /// The approval item a plan becomes: what OBSERVE queues, and what LIVE
    /// queues when the worth judgment holds it.
    static func approvalItem(_ a: PlannedSwarmAction, domain: String, rationale: String) -> PendingApproval {
        PendingApproval(
            action: ProposedAction(
                kind: .other,
                summary: "Run a Claude Code session: \(a.title)",
                target: "claude-code-swarm",
                detail: ["goal": a.goal, "template": a.template, "domain": domain, "rationale": rationale]
            ),
            urgent: false,
            reason: "\(UserIdentity.assistantName) goal-pursuit (\(domain)): \(rationale)"
        )
    }

    private func queueForApproval(_ a: PlannedSwarmAction, domain: String, rationale: String,
                                  risk: ApprovalRisk? = nil) {
        // Route through the gate so even an OBSERVE-queued action obeys the
        // guardrails; queue it for the user's one-tap yes. A held LIVE plan
        // carries the risk its event already asked, so queueing it does not
        // pay for a second call.
        var item = Self.approvalItem(a, domain: domain, rationale: rationale)
        item.risk = risk
        ApprovalQueue.shared.enqueue(item)
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
