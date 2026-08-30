import Foundation
import GruxAgentCore

// MARK: - RDWorker (Phase B core, blueprint sections 01 + 04)
//
// The Foundry's Claude Code execution rail. Generalizes the ship-ios-app
// terminal automation into a worker that takes one UpgradeProposal and:
//
//   1. composePrompt(_:)  : builds the context-packed prompt: evidence,
//      exact file paths, the conventions block, and ordered verify
//      steps. Pure and deterministic so tests snapshot it.
//   2. execute(_:)        : creates a git worktree upgrade/<slug> from the
//      current branch, drives a real `claude --print` session against it
//      on the proven SwarmWorker rail (stream-json parse, idle TTL stuck
//      watchdog, LimitSignal monthly-limit detection), and folds every
//      stream event into an RDRunLog (NDJSON, same shape as AgentStore).
//      Follow-up prompts re-enter the same worktree via followUp(_:handle:).
//   3. escalate(_:)       : effort M+ proposals hand off to the existing
//      SwarmOrchestrator through AgentService with an architectImplement
//      plan built from the composed prompt, rooted in the same worktree.
//
// Worktree lifecycle: complete(_:) removes the worktree and KEEPS the
// upgrade/ branch (Phase C landing machinery consumes it); abandon(_:)
// removes the worktree AND deletes the branch.
//
// Execution mode: `.headless` is the implemented rail (SwarmWorker /
// claude --print). `.interactive` is a RESERVED fallback flag for the
// TerminalFocus rail; selecting it today logs the reservation and runs
// headless. No new dependencies, no shared-file edits: shell access rides
// the existing ShellRunner seam, claude sessions ride GruxAgentCore.

// MARK: - Effort sizing

// T-shirt size for a proposal. S runs on the single headless session;
// M and L escalate to the swarm (blueprint: "Swarm patterns for anything
// sized M or larger").
enum RDEffort: Int, Codable, Comparable, Sendable {
    case s = 0
    case m = 1
    case l = 2

    static func < (lhs: RDEffort, rhs: RDEffort) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .s: return "S"
        case .m: return "M"
        case .l: return "L"
        }
    }

    // Deterministic heuristic over the proposal's blast radius. Risk class
    // and pinned-path count dominate; very long ready prompts nudge up one
    // notch because they encode multi-file work.
    static func estimate(for proposal: UpgradeProposal) -> RDEffort {
        var score = 0
        switch proposal.riskClass {
        case .low: break
        case .medium: score += 1
        case .high, .protected: score += 2
        }
        if proposal.touchedPaths.count >= 6 {
            score += 2
        } else if proposal.touchedPaths.count >= 3 {
            score += 1
        }
        if proposal.readyPrompt.count > 2400 { score += 1 }
        if score >= 3 { return .l }
        if score >= 1 { return .m }
        return .s
    }
}

// MARK: - Worktree naming + git commands

// Pure path/slug/command builders so tests verify the worktree logic
// without ever touching git. Worktrees live in a `.worktrees/` directory
// SIBLING to the repo root (same convention as the grux-roadmap worktree),
// so `git status` inside the repo never sees them.
enum RDWorktree {

    // Kebab slug from the proposal title plus a 6-char id suffix so two
    // proposals with the same title never collide.
    static func slug(for proposal: UpgradeProposal) -> String {
        var out = ""
        var lastWasHyphen = true  // suppress leading hyphen
        for ch in proposal.title.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 {
            out = String(out.prefix(40))
            while out.hasSuffix("-") { out.removeLast() }
        }
        if out.isEmpty { out = "upgrade" }
        let suffix = proposal.id.uuidString.prefix(6).lowercased()
        return "\(out)-\(suffix)"
    }

    static func branchName(slug: String) -> String {
        "upgrade/\(slug)"
    }

    static func worktreeURL(repoRoot: URL, slug: String) -> URL {
        repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".worktrees", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    // Single-quote shell escaping: ' → '\''
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Creates the branch from the CURRENT branch (HEAD) and checks it out
    // into the worktree directory in one move.
    static func addCommand(repoRoot: String, branch: String, worktreePath: String) -> String {
        let parent = (worktreePath as NSString).deletingLastPathComponent
        return "mkdir -p \(shellQuote(parent)) && git -C \(shellQuote(repoRoot)) worktree add -b \(shellQuote(branch)) \(shellQuote(worktreePath)) HEAD"
    }

    // Removes the worktree directory; the branch survives (landing keeps it).
    static func removeCommand(repoRoot: String, worktreePath: String) -> String {
        "git -C \(shellQuote(repoRoot)) worktree remove --force \(shellQuote(worktreePath)) ; git -C \(shellQuote(repoRoot)) worktree prune"
    }

    static func deleteBranchCommand(repoRoot: String, branch: String) -> String {
        "git -C \(shellQuote(repoRoot)) branch -D \(shellQuote(branch))"
    }
}

// MARK: - Run log (NDJSON, AgentStore-shaped)

// One progress line per interesting event. Persisted append-only as NDJSON
// at <foundry>/runs/<runId>/log.ndjson, exactly the AgentStore convention,
// so existing log tooling reads both.
struct RDRunEvent: Codable, Sendable, Identifiable, Equatable {
    enum Kind: String, Codable, Sendable {
        case runStart
        case worktreeCreated
        case promptComposed
        case assistantText
        case toolUse
        case toolResult
        case usage
        case limitDetected   // LimitSignal fired: monthly usage limit
        case stuckDetected   // idle/wall TTL watchdog terminated the session
        case followUp
        case escalated       // handed to SwarmOrchestrator
        case runEnd
        case cleanup
        case error
        case info
    }

    var id: String = UUID().uuidString
    var ts: Date = Date()
    var kind: Kind
    var text: String
    var costUSD: Double?

    init(id: String = UUID().uuidString, ts: Date = Date(), kind: Kind, text: String, costUSD: Double? = nil) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.text = text
        self.costUSD = costUSD
    }
}

actor RDRunLog {

    let runDir: URL
    private let logURL: URL
    private let decoder: JSONDecoder

    init(runDir: URL) {
        self.runDir = runDir
        self.logURL = runDir.appendingPathComponent("log.ndjson")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    func append(_ event: RDRunEvent) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let compact = try? enc.encode(event) else { return }
        var line = compact
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: line)
                return
            }
        }
        try? line.write(to: logURL, options: .atomic)
    }

    func load(limit: Int? = nil) -> [RDRunEvent] {
        guard let raw = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        var events: [RDRunEvent] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let ev = try? decoder.decode(RDRunEvent.self, from: data)
            else { continue }
            events.append(ev)
        }
        if let n = limit, events.count > n {
            return Array(events.suffix(n))
        }
        return events
    }

    // Forensics copy of the exact prompt that drove the session.
    func writePrompt(_ text: String, name: String = "prompt.md") {
        let url = runDir.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

// MARK: - Stream-event fold

// Folds raw `claude --print --output-format stream-json` lines into a
// summary state + RDRunEvents. Pure, so tests drive it with mock CLI
// output fixtures and never spawn a real claude. Rides the EXISTING
// detectors: StreamJSONParser for shape, LimitSignal for the monthly
// usage limit markers.
struct RDFoldState: Equatable, Sendable {
    var assistantTexts: [String] = []
    var toolUseCount: Int = 0
    var toolResultCount: Int = 0
    var costUSD: Double = 0
    var finalText: String?
    var finalSuccess: Bool?
    var limitDetected: Bool = false

    var lastAssistantText: String? { assistantTexts.last }
}

enum RDStreamFold {

    // The marker SwarmWorker's TTL watchdog writes into its .error steps.
    // Matching it here is the "existing detector" for stuck sessions.
    static func isStuckSignal(stepText: String) -> Bool {
        stepText.contains("TTL exceeded")
    }

    static func fold(rawLines: [String]) -> (state: RDFoldState, events: [RDRunEvent]) {
        var state = RDFoldState()
        var events: [RDRunEvent] = []
        for line in rawLines {
            if !state.limitDetected, LimitSignal.detect(rawLine: line) {
                state.limitDetected = true
                events.append(RDRunEvent(kind: .limitDetected, text: "Anthropic monthly usage limit signal detected"))
            }
            guard let ev = StreamJSONParser.parse(line: line) else { continue }
            switch ev {
            case .systemInit(let sid, let model, _):
                events.append(RDRunEvent(kind: .info, text: "session \(sid ?? "?") model \(model ?? "?")"))
            case .assistantText(let text, _):
                state.assistantTexts.append(text)
                events.append(RDRunEvent(kind: .assistantText, text: String(text.prefix(200))))
            case .toolUse(let name, let inputJSON, _):
                state.toolUseCount += 1
                events.append(RDRunEvent(kind: .toolUse, text: "\(name) \(String(inputJSON.prefix(160)))"))
            case .toolResult(let text, _):
                state.toolResultCount += 1
                events.append(RDRunEvent(kind: .toolResult, text: String(text.prefix(160))))
            case .usage(let cost, _, _, _):
                if let cost {
                    state.costUSD = max(state.costUSD, cost)
                    events.append(RDRunEvent(kind: .usage, text: String(format: "cost $%.4f estimated", cost), costUSD: cost))
                }
            case .finalResult(let text, let cost, let success, _):
                state.finalText = text
                state.finalSuccess = success
                if let cost { state.costUSD = max(state.costUSD, cost) }
                events.append(RDRunEvent(
                    kind: .runEnd,
                    text: "final success=\(success) \(String(text.prefix(160)))",
                    costUSD: cost
                ))
            case .unknown:
                break
            }
        }
        return (state, events)
    }

    // Token counts from a stream-json payload (the raw JSON SwarmWorker
    // stashes on usage AgentSteps). Looks for a usage object at the top
    // level or nested under "message", matching the claude CLI shapes.
    static func tokenUsage(fromPayloadJSON payload: String?) -> FoundryTokenUsage? {
        guard let payload, let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let usageDict = (obj["usage"] as? [String: Any])
            ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
        guard let usageDict else { return nil }
        var usage = FoundryTokenUsage()
        usage.inputTokens = usageDict["input_tokens"] as? Int ?? 0
        usage.outputTokens = usageDict["output_tokens"] as? Int ?? 0
        usage.cacheReadTokens = usageDict["cache_read_input_tokens"] as? Int ?? 0
        usage.cacheCreationTokens = usageDict["cache_creation_input_tokens"] as? Int ?? 0
        guard usage.total > 0 else { return nil }
        return usage
    }

    // Maps a live AgentStep (the shape SwarmWorker already emits after its
    // own stream parse) onto an RDRunEvent for the NDJSON log.
    static func event(forStep step: AgentStep) -> RDRunEvent {
        let kind: RDRunEvent.Kind
        switch step.kind {
        case .assistantText: kind = .assistantText
        case .toolUse: kind = .toolUse
        case .toolResult: kind = .toolResult
        case .usage: kind = .usage
        case .authLimitDetected: kind = .limitDetected
        case .error: kind = isStuckSignal(stepText: step.text) ? .stuckDetected : .error
        case .workerStart, .workerEnd, .orchestrator, .approvalRequested,
             .approvalGranted, .info, .accountSwitched, .workerResumed:
            kind = .info
        }
        return RDRunEvent(kind: kind, text: step.text, costUSD: step.costUSD)
    }
}

// MARK: - Live sink

// SwarmWorkerObserver that streams every AgentStep into the run's NDJSON
// log and latches the stuck/limit flags the outcome classifier reads.
// SwarmWorker holds its observer weakly, so callers MUST keep this sink
// alive for the duration of worker.run().
actor RDRunSink: SwarmWorkerObserver {

    private let log: RDRunLog
    private let modelID: String
    // Budget governor seam: every usage step's token counts forward here
    // (the hard per-cycle token cap is only enforced if someone reports
    // usage). Injectable so tests assert the forwarding without the live
    // FoundryGovernor singleton.
    private let recordUsage: (@MainActor (FoundryTokenUsage, String) -> Void)?
    private(set) var limitDetected = false
    private(set) var stuckDetail: String?

    init(
        log: RDRunLog,
        modelID: String = "",
        recordUsage: (@MainActor (FoundryTokenUsage, String) -> Void)? = nil
    ) {
        self.log = log
        self.modelID = modelID
        self.recordUsage = recordUsage
    }

    func worker(_ workerId: String, didEmit step: AgentStep) async {
        if step.kind == .authLimitDetected { limitDetected = true }
        if step.kind == .error, RDStreamFold.isStuckSignal(stepText: step.text) {
            stuckDetail = step.text
        }
        if step.kind == .usage, let recordUsage,
           let usage = RDStreamFold.tokenUsage(fromPayloadJSON: step.payloadJSON) {
            let model = modelID
            await MainActor.run { recordUsage(usage, model) }
        }
        await log.append(RDStreamFold.event(forStep: step))
    }
}

// MARK: - Run handle + outcome

// Everything a caller needs to follow up on, complete, or abandon a run.
// Codable: the engine persists its handles map so installs approved after
// a relaunch (and watch-settled cleanup) still resolve their worktrees.
struct RDRunHandle: Codable, Sendable {
    let runId: String
    let proposalId: UUID
    let proposalTitle: String
    let lane: UpgradeLane
    let domain: UpgradeDomain
    let slug: String
    let branch: String
    let repoRoot: URL
    let worktreePath: String
    let runDir: URL
    // Fork-point SHA recorded at worktree creation. The adversarial review
    // gate diffs against THIS, never a hardcoded "main": the source
    // checkout's current branch can sit tens of thousands of lines ahead
    // of main, which would drown (and truncate away) the actual change.
    var baseRef: String? = nil
}

enum RDRunOutcome: Equatable, Sendable {
    case success(finalText: String)
    case pausedForLimit            // monthly usage limit; resume after account swap
    case stuck(detail: String)     // TTL watchdog killed a silent session
    case failed(message: String)
    case escalated(jobId: String)  // handed to SwarmOrchestrator (M+ effort)
}

// MARK: - RDWorker

@MainActor
final class RDWorker: ObservableObject {

    enum Mode: String, Codable, Sendable {
        case headless     // SwarmWorker claude --print rail (implemented)
        case interactive  // TerminalFocus rail, RESERVED fallback flag
    }

    struct Config {
        // Git repo root the upgrade branches off. Worktrees land in a
        // sibling .worktrees/ directory.
        var repoRoot: URL
        // Autonomous R&D defaults to Sonnet: it does structural dup/lint and
        // iteration work at a fraction of Opus cost with negligible quality
        // loss. Pass "claude-opus-4-8" explicitly for genuinely high-stakes runs.
        var model: String = "claude-sonnet-4-6"
        var mode: Mode = .headless
        var runsDir: URL = RDWorkerPaths.runsDir

        init(repoRoot: URL, model: String = "claude-sonnet-4-6", mode: Mode = .headless, runsDir: URL = RDWorkerPaths.runsDir) {
            self.repoRoot = repoRoot
            self.model = model
            self.mode = mode
            self.runsDir = runsDir
        }
    }

    let config: Config
    private let store: ProposalStore
    private let timeline: FoundryTimelineStore
    // Final assistant text per run, fed back into follow-up prompts.
    private var lastFinalTextByRun: [String: String] = [:]

    // Session-limit stamp seam: a headless run that hits the monthly limit
    // must mark the active account so FoundryGovernorDecision.sessionLimited
    // sees it (the AgentService notification path never fires for headless
    // RD sessions). Injectable for tests.
    var limitStamper: @MainActor () -> Void = {
        AccountSwitcher.shared.recordLimitHitOnActiveAccount()
    }
    // Budget governor seam, forwarded into RDRunSink. Defaults to the live
    // FoundryGovernor so the per-cycle hard token cap actually accrues.
    var usageRecorder: @MainActor (FoundryTokenUsage, String) -> Void = { usage, model in
        _ = FoundryGovernor.shared.recordUsage(usage, modelID: model)
    }

    // Optional injection points default to the shared singletons inside the
    // body (not as default arguments) so the references stay on the main
    // actor under Swift 6 isolation checking.
    init(config: Config, store: ProposalStore? = nil, timeline: FoundryTimelineStore? = nil) {
        self.config = config
        self.store = store ?? .shared
        self.timeline = timeline ?? .shared
    }

    // MARK: - Routing

    // The one-call entry: S effort runs the single headless session,
    // M and L escalate to the swarm.
    func run(_ proposal: UpgradeProposal) async -> (outcome: RDRunOutcome, handle: RDRunHandle?) {
        if RDEffort.estimate(for: proposal) >= .m {
            return await escalate(proposal)
        }
        return await execute(proposal)
    }

    // MARK: - (1) Prompt composition

    // Always-estimated cost labels: the engine is subscription powered, so
    // any label missing the word gets it appended.
    static func normalizedCostLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "$0 estimated" }
        if trimmed.lowercased().contains("estimated") { return trimmed }
        return "\(trimmed) estimated"
    }

    static func conventionsBlock() -> String {
        """
        ## Conventions (hard rules)
        - No em dash (U+2014) and no en dash (U+2013) anywhere: code, comments, docs, tests, commit messages. Use a comma, period, colon, parentheses, or pipe instead.
        - Dollar figures in any copy are written as $N (numeral with symbol), and every cost figure is labeled estimated. The engine is subscription powered; nothing here is billed dollars.
        - Commit messages use Conventional Commits: feat(scope):, fix(scope):, docs(scope):. Stage specific files by name, never git add -A.
        - Tests stay at baseline: the existing suite must pass before you finish, and the new behavior gets focused tests.
        - Native Swift and SwiftUI only. Zero new dependencies.
        - Protected zones are off limits, do not touch: \(TrustLedger.protectedPathMarkers.joined(separator: ", ")).
        """
    }

    static func verifyBlock() -> String {
        """
        ## Verify before you finish (in order)
        1. swift build (zero errors)
        2. swift test (full suite green at baseline)
        3. Run your focused new tests and confirm they pass
        4. Scan the diff for U+2014 and U+2013 characters and remove any
        5. Commit with a conventional message, then report files changed, insertions, deletions

        End your final message with a single line starting with RD_RESULT: followed by PASS or FAIL and a one sentence summary.
        """
    }

    // Context pack: proposal facts, evidence, exact file paths, conventions,
    // the task itself, and ordered verify steps. Deterministic for a given
    // proposal so tests snapshot it.
    static func composePrompt(_ proposal: UpgradeProposal) -> String {
        composePrompt(proposal, workspaceBlock: nil)
    }

    // Worktree-aware variant used by execute/escalate once the workspace exists.
    static func composePrompt(_ proposal: UpgradeProposal, worktreePath: String, branch: String) -> String {
        let workspace = """
        ## Workspace
        - Worktree: \(worktreePath)
        - Branch: \(branch) (created from the current branch; commit here only)
        - Never modify files outside this worktree.
        """
        return composePrompt(proposal, workspaceBlock: workspace)
    }

    private static func composePrompt(_ proposal: UpgradeProposal, workspaceBlock: String?) -> String {
        let evidenceLines = proposal.evidence.isEmpty
            ? "- (no recorded signals; treat the task description as the evidence)"
            : proposal.evidence.map { "- \($0.display)" }.joined(separator: "\n")
        let pathLines = proposal.touchedPaths.isEmpty
            ? "- (no paths pinned; choose the smallest possible blast radius)"
            : proposal.touchedPaths.map { "- \($0)" }.joined(separator: "\n")

        var sections: [String] = []
        sections.append("You are the Grux Foundry R&D worker. Deliver exactly one upgrade end to end inside the workspace described below, then stop. Work autonomously: read the evidence, make the change, verify, commit.")
        sections.append("""
        ## Proposal
        - Title: \(proposal.title)
        - Lane: \(proposal.lane.displayName) | Domain: \(proposal.domain.displayName)
        - Risk class: \(proposal.riskClass.displayName) | Trust tier required: \(proposal.tierRequired.displayName)
        - Expected gain: \(String(format: "%.2f", proposal.expectedGain)) of 1.0
        - Cost: \(normalizedCostLabel(proposal.estCostLabel))
        """)
        sections.append("## Evidence\n\(evidenceLines)")
        sections.append("## Files in scope (exact paths)\n\(pathLines)")
        if let workspaceBlock { sections.append(workspaceBlock) }
        sections.append(conventionsBlock())
        sections.append("## Task\n\(proposal.readyPrompt)")
        sections.append(verifyBlock())
        return sections.joined(separator: "\n\n")
    }

    // Follow-up prompt: same workspace, prior session's final report, new
    // instruction, condensed gate reminder.
    static func composeFollowUpPrompt(
        title: String,
        branch: String,
        worktreePath: String,
        previousFinalText: String?,
        instruction: String
    ) -> String {
        let prior = previousFinalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorBlock = (prior?.isEmpty ?? true) ? "(none captured)" : prior!
        return """
        You are continuing Foundry upgrade '\(title)' on branch \(branch) in worktree \(worktreePath). Never modify files outside this worktree.

        ## Previous session final report
        \(priorBlock)

        ## Follow-up instruction
        \(instruction)

        \(conventionsBlock())

        \(verifyBlock())
        """
    }

    // MARK: - (2) Execute: worktree + headless claude session

    func execute(_ proposal: UpgradeProposal) async -> (outcome: RDRunOutcome, handle: RDRunHandle?) {
        var handle = makeHandle(proposal)
        let log = RDRunLog(runDir: handle.runDir)
        let effort = RDEffort.estimate(for: proposal)
        await log.append(RDRunEvent(
            kind: .runStart,
            text: "executing '\(proposal.title)' [\(proposal.lane.rawValue)/\(proposal.domain.rawValue)] effort \(effort.displayName) cost \(Self.normalizedCostLabel(proposal.estCostLabel))"
        ))
        if config.mode == .interactive {
            await log.append(RDRunEvent(
                kind: .info,
                text: "interactive TerminalFocus rail is reserved as a fallback flag and not wired in Phase B; running headless claude --print rail"
            ))
        }

        guard await createWorktree(handle: handle, log: log) else {
            return (.failed(message: "git worktree add failed for \(handle.branch)"), handle)
        }
        handle.baseRef = await forkPointSHA(worktreePath: handle.worktreePath, log: log)

        // Status. transition() enforces the legal loop itself; a proposal
        // not yet accepted simply stays where it is.
        store.transition(id: proposal.id, to: .building)

        let prompt = Self.composePrompt(proposal, worktreePath: handle.worktreePath, branch: handle.branch)
        await log.writePrompt(prompt)
        await log.append(RDRunEvent(kind: .promptComposed, text: "prompt \(prompt.count) chars, saved to prompt.md"))

        let outcome = await runHeadlessSession(
            goal: prompt,
            cwd: handle.worktreePath,
            label: "rd-\(handle.slug)",
            log: log
        )

        switch outcome {
        case .success(let finalText):
            lastFinalTextByRun[handle.runId] = finalText
            store.transition(id: proposal.id, to: .verifying)
            timeline.append(FoundryTimelineEntry(
                kind: .built,
                title: "Built: \(proposal.title)",
                detail: "Branch \(handle.branch) built on the R&D rail; verify gates ran in-session.",
                lane: proposal.lane.rawValue,
                domain: proposal.domain.rawValue
            ))
            await log.append(RDRunEvent(kind: .runEnd, text: "session succeeded; branch \(handle.branch) awaits review + land"))
        case .pausedForLimit:
            await log.append(RDRunEvent(kind: .limitDetected, text: "run paused: monthly usage limit; worktree kept for resume"))
        case .stuck(let detail):
            await log.append(RDRunEvent(kind: .stuckDetected, text: detail))
        case .failed(let message):
            await log.append(RDRunEvent(kind: .error, text: "run failed: \(message); worktree kept for forensics"))
        case .escalated:
            break // execute never produces this
        }
        return (outcome, handle)
    }

    // Re-enter the same worktree with a follow-up instruction. The previous
    // session's final text rides along as context.
    func followUp(_ instruction: String, handle: RDRunHandle) async -> RDRunOutcome {
        guard FileManager.default.fileExists(atPath: handle.worktreePath) else {
            return .failed(message: "worktree missing at \(handle.worktreePath) (completed or abandoned?)")
        }
        let log = RDRunLog(runDir: handle.runDir)
        await log.append(RDRunEvent(kind: .followUp, text: String(instruction.prefix(200))))
        let prompt = Self.composeFollowUpPrompt(
            title: handle.proposalTitle,
            branch: handle.branch,
            worktreePath: handle.worktreePath,
            previousFinalText: lastFinalTextByRun[handle.runId],
            instruction: instruction
        )
        await log.writePrompt(prompt, name: "followup-\(Int(Date().timeIntervalSince1970)).md")
        let outcome = await runHeadlessSession(
            goal: prompt,
            cwd: handle.worktreePath,
            label: "rd-followup-\(handle.slug)",
            log: log
        )
        if case .success(let text) = outcome {
            lastFinalTextByRun[handle.runId] = text
        }
        return outcome
    }

    // MARK: - (3) Escalate: M+ effort hands to the swarm

    // Builds the same worktree, then routes the composed prompt through
    // AgentService.startSwarm with the architectImplement template, so the
    // existing SwarmOrchestrator (DAG, pause/resume, Agents tab UI) drives
    // the build. The worktree stays alive for the job's lifetime; call
    // complete(_:)/abandon(_:) after the AgentJob reaches a terminal state.
    func escalate(_ proposal: UpgradeProposal) async -> (outcome: RDRunOutcome, handle: RDRunHandle?) {
        var handle = makeHandle(proposal)
        let log = RDRunLog(runDir: handle.runDir)
        await log.append(RDRunEvent(
            kind: .runStart,
            text: "escalating '\(proposal.title)' effort \(RDEffort.estimate(for: proposal).displayName) to SwarmOrchestrator (architectImplement)"
        ))

        guard await createWorktree(handle: handle, log: log) else {
            return (.failed(message: "git worktree add failed for \(handle.branch)"), handle)
        }
        handle.baseRef = await forkPointSHA(worktreePath: handle.worktreePath, log: log)

        store.transition(id: proposal.id, to: .building)

        let prompt = Self.composePrompt(proposal, worktreePath: handle.worktreePath, branch: handle.branch)
        await log.writePrompt(prompt)

        let job = await AgentService.shared.startSwarm(
            title: "foundry: \(proposal.title)",
            goal: prompt,
            template: .architectImplement,
            rootDir: handle.worktreePath,
            maxParallelWorkers: 1
        )
        await log.append(RDRunEvent(kind: .escalated, text: "swarm job \(job.id) running architectImplement in \(handle.worktreePath)"))
        return (.escalated(jobId: job.id), handle)
    }

    // MARK: - Worktree cleanup

    // Completion: remove the worktree, KEEP the upgrade/ branch for the
    // landing machinery (Phase C) to merge or cherry-pick.
    func complete(_ handle: RDRunHandle) async {
        let log = RDRunLog(runDir: handle.runDir)
        let cmd = RDWorktree.removeCommand(repoRoot: handle.repoRoot.path, worktreePath: handle.worktreePath)
        let r = await ShellRunner.runRaw(command: cmd, timeoutSeconds: 60)
        await log.append(RDRunEvent(
            kind: .cleanup,
            text: r.status == 0
                ? "completed: worktree removed, branch \(handle.branch) kept for landing"
                : "completed with cleanup warning (exit \(r.status)): \(String(r.truncated.prefix(200)))"
        ))
        lastFinalTextByRun.removeValue(forKey: handle.runId)
    }

    // Abandonment: remove the worktree AND delete the branch. A retry files
    // a fresh proposal per the ProposalStore terminal-state rules.
    func abandon(_ handle: RDRunHandle) async {
        let log = RDRunLog(runDir: handle.runDir)
        let rm = RDWorktree.removeCommand(repoRoot: handle.repoRoot.path, worktreePath: handle.worktreePath)
        _ = await ShellRunner.runRaw(command: rm, timeoutSeconds: 60)
        let del = RDWorktree.deleteBranchCommand(repoRoot: handle.repoRoot.path, branch: handle.branch)
        let r = await ShellRunner.runRaw(command: del, timeoutSeconds: 30)
        await log.append(RDRunEvent(
            kind: .cleanup,
            text: r.status == 0
                ? "abandoned: worktree removed, branch \(handle.branch) deleted"
                : "abandoned: worktree removed, branch delete exit \(r.status)"
        ))
        lastFinalTextByRun.removeValue(forKey: handle.runId)
    }

    // MARK: - Internals

    private func makeHandle(_ proposal: UpgradeProposal) -> RDRunHandle {
        let slug = RDWorktree.slug(for: proposal)
        let runId = "rd-\(Int(Date().timeIntervalSince1970))-\(slug)"
        return RDRunHandle(
            runId: runId,
            proposalId: proposal.id,
            proposalTitle: proposal.title,
            lane: proposal.lane,
            domain: proposal.domain,
            slug: slug,
            branch: RDWorktree.branchName(slug: slug),
            repoRoot: config.repoRoot,
            worktreePath: RDWorktree.worktreeURL(repoRoot: config.repoRoot, slug: slug).path,
            runDir: config.runsDir.appendingPathComponent(runId, isDirectory: true)
        )
    }

    private func createWorktree(handle: RDRunHandle, log: RDRunLog) async -> Bool {
        let cmd = RDWorktree.addCommand(
            repoRoot: handle.repoRoot.path,
            branch: handle.branch,
            worktreePath: handle.worktreePath
        )
        let r = await ShellRunner.runRaw(command: cmd, timeoutSeconds: 120)
        guard r.status == 0 else {
            await log.append(RDRunEvent(kind: .error, text: "worktree add failed (exit \(r.status)): \(String(r.truncated.prefix(300)))"))
            return false
        }
        await log.append(RDRunEvent(kind: .worktreeCreated, text: "\(handle.branch) at \(handle.worktreePath)"))
        return true
    }

    // The fresh worktree's HEAD IS the fork point (recorded before any
    // session commits land), so the verify gates can diff exactly the
    // upgrade's changes instead of everything since main.
    private func forkPointSHA(worktreePath: String, log: RDRunLog) async -> String? {
        let cmd = "git -C \(RDWorktree.shellQuote(worktreePath)) rev-parse HEAD"
        let r = await ShellRunner.runRaw(command: cmd, timeoutSeconds: 30)
        let sha = r.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
        guard r.status == 0, let sha, sha.count >= 7, !sha.contains(" ") else {
            await log.append(RDRunEvent(
                kind: .info,
                text: "fork-point rev-parse failed (exit \(r.status)); adversarial review falls back to main"
            ))
            return nil
        }
        await log.append(RDRunEvent(kind: .info, text: "fork point recorded: \(sha)"))
        return sha
    }

    // One headless claude --print session on the SwarmWorker rail. The
    // worker already enforces the wall + idle TTLs (stuck detector), strips
    // API-billing env keys, and latches LimitSignal; we classify its result.
    private func runHeadlessSession(
        goal: String,
        cwd: String,
        label: String,
        log: RDRunLog
    ) async -> RDRunOutcome {
        // Keep the sink strong: SwarmWorker holds it weakly.
        let sink = RDRunSink(log: log, modelID: config.model, recordUsage: usageRecorder)
        let spec = SwarmWorkerSpec(
            role: .implementor,
            label: label,
            goal: goal,
            cwd: cwd,
            model: config.model
        )
        let worker = SwarmWorker(spec: spec, observer: sink)
        let ttl = (ProcessInfo.processInfo.environment["GRUX_RD_TTL_SECONDS"].flatMap(Int.init)) ?? 1800
        let result = await worker.run(scaffold: MegapromptScaffold.block(), ttlSeconds: ttl)

        let limitLatched = await sink.limitDetected
        if result.interruption?.kind == .authLimitHit || limitLatched {
            // Stamp the active account so the governor's session-limit
            // yield and the cycle loop's stand-down see this hit.
            limitStamper()
            return .pausedForLimit
        }
        if let stuck = await sink.stuckDetail {
            return .stuck(detail: stuck)
        }
        if result.success {
            return .success(finalText: result.finalText)
        }
        return .failed(message: result.errorMessage ?? "exit \(result.exitCode)")
    }
}

// MARK: - Paths

// Run artifacts live under the Foundry's own directory, beside proposals
// and the trust ledger: <support>/foundry/runs/<runId>/.
enum RDWorkerPaths {
    static var runsDir: URL {
        let dir = FoundryPaths.dir.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
