import Foundation
import Combine
import AppKit
import GruxShellCore

// MARK: - Engine
//
// The Commands V2 engine executes phase-gated workflows. Unlike V1 macros
// (linear, runs-to-completion-in-seconds), V2 runs can:
//
//  • Pause for user approval and resume on chat/voice reply
//  • Schedule a future resume (24h waits) and survive Mac restarts
//  • Branch on runtime state (e.g. ASC submission state)
//  • Spawn Claude agents (single or swarm) - currently stubbed
//
// State model: each `CommandV2Run` is persisted as one JSON file under
// ~/Library/Application Support/Grux/v2-runs/<run-id>.json. Every phase
// boundary writes the run; a Mac shutdown mid-phase is recoverable to
// the prior boundary on next launch (phases are designed idempotent).

extension Notification.Name {
    static let gruxCommandV2RunsChanged = Notification.Name("gruxCommandV2RunsChanged")
    static let gruxCommandV2RunStarted = Notification.Name("gruxCommandV2RunStarted")
    static let gruxCommandV2RunFinished = Notification.Name("gruxCommandV2RunFinished")
    // Posted when an active V2 run advances from one phase to the next. Carries
    // userInfo: ["runId": UUID, "fromPhase": Int (1-based), "toPhase": Int
    // (1-based), "phaseName": String, "commandId": String]. Subscribers
    // (CommandV2PhaseNotifier, MenuBarView) react to this without taking a
    // hard dependency on CommandV2Engine internals.
    static let gruxCommandV2PhaseTransitioned = Notification.Name("gruxCommandV2PhaseTransitioned")
    // Posted when a run stops to wait for the person. object: the run id;
    // userInfo: ["question": String]. Chat shows the question, because a
    // spoken question alone reaches nobody with speech off.
    static let gruxCommandV2GateWaiting = Notification.Name("gruxCommandV2GateWaiting")
}

@MainActor
public final class CommandV2Engine: ObservableObject {
    public static let shared = CommandV2Engine()

    @Published public private(set) var activeRuns: [CommandV2Run] = []
    // Last N terminal runs (success/failed/canceled). Populated at load + on
    // every run finalization so the Workflows tab can show "what happened
    // recently" instead of pretending the run vanished. Capped at 20.
    @Published public private(set) var recentRuns: [CommandV2Run] = []
    @Published public private(set) var definitions: [CommandV2Definition] = []
    private static let recentRunsCap = 20

    private var loaded = false
    private var resumeTimers: [UUID: Timer] = [:]

    private var runsDir: URL {
        let dir = Persistence.supportDir.appendingPathComponent("v2-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Bootstrap

    public func load() {
        guard !loaded else { return }
        loaded = true
        loadAllRunsFromDisk()
        registerBuiltinDefinitions()
        rearmScheduledRuns()
    }

    private func loadAllRunsFromDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [CommandV2Run] = []
        var terminals: [CommandV2Run] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let run = try? dec.decode(CommandV2Run.self, from: data) {
                if run.status == .completed || run.status == .failed || run.status == .canceled {
                    terminals.append(run)
                } else {
                    loaded.append(run)
                }
            }
        }
        self.activeRuns = loaded.sorted { $0.startedAt > $1.startedAt }
        let sortedTerminals = terminals.sorted {
            ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
        }
        self.recentRuns = Array(sortedTerminals.prefix(Self.recentRunsCap))
    }

    // Called by upsert() when a run reaches a terminal status. Moves it from
    // activeRuns into recentRuns (capped at 20). Without this, terminal runs
    // simply vanish from the Workflows tab - operators can't tell whether the
    // workflow finished, errored, or was lost. v2-runs/<id>.json is preserved
    // either way; this is purely a UI hydration concern.
    private func archiveTerminalRun(_ run: CommandV2Run) {
        guard run.status == .completed || run.status == .failed || run.status == .canceled else { return }
        recentRuns.removeAll(where: { $0.id == run.id })
        recentRuns.insert(run, at: 0)
        if recentRuns.count > Self.recentRunsCap {
            recentRuns = Array(recentRuns.prefix(Self.recentRunsCap))
        }
    }

    private func registerBuiltinDefinitions() {
        for d in Self.builtinDefinitions {
            if !definitions.contains(where: { $0.id == d.id }) {
                definitions.append(d)
            }
        }
    }

    static var builtinDefinitions: [CommandV2Definition] {
        [
            CommandV2Definitions.smokeHelloWorld(),
            CommandV2Definitions.checkASCStatus(),
            CommandV2Definitions.generateMarketingScreenshots(),
            CommandV2Definitions.shipExistingIOSApp(),
            CommandV2Definitions.shipIOSApp(),
            CommandV2Definitions.localizeApp(),
            CommandV2Definitions.testflightFeedback(),
            CommandV2Definitions.captureIdea()
        ]
    }

    private func rearmScheduledRuns() {
        for run in activeRuns where run.status == .waitingScheduled {
            guard let wakeAt = run.nextWakeAt else { continue }
            let delay = max(1.0, wakeAt.timeIntervalSinceNow)
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleScheduledWake(runId: run.id, phase: run.currentPhaseId)
                }
            }
            resumeTimers[run.id] = timer
            WakeLog.shared.log("v2: re-armed scheduled run \(run.id.uuidString.prefix(8)) → \(run.currentPhaseId) in \(Int(delay))s")
        }
    }

    // MARK: - Public API

    public func register(_ def: CommandV2Definition) {
        if let idx = definitions.firstIndex(where: { $0.id == def.id }) {
            definitions[idx] = def
        } else {
            definitions.append(def)
        }
    }

    /// What each outside step of a recent dry run would have been given (its
    /// resolved prompt, command or tool input), by run and step id. Kept in
    /// memory for tests and debugging only: the run record a person opens
    /// says the step's name instead (SWEEP-12).
    private var dryRunInputs: [UUID: [String: String]] = [:]

    func recordDryRunInput(_ input: String, run: UUID, phase: String) {
        let keep = Set(activeRuns.map(\.id) + recentRuns.map(\.id) + [run])
        dryRunInputs = dryRunInputs.filter { keep.contains($0.key) }
        dryRunInputs[run, default: [:]][phase] = input
    }

    /// What the step `phase` of the dry run `run` would have been given.
    func dryRunInput(run: UUID, phase: String) -> String? { dryRunInputs[run]?[phase] }

    public func definition(id: String) -> CommandV2Definition? {
        definitions.first(where: { $0.id == id })
    }

    public func run(id: UUID) -> CommandV2Run? {
        activeRuns.first(where: { $0.id == id })
    }

    // MARK: - Answering a gate

    // Generic words for a phase that pauses without asking a question of its
    // own (`userApprovalRequired` on an agent or tool phase).
    static let plainApprovalReplies = ["approve", "approved", "go", "yes", "continue"]

    // Words that only say "go on". A resume with no reply (a CLI or file-drop
    // approve) may answer a gate that lists one of these, with that word; a
    // gate whose words are choices (fix / ship / hold) or free text needs one
    // said on purpose.
    static let approveWords: Set<String> = Set(plainApprovalReplies)
        .union(["ok", "okay", "done", "accepted", "looks good", "lgtm", "ship it", "build it"])

    // A free-text gate ("what are your final thoughts?") takes the next chat
    // message only this soon after it asked; after that a message is chat.
    static let freeTextGateWindow: TimeInterval = 30 * 60

    // The replies a waiting run understands, first one being what a plain
    // Approve means. nil means any words (a free-text gate); empty means the
    // run is not waiting at a gate.
    func acceptedReplies(for run: CommandV2Run) -> [String]? {
        guard run.status == .waitingForApproval,
              let phase = definition(id: run.definitionId)?.phases.first(where: { $0.id == run.currentPhaseId })
        else { return [] }
        switch phase.action {
        case .userApprovalGate(_, let expected):
            return expected.map { $0.map(Self.normalizedReply) }
        case .walkthrough:
            // The last stop before the App Store takes the one word its
            // question names (RV2, RV3; ruled again after the final sweep).
            return ["ship it"]
        default:
            return Self.plainApprovalReplies
        }
    }

    // The answers worth a button. Every accepted word when the workflow
    // branches on the reply (fix / ship / hold mean different things), else
    // only the first, since the rest are synonyms ("go", "approved", "lgtm").
    // nil for a free-text gate.
    func buttonReplies(for run: CommandV2Run) -> [String]? {
        guard let accepted = acceptedReplies(for: run) else { return nil }
        let phases = definition(id: run.definitionId)?.phases ?? []
        let branchesOnReply = phases.contains { phase in
            if case .branch(let cond, _, _) = phase.action { return Self.readsReply(cond) }
            return false
        }
        return branchesOnReply ? accepted : Array(accepted.prefix(1))
    }

    private static func readsReply(_ cond: ConditionExpr) -> Bool {
        switch cond {
        case .stateEquals(let key, _), .stateMatches(let key, _): return key == "user_reply"
        case .ascSubmissionState: return false
        case .allOf(let all), .anyOf(let all): return all.contains(where: readsReply)
        case .not(let inner): return readsReply(inner)
        }
    }

    // The question a waiting run is asking, with the words that answer it.
    // A gate whose own words name none of its answers gets them added.
    func gateQuestion(for run: CommandV2Run) -> String {
        let reason = run.blockingReason ?? ""
        guard let accepted = acceptedReplies(for: run), !accepted.isEmpty,
              !accepted.contains(where: { word in
                  reason.range(of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
                               options: .regularExpression) != nil
              })
        else { return "\(run.displayName): \(reason)" }
        let words = accepted.count == 1 ? accepted[0]
            : accepted.dropLast().joined(separator: ", ") + " or " + accepted[accepted.count - 1]
        return "\(run.displayName): \(reason) Reply \(words)."
    }

    /// What an observer of a run's notifications needs, taken from the run
    /// at post time. REVIEW-2: the phase notifier looked the run up after an
    /// async hop, and a run gone from activeRuns and the 20-slot recentRuns
    /// by then read as live, so a dry run posted a real banner and phone push.
    /// Observers read these and never re-find the run.
    static func runFacts(_ run: CommandV2Run) -> [String: Any] {
        var info: [String: Any] = [
            "runId": run.id,
            "isDryRun": run.isDryRun,
            "runName": run.displayName,
            "status": run.status.rawValue,
        ]
        for (key, name) in [("asc_state", "ascState"), ("asc_bundle_id", "ascBundleId"),
                            ("asc_app_id", "ascAppId"), ("asc_version", "ascVersion")] {
            if let value = run.state[key]?.stringValue { info[name] = value }
        }
        return info
    }

    private func postGateWaiting(_ run: CommandV2Run) {
        NotificationCenter.default.post(name: .gruxCommandV2GateWaiting, object: run.id,
                                        userInfo: Self.runFacts(run).merging(["question": gateQuestion(for: run)]) { $1 })
    }

    enum GateAnswer: Equatable {
        case none
        case resume(runId: UUID, reply: String)
        // More than one waiting run takes these words: answering one of them
        // on a guess could submit the wrong app.
        case ambiguous([UUID])
        // These runs take the word, but asked too long ago for it to be an
        // answer: ask them again instead.
        case stale([UUID])
    }

    // Which waiting run a chat message answers. A message answers a gate only
    // if it was sent after the gate asked and within `freeTextGateWindow` of
    // it, and then only when it is one of the words the gate asked for or the
    // gate asked for free text. A listed word sent long after the question
    // (a "no" to something else, days later) is `.stale`: the gate asks again
    // rather than taking it. So is any message to a free-text gate whose
    // window has lapsed, so it is never a dead end that "Answer in Chat"
    // still points at. Anything else is ordinary chat.
    //
    // A free-text gate takes any words, so it also needs its question to be
    // `lastSaid`, Grux's latest line in Chat. Once Grux has said anything
    // else (a reply to other chat, a card's result), the next message is
    // about that, not the question: `.stale`, asked again (integrated review:
    // "thanks" to an unrelated reply became a workflow's final thoughts).
    func gateAnswer(for text: String, sentAt: Date = Date(), lastSaid: String? = nil) -> GateAnswer {
        let said = Self.normalizedReply(text)
        guard !said.isEmpty else { return .none }
        var byWord: [UUID] = []
        var freeText: [UUID] = []
        var stale: [UUID] = []
        for run in activeRuns where run.status == .waitingForApproval {
            // A run saved before the engine recorded this reads as asked long ago.
            let asked = run.gateAskedAt ?? .distantPast
            guard sentAt >= asked else { continue }
            let fresh = sentAt.timeIntervalSince(asked) <= Self.freeTextGateWindow
            guard let accepted = acceptedReplies(for: run) else {
                if fresh, asksLast(run, lastSaid: lastSaid) { freeText.append(run.id) } else { stale.append(run.id) }
                continue
            }
            guard accepted.contains(said) else { continue }
            if fresh { byWord.append(run.id) } else { stale.append(run.id) }
        }
        let matched = byWord.isEmpty ? freeText : byWord
        switch matched.count {
        case 0: return stale.isEmpty ? .none : .stale(stale)
        case 1: return .resume(runId: matched[0], reply: text)
        default: return .ambiguous(matched)
        }
    }

    // True when `lastSaid` is this run's question as Chat shows it.
    private func asksLast(_ run: CommandV2Run, lastSaid: String?) -> Bool {
        guard let lastSaid else { return false }
        let question = DashSanitizer.stripDashesOnly(gateQuestion(for: run))
        return lastSaid.trimmingCharacters(in: .whitespacesAndNewlines)
            == question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // While this file exists every run starts as a dry run, whichever door
    // started it (chat, `grux run`, fire-v2-run, a schedule, the palette), so
    // a test machine can drive the App Store workflows without reaching Apple.
    static var dryRunSentinelURL: URL { Persistence.gruxDir.appendingPathComponent("DRY-RUN-WORKFLOWS") }

    // In a dry run a parameter named `dryRun.<key>` seeds `state.<key>`: it
    // stands in for what Apple or a device would have answered, so a branch
    // like `asc_state == READY_FOR_SALE` can be walked without asking Apple.
    static let dryRunStatePrefix = "dryRun."

    // A dry run collapses waits, so a phase that loops on Apple's answer
    // would spin. It stops the run on this visit instead.
    static let dryRunMaxVisitsPerPhase = 3

    @discardableResult
    public func start(definitionId: String, params: [String: JSONValue] = [:], displayName: String? = nil, dryRun: Bool = false) async -> Result<UUID, EngineError> {
        guard let def = definition(id: definitionId) else {
            return .failure(.unknownDefinition(definitionId))
        }
        // Prevent multiple ship runs for the same project (per spec edge case 1).
        if def.category == .ship,
           let project = params["project"]?.stringValue {
            let conflict = activeRuns.first {
                $0.definitionId == def.id &&
                $0.parameters["project"]?.stringValue == project &&
                ($0.status == .running || $0.status == .waitingForApproval ||
                 $0.status == .waitingScheduled || $0.status == .waitingForActiveUser)
            }
            if let c = conflict {
                return .failure(.alreadyRunning(c.id, Self.alreadyRunningMessage(c, in: def)))
            }
        }
        guard let firstPhase = def.phases.first else {
            return .failure(.invalidDefinition("\(def.id) has no phases"))
        }
        if let problem = def.structuralProblems().first {
            return .failure(.invalidDefinition("\(def.id): \(problem)"))
        }
        var run = CommandV2Run(
            definitionId: def.id,
            displayName: displayName ?? Self.runName(def.displayName, params: params),
            currentPhaseId: firstPhase.id,
            parameters: params
        )
        if dryRun || FileManager.default.fileExists(atPath: Self.dryRunSentinelURL.path) {
            run.dryRun = true
            for (key, value) in params where key.hasPrefix(Self.dryRunStatePrefix) {
                run.state[String(key.dropFirst(Self.dryRunStatePrefix.count))] = value
            }
        }
        activeRuns.insert(run, at: 0)
        persist(run)
        NotificationCenter.default.post(name: .gruxCommandV2RunStarted, object: run.id, userInfo: Self.runFacts(run))
        NotificationCenter.default.post(name: .gruxCommandV2RunsChanged, object: nil)
        WakeLog.shared.log("v2: started \(run.isDryRun ? "DRY RUN" : "run") \(run.id.uuidString.prefix(8)) of '\(def.id)'")
        Task { await self.executeFromCurrentPhase(runId: run.id) }
        return .success(run.id)
    }

    /// Asks a waiting run's question in Chat again because a message could
    /// not answer it. `ChatService.send` calls this once the turn's reply is
    /// posted, so the question is Grux's latest line and the person's next
    /// message answers it. At most once per `freeTextGateWindow` per run:
    /// between re-asks the person's messages go on as chat with no re-post.
    /// Returns whether it asked.
    @discardableResult
    func reask(_ runId: UUID, now: Date = Date()) -> Bool {
        guard var run = run(id: runId), run.status == .waitingForApproval else { return false }
        if let last = run.gateReaskedAt, now.timeIntervalSince(last) < Self.freeTextGateWindow {
            WakeLog.shared.log("v2: \(runId.uuidString.prefix(8)) asked again \(Int(now.timeIntervalSince(last) / 60)) min ago; not re-posting the question")
            return false
        }
        run.gateReaskedAt = now
        askAtGate(run, now: now)
        return true
    }

    /// The Workflows card's "Answer in Chat": asks a waiting run's question in
    /// Chat now, whenever it last asked, so the line is always true.
    func askAgainInChat(_ runId: UUID) {
        guard let run = run(id: runId), run.status == .waitingForApproval else { return }
        askAtGate(run)
    }

    /// Stamps when the question was asked, saves the run and posts the
    /// question to Chat.
    private func askAtGate(_ run: CommandV2Run, now: Date = Date()) {
        var run = run
        run.gateAskedAt = now
        upsert(run)
        postGateWaiting(run)
    }

    /// Moves a waiting run past its gate with `userReply`, which must be one of
    /// the words the gate asked for (any words for a free-text gate). With no
    /// reply, only a gate that lists an approve word and offers no choice goes
    /// on, answered with that word: a gate whose words the workflow branches
    /// on (fix / ship / hold, yes / no / skip) or a free-text gate stays
    /// waiting. Returns false, leaving the run waiting, when the reply does
    /// not answer the gate.
    @discardableResult
    public func resume(_ runId: UUID, userReply: String? = nil) async -> Bool {
        guard var run = run(id: runId) else { return false }
        guard run.status == .waitingForApproval else {
            WakeLog.shared.log("v2: resume on \(runId.uuidString.prefix(8)) - not waiting for approval (status=\(run.status.rawValue))")
            return false
        }
        let accepted = acceptedReplies(for: run)
        let saidText = (userReply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Branches compare `state.user_reply` with a bare word ("yes", "fix",
        // "ship"), so keep the reply in that shape: "Fix." and " fix" both mean fix.
        let word: String
        let text: String
        if saidText.isEmpty {
            // More than one button means the words are a choice (the workflow
            // branches on them), and a blind approve does not choose.
            let offersAChoice = (buttonReplies(for: run)?.count ?? 0) > 1
            guard let accepted, !offersAChoice, let ok = accepted.first(where: Self.approveWords.contains) else {
                WakeLog.shared.log("v2: resume on \(runId.uuidString.prefix(8)) refused - no reply given, and the gate at \(run.currentPhaseId) asks for \(accepted.map { $0.joined(separator: "/") } ?? "free text")")
                return false
            }
            word = ok
            text = ok
        } else {
            word = Self.normalizedReply(saidText)
            text = saidText
            if let accepted, !accepted.contains(word) {
                WakeLog.shared.log("v2: resume on \(runId.uuidString.prefix(8)) refused - '\(saidText)' is not one of \(accepted.joined(separator: "/"))")
                return false
            }
        }
        run.state["user_reply"] = .string(word)
        // The words as said, for a gate that asks for more than a word.
        run.state["user_reply_text"] = .string(text)
        run.status = .running
        run.blockingReason = nil
        if let lastIdx = run.phaseHistory.indices.last {
            run.phaseHistory[lastIdx].endedAt = Date()
            run.phaseHistory[lastIdx].outcome = .success
            run.phaseHistory[lastIdx].log += "\n" + (saidText.isEmpty
                ? PhaseLogCopy.answered(text, gateWord: word)
                : PhaseLogCopy.answered(text))
        }
        upsert(run)
        await advanceToNextPhase(runId: runId)
        return true
    }

    /// What a canceled run says in the Workflows list.
    static let canceledReason = "You canceled it."

    /// The value the Workflows tab's Run button gives every parameter it has
    /// no way to ask for. Reads as not given.
    nonisolated static let unspecifiedParameter = "(unspecified)"

    /// The Workflows list's line for the step a run is on: the step's own
    /// name, never its id.
    static func stepLine(for run: CommandV2Run, in def: CommandV2Definition?) -> String {
        guard let phase = def?.phases.first(where: { $0.id == run.currentPhaseId }) else { return "" }
        return "Step: \(phase.displayName)"
    }

    /// Why a second ship run for the same project did not start.
    /// One sentence, capitalized, the step after a colon so any step name
    /// reads: "Ship the iOS app is already running, on this step: Confirm the
    /// plan before building."
    static func alreadyRunningMessage(_ running: CommandV2Run, in def: CommandV2Definition) -> String {
        let step = def.phases.first { $0.id == running.currentPhaseId }?.displayName
        let name = running.displayName.prefix(1).uppercased() + running.displayName.dropFirst()
        return "\(name) is already running" + (step.map { ", on this step: \($0)." } ?? ".")
    }

    /// A parameter a person did not give, as a sentence reads it:
    /// `project` is "your project".
    nonisolated static func unfilledParameter(_ key: String) -> String {
        "your " + key.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated static func givenParameter(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue, !value.isEmpty, value != unspecifiedParameter else { return nil }
        return value
    }

    // A definition's name with its `{param}` placeholders filled from this
    // run's parameters ("localize {project}" -> "localize Tracker"). A
    // placeholder with no parameter reads as the thing it stands for
    // ("localize your project"), never as the placeholder.
    nonisolated static func runName(_ template: String, params: [String: JSONValue]) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)\}"#) else { return template }
        var out = template
        for m in re.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let whole = Range(m.range, in: out), let keyR = Range(m.range(at: 1), in: template) else { continue }
            let key = String(template[keyR])
            out.replaceSubrange(whole, with: givenParameter(params[key]) ?? unfilledParameter(key))
        }
        return out
    }

    nonisolated static func normalizedReply(_ reply: String) -> String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    public func cancel(_ runId: UUID) async {
        guard var run = run(id: runId) else { return }
        run.status = .canceled
        run.completedAt = Date()
        run.blockingReason = Self.canceledReason
        upsert(run)
        if let t = resumeTimers.removeValue(forKey: runId) { t.invalidate() }
        // Move out of activeRuns
        activeRuns.removeAll(where: { $0.id == runId })
        archiveTerminalRun(run)
        NotificationCenter.default.post(name: .gruxCommandV2RunsChanged, object: nil)
        WakeLog.shared.log("v2: canceled run \(runId.uuidString.prefix(8))")
    }

    public func handleScheduledWake(runId: UUID, phase: String) async {
        if let t = resumeTimers.removeValue(forKey: runId) { t.invalidate() }
        guard var run = run(id: runId) else { return }
        guard run.status == .waitingScheduled else {
            WakeLog.shared.log("v2: scheduled wake on \(runId.uuidString.prefix(8)) - but status is \(run.status.rawValue), ignoring")
            return
        }
        run.currentPhaseId = phase
        run.status = .running
        run.nextWakeAt = nil
        run.blockingReason = nil
        upsert(run)
        WakeLog.shared.log("v2: scheduled wake fired for \(runId.uuidString.prefix(8)) → \(phase)")
        await executeFromCurrentPhase(runId: runId)
    }

    // MARK: - Voice trigger matching

    // Resolve a freeform spoken phrase to a definition + extracted params.
    // Triggers may include `{slot}` placeholders captured into parameters.
    // Returns nil if no trigger matches.
    public func matchTrigger(_ utterance: String) -> (CommandV2Definition, [String: JSONValue])? {
        let q = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        for def in definitions {
            for trig in def.voiceTriggers {
                if let match = matchTriggerPattern(trig, against: q) {
                    return (def, match)
                }
            }
        }
        return nil
    }

    /// AN UNANCHORED `(.+)` AFTER ONE COMMON WORD IS NOT A COMMAND, IT IS A SENTENCE.
    ///
    /// `{slot}` compiles to `(.+)`, so "translate {project}" became `^translate (.+)$` and
    /// swallowed "translate this email into Spanish". ChatService runs this fast path BEFORE
    /// the model, so the person got no answer at all: instead the Mac said out loud "this
    /// email into Spanish just shipped. I'll check back in a week before localizing.", and a
    /// run was persisted with nextWakeAt = now + 7 days that re-armed on every later launch.
    ///
    /// Two different rules, because the two slots fail differently.
    ///
    /// A `{project}` capture has to NAME a project that exists. That is precise, it needs no
    /// heuristic, and it keeps every intended phrasing working: "ship Grux" still
    /// fires, "ship it when you get a chance" does not.
    ///
    /// A `{content}` capture can be anything by definition, so there is nothing to check
    /// against and the literal part has to carry the weight instead. Two words, or a
    /// terminator, is the line: "idea: ", "grux idea ", "new idea " and "capture idea " all
    /// read as commands and all still work. Bare "idea " does not, and it was swallowing
    /// sentences like "idea generation is hard, any tips?".
    nonisolated static func literalPrefixIsCommandShaped(_ literalPrefix: String) -> Bool {
        let p = literalPrefix.trimmingCharacters(in: .whitespaces)
        if p.hasSuffix(":") || p.hasSuffix("-") { return true }
        return p.split(separator: " ").count >= 2
    }

    private func matchTriggerPattern(_ pattern: String, against utterance: String) -> [String: JSONValue]? {
        let trig = pattern.lowercased()
        // Simple slot matching: convert {slot} into a regex capture group.
        if trig.contains("{") {
            var regex = "^"
            var slots: [String] = []
            var i = trig.startIndex
            while i < trig.endIndex {
                if trig[i] == "{" {
                    if let end = trig[i...].firstIndex(of: "}") {
                        let slot = String(trig[trig.index(after: i)..<end])
                        slots.append(slot)
                        regex += "(.+)"
                        i = trig.index(after: end)
                        continue
                    }
                }
                let ch = trig[i]
                if ".\\+*?()[]^$|".contains(ch) { regex += "\\\(ch)" } else { regex += String(ch) }
                i = trig.index(after: i)
            }
            regex += "$"
            guard let re = try? NSRegularExpression(pattern: regex) else { return nil }
            let r = NSRange(utterance.startIndex..., in: utterance)
            guard let m = re.firstMatch(in: utterance, range: r) else { return nil }
            // Everything before the first slot, which is the only literal the person had to
            // type on purpose.
            let literalPrefix = trig.firstIndex(of: "{").map { String(trig[trig.startIndex..<$0]) } ?? trig

            var out: [String: JSONValue] = [:]
            for (idx, slot) in slots.enumerated() {
                guard let range = Range(m.range(at: idx + 1), in: utterance) else { continue }
                let value = String(utterance[range]).trimmingCharacters(in: .whitespaces)
                if slot == "project" {
                    guard ProjectsResolver.namesAKnownProject(value) else { return nil }
                } else {
                    guard Self.literalPrefixIsCommandShaped(literalPrefix) else { return nil }
                }
                out[slot] = .string(value)
            }
            return out
        }
        // No slots: literal match.
        return utterance == trig ? [:] : nil
    }

    // MARK: - Internals

    func upsert(_ run: CommandV2Run) {
        // Every save goes through here, so the saved question can never
        // outlive the gate that asked it.
        var run = run
        run.gateQuestion = run.status == .waitingForApproval ? gateQuestion(for: run) : nil
        if let idx = activeRuns.firstIndex(where: { $0.id == run.id }) {
            activeRuns[idx] = run
        } else {
            activeRuns.insert(run, at: 0)
        }
        persist(run)
        NotificationCenter.default.post(name: .gruxCommandV2RunsChanged, object: nil)
    }

    private func persist(_ run: CommandV2Run) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(run) else { return }
        let url = runsDir.appendingPathComponent("\(run.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Execution loop

    private func executeFromCurrentPhase(runId: UUID) async {
        guard var run = run(id: runId) else { return }
        guard let def = definition(id: run.definitionId) else {
            run.status = .failed
            run.lastError = "definition '\(run.definitionId)' missing"
            run.completedAt = Date()
            upsert(run)
            return
        }
        guard let phase = def.phases.first(where: { $0.id == run.currentPhaseId }) else {
            run.status = .failed
            run.lastError = "phase '\(run.currentPhaseId)' missing in definition"
            run.completedAt = Date()
            upsert(run)
            return
        }

        // In-flight placeholder. The terminal outcome (.success / .failure /
        // .branched / .skipped / .paused / .scheduled) is written below once
        // the executor returns. Using `.running` here instead of `.success`
        // keeps the UI honest while the phase is mid-execution - historically
        // the placeholder was `.success`, which made every just-started phase
        // look already-succeeded in the UI even when the agent/swarm was
        // still working (or had been killed mid-run, leaving the stale
        // `.success` placeholder pinned forever).
        // Dry run belongs to the run, but the file says this Mac must not
        // reach outside. A live run saved before the file existed (waiting at
        // a gate or on the clock) stops here instead of going on after a
        // relaunch, and says why.
        if !run.isDryRun, FileManager.default.fileExists(atPath: Self.dryRunSentinelURL.path) {
            run.status = .failed
            run.lastError = Self.liveRunUnderDryRunMessage
            run.completedAt = Date()
            upsert(run)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(run)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId, userInfo: Self.runFacts(run))
            WakeLog.shared.log("v2: refused live run \(runId.uuidString.prefix(8)) at \(phase.id): the dry-run file exists and the run started live")
            return
        }
        if run.isDryRun,
           run.phaseHistory.filter({ $0.phaseId == phase.id }).count >= Self.dryRunMaxVisitsPerPhase {
            run.status = .failed
            run.lastError = Self.dryRunStopMessage(at: phase)
            run.completedAt = Date()
            if let lastIdx = run.phaseHistory.indices.last {
                run.phaseHistory[lastIdx].log += "\n" + PhaseLogCopy.dryRunStoppedHere
            }
            upsert(run)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(run)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId, userInfo: Self.runFacts(run))
            return
        }

        let record = CommandV2Run.PhaseRecord(
            phaseId: phase.id,
            startedAt: Date(),
            outcome: .running,
            log: ""
        )
        run.phaseHistory.append(record)
        run.status = .running
        upsert(run)

        let outcome = run.isDryRun
            ? await CommandV2Executor.executeDry(action: phase.action, step: phase.displayName, run: run, definition: def, engine: self)
            : await CommandV2Executor.execute(action: phase.action, step: phase.displayName, run: run, definition: def, engine: self)

        // Re-fetch in case another flow mutated state.
        guard var fresh = self.run(id: runId) else { return }
        if let lastIdx = fresh.phaseHistory.indices.last {
            fresh.phaseHistory[lastIdx].endedAt = Date()
            fresh.phaseHistory[lastIdx].log = outcome.log
            fresh.phaseHistory[lastIdx].details = outcome.details
            fresh.phaseHistory[lastIdx].outcome = outcome.kind
        }
        // Apply state mutations from the action.
        for (k, v) in outcome.stateMutations { fresh.state[k] = v }

        switch outcome.kind {
        case .success:
            // Honor approval gates declared on the phase itself.
            if phase.userApprovalRequired && outcome.kind != .paused {
                fresh.status = .waitingForApproval
                fresh.blockingReason = CommandV2Executor.gatePrompt(Self.approvalRequiredReason(at: phase), in: fresh)
                askAtGate(fresh)
                return
            }
            if let scheduled = phase.scheduledFollowup, fresh.isDryRun {
                await continueDryRunInsteadOfWaiting(fresh, interval: scheduled.interval, nextPhaseId: scheduled.nextPhaseId)
                return
            }
            if let scheduled = phase.scheduledFollowup {
                let wakeAt = Date().addingTimeInterval(scheduled.interval)
                fresh.nextWakeAt = wakeAt
                fresh.currentPhaseId = scheduled.nextPhaseId
                fresh.status = .waitingScheduled
                fresh.blockingReason = Self.scheduledWaitReason(until: wakeAt, next: scheduled.nextPhaseId)
                upsert(fresh)
                let timer = Timer.scheduledTimer(withTimeInterval: scheduled.interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in await self?.handleScheduledWake(runId: runId, phase: scheduled.nextPhaseId) }
                }
                resumeTimers[runId] = timer
                WakeLog.shared.log("v2: scheduled run \(runId.uuidString.prefix(8)) to wake in \(Int(scheduled.interval))s for phase \(scheduled.nextPhaseId)")
                return
            }
            upsert(fresh)
            await advanceToNextPhase(runId: runId)

        case .branched:
            if let target = outcome.branchToPhaseId {
                fresh.currentPhaseId = target
                upsert(fresh)
                await executeFromCurrentPhase(runId: runId)
            } else {
                upsert(fresh)
                await advanceToNextPhase(runId: runId)
            }

        case .paused:
            fresh.status = .waitingForApproval
            fresh.blockingReason = outcome.blockingReason ?? "This is waiting for your OK."
            askAtGate(fresh)

        case .scheduled:
            // Action handled scheduling itself (e.g. scheduleResume action).
            if let t = outcome.scheduledFollowup, fresh.isDryRun {
                await continueDryRunInsteadOfWaiting(fresh, interval: t.interval, nextPhaseId: t.nextPhaseId)
            } else if let t = outcome.scheduledFollowup {
                fresh.nextWakeAt = Date().addingTimeInterval(t.interval)
                fresh.currentPhaseId = t.nextPhaseId
                fresh.status = .waitingScheduled
                fresh.blockingReason = Self.scheduledWaitReason(until: fresh.nextWakeAt!, next: t.nextPhaseId)
                upsert(fresh)
                let runIdLocal = runId
                let nextPhase = t.nextPhaseId
                let timer = Timer.scheduledTimer(withTimeInterval: t.interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in await self?.handleScheduledWake(runId: runIdLocal, phase: nextPhase) }
                }
                resumeTimers[runId] = timer
            } else {
                upsert(fresh)
            }

        case .failure:
            fresh.status = .failed
            fresh.lastError = outcome.log
            fresh.completedAt = Date()
            upsert(fresh)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(fresh)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId, userInfo: Self.runFacts(fresh))

        case .skipped:
            upsert(fresh)
            await advanceToNextPhase(runId: runId)

        case .running:
            // Defensive: an executor should NEVER return `.running`. The
            // `.running` case exists purely as the in-flight phaseHistory
            // placeholder written at executeFromCurrentPhase entry. If we
            // ever land here, an executor implementation is buggy. Treat as
            // a hard failure so the run doesn't pin in an inconsistent state.
            fresh.status = .failed
            fresh.lastError = "executor returned .running outcome from phase '\(phase.id)' - invalid (executors must return a terminal kind)"
            fresh.completedAt = Date()
            if let lastIdx = fresh.phaseHistory.indices.last {
                fresh.phaseHistory[lastIdx].outcome = .failure
                fresh.phaseHistory[lastIdx].endedAt = Date()
                fresh.phaseHistory[lastIdx].log = PhaseLogCopy.stoppedUnexpectedly
                fresh.phaseHistory[lastIdx].details = "internal error: executor returned .running"
            }
            upsert(fresh)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(fresh)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId, userInfo: Self.runFacts(fresh))
        }
    }

    // MARK: - What a person reads

    /// What a run stopped at `phase` says to the person before the words that
    /// answer it, as the executor and the engine write it. nil for a phase
    /// that does not wait on the person.
    static func waitingReason(at phase: CommandV2Definition.Phase, in run: CommandV2Run) -> String? {
        switch phase.action {
        case .userApprovalGate(let prompt, _): return CommandV2Executor.gatePrompt(prompt, in: run)
        case .walkthrough: return CommandV2Executor.gatePrompt(CommandV2Executor.walkthroughQuestion, in: run)
        default:
            return phase.userApprovalRequired
                ? CommandV2Executor.gatePrompt(approvalRequiredReason(at: phase), in: run) : nil
        }
    }

    /// A phase that asks nothing of its own but may not go on without an OK.
    /// Step names are written for the definition's author and can carry ids,
    /// so the person is not shown one.
    static func approvalRequiredReason(at phase: CommandV2Definition.Phase) -> String {
        "The last step is done and waits for your OK. Reply approve to go on."
    }

    /// What a run waiting on the clock says until it wakes.
    static func scheduledWaitReason(until wakeAt: Date, next nextPhaseId: String) -> String {
        "Waiting until \(formattedDate(wakeAt)), then it carries on."
    }

    /// Why a dry run ended at a phase it would visit again. The key a tester
    /// seeds to walk past it goes in the phase log, not here.
    static func dryRunStopMessage(at phase: CommandV2Definition.Phase) -> String {
        "The dry run stopped here: a real run would wait at this step for an answer from Apple or a device, and a dry run cannot get one."
    }

    /// Why a live run stopped once dry runs were turned on for this Mac.
    static let liveRunUnderDryRunMessage =
        "This run started for real before dry runs were turned on for this Mac, so I stopped it instead of letting it reach Apple or a device."

    // A dry run records the wait a real run would take and goes straight on,
    // so a week-long workflow can be walked end to end in seconds.
    private func continueDryRunInsteadOfWaiting(_ run: CommandV2Run, interval: TimeInterval, nextPhaseId: String) async {
        var run = run
        if let lastIdx = run.phaseHistory.indices.last {
            let next = definition(id: run.definitionId)?.phases.first { $0.id == nextPhaseId }?.displayName ?? "the next step"
            run.phaseHistory[lastIdx].log += "\n" + PhaseLogCopy.dryRunSkippedWait(interval, then: next)
        }
        run.currentPhaseId = nextPhaseId
        upsert(run)
        await executeFromCurrentPhase(runId: run.id)
    }

    private func advanceToNextPhase(runId: UUID) async {
        guard var run = run(id: runId) else { return }
        guard let def = definition(id: run.definitionId) else { return }
        guard let currentIdx = def.phases.firstIndex(where: { $0.id == run.currentPhaseId }) else { return }
        var nextIdx = currentIdx + 1
        switch def.phases[currentIdx].after {
        case .endRun?: nextIdx = def.phases.count
        case .continueAt(let target)?:
            // `start` refuses a definition whose target is unknown.
            nextIdx = def.phases.firstIndex(where: { $0.id == target }) ?? def.phases.count
        case nil: break
        }
        if nextIdx >= def.phases.count {
            run.status = .completed
            run.completedAt = Date()
            run.blockingReason = nil
            upsert(run)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(run)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId, userInfo: Self.runFacts(run))
            WakeLog.shared.log("v2: completed run \(runId.uuidString.prefix(8))")
            return
        }
        let nextPhase = def.phases[nextIdx]
        run.currentPhaseId = nextPhase.id
        upsert(run)
        // Phase transition broadcast - fire BEFORE executeFromCurrentPhase so
        // observers (notification dispatchers, the menu bar ribbon) see the
        // new phase before it starts executing. fromPhase/toPhase are 1-based
        // to match the spec doc's "phase N/9" numbering. Bag includes
        // commandId for filtering (the dispatcher only cares about
        // ship-ios-app milestones).
        NotificationCenter.default.post(
            name: .gruxCommandV2PhaseTransitioned,
            object: runId,
            userInfo: Self.runFacts(run).merging([
                "runId": runId,
                "fromPhase": currentIdx + 1,
                "toPhase": nextIdx + 1,
                "phaseName": nextPhase.displayName,
                "commandId": run.definitionId
            ]) { $1 }
        )
        await executeFromCurrentPhase(runId: runId)
    }

    private static func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }

    public enum EngineError: Error, LocalizedError {
        case unknownDefinition(String)
        case alreadyRunning(UUID, String)
        case invalidDefinition(String)
        public var errorDescription: String? {
            switch self {
            case .unknownDefinition(let id): return "Unknown definition '\(id)'"
            case .alreadyRunning(_, let msg): return msg
            case .invalidDefinition(let msg): return "Invalid definition: \(msg)"
            }
        }
    }
}

// MARK: - Executor (action dispatch)

@MainActor
enum CommandV2Executor {
    struct Outcome {
        var kind: CommandV2Run.PhaseRecord.Outcome
        var log: String
        /// Raw output, kept under the record's details label (SWEEP-12).
        var details: String? = nil
        var stateMutations: [String: JSONValue] = [:]
        var branchToPhaseId: String? = nil
        var blockingReason: String? = nil
        var scheduledFollowup: CommandV2Definition.ScheduledFollowup? = nil
    }

    static func execute(
        action: CommandV2Action,
        step: String = "this step",
        run: CommandV2Run,
        definition: CommandV2Definition,
        engine: CommandV2Engine
    ) async -> Outcome {
        switch action {
        case .noop:
            return .init(kind: .success, log: PhaseLogCopy.nothingToDo)

        case .builtin(let name, let args):
            return await runBuiltin(name: name, args: args, step: step, run: run, definition: definition, engine: engine)

        case .shell(let cmd, _):
            let resolved = interpolate(cmd, in: run)
            let r = await ShellRunner.runRaw(command: resolved)
            let raw = "[shell exit \(r.status)]\n\(r.truncated)"
            let log = PhaseLogCopy.command(step: step, exitCode: r.status)
            if r.status != 0 {
                return .init(kind: .failure, log: log, details: raw)
            }
            return .init(kind: .success, log: log, details: raw, stateMutations: ["last_shell_output": .string(r.stdout)])

        case .speak(let text, let cue):
            let resolved = speechText(text, in: run, definition: definition)
            await speakAndWait(resolved)
            if let cue = cue { await playAudioCue(cue, in: run) }
            return .init(kind: .success, log: PhaseLogCopy.said(resolved))

        case .setState(let key, let valueExpr):
            let v = resolveValueExpr(valueExpr, run: run)
            return .init(kind: .success, log: PhaseLogCopy.noted(v), stateMutations: [key: v])

        case .userApprovalGate(let prompt, _):
            let resolved = gatePrompt(prompt, in: run)
            await speakAndWait(resolved)
            return .init(
                kind: .paused,
                log: "Waiting for your answer. \(resolved)",
                blockingReason: resolved
            )

        case .branch(let cond, let ifTrue, let ifFalse):
            let result = evaluate(cond, run: run)
            let target = result ? ifTrue : ifFalse
            return .init(
                kind: .branched,
                log: PhaseLogCopy.next(stepName(target, in: definition)),
                branchToPhaseId: target
            )

        case .scheduleResume(let after, let phase):
            let scheduled = CommandV2Definition.ScheduledFollowup(
                nextPhaseId: phase, interval: after, interruptUserOnFire: false
            )
            return .init(
                kind: .scheduled,
                log: PhaseLogCopy.scheduled(after, then: stepName(phase, in: definition)),
                scheduledFollowup: scheduled
            )

        case .iosTool(let name, let input):
            let resolvedInput = input.mapValues { v -> JSONValue in
                if case .string(let s) = v { return .string(interpolate(s, in: run)) }
                return v
            }
            let result = await runIOSTool(name: name, input: resolvedInput, step: step, run: run)
            return result

        case .claudeAgent(let prompt, _, _):
            // V2.1: real claudeAgent dispatch via CommandV2AgentBridge → spawns
            // a SwarmWorker subprocess (claude --print --output-format stream-json
            // with subscription-only env scrubbed) and awaits its terminal text.
            let resolved = interpolate(prompt, in: run)
            let cwd = resolveProjectCwd(run: run)
            // TTL is dynamic by phase. The publish phase polls Apple's ASC
            // build-processing queue which routinely takes 15-45 min for a
            // brand-new app's first build, so 30 min is too tight. Bump to
            // 90 min for any phase that mentions altool/upload/publish in
            // the prompt. Default 30 min for everything else.
            let ttl: Int = {
                let lower = resolved.lowercased()
                if lower.contains("altool") || lower.contains("appstoreversion")
                    || lower.contains("polling") || lower.contains("processing")
                    || run.currentPhaseId.contains("publish") {
                    return 5400  // 90 min
                }
                return 1800
            }()
            let result: CommandV2AgentBridge.AgentResult
            if let stub = agentStubForTests {
                result = await stub([resolved], run)
            } else {
                result = await CommandV2AgentBridge.runSingleAgent(
                    prompt: resolved,
                    cwd: cwd,
                    model: "claude-sonnet-4-6",
                    ttlSeconds: ttl,
                    runId: run.id
                )
            }
            return .init(
                kind: result.success ? .success : .failure,
                log: PhaseLogCopy.agent(step: step, count: 1, ok: result.success, seconds: result.durationSec,
                                        cost: result.costUSD, needsSignIn: result.pausedForAuth || result.signInExpired,
                                        raw: result.text),
                details: "claudeAgent \(result.workerCount)w success=\(result.success) $\(String(format: "%.4f", result.costUSD)) \(Int(result.durationSec))s\n\(String(result.text.suffix(800)))",
                stateMutations: [
                    "last_agent_output": .string(result.text),
                    "last_agent_success": .bool(result.success),
                    "last_agent_cost_usd": .double(result.costUSD),
                    "last_agent_paused_for_auth": .bool(result.pausedForAuth)
                ]
            )

        case .claudeAgentSwarm(let prompts, _):
            // V2.1: real swarm dispatch via CommandV2AgentBridge → SwarmOrchestrator
            // with N parallel workers, each subprocess inherits OAuth/subscription
            // path. Awaits until all workers reach a terminal status.
            let resolved = prompts.map { interpolate($0, in: run) }
            let cwd = resolveProjectCwd(run: run)
            let result: CommandV2AgentBridge.AgentResult
            if let stub = agentStubForTests {
                result = await stub(resolved, run)
            } else {
                result = await CommandV2AgentBridge.runSwarm(
                    prompts: resolved,
                    cwd: cwd,
                    model: "claude-sonnet-4-6",
                    ttlSeconds: 1800,
                    runId: run.id,
                    title: "v2:\(run.definitionId):\(run.currentPhaseId)"
                )
            }
            return .init(
                kind: result.success ? .success : .failure,
                log: PhaseLogCopy.agent(step: step, count: max(result.workerCount, prompts.count), ok: result.success,
                                        seconds: result.durationSec, cost: result.costUSD,
                                        needsSignIn: result.pausedForAuth || result.signInExpired, raw: result.text),
                details: "claudeAgentSwarm \(result.workerCount)w success=\(result.success) $\(String(format: "%.4f", result.costUSD)) \(Int(result.durationSec))s\n\(String(result.text.suffix(800)))",
                stateMutations: [
                    "last_swarm_count": .int(result.workerCount),
                    "last_swarm_success": .bool(result.success),
                    "last_swarm_cost_usd": .double(result.costUSD),
                    "last_swarm_paused_for_auth": .bool(result.pausedForAuth),
                    "last_agent_output": .string(result.text)
                ]
            )

        case .interruptOnNextActive(let message, let cue):
            let resolved = interruptText(message, in: run, definition: definition)
            // V2.0: speak immediately as a fallback. Real "wait for active" lands in V2.1.
            await speakAndWait(resolved)
            if let cue = cue { await playAudioCue(cue, in: run) }
            return .init(kind: .success, log: PhaseLogCopy.said(resolved))

        case .walkthrough(let points):
            // V2.0: speak each point's title sequentially. Full chat-panel walkthrough lands in V2.1.
            var log = ""
            for p in points {
                let line = walkthroughLine(p, in: run)
                await speakAndWait(line)
                log += "• \(line)\n"
            }
            return .init(
                kind: .paused,
                log: log,
                blockingReason: gatePrompt(walkthroughQuestion, in: run)
            )
        }
    }

    /// What a run says once the walkthrough has been spoken. The one built-in
    /// walkthrough is the last stop before the App Store.
    static let walkthroughQuestion = "Ready to send it to the App Store? Reply ship it to go, or cancel the run in Workflows to stop."

    // MARK: - Dry run

    // Builtins that only read or write the run itself.
    static let dryRunSafeBuiltins: Set<String> = ["log", "echo"]

    // True only for a phase that changes nothing but the run: control flow,
    // state, and speech (which the silence switch still governs). Anything
    // else might reach Apple, a device, a shell, another app, an agent that
    // spends money, or the user's files, so a dry run records it instead.
    // Exhaustive on purpose: a new action kind must be sorted here to compile.
    static func changesNothingOutside(_ action: CommandV2Action) -> Bool {
        switch action {
        case .noop, .setState, .branch, .speak, .userApprovalGate,
             .scheduleResume, .interruptOnNextActive, .walkthrough:
            return true
        case .builtin(let name, _):
            return dryRunSafeBuiltins.contains(name)
        case .shell, .iosTool, .claudeAgent, .claudeAgentSwarm:
            return false
        }
    }

    /// A step's name as a person reads it, for a phase id.
    static func stepName(_ phaseId: String, in definition: CommandV2Definition) -> String {
        definition.phases.first { $0.id == phaseId }?.displayName ?? "the next step"
    }

    static func executeDry(
        action: CommandV2Action,
        step: String,
        run: CommandV2Run,
        definition: CommandV2Definition,
        engine: CommandV2Engine
    ) async -> Outcome {
        if changesNothingOutside(action) {
            return await execute(action: action, step: step, run: run, definition: definition, engine: engine)
        }
        // What the step would have been given, for tests and debugging only.
        let input: String
        switch action {
        case .shell(let cmd, _):
            input = "run shell: \(interpolate(cmd, in: run))"
        case .iosTool(let name, let args):
            let resolved = args.mapValues { v -> JSONValue in
                if case .string(let s) = v { return .string(interpolate(s, in: run)) }
                return v
            }
            let list = resolved.keys.sorted().map { key -> String in
                let value = resolved[key]!
                let json = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
                return "\(key)=\(value.stringValue ?? json ?? "\(value)")"
            }
            input = "call \(name)(\(list.joined(separator: ", ")))"
        case .claudeAgent(let prompt, _, _):
            input = "start a Claude agent: \(interpolate(prompt, in: run))"
        case .claudeAgentSwarm(let prompts, _):
            input = "start \(prompts.count) Claude agents: " + prompts.map { interpolate($0, in: run) }.joined(separator: "\n")
        case .builtin(let name, _):
            input = "run builtin \(name)"
        default:
            input = action.summary
        }
        engine.recordDryRunInput(input, run: run.id, phase: run.currentPhaseId)
        // A person reads this in Workflows: the step's own name, never its
        // prompt, command or tool id (SWEEP-12).
        return .init(kind: .success, log: PhaseLogCopy.dryRun(action, step: step))
    }

    // MARK: - Builtins

    private static func runBuiltin(
        name: String,
        args: [String: JSONValue],
        step: String,
        run: CommandV2Run,
        definition: CommandV2Definition,
        engine: CommandV2Engine
    ) async -> Outcome {
        switch name {
        case "log":
            let msg = args["message"]?.stringValue ?? "(no message)"
            WakeLog.shared.log("v2.builtin.log: \(interpolate(msg, in: run))")
            return .init(kind: .success, log: PhaseLogCopy.sentence(interpolate(msg, in: run)))

        case "v1.runMacro":
            guard let macroName = args["macroName"]?.stringValue else {
                return .init(kind: .failure, log: "No macro was named for \(PhaseLogCopy.quoted(step)).",
                             details: "v1.runMacro: missing macroName")
            }
            let result = await VoiceMacroRegistry.shared.run(name: macroName)
            return .init(kind: .success, log: "Ran your macro \(PhaseLogCopy.quoted(macroName)).",
                         details: "v1.runMacro(\(macroName)) → \(result)")

        case "echo":
            let text = args["text"]?.stringValue ?? ""
            return .init(kind: .success, log: "Repeated back: \"\(text)\"", stateMutations: ["last_echo": .string(text)])

        case "verify-ios-project-ready":
            // Replaces the legacy `brainstorm` claudeAgent - that 64s-of-
            // thinking phase was meant to extract a spec from chat, but the
            // sub-agent has no chat connection so the question never reached
            // the user (incident 2026-04-28). Brainstorming now happens in chat
            // BEFORE the workflow starts; by the time we reach this phase
            // the project either already exists (`ship <project>`) or was
            // just scaffolded into ~/Projects/GruxApps/<name> by the chat
            // assistant calling ios_scaffold. Either way, all this phase
            // needs to do is verify the project is on disk and has source.
            let rawProject = Self.interpolate(args["project"]?.stringValue ?? "", in: run)
            let projectPath: String = {
                if rawProject.hasPrefix("/") { return rawProject }
                let resolved = ProjectsResolver.resolve(project: rawProject)
                return resolved.isEmpty ? rawProject : resolved
            }()
            guard !projectPath.isEmpty else {
                return .init(
                    kind: .failure,
                    log: "No project was named for this run, so there is nothing to build.",
                    details: "verify-ios-project-ready: no project param. Workflow should have been started with parameters={\"project\":\"<name>\"}."
                )
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                return .init(
                    kind: .failure,
                    log: "The folder for this project does not exist yet, so there is nothing to build.",
                    details: "verify-ios-project-ready: project root '\(projectPath)' does not exist. Scaffold the app via ios_scaffold first."
                )
            }
            // Find the iOS project root. GruxApps-style apps have project.yml
            // or .xcodeproj at the top level. Some monorepos put the
            // iOS app under mobile/ios/. RN apps use ios/. Others may use
            // apps/ios/ or App/ios/. Walk common candidates and accept the
            // first that has a project.yml or .xcodeproj.
            let candidates = [
                projectPath,
                projectPath + "/mobile/ios",
                projectPath + "/ios",
                projectPath + "/apps/ios",
                projectPath + "/App/ios"
            ]
            var foundRoot: String? = nil
            var foundFlavor: String = ""
            for cand in candidates {
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: cand)) ?? []
                let hasXcodegen = FileManager.default.fileExists(atPath: cand + "/project.yml")
                let hasXcodeproj = kids.contains(where: { $0.hasSuffix(".xcodeproj") })
                if hasXcodegen { foundRoot = cand; foundFlavor = "project.yml"; break }
                if hasXcodeproj { foundRoot = cand; foundFlavor = ".xcodeproj"; break }
            }
            guard let iosRoot = foundRoot else {
                return .init(
                    kind: .failure,
                    log: "This project has no Xcode project to build yet.",
                    details: "verify-ios-project-ready: '\(projectPath)' has no project.yml/.xcodeproj at the top level or in mobile/ios, ios, apps/ios, App/ios. Not a buildable iOS project, scaffold it via ios_scaffold first."
                )
            }
            let summary = "verify-ios-project-ready: '\(projectPath)' ready (iOS root: '\(iosRoot)', flavor: \(foundFlavor)). Skipping brainstorm - handled in chat before workflow start."
            return .init(
                kind: .success,
                log: "The project is ready to build.",
                details: summary,
                stateMutations: [
                    "project_root": .string(projectPath),
                    "ios_project_root": .string(iosRoot),
                    "ios_project_flavor": .string(foundFlavor)
                ]
            )

        case "convention-audit":
            // Run the mobile convention audit (WCAG contrast, hit-targets,
            // privacy manifest, version sync, App Group usage, Siri brand-
            // leading phrases, Universal Links, Export Compliance, etc.)
            // against the project. This is INFORMATIONAL: the worker decides
            // what to do with the report.
            // Always returns success; never blocks. Failures live in the
            // markdown report for the next worker (or the user) to read.
            // projectDir from definition is typically "${param.project}"; after
            // interpolation it's the alias ("myapp"). Resolve to absolute
            // so the audit reads files from the actual project root, not a
            // relative path that resolves under Grux.app's CWD.
            let rawProjectDir = Self.interpolate(args["projectDir"]?.stringValue ?? "", in: run)
            let projectDir: String = {
                if rawProjectDir.hasPrefix("/") { return rawProjectDir }
                let resolved = ProjectsResolver.resolve(project: rawProjectDir)
                return resolved.isEmpty ? rawProjectDir : resolved
            }()
            // No built-in default: the conventions doc is a per-user file, so
            // the workflow supplies its path. Empty means "not configured" and
            // the audit still runs, recording the conventions version as
            // "missing" rather than failing.
            let conventionsPath = args["conventionsPath"]?.stringValue ?? ""
            let brand = Self.interpolate(args["brand"]?.stringValue ?? "", in: run)
            let report: ConventionAuditReport
            if brand.isEmpty {
                report = await ConventionAuditRunner.audit(
                    projectDir: projectDir,
                    conventionsPath: conventionsPath
                )
            } else {
                report = await ConventionAuditRunner.audit(
                    projectDir: projectDir,
                    conventionsPath: conventionsPath,
                    brand: brand
                )
            }
            let auditsDir = projectDir + "/audits"
            try? FileManager.default.createDirectory(atPath: auditsDir, withIntermediateDirectories: true)
            let mdPath = auditsDir + "/convention_audit.md"
            try? report.markdown().write(toFile: mdPath, atomically: true, encoding: String.Encoding.utf8)
            let blockers = report.checks.filter { !$0.passed && $0.severity == RuleCheck.Severity.blocker }.count
            let warnings = report.checks.filter { !$0.passed && $0.severity == RuleCheck.Severity.warning }.count
            let passed = report.checks.filter { $0.passed }.count
            let summary = "convention-audit: \(passed)/\(report.checks.count) passed (\(blockers) blockers, \(warnings) warnings) → \(mdPath)"
            let failedNote = [blockers == 1 ? "1 blocker" : "\(blockers) blockers",
                              warnings == 1 ? "1 warning" : "\(warnings) warnings"].joined(separator: " and ")
            return .init(
                kind: .success,
                log: "Checked the app against its conventions: \(passed) of \(report.checks.count) passed, with \(failedNote).",
                details: summary,
                stateMutations: [
                    "audit_report_path": .string(mdPath),
                    "audit_all_passed": .bool(report.allPassed),
                    "audit_blockers": .int(blockers),
                    "audit_warnings": .int(warnings)
                ]
            )

        case "capture-idea":
            // Persists the spoken/typed content to ~/.grux/ideas/<id>.md and
            // checks the companion's Lance index for near-duplicates. The follow-up
            // `speak-result` phase reads `idea_spoken_message` from state.
            let raw = Self.interpolate(args["content"]?.stringValue ?? "", in: run)
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return .init(kind: .failure, log: "There was no idea to save.", details: "capture-idea: empty content")
            }
            let result = await IdeaQueue.shared.capture(content: content)
            let spoken = IdeaQueue.spokenResult(result)
            var muts: [String: JSONValue] = [
                "idea_id": .string(result.id),
                "idea_file_path": .string(result.filePath),
                "idea_is_duplicate": .bool(result.isDuplicate),
                "idea_memory_available": .bool(result.memoryAvailable),
                "idea_spoken_message": .string(spoken)
            ]
            if let pid = result.priorId { muts["idea_prior_id"] = .string(pid) }
            if let pd = result.priorDate {
                muts["idea_prior_date"] = .string(ISO8601DateFormatter().string(from: pd))
            }
            if let pt = result.priorText { muts["idea_prior_text"] = .string(pt) }
            if let s = result.score { muts["idea_score"] = .double(s) }
            let log = result.isDuplicate
                ? "capture-idea: \(result.id) DUPLICATE of \(result.priorId ?? "?") score=\(String(format: "%.3f", result.score ?? 0))"
                : "capture-idea: \(result.id) (memory_available=\(result.memoryAvailable))"
            return .init(kind: .success,
                         log: result.isDuplicate ? "Saved the idea. It repeats one you had before." : "Saved the idea.",
                         details: log, stateMutations: muts)

        default:
            return .init(kind: .failure, log: PhaseLogCopy.cannotDo, details: "unknown builtin: '\(name)'")
        }
    }

    // MARK: - Helpers

    /// Interpolate `${state.key}` and `${param.key}` references inside a string.
    /// A dry run names a missing value instead of leaving a hole: it is
    /// usually one a skipped outside phase would have set. That phrase is for the
    /// log (which the Workflows drill-in shows) and agent prompts: speech never
    /// uses it (`speechText` says the step was skipped), and a missing
    /// parameter reads "your project" everywhere.
    ///
    /// `forPerson`: the words go to a person (a gate's question), so a missing
    /// parameter reads as what it stands for ("your project") and a missing
    /// value in a dry run as "unknown", with no key in parentheses.
    static func interpolate(_ text: String, in run: CommandV2Run, forPerson: Bool = false) -> String {
        let text = forPerson ? text : dryRunSentencesForMissingValues(text, in: run)
        var out = text
        // Match ${state.key} and ${param.key}
        guard let re = try? NSRegularExpression(pattern: "\\$\\{(state|param)\\.([a-zA-Z0-9_]+)\\}") else { return out }
        let matches = re.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for m in matches.reversed() {
            guard let scopeR = Range(m.range(at: 1), in: out),
                  let keyR = Range(m.range(at: 2), in: out),
                  let fullR = Range(m.range, in: out) else { continue }
            let scope = String(out[scopeR])
            let key = String(out[keyR])
            let v: String?
            if scope == "state" { v = run.state[key]?.stringValue }
            else if scope == "param" {
                v = forPerson ? CommandV2Engine.givenParameter(run.parameters[key]) : run.parameters[key]?.stringValue
            }
            else { v = nil }
            let missing: String
            if forPerson {
                missing = scope == "param" ? CommandV2Engine.unfilledParameter(key) : (run.isDryRun ? "unknown" : "")
            } else if scope == "param", run.isDryRun {
                // A dry run's own log names a missing project the way a
                // person would, not "unknown (dry run: no project)".
                missing = CommandV2Engine.unfilledParameter(key)
            } else {
                // The Workflows drill-in shows this log to the person.
                missing = run.isDryRun ? Self.dryRunMissingValue : ""
            }
            out.replaceSubrange(fullR, with: v ?? missing)
        }
        return out
    }

    /// What a dry run's gates lead with. A gate's words can assert an outside
    /// effect ("Safari is open at the right page") that the dry run only
    /// recorded, so the person is told before being asked to act on it.
    static let dryRunGateNote = "Dry run: the steps before this were only recorded, nothing was opened or changed."

    /// What an approval gate says and shows.
    static func gatePrompt(_ prompt: String, in run: CommandV2Run) -> String {
        let resolved = interpolate(prompt, in: run, forPerson: true)
        return run.isDryRun ? dryRunGateNote + " " + resolved : resolved
    }

    /// What a value a skipped step would have set reads as in a dry run's log,
    /// if a sentence around it is not replaced whole (a value not inside a
    /// sentence).
    static let dryRunMissingValue = "not known in a dry run"

    /// What a dry-run sentence needing a missing value names, by value.
    static let dryRunValueNames: [String: String] = [
        "screenshots_dir": "the folder with the raw simulator frames"
    ]

    /// In a dry run, each sentence that needs a state value no step set is
    /// said whole as what a real run would name ("Raw simulator frames live
    /// at <nothing>." reads "In a real run, this names the folder with the
    /// raw simulator frames."). The Workflows drill-in shows these logs.
    static func dryRunSentencesForMissingValues(_ text: String, in run: CommandV2Run) -> String {
        guard run.isDryRun,
              let re = try? NSRegularExpression(pattern: "\\$\\{state\\.([a-zA-Z0-9_]+)\\}") else { return text }
        var out = text
        while true {
            let ns = out as NSString
            guard let m = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
                .first(where: { run.state[ns.substring(with: $0.range(at: 1))]?.stringValue == nil }) else { break }
            let key = ns.substring(with: m.range(at: 1))
            // The sentence around it: back to the previous end of sentence or
            // line, on to the next. A ".", "!" or "?" ends a sentence only
            // before a space or the end of the text, so a URL, a version or a
            // decimal ("v1.2", "2.5x") stays inside it.
            func endsSentence(_ i: Int) -> Bool {
                guard i >= 0, i < ns.length else { return false }
                let c = ns.character(at: i)
                if c == 10 { return true }
                guard let u = UnicodeScalar(c), ".!?".unicodeScalars.contains(u) else { return false }
                guard i + 1 < ns.length, let next = UnicodeScalar(ns.character(at: i + 1)) else { return true }
                return CharacterSet.whitespacesAndNewlines.contains(next)
            }
            var start = m.range.location
            while start > 0, !endsSentence(start - 1) { start -= 1 }
            while start < m.range.location, ns.character(at: start) == 32 { start += 1 }
            var end = m.range.location + m.range.length
            while end < ns.length, !endsSentence(end) { end += 1 }
            if end < ns.length, ns.character(at: end) != 10 { end += 1 }
            let name = dryRunValueNames[key] ?? "a value an earlier step sets"
            out = ns.replacingCharacters(in: NSRange(location: start, length: end - start),
                                         with: "In a real run, this names \(name).")
        }
        return out
    }

    /// What a dry run's spoken lines lead with.
    static let dryRunSpeechLead = "Dry run, so nothing happened. A real run would say:"

    /// Every line `action` speaks, in order, as `execute` speaks them.
    static func spokenLines(for action: CommandV2Action, in run: CommandV2Run,
                            definition: CommandV2Definition) -> [String] {
        switch action {
        case .speak(let text, let cue):
            return [speechText(text, in: run, definition: definition)] + (cue.map { cueLines($0, in: run) } ?? [])
        case .interruptOnNextActive(let message, let cue):
            return [interruptText(message, in: run, definition: definition)] + (cue.map { cueLines($0, in: run) } ?? [])
        case .walkthrough(let points):
            return points.map { walkthroughLine($0, in: run) }
        case .userApprovalGate(let prompt, _):
            return [gatePrompt(prompt, in: run)]
        default:
            return []
        }
    }

    /// What an audio cue says aloud, if anything. The celebration cue claims
    /// a launch, so a dry run keeps it quiet; its line already says what a
    /// real run would celebrate.
    static func cueLines(_ cue: AudioCue, in run: CommandV2Run) -> [String] {
        cue.kind == .djKhaledAnotherOne && !run.isDryRun ? ["Anotha one!"] : []
    }

    /// What an interrupt-on-next-active phase says: the same rules as speech.
    static func interruptText(_ message: String, in run: CommandV2Run, definition: CommandV2Definition) -> String {
        speechText(message, in: run, definition: definition)
    }

    /// What a walkthrough point says: a question to the person, so it reads
    /// like its gate's text, dry-run note included.
    static func walkthroughLine(_ point: WalkthroughPoint, in run: CommandV2Run) -> String {
        gatePrompt("\(point.title): \(point.body)", in: run)
    }

    /// What a speak phase says. In a dry run a line made only of values that
    /// skipped phases would have set says so, instead of the bare "unknown"
    /// (capture-idea speaks nothing but `${state.idea_spoken_message}`).
    ///
    /// SWEEP-10: a dry run said "unknown is in Apple's review queue" and
    /// "good news, unknown is approved on the App Store" as if they had
    /// happened. A dry line is now led by the dry-run note and said as what
    /// a real run would say; a line that needs a value only a skipped step
    /// would set says that step was skipped; a missing project is "your
    /// project". Never "unknown".
    static func speechText(_ text: String, in run: CommandV2Run, definition: CommandV2Definition) -> String {
        guard run.isDryRun,
              let re = try? NSRegularExpression(pattern: "\\$\\{state\\.([a-zA-Z0-9_]+)\\}") else {
            return interpolate(text, in: run)
        }
        let ns = text as NSString
        let missingState = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).contains { m in
            run.state[ns.substring(with: m.range(at: 1))]?.stringValue == nil
        }
        if missingState {
            let name = CommandV2Engine.runName(definition.displayName, params: run.parameters)
            return "Dry run of \(name): the step that would say how it went was skipped."
        }
        return dryRunSpeechLead + " " + interpolate(text, in: run, forPerson: true)
    }

    // Resolve the cwd for a workflow run's spawned agents/swarms. Falls back
    // to a temp directory under v2-runs/<runId>/ when the run has no project
    // parameter (e.g. smoke tests, ad-hoc workflows) so the spawned `claude`
    // subprocess always has a writable directory to operate in.
    private static func resolveProjectCwd(run: CommandV2Run) -> String {
        if let project = run.parameters["project"]?.stringValue, !project.isEmpty,
           project != CommandV2Engine.unspecifiedParameter {
            let resolved = ProjectsResolver.resolve(project: project)
            if !resolved.isEmpty,
               FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        let scratch = Persistence.supportDir
            .appendingPathComponent("v2-runs", isDirectory: true)
            .appendingPathComponent(run.id.uuidString, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch.path
    }

    private static func resolveValueExpr(_ expr: ValueExpr, run: CommandV2Run) -> JSONValue {
        switch expr {
        case .literal(let v): return v
        case .fromAgentOutput: return run.state["last_agent_output"] ?? .null
        case .fromShellOutput: return run.state["last_shell_output"] ?? .null
        case .fromState(let k): return run.state[k] ?? .null
        case .fromIOSTool(let f): return run.state["last_ios_tool_\(f)"] ?? (run.state["last_ios_tool"] ?? .null)
        }
    }

    private static func evaluate(_ cond: ConditionExpr, run: CommandV2Run) -> Bool {
        switch cond {
        case .stateEquals(let k, let v):
            return run.state[k]?.stringValue == v
        case .stateMatches(let k, let pattern):
            guard let s = run.state[k]?.stringValue,
                  let re = try? NSRegularExpression(pattern: pattern) else { return false }
            let r = NSRange(s.startIndex..., in: s)
            return re.firstMatch(in: s, range: r) != nil
        case .ascSubmissionState(let target):
            return run.state["asc_state"]?.stringValue == target
        case .allOf(let xs): return xs.allSatisfy { evaluate($0, run: run) }
        case .anyOf(let xs): return xs.contains(where: { evaluate($0, run: run) })
        case .not(let x): return !evaluate(x, run: run)
        }
    }

    /// Stands in for IOSDispatcherV2 in tests, so a live run's App Store
    /// Connect answers can come from the test and never from Apple. Nil in
    /// the app. Set and cleared by the test that uses it.
    nonisolated(unsafe) static var iosToolStubForTests: ((String, [String: JSONValue], CommandV2Run) async -> IOSDispatcherV2Result)?

    /// Stands in for the agent layer in tests: gets the resolved prompts (one
    /// for a single agent) and answers as a finished, failed or timed-out
    /// agent would. Nil in the app. Set and cleared by the test that uses it.
    nonisolated(unsafe) static var agentStubForTests: (([String], CommandV2Run) async -> CommandV2AgentBridge.AgentResult)?

    private static func runIOSTool(name: String, input: [String: JSONValue], step: String, run: CommandV2Run) async -> Outcome {
        // The new tools added for V2 (ios_check_asc_status, ios_install_to_device,
        // ios_publish_to_appstore) live in IOSDispatcherV2 - a thin shim over
        // the App Store Connect scripts. This keeps GruxShellCore platform-pure;
        // adding REST/JWT clients to that module would explode its dependency
        // surface for one consumer.
        let result: IOSDispatcherV2Result
        if let stub = iosToolStubForTests {
            result = await stub(name, input, run)
        } else {
            result = await IOSDispatcherV2.dispatch(name: name, input: input, run: run)
        }
        var muts: [String: JSONValue] = ["last_ios_tool": .string(result.text)]
        for (k, v) in result.stateUpdates { muts["last_ios_tool_\(k)"] = v; muts[k] = v }
        return .init(
            kind: result.success ? .success : .failure,
            log: PhaseLogCopy.tool(step: step, ok: result.success, raw: result.text,
                                   appleState: result.stateUpdates["asc_state"]?.stringValue),
            details: result.text,
            stateMutations: muts
        )
    }

    private static func playAudioCue(_ cue: AudioCue, in run: CommandV2Run) async {
        if let delay = cue.postSpeakDelay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        switch cue.kind {
        case .djKhaledAnotherOne:
            // V2.0: speak placeholder. Real m4a playback lands when Resources/audio/celebrations/ is populated.
            for line in cueLines(cue, in: run) { await speakAndWait(line) }
        case .successChime:
            AudioOutput.chime([.glass], source: "CommandV2Engine.successChime")
        case .warningChime:
            AudioOutput.chime([.funk], source: "CommandV2Engine.warningChime")
        case .ttsTone:
            AudioOutput.chime([.tink], source: "CommandV2Engine.ttsTone")
        }
    }

    private static func speakAndWait(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let engine = SpeechEngine.shared
        let stream = AsyncStream<Void> { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: .gruxSpeechDidStop, object: nil, queue: .main
            ) { _ in continuation.yield() }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }
        engine.speak(trimmed)
        // Silenced speech never starts, so there is no end to wait for.
        if AudioOutput.isSilent { return }
        let startDeadline = Date().addingTimeInterval(1.5)
        while !engine.isSpeaking && Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let timeout = min(120.0, max(2.0, Double(trimmed.count) / 12.0 + 2.0))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream { return } }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}
