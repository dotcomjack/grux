# Grux Commands V2

**Status:** spec, ready to implement
**Author:** Claude (Opus 4.7)
**Date:** 2026-04-25
**Companion spec:** `2026-04-25-ios-app-launch-workflow.md` (the first big consumer of V2)

---

## Why V2

V1 macros (`Sources/Grux/VoiceMacros.swift`, `CommandsView.swift`) are great for short, deterministic, one-shot sequences: "open Cursor + tile terminals + speak hello." They struggle when the work is:

| V1 limit | What V2 needs |
|---|---|
| Linear step list (`[MacroAction]`), no branches | If/else on runtime state (e.g. `if asc_state == REJECTED then ...`) |
| Runs to completion in seconds | Long-running across hours/days, must survive app restart |
| Each `MacroAction` is one shell call / one AppleScript | Some steps are "spawn 5 Claude agents in parallel and wait for all" |
| No user-approval gates | Phase gates: pause for "go/no-go" before continuing to a destructive or expensive step |
| Triggered, then forgotten | Reschedulable, resumable, observable from the Commands tab |
| No `awaitTimer(24h)` | Native scheduled wakeups via existing `CommitmentScheduler` |
| Text-based output only | TTS celebrations, audio-cue notifications, "tell the owner at next active session" semantics |

The smell test: the iOS app launch workflow (the first concrete use case the owner asked for) cannot be expressed as a V1 macro. Every limit above blocks it.

V2 is **additive**: V1 macros stay, V1 tab stays, both keep working. V2 lives in a new tab and a new engine.

---

## Design principles

1. **One command = one big atomic outcome.** Not "build" + "install" + "submit." A V2 command says "ship the iOS app." The intermediate steps are the engine's problem, not the user's.
2. **Voice-first triggers.** Every V2 command has a natural-language phrase (e.g. "ship the sample app") that fires it from the orb, the menu bar, or the chat.
3. **Phase-gated, never silent.** Long-running commands speak (or post chat updates) at every phase boundary. You should always be able to ask "what are you doing right now?" and Grux replies in one sentence.
4. **Resilient by default.** A power cycle / app restart / Mac reboot does not lose state. Every active run persists to `~/Library/Application Support/Grux/v2-runs/<run-id>.json`.
5. **Clear ownership of who's doing the work.** Each step is either *me-the-engine* (deterministic Swift), *Claude* (LLM with tools), or *you* (approval gate). The runtime never confuses these.
6. **Observable.** The Commands V2 tab shows every active run, current phase, what's blocking, and "next event at HH:MM." Power user can drill into the per-run timeline.
7. **Idempotent on resume.** If Grux dies during phase 3, restarting Grux re-enters phase 3 from its last persisted checkpoint, no duplicate ASC submissions, no double-installs.

---

## Architecture

### New types (all in a new module `GruxCommandsV2`)

```swift
// MARK: Definition (declarative, what a command IS)

public struct CommandV2Definition: Codable, Identifiable {
    public let id: String                // stable, e.g. "ship-ios-app"
    public let displayName: String       // shown in Commands tab and in chat
    public let voiceTriggers: [String]   // ["ship the iOS app", "ship <project>", "publish to App Store"]
    public let description: String       // one-paragraph user-facing
    public let phases: [Phase]
    public let parameters: [Parameter]   // declared inputs, validated before run
    public let category: Category        // .ship, .observe, .develop, .lifestyle, ...

    public struct Phase: Codable {
        public let id: String            // "brainstorm", "build", "walkthrough", ...
        public let displayName: String
        public let action: Action
        // If true and gate is unmet, run pauses; user must explicitly resume
        public let userApprovalRequired: Bool
        // If non-nil, after this phase succeeds, schedule the named phase to run
        // after `interval` instead of running immediately. Used for "wait 24h."
        public let scheduledFollowup: ScheduledFollowup?
    }

    public struct ScheduledFollowup: Codable {
        public let nextPhaseId: String
        public let interval: TimeInterval        // e.g. 24*60*60
        public let interruptUserOnFire: Bool     // true for the celebration moment
    }

    public struct Parameter: Codable {
        public let name: String
        public let kind: Kind
        public let prompt: String        // shown to user when collecting (chat / voice)
        public enum Kind: String, Codable { case projectPath, freeText, choice, secret }
        public let choices: [String]?
    }

    public enum Category: String, Codable { case ship, observe, develop, lifestyle }
}

// MARK: Action (what each phase DOES, much richer than V1's MacroAction)

public enum CommandV2Action: Codable {
    /// Pure deterministic Swift function in GruxCommandsV2.Builtins
    case builtin(name: String, args: [String: AnyCodable])

    /// Run a `~/.grux/bin/*.sh` or `tools/*.sh` script
    case shell(command: String, captureOutput: Bool)

    /// Call IOSDispatcher.dispatch, lets V2 commands reuse all the
    /// ios_doctor / ios_scaffold / ios_build_verify / ios_simulator_run
    /// machinery that already exists in GruxShellCore.
    case iosTool(name: String, input: [String: AnyCodable])

    /// Spawn a Claude agent with a system prompt + selected tools.
    /// Engine waits for the agent's final message and stores it for the
    /// next phase to read. Optional max iterations.
    case claudeAgent(systemPrompt: String, tools: [String], maxTokens: Int?)

    /// Fan out N Claude agents in parallel, give each a different prompt,
    /// wait for all. Used for multi-screen redesigns, multi-target ASC ops, etc.
    case claudeAgentSwarm(prompts: [String], sharedTools: [String])

    /// Pause and ask the user explicitly. Resumes when user replies in chat
    /// OR via voice OR via the Commands tab "Approve" button.
    case userApprovalGate(prompt: String, expectedReplies: [String]?)

    /// Run condition; pick one of two phase IDs to jump to. Conditions are
    /// limited to a small DSL (see Conditions section).
    case branch(condition: ConditionExpr, ifTrue: String, ifFalse: String)

    /// Speak with the existing SpeechEngine. May queue audio cues
    /// (e.g. play song clip after speaking).
    case speak(text: String, audioCueAfter: AudioCue?)

    /// Schedule a future trigger via CommitmentScheduler.
    /// On fire, the engine resumes the run at the named phase.
    case scheduleResume(at: Date, atPhase: String)

    /// Wait until the owner is "actively engaged" (mic active, chat focused,
    /// foreground app in approved list). When detected, deliver
    /// `interruptionMessage` and any audioCue. Used for the
    /// "tell the owner at next active session" celebration semantics.
    case interruptOnNextActive(message: String, audioCue: AudioCue?)

    /// Open a chat panel mode and walk through a list of feature points.
    /// Used by the iOS workflow's "walkthrough" phase. Each point is one
    /// chat turn from Grux, then waits for user reply.
    case walkthrough(points: [WalkthroughPoint])

    /// Set / read a value in the run's persistent state dictionary.
    /// Used to pass values between phases (project_id, asc_submission_id, ...)
    case setState(key: String, valueExpr: ValueExpr)

    public struct AudioCue: Codable {
        public let kind: Kind
        public enum Kind: String, Codable {
            case djKhaledAnotherOne   // canonical "you shipped another one" celebration
            case successChime
            case warningChime
            case ttsTone              // existing fire-tts-tone diagnostic
        }
        public let postSpeakDelay: TimeInterval?  // e.g. 0.5s before song fires
    }

    public struct WalkthroughPoint: Codable {
        public let title: String         // "New Pond home screen"
        public let body: String          // 2-3 sentences describing what changed
        public let demoAction: Action?   // optional: e.g. open a screenshot or fire a deep link to the iPhone
    }
}

// MARK: Run (executable instance, what a command becomes when started)

public struct CommandV2Run: Codable, Identifiable {
    public let id: UUID                  // stable; persisted to disk
    public let definitionId: String      // e.g. "ship-ios-app"
    public let displayName: String       // "ship the sample app"
    public var startedAt: Date
    public var completedAt: Date?
    public var currentPhaseId: String
    public var status: Status
    public var parameters: [String: AnyCodable]   // collected at start
    public var state: [String: AnyCodable]        // shared across phases (set by setState)
    public var phaseHistory: [PhaseRecord]        // one entry per completed phase
    public var blockingReason: String?            // shown in UI when paused

    public enum Status: String, Codable {
        case running          // engine is actively executing
        case waitingForApproval
        case waitingScheduled // scheduled wakeup pending; nextWakeAt set
        case waitingForActiveUser  // interruptOnNextActive armed
        case completed
        case failed
        case canceled
    }

    public struct PhaseRecord: Codable {
        public let phaseId: String
        public let startedAt: Date
        public let endedAt: Date?
        public let outcome: Outcome
        public let log: String        // capture of speech/output/agent reply
        public enum Outcome: String, Codable { case success, failure, skipped, branched }
    }

    public var nextWakeAt: Date?
}
```

### Engine

```swift
@MainActor
public final class CommandV2Engine: ObservableObject {
    public static let shared = CommandV2Engine()

    @Published public private(set) var activeRuns: [CommandV2Run] = []
    @Published public private(set) var definitions: [CommandV2Definition] = []

    public func register(_ def: CommandV2Definition) { ... }
    public func start(definitionId: String, params: [String: Any]) async throws -> UUID { ... }
    public func resume(_ runId: UUID) async { ... }       // user-triggered resume from approval gate
    public func cancel(_ runId: UUID) async { ... }
    public func tick() { ... }                            // called every 30s by app loop
    public func handleScheduledWake(runId: UUID, phase: String) async { ... }
    public func handleUserActivity() async { ... }        // fires interruptOnNextActive
}
```

Persistence: every state mutation writes the run JSON to `~/Library/Application Support/Grux/v2-runs/<run-id>.json`. On Grux launch, `CommandV2Engine` reads that directory and reconstitutes `activeRuns`.

### Conditions DSL

Branching needs a real condition language without bringing in JS. Three primitives:

```swift
public enum ConditionExpr: Codable {
    case stateEquals(key: String, value: String)
    case stateMatches(key: String, regex: String)
    case ascSubmissionState(equals: String)   // resolves at runtime via ASC API
    case allOf([ConditionExpr])
    case anyOf([ConditionExpr])
    case not(ConditionExpr)
}
```

Enough to express: "if state[asc_submission_state] == REJECTED" (the iOS workflow's branch on rejection).

### ValueExpr (passing data between phases)

```swift
public enum ValueExpr: Codable {
    case literal(AnyCodable)
    case fromAgentOutput        // last Claude agent's final message
    case fromShellOutput        // last shell stdout
    case fromState(key: String) // copy from run state
    case fromIOSTool(field: String)  // pluck a JSON field from the last ios_* tool result
}
```

---

## Commands V2 tab (UI)

New tab next to "Commands" called **Commands V2** (or rename the V1 to "Macros" and the new one to "Commands", owner's choice; this spec doesn't bikeshed labels).

```
┌─────────────────────────────────────────────────────┐
│ ACTIVE                                              │
│ ┌─────────────────────────────────────────────────┐ │
│ │ ▶ ship the sample app        (started 2h ago)   │ │
│ │   phase: waiting 24h for Apple review           │ │
│ │   next event: Tomorrow 10:14 AM                 │ │
│ │   [Cancel] [Drill in]                           │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ DEFINITIONS                                         │
│ ┌─────────────────────────────────────────────────┐ │
│ │ ship the iOS app           ▶ Run                │ │
│ │ Brainstorm → build → walkthrough → publish →    │ │
│ │ wait → check → celebrate. Long-running.         │ │
│ │ Voice: "ship the iOS app", "ship <project>"     │ │
│ ├─────────────────────────────────────────────────┤ │
│ │ check ASC submission status                     │ │
│ │ Voice: "what's the status of <project>"         │ │
│ ├─────────────────────────────────────────────────┤ │
│ │ + New definition                                │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

Drill-in shows: phase timeline, current state, every previous phase's log (speech, agent replies, shell stdout), the persistent state dictionary, the next scheduled wake.

---

## Voice integration

`VoiceMacroRegistry` keeps handling V1 macros. New `CommandV2Registry` handles V2 voice triggers. Both feed into the same orb / ambient listener, the listener routes a phrase by checking V2 first (richer triggers usually win), falling back to V1.

A V2 trigger may include a parameter slot:
```
trigger: "ship the {project}"
```

When matched, the engine collects `{project}` from the captured fragment, looks it up against `ProjectsIndex.swift` to resolve to a real path, asks for confirmation if ambiguous.

---

## Built-in catalog (ships with V2)

Required for the iOS workflow + obvious other utilities:

| Definition ID | Use |
|---|---|
| `ship-ios-app` | The full e2e workflow (see companion spec) |
| `check-asc-status` | One-off status read for a project |
| `daily-app-stats` | Pull PostHog + ASC + revenue numbers, speak summary |
| `weekly-recap` | Spoken Friday-evening recap of all active runs |
| `pause-all-runs` | Operator escape hatch |

User-defined commands are saved alongside these in the same registry.

---

## Migration / coexistence

Strict additive. No V1 file is touched. The two systems are intentionally different shapes, V1 stays best-of-class for fast deterministic chains, V2 is the home for everything that has a phase boundary or a wait or an LLM call.

A V2 phase can `case shell(...)` or `case builtin(name: "v1.runMacro", args: ["macroName": ...])` to invoke an existing V1 macro inside a V2 run. So upgrading a V1 macro to V2 is "wrap it in a single-phase V2 def" until you actually need the new powers.

---

## Implementation plan (high level, pull into a writing-plans pass before coding)

1. **`GruxCommandsV2/` Swift module skeleton**, types, engine, persistence, definition registry. No UI, no actions wired. Compile clean.
2. **First action backends**: `builtin`, `shell`, `speak`, `userApprovalGate`, `setState`. Test with a no-op definition.
3. **`scheduleResume` + `tick` integration** with `CommitmentScheduler`.
4. **`claudeAgent` + `claudeAgentSwarm`** action backends, reusing the existing `ClaudeClient` / `ClaudeSession` infrastructure.
5. **`iosTool` action backend**, thin pass-through to `IOSDispatcher.dispatch`. ASC ops live here.
6. **`interruptOnNextActive`**, wire to `AmbientState` activity signals + chat focus state.
7. **`walkthrough` action backend**, chat-panel modal driving a list of points.
8. **`Commands V2` SwiftUI tab + drill-in view + voice trigger registry**.
9. **Ship the `ship-ios-app` definition** (companion spec) as the first real consumer. Eat our own dog food.
10. **Migrate one V1 macro** (e.g. "ship the sample app") to V2 and confirm it still fires from the orb.

Acceptance: a V2 run can survive a Mac restart in the middle of a 24-hour wait. Verified by killing the Grux process, waiting, restarting, watching the run resume and fire the celebration on schedule.

---

## Out of scope (V2.0)

- Cross-machine sync (a V2 run starts on the Mac and stays there).
- Run history rollups / analytics dashboards.
- Public marketplace of V2 definitions.
- Mobile-side trigger, for now, V2 runs start on the Mac, and the GruxPhone receives state via the existing wire protocol.

These are real follow-ups for V2.1+.

---

## Open questions

- **Naming of the tab.** "Commands V2" is the working name; consider "Workflows" or "Routines" if it feels truer.
- **Whether `MacroAction` should grow new cases vs. live alongside `CommandV2Action`.** This spec assumes alongside, V1 stays static. Could revisit if maintenance becomes annoying after 6 months.
- **Definition authoring UX.** V1 has a step editor; V2 needs something richer to express phases + gates + branches. First pass: JSON-on-disk editing only, no GUI builder. GUI builder in V2.1.
