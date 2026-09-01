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
        let builtins: [CommandV2Definition] = [
            CommandV2Definitions.smokeHelloWorld(),
            CommandV2Definitions.checkASCStatus(),
            CommandV2Definitions.generateMarketingScreenshots(),
            CommandV2Definitions.shipExistingIOSApp(),
            CommandV2Definitions.shipIOSApp(),
            CommandV2Definitions.localizeApp(),
            CommandV2Definitions.testflightFeedback(),
            CommandV2Definitions.captureIdea()
        ]
        for d in builtins {
            if !definitions.contains(where: { $0.id == d.id }) {
                definitions.append(d)
            }
        }
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

    public func definition(id: String) -> CommandV2Definition? {
        definitions.first(where: { $0.id == id })
    }

    public func run(id: UUID) -> CommandV2Run? {
        activeRuns.first(where: { $0.id == id })
    }

    @discardableResult
    public func start(definitionId: String, params: [String: JSONValue] = [:], displayName: String? = nil) async -> Result<UUID, EngineError> {
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
                return .failure(.alreadyRunning(c.id, "There's already a ship run for \(project) in progress, currently in phase \(c.currentPhaseId)."))
            }
        }
        guard let firstPhase = def.phases.first else {
            return .failure(.invalidDefinition("\(def.id) has no phases"))
        }
        let run = CommandV2Run(
            definitionId: def.id,
            displayName: displayName ?? def.displayName,
            currentPhaseId: firstPhase.id,
            parameters: params
        )
        activeRuns.insert(run, at: 0)
        persist(run)
        NotificationCenter.default.post(name: .gruxCommandV2RunStarted, object: run.id)
        NotificationCenter.default.post(name: .gruxCommandV2RunsChanged, object: nil)
        WakeLog.shared.log("v2: started run \(run.id.uuidString.prefix(8)) of '\(def.id)'")
        Task { await self.executeFromCurrentPhase(runId: run.id) }
        return .success(run.id)
    }

    public func resume(_ runId: UUID, userReply: String? = nil) async {
        guard var run = run(id: runId) else { return }
        guard run.status == .waitingForApproval else {
            WakeLog.shared.log("v2: resume on \(runId.uuidString.prefix(8)) - not waiting for approval (status=\(run.status.rawValue))")
            return
        }
        if let reply = userReply, !reply.isEmpty {
            run.state["last_user_reply"] = .string(reply)
        }
        run.status = .running
        run.blockingReason = nil
        if let lastIdx = run.phaseHistory.indices.last {
            run.phaseHistory[lastIdx].endedAt = Date()
            run.phaseHistory[lastIdx].outcome = .success
            run.phaseHistory[lastIdx].log += "\n[resumed by user reply: \(userReply ?? "(none)")]"
        }
        upsert(run)
        await advanceToNextPhase(runId: runId)
    }

    public func cancel(_ runId: UUID) async {
        guard var run = run(id: runId) else { return }
        run.status = .canceled
        run.completedAt = Date()
        run.blockingReason = "canceled by user"
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
        let record = CommandV2Run.PhaseRecord(
            phaseId: phase.id,
            startedAt: Date(),
            outcome: .running,
            log: ""
        )
        run.phaseHistory.append(record)
        run.status = .running
        upsert(run)

        let outcome = await CommandV2Executor.execute(action: phase.action, run: run, definition: def, engine: self)

        // Re-fetch in case another flow mutated state.
        guard var fresh = self.run(id: runId) else { return }
        if let lastIdx = fresh.phaseHistory.indices.last {
            fresh.phaseHistory[lastIdx].endedAt = Date()
            fresh.phaseHistory[lastIdx].log = outcome.log
            fresh.phaseHistory[lastIdx].outcome = outcome.kind
        }
        // Apply state mutations from the action.
        for (k, v) in outcome.stateMutations { fresh.state[k] = v }

        switch outcome.kind {
        case .success:
            // Honor approval gates declared on the phase itself.
            if phase.userApprovalRequired && outcome.kind != .paused {
                fresh.status = .waitingForApproval
                fresh.blockingReason = "Awaiting user approval to continue past phase \(phase.id)"
                upsert(fresh)
                return
            }
            if let scheduled = phase.scheduledFollowup {
                let wakeAt = Date().addingTimeInterval(scheduled.interval)
                fresh.nextWakeAt = wakeAt
                fresh.currentPhaseId = scheduled.nextPhaseId
                fresh.status = .waitingScheduled
                fresh.blockingReason = "Waiting until \(formattedDate(wakeAt)) to continue at \(scheduled.nextPhaseId)"
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
            fresh.blockingReason = outcome.blockingReason ?? "Paused awaiting approval"
            upsert(fresh)

        case .scheduled:
            // Action handled scheduling itself (e.g. scheduleResume action).
            if let t = outcome.scheduledFollowup {
                fresh.nextWakeAt = Date().addingTimeInterval(t.interval)
                fresh.currentPhaseId = t.nextPhaseId
                fresh.status = .waitingScheduled
                fresh.blockingReason = "Waiting until \(formattedDate(fresh.nextWakeAt!)) → \(t.nextPhaseId)"
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
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId)

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
                fresh.phaseHistory[lastIdx].log = "internal error: executor returned .running"
            }
            upsert(fresh)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(fresh)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId)
        }
    }

    private func advanceToNextPhase(runId: UUID) async {
        guard var run = run(id: runId) else { return }
        guard let def = definition(id: run.definitionId) else { return }
        guard let currentIdx = def.phases.firstIndex(where: { $0.id == run.currentPhaseId }) else { return }
        let nextIdx = currentIdx + 1
        if nextIdx >= def.phases.count {
            run.status = .completed
            run.completedAt = Date()
            run.blockingReason = nil
            upsert(run)
            activeRuns.removeAll(where: { $0.id == runId })
            archiveTerminalRun(run)
            NotificationCenter.default.post(name: .gruxCommandV2RunFinished, object: runId)
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
            userInfo: [
                "runId": runId,
                "fromPhase": currentIdx + 1,
                "toPhase": nextIdx + 1,
                "phaseName": nextPhase.displayName,
                "commandId": run.definitionId
            ]
        )
        await executeFromCurrentPhase(runId: runId)
    }

    private func formattedDate(_ d: Date) -> String {
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
        var stateMutations: [String: JSONValue] = [:]
        var branchToPhaseId: String? = nil
        var blockingReason: String? = nil
        var scheduledFollowup: CommandV2Definition.ScheduledFollowup? = nil
    }

    static func execute(
        action: CommandV2Action,
        run: CommandV2Run,
        definition: CommandV2Definition,
        engine: CommandV2Engine
    ) async -> Outcome {
        switch action {
        case .noop:
            return .init(kind: .success, log: "noop")

        case .builtin(let name, let args):
            return await runBuiltin(name: name, args: args, run: run, definition: definition, engine: engine)

        case .shell(let cmd, _):
            let resolved = interpolate(cmd, in: run)
            let r = await ShellRunner.runRaw(command: resolved)
            let log = "[shell exit \(r.status)]\n\(r.truncated)"
            if r.status != 0 {
                return .init(kind: .failure, log: log)
            }
            return .init(kind: .success, log: log, stateMutations: ["last_shell_output": .string(r.stdout)])

        case .speak(let text, let cue):
            let resolved = interpolate(text, in: run)
            await speakAndWait(resolved)
            if let cue = cue { await playAudioCue(cue) }
            return .init(kind: .success, log: "spoke: \(resolved.prefix(80))")

        case .setState(let key, let valueExpr):
            let v = resolveValueExpr(valueExpr, run: run)
            return .init(kind: .success, log: "setState \(key) = \(v)", stateMutations: [key: v])

        case .userApprovalGate(let prompt, _):
            let resolved = interpolate(prompt, in: run)
            await speakAndWait(resolved)
            return .init(
                kind: .paused,
                log: "awaiting user approval - \(resolved)",
                blockingReason: resolved
            )

        case .branch(let cond, let ifTrue, let ifFalse):
            let result = evaluate(cond, run: run)
            let target = result ? ifTrue : ifFalse
            return .init(
                kind: .branched,
                log: "branch evaluated to \(result) → \(target)",
                branchToPhaseId: target
            )

        case .scheduleResume(let after, let phase):
            let scheduled = CommandV2Definition.ScheduledFollowup(
                nextPhaseId: phase, interval: after, interruptUserOnFire: false
            )
            return .init(
                kind: .scheduled,
                log: "scheduled resume → \(phase) in \(Int(after))s",
                scheduledFollowup: scheduled
            )

        case .iosTool(let name, let input):
            let resolvedInput = input.mapValues { v -> JSONValue in
                if case .string(let s) = v { return .string(interpolate(s, in: run)) }
                return v
            }
            let result = await runIOSTool(name: name, input: resolvedInput, run: run)
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
            let result = await CommandV2AgentBridge.runSingleAgent(
                prompt: resolved,
                cwd: cwd,
                model: "claude-sonnet-4-6",
                ttlSeconds: ttl,
                runId: run.id
            )
            return .init(
                kind: result.success ? .success : .failure,
                log: "claudeAgent \(result.workerCount)w success=\(result.success) $\(String(format: "%.4f", result.costUSD)) \(Int(result.durationSec))s\n\(String(result.text.suffix(800)))",
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
            let result = await CommandV2AgentBridge.runSwarm(
                prompts: resolved,
                cwd: cwd,
                model: "claude-sonnet-4-6",
                ttlSeconds: 1800,
                runId: run.id,
                title: "v2:\(run.definitionId):\(run.currentPhaseId)"
            )
            return .init(
                kind: result.success ? .success : .failure,
                log: "claudeAgentSwarm \(result.workerCount)w success=\(result.success) $\(String(format: "%.4f", result.costUSD)) \(Int(result.durationSec))s\n\(String(result.text.suffix(800)))",
                stateMutations: [
                    "last_swarm_count": .int(result.workerCount),
                    "last_swarm_success": .bool(result.success),
                    "last_swarm_cost_usd": .double(result.costUSD),
                    "last_swarm_paused_for_auth": .bool(result.pausedForAuth),
                    "last_agent_output": .string(result.text)
                ]
            )

        case .interruptOnNextActive(let message, let cue):
            let resolved = interpolate(message, in: run)
            // V2.0: speak immediately as a fallback. Real "wait for active" lands in V2.1.
            await speakAndWait(resolved)
            if let cue = cue { await playAudioCue(cue) }
            return .init(kind: .success, log: "interruptOnNextActive (immediate-fallback): \(resolved)")

        case .walkthrough(let points):
            // V2.0: speak each point's title sequentially. Full chat-panel walkthrough lands in V2.1.
            var log = ""
            for p in points {
                let line = interpolate("\(p.title): \(p.body)", in: run)
                await speakAndWait(line)
                log += "• \(line)\n"
            }
            return .init(
                kind: .paused,
                log: log,
                blockingReason: "Walkthrough delivered. Reply 'ship it' to continue."
            )
        }
    }

    // MARK: - Builtins

    private static func runBuiltin(
        name: String,
        args: [String: JSONValue],
        run: CommandV2Run,
        definition: CommandV2Definition,
        engine: CommandV2Engine
    ) async -> Outcome {
        switch name {
        case "log":
            let msg = args["message"]?.stringValue ?? "(no message)"
            WakeLog.shared.log("v2.builtin.log: \(interpolate(msg, in: run))")
            return .init(kind: .success, log: msg)

        case "v1.runMacro":
            guard let macroName = args["macroName"]?.stringValue else {
                return .init(kind: .failure, log: "v1.runMacro: missing macroName")
            }
            let result = await VoiceMacroRegistry.shared.run(name: macroName)
            return .init(kind: .success, log: "v1.runMacro(\(macroName)) → \(result)")

        case "echo":
            let text = args["text"]?.stringValue ?? ""
            return .init(kind: .success, log: text, stateMutations: ["last_echo": .string(text)])

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
                    log: "verify-ios-project-ready: no project param. Workflow should have been started with parameters={\"project\":\"<name>\"}."
                )
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                return .init(
                    kind: .failure,
                    log: "verify-ios-project-ready: project root '\(projectPath)' does not exist. Scaffold the app via ios_scaffold first."
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
                    log: "verify-ios-project-ready: '\(projectPath)' has no project.yml/.xcodeproj at the top level or in mobile/ios, ios, apps/ios, App/ios. Not a buildable iOS project - scaffold it via ios_scaffold first."
                )
            }
            let summary = "verify-ios-project-ready: '\(projectPath)' ready (iOS root: '\(iosRoot)', flavor: \(foundFlavor)). Skipping brainstorm - handled in chat before workflow start."
            return .init(
                kind: .success,
                log: summary,
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
            return .init(
                kind: .success,
                log: summary,
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
                return .init(kind: .failure, log: "capture-idea: empty content")
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
            return .init(kind: .success, log: log, stateMutations: muts)

        default:
            return .init(kind: .failure, log: "unknown builtin: '\(name)'")
        }
    }

    // MARK: - Helpers

    /// Interpolate `${state.key}` and `${param.key}` references inside a string.
    private static func interpolate(_ text: String, in run: CommandV2Run) -> String {
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
            else if scope == "param" { v = run.parameters[key]?.stringValue }
            else { v = nil }
            out.replaceSubrange(fullR, with: v ?? "")
        }
        return out
    }

    // Resolve the cwd for a workflow run's spawned agents/swarms. Falls back
    // to a temp directory under v2-runs/<runId>/ when the run has no project
    // parameter (e.g. smoke tests, ad-hoc workflows) so the spawned `claude`
    // subprocess always has a writable directory to operate in.
    private static func resolveProjectCwd(run: CommandV2Run) -> String {
        if let project = run.parameters["project"]?.stringValue, !project.isEmpty,
           project != "(unspecified)" {
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

    private static func runIOSTool(name: String, input: [String: JSONValue], run: CommandV2Run) async -> Outcome {
        // The new tools added for V2 (ios_check_asc_status, ios_install_to_device,
        // ios_publish_to_appstore) live in IOSDispatcherV2 - a thin shim over
        // the App Store Connect scripts. This keeps GruxShellCore platform-pure;
        // adding REST/JWT clients to that module would explode its dependency
        // surface for one consumer.
        let result = await IOSDispatcherV2.dispatch(name: name, input: input, run: run)
        var muts: [String: JSONValue] = ["last_ios_tool": .string(result.text)]
        for (k, v) in result.stateUpdates { muts["last_ios_tool_\(k)"] = v; muts[k] = v }
        return .init(
            kind: result.success ? .success : .failure,
            log: result.text,
            stateMutations: muts
        )
    }

    private static func playAudioCue(_ cue: AudioCue) async {
        if let delay = cue.postSpeakDelay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        switch cue.kind {
        case .djKhaledAnotherOne:
            // V2.0: speak placeholder. Real m4a playback lands when Resources/audio/celebrations/ is populated.
            await speakAndWait("Anotha one!")
        case .successChime:
            NSSound(named: NSSound.Name("Glass"))?.play()
        case .warningChime:
            NSSound(named: NSSound.Name("Funk"))?.play()
        case .ttsTone:
            NSSound(named: NSSound.Name("Tink"))?.play()
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
