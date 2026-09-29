import Foundation

// MARK: - JSONValue (lightweight Any-Codable)
//
// Swift has no native `AnyCodable`. We wrap a JSON-shaped value so the
// command engine can serialize state dictionaries (`[String: JSONValue]`)
// and parameter blobs without dragging in a dependency. Supports all the
// primitive shapes the workflow needs: strings, numbers, bools, arrays,
// nested dicts, and null.
public enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSONValue unrecognized")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience: lift a raw Any into JSONValue for state writes from
    // call sites that already have heterogeneous dictionaries (e.g. iOS
    // dispatcher results decoded as `[String: Any]`).
    public init(any: Any?) {
        guard let any = any else { self = .null; return }
        if let b = any as? Bool { self = .bool(b); return }
        if let i = any as? Int { self = .int(i); return }
        if let d = any as? Double { self = .double(d); return }
        if let s = any as? String { self = .string(s); return }
        if let a = any as? [Any] { self = .array(a.map { JSONValue(any: $0) }); return }
        if let o = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k] = JSONValue(any: v) }
            self = .object(out); return
        }
        self = .string(String(describing: any))
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        if case .int(let i) = self { return String(i) }
        if case .double(let d) = self { return String(d) }
        if case .bool(let b) = self { return String(b) }
        return nil
    }
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        if case .string(let s) = self { return Int(s) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        if case .string(let s) = self { return Bool(s) }
        return nil
    }
}

// Interpolating a value (run logs, the Workflows drill-in) prints what it
// holds: a scalar as itself, a list or object as JSON. Never the Swift case.
extension JSONValue: CustomStringConvertible {
    public var description: String {
        if let s = stringValue { return s }
        if case .null = self { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

// MARK: - Definition

public struct CommandV2Definition: Codable, Identifiable, Sendable, Hashable {
    public let id: String                  // stable, e.g. "ship-ios-app"
    public let displayName: String
    public let voiceTriggers: [String]
    public let description: String
    public let category: Category
    public let parameters: [Parameter]
    public let phases: [Phase]

    public enum Category: String, Codable, Sendable, Hashable, CaseIterable {
        case ship, observe, develop, lifestyle, system
    }

    public struct Parameter: Codable, Sendable, Hashable {
        public let name: String
        public let kind: Kind
        public let prompt: String
        public let choices: [String]?
        public enum Kind: String, Codable, Sendable, Hashable {
            case projectPath, freeText, choice, secret
        }
        public init(name: String, kind: Kind, prompt: String, choices: [String]? = nil) {
            self.name = name; self.kind = kind; self.prompt = prompt; self.choices = choices
        }
    }

    public struct Phase: Codable, Sendable, Hashable {
        public let id: String
        public let displayName: String
        public let action: CommandV2Action
        public let userApprovalRequired: Bool
        public let scheduledFollowup: ScheduledFollowup?
        /// Where the run goes once this phase succeeds. nil means the next
        /// phase in the list, which a branch arm may not rely on: an arm
        /// that falls into its sibling arm runs both (see `structuralProblems`).
        public let after: After?

        public init(
            id: String,
            displayName: String,
            action: CommandV2Action,
            userApprovalRequired: Bool = false,
            scheduledFollowup: ScheduledFollowup? = nil,
            after: After? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.action = action
            self.userApprovalRequired = userApprovalRequired
            self.scheduledFollowup = scheduledFollowup
            self.after = after
        }
    }

    public enum After: Codable, Sendable, Hashable {
        case endRun
        case continueAt(String)
    }

    /// What is wrong with the shape of this definition, in words. A definition
    /// with any problem does not start. Beyond unknown targets, this refuses
    /// the fall-through that once let testflight-feedback's `fix` arm run on
    /// into the App Store submit: a phase that would slide into a phase some
    /// branch jumps to must say `.endRun` or `.continueAt(...)` instead.
    public func structuralProblems() -> [String] {
        let ids = Set(phases.map(\.id))
        var problems: [String] = []
        var branchTargets = Set<String>()
        for phase in phases {
            if case .branch(_, let ifTrue, let ifFalse) = phase.action {
                for target in [ifTrue, ifFalse] {
                    if ids.contains(target) { branchTargets.insert(target) }
                    else { problems.append("phase \(phase.id) branches to unknown phase \(target)") }
                }
            }
            if case .continueAt(let target) = phase.after, !ids.contains(target) {
                problems.append("phase \(phase.id) continues at unknown phase \(target)")
            }
            if let followup = phase.scheduledFollowup, !ids.contains(followup.nextPhaseId) {
                problems.append("phase \(phase.id) resumes at unknown phase \(followup.nextPhaseId)")
            }
        }
        for (phase, next) in zip(phases, phases.dropFirst()) where branchTargets.contains(next.id) {
            if case .branch = phase.action { continue }
            if phase.after != nil || phase.scheduledFollowup != nil { continue }
            problems.append("phase \(phase.id) falls through into \(next.id), which a branch jumps to; say .endRun or .continueAt(\"\(next.id)\")")
        }
        return problems
    }

    public struct ScheduledFollowup: Codable, Sendable, Hashable {
        public let nextPhaseId: String
        public let interval: TimeInterval
        public let interruptUserOnFire: Bool
        public init(nextPhaseId: String, interval: TimeInterval, interruptUserOnFire: Bool = false) {
            self.nextPhaseId = nextPhaseId
            self.interval = interval
            self.interruptUserOnFire = interruptUserOnFire
        }
    }

    public init(
        id: String,
        displayName: String,
        voiceTriggers: [String],
        description: String,
        category: Category,
        parameters: [Parameter] = [],
        phases: [Phase]
    ) {
        self.id = id
        self.displayName = displayName
        self.voiceTriggers = voiceTriggers
        self.description = description
        self.category = category
        self.parameters = parameters
        self.phases = phases
    }
}

// MARK: - Action (what each phase DOES)

public indirect enum CommandV2Action: Codable, Sendable, Hashable {
    case builtin(name: String, args: [String: JSONValue])
    case shell(command: String, captureOutput: Bool)
    case iosTool(name: String, input: [String: JSONValue])
    case claudeAgent(systemPrompt: String, tools: [String], maxTokens: Int?)
    case claudeAgentSwarm(prompts: [String], sharedTools: [String])
    case userApprovalGate(prompt: String, expectedReplies: [String]?)
    case branch(condition: ConditionExpr, ifTrue: String, ifFalse: String)
    case speak(text: String, audioCueAfter: AudioCue?)
    case scheduleResume(after: TimeInterval, atPhase: String)
    case interruptOnNextActive(message: String, audioCue: AudioCue?)
    case walkthrough(points: [WalkthroughPoint])
    case setState(key: String, valueExpr: ValueExpr)
    case noop

    // Codable: tagged-union shape `{ "kind": "...", ...payload }`
    private enum Kind: String, Codable {
        case builtin, shell, iosTool, claudeAgent, claudeAgentSwarm,
             userApprovalGate, branch, speak, scheduleResume,
             interruptOnNextActive, walkthrough, setState, noop
    }
    private enum CodingKeys: String, CodingKey {
        case kind, name, args, command, captureOutput, input, systemPrompt, tools,
             maxTokens, prompts, sharedTools, prompt, expectedReplies,
             condition, ifTrue, ifFalse, text, audioCueAfter, after, atPhase,
             message, audioCue, points, key, valueExpr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .builtin:
            self = .builtin(
                name: try c.decode(String.self, forKey: .name),
                args: try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
            )
        case .shell:
            self = .shell(
                command: try c.decode(String.self, forKey: .command),
                captureOutput: try c.decodeIfPresent(Bool.self, forKey: .captureOutput) ?? true
            )
        case .iosTool:
            self = .iosTool(
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
            )
        case .claudeAgent:
            self = .claudeAgent(
                systemPrompt: try c.decode(String.self, forKey: .systemPrompt),
                tools: try c.decodeIfPresent([String].self, forKey: .tools) ?? [],
                maxTokens: try c.decodeIfPresent(Int.self, forKey: .maxTokens)
            )
        case .claudeAgentSwarm:
            self = .claudeAgentSwarm(
                prompts: try c.decode([String].self, forKey: .prompts),
                sharedTools: try c.decodeIfPresent([String].self, forKey: .sharedTools) ?? []
            )
        case .userApprovalGate:
            self = .userApprovalGate(
                prompt: try c.decode(String.self, forKey: .prompt),
                expectedReplies: try c.decodeIfPresent([String].self, forKey: .expectedReplies)
            )
        case .branch:
            self = .branch(
                condition: try c.decode(ConditionExpr.self, forKey: .condition),
                ifTrue: try c.decode(String.self, forKey: .ifTrue),
                ifFalse: try c.decode(String.self, forKey: .ifFalse)
            )
        case .speak:
            self = .speak(
                text: try c.decode(String.self, forKey: .text),
                audioCueAfter: try c.decodeIfPresent(AudioCue.self, forKey: .audioCueAfter)
            )
        case .scheduleResume:
            self = .scheduleResume(
                after: try c.decode(TimeInterval.self, forKey: .after),
                atPhase: try c.decode(String.self, forKey: .atPhase)
            )
        case .interruptOnNextActive:
            self = .interruptOnNextActive(
                message: try c.decode(String.self, forKey: .message),
                audioCue: try c.decodeIfPresent(AudioCue.self, forKey: .audioCue)
            )
        case .walkthrough:
            self = .walkthrough(points: try c.decode([WalkthroughPoint].self, forKey: .points))
        case .setState:
            self = .setState(
                key: try c.decode(String.self, forKey: .key),
                valueExpr: try c.decode(ValueExpr.self, forKey: .valueExpr)
            )
        case .noop:
            self = .noop
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let n, let args):
            try c.encode(Kind.builtin, forKey: .kind)
            try c.encode(n, forKey: .name)
            try c.encode(args, forKey: .args)
        case .shell(let cmd, let cap):
            try c.encode(Kind.shell, forKey: .kind)
            try c.encode(cmd, forKey: .command)
            try c.encode(cap, forKey: .captureOutput)
        case .iosTool(let n, let i):
            try c.encode(Kind.iosTool, forKey: .kind)
            try c.encode(n, forKey: .name)
            try c.encode(i, forKey: .input)
        case .claudeAgent(let sp, let t, let mt):
            try c.encode(Kind.claudeAgent, forKey: .kind)
            try c.encode(sp, forKey: .systemPrompt)
            try c.encode(t, forKey: .tools)
            try c.encodeIfPresent(mt, forKey: .maxTokens)
        case .claudeAgentSwarm(let ps, let t):
            try c.encode(Kind.claudeAgentSwarm, forKey: .kind)
            try c.encode(ps, forKey: .prompts)
            try c.encode(t, forKey: .sharedTools)
        case .userApprovalGate(let p, let er):
            try c.encode(Kind.userApprovalGate, forKey: .kind)
            try c.encode(p, forKey: .prompt)
            try c.encodeIfPresent(er, forKey: .expectedReplies)
        case .branch(let cond, let it, let ifs):
            try c.encode(Kind.branch, forKey: .kind)
            try c.encode(cond, forKey: .condition)
            try c.encode(it, forKey: .ifTrue)
            try c.encode(ifs, forKey: .ifFalse)
        case .speak(let t, let cue):
            try c.encode(Kind.speak, forKey: .kind)
            try c.encode(t, forKey: .text)
            try c.encodeIfPresent(cue, forKey: .audioCueAfter)
        case .scheduleResume(let a, let p):
            try c.encode(Kind.scheduleResume, forKey: .kind)
            try c.encode(a, forKey: .after)
            try c.encode(p, forKey: .atPhase)
        case .interruptOnNextActive(let m, let cue):
            try c.encode(Kind.interruptOnNextActive, forKey: .kind)
            try c.encode(m, forKey: .message)
            try c.encodeIfPresent(cue, forKey: .audioCue)
        case .walkthrough(let pts):
            try c.encode(Kind.walkthrough, forKey: .kind)
            try c.encode(pts, forKey: .points)
        case .setState(let k, let v):
            try c.encode(Kind.setState, forKey: .kind)
            try c.encode(k, forKey: .key)
            try c.encode(v, forKey: .valueExpr)
        case .noop:
            try c.encode(Kind.noop, forKey: .kind)
        }
    }

    public var summary: String {
        switch self {
        case .builtin(let n, _): return "builtin → \(n)"
        case .shell(let c, _):
            let one = c.split(separator: "\n").first.map(String.init) ?? c
            return "shell → \(one)"
        case .iosTool(let n, _): return "iosTool → \(n)"
        case .claudeAgent: return "claudeAgent"
        case .claudeAgentSwarm(let ps, _): return "claudeAgentSwarm × \(ps.count)"
        case .userApprovalGate(let p, _): return "approvalGate → \(p.prefix(40))…"
        case .branch(_, let t, let f): return "branch → if true \(t), else \(f)"
        case .speak(let t, _): return "speak → \(t.prefix(40))…"
        case .scheduleResume(let a, let p): return "scheduleResume → +\(Int(a))s → \(p)"
        case .interruptOnNextActive(let m, _): return "interruptOnNextActive → \(m.prefix(40))…"
        case .walkthrough(let pts): return "walkthrough × \(pts.count)"
        case .setState(let k, _): return "setState → \(k)"
        case .noop: return "noop"
        }
    }
}

public struct AudioCue: Codable, Sendable, Hashable {
    public let kind: Kind
    public let postSpeakDelay: TimeInterval?
    public enum Kind: String, Codable, Sendable, Hashable {
        case djKhaledAnotherOne, successChime, warningChime, ttsTone
    }
    public init(kind: Kind, postSpeakDelay: TimeInterval? = 0.4) {
        self.kind = kind
        self.postSpeakDelay = postSpeakDelay
    }
}

public struct WalkthroughPoint: Codable, Sendable, Hashable {
    public let title: String
    public let body: String
    public let demoAction: CommandV2Action?
    public init(title: String, body: String, demoAction: CommandV2Action? = nil) {
        self.title = title; self.body = body; self.demoAction = demoAction
    }
}

// MARK: - Conditions

public indirect enum ConditionExpr: Codable, Sendable, Hashable {
    case stateEquals(key: String, value: String)
    case stateMatches(key: String, regex: String)
    case ascSubmissionState(equals: String)
    case allOf([ConditionExpr])
    case anyOf([ConditionExpr])
    case not(ConditionExpr)

    private enum Kind: String, Codable { case stateEquals, stateMatches, ascSubmissionState, allOf, anyOf, not }
    private enum CodingKeys: String, CodingKey { case kind, key, value, regex, equals, conditions, condition }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .stateEquals:
            self = .stateEquals(
                key: try c.decode(String.self, forKey: .key),
                value: try c.decode(String.self, forKey: .value)
            )
        case .stateMatches:
            self = .stateMatches(
                key: try c.decode(String.self, forKey: .key),
                regex: try c.decode(String.self, forKey: .regex)
            )
        case .ascSubmissionState:
            self = .ascSubmissionState(equals: try c.decode(String.self, forKey: .equals))
        case .allOf:
            self = .allOf(try c.decode([ConditionExpr].self, forKey: .conditions))
        case .anyOf:
            self = .anyOf(try c.decode([ConditionExpr].self, forKey: .conditions))
        case .not:
            self = .not(try c.decode(ConditionExpr.self, forKey: .condition))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stateEquals(let k, let v):
            try c.encode(Kind.stateEquals, forKey: .kind)
            try c.encode(k, forKey: .key); try c.encode(v, forKey: .value)
        case .stateMatches(let k, let r):
            try c.encode(Kind.stateMatches, forKey: .kind)
            try c.encode(k, forKey: .key); try c.encode(r, forKey: .regex)
        case .ascSubmissionState(let e):
            try c.encode(Kind.ascSubmissionState, forKey: .kind)
            try c.encode(e, forKey: .equals)
        case .allOf(let xs):
            try c.encode(Kind.allOf, forKey: .kind)
            try c.encode(xs, forKey: .conditions)
        case .anyOf(let xs):
            try c.encode(Kind.anyOf, forKey: .kind)
            try c.encode(xs, forKey: .conditions)
        case .not(let x):
            try c.encode(Kind.not, forKey: .kind)
            try c.encode(x, forKey: .condition)
        }
    }
}

// MARK: - ValueExpr

public enum ValueExpr: Codable, Sendable, Hashable {
    case literal(JSONValue)
    case fromAgentOutput
    case fromShellOutput
    case fromState(key: String)
    case fromIOSTool(field: String)

    private enum Kind: String, Codable { case literal, fromAgentOutput, fromShellOutput, fromState, fromIOSTool }
    private enum CodingKeys: String, CodingKey { case kind, value, key, field }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .literal:
            self = .literal(try c.decode(JSONValue.self, forKey: .value))
        case .fromAgentOutput: self = .fromAgentOutput
        case .fromShellOutput: self = .fromShellOutput
        case .fromState:
            self = .fromState(key: try c.decode(String.self, forKey: .key))
        case .fromIOSTool:
            self = .fromIOSTool(field: try c.decode(String.self, forKey: .field))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let v):
            try c.encode(Kind.literal, forKey: .kind); try c.encode(v, forKey: .value)
        case .fromAgentOutput: try c.encode(Kind.fromAgentOutput, forKey: .kind)
        case .fromShellOutput: try c.encode(Kind.fromShellOutput, forKey: .kind)
        case .fromState(let k):
            try c.encode(Kind.fromState, forKey: .kind); try c.encode(k, forKey: .key)
        case .fromIOSTool(let f):
            try c.encode(Kind.fromIOSTool, forKey: .kind); try c.encode(f, forKey: .field)
        }
    }
}

// MARK: - Run (executable instance)

public struct CommandV2Run: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let definitionId: String
    public var displayName: String
    public var startedAt: Date
    public var completedAt: Date?
    public var currentPhaseId: String
    public var status: Status {
        didSet { if status != .waitingForApproval { gateQuestion = nil; gateAskedAt = nil; gateReaskedAt = nil } }
    }
    public var parameters: [String: JSONValue]
    public var state: [String: JSONValue]
    public var phaseHistory: [PhaseRecord]
    public var blockingReason: String?
    public var nextWakeAt: Date?
    public var lastError: String?
    // A dry run executes only the phases that change nothing outside the run
    // (see `CommandV2Executor.changesNothingOutside`) and records what every
    // other phase would have done. Optional so runs saved before the field
    // existed still decode; read it through `isDryRun`.
    public var dryRun: Bool?
    public var isDryRun: Bool { dryRun ?? false }
    // What a run waiting at a gate is asking, with the words that answer it,
    // saved with the run so `grux approvals` can say it with Grux closed.
    // Set by the engine on save (see `upsert`), dropped here the moment the
    // run stops waiting, so no copy of a finished run still asks.
    public var gateQuestion: String?
    // When the person was last asked the gate's question in Chat. A reply
    // counts only if it was sent after this and within
    // `CommandV2Engine.freeTextGateWindow` of it. Nil on a run saved before
    // the field existed, which reads as asked long ago.
    public var gateAskedAt: Date?
    // When a message the gate could not take last asked it again. It asks
    // again at most once per `CommandV2Engine.freeTextGateWindow`, so
    // chatting past a buried question does not re-post it on every message.
    public var gateReaskedAt: Date?

    public enum Status: String, Codable, Sendable, Hashable {
        case running, waitingForApproval, waitingScheduled,
             waitingForActiveUser, completed, failed, canceled

        // A run in a terminal state has finished and cannot transition
        // further, so there is nothing left to cancel.
        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .canceled:
                return true
            case .running, .waitingForApproval, .waitingScheduled, .waitingForActiveUser:
                return false
            }
        }

        // Only in-flight (non-terminal) runs can be canceled.
        public var isCancellable: Bool { !isTerminal }
    }

    public struct PhaseRecord: Codable, Sendable, Hashable {
        public let phaseId: String
        public let startedAt: Date
        public var endedAt: Date?
        public var outcome: Outcome
        public var log: String
        /// What the tool, command or agent printed, shown under its own
        /// label in the run record, never as the step's line (SWEEP-12).
        /// Absent in records saved before it existed.
        public var details: String?
        public enum Outcome: String, Codable, Sendable, Hashable {
            // `.running` is the in-flight placeholder - the engine writes it
            // when a phase starts so the UI can render "(running)" until the
            // executor returns and the real terminal outcome is written.
            // Without this case, the placeholder used to be `.success`, which
            // made every just-started phase look already-succeeded in the UI.
            case running, success, failure, skipped, branched, scheduled, paused
        }
        public init(phaseId: String, startedAt: Date, endedAt: Date? = nil, outcome: Outcome, log: String) {
            self.phaseId = phaseId; self.startedAt = startedAt
            self.endedAt = endedAt; self.outcome = outcome; self.log = log
        }
    }

    public init(
        id: UUID = UUID(),
        definitionId: String,
        displayName: String,
        currentPhaseId: String,
        parameters: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.definitionId = definitionId
        self.displayName = displayName
        self.startedAt = Date()
        self.currentPhaseId = currentPhaseId
        self.status = .running
        self.parameters = parameters
        self.state = [:]
        self.phaseHistory = []
    }
}

extension CommandV2Definition {
    /// Where `phaseId` falls among the steps a person moves through, as
    /// "step n of total"; nil for a step off that path.
    func mainPathStep(of phaseId: String) -> (n: Int, total: Int)? {
        let path = mainPath
        guard let i = path.firstIndex(of: phaseId) else { return nil }
        return (i + 1, path.count)
    }

    /// The steps a person moves through: the longest route of non-branch
    /// phases from the first phase to the run's natural end, going the way
    /// the engine goes (a branch to either target, a scheduled follow-up to
    /// its next phase, `after` where set, else the next phase in order). A
    /// route that comes back to a phase it passed is a retry loop and never
    /// counts, and branch phases are never steps. So ship-ios-app is 13
    /// steps, not its 17 phases.
    var mainPath: [String] {
        var best: [String] = []
        func walk(_ index: Int, _ visited: Set<String>, _ path: [String]) {
            guard index < phases.count else {
                if path.count > best.count { best = path }
                return
            }
            let phase = phases[index]
            guard !visited.contains(phase.id) else { return }
            let seen = visited.union([phase.id])
            func go(_ id: String, _ path: [String]) {
                guard let next = phases.firstIndex(where: { $0.id == id }) else { return }
                walk(next, seen, path)
            }
            if case .branch(_, let ifTrue, let ifFalse) = phase.action {
                go(ifTrue, path)
                go(ifFalse, path)
                return
            }
            let here = path + [phase.id]
            if let followup = phase.scheduledFollowup {
                go(followup.nextPhaseId, here)
                return
            }
            switch phase.after {
            case .endRun?: walk(phases.count, seen, here)
            case .continueAt(let id)?: go(id, here)
            case nil: walk(index + 1, seen, here)
            }
        }
        walk(0, [], [])
        return best
    }
}
