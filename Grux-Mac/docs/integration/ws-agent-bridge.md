# Agent Bridge Integration (WS-C)

How the Design Studio engine drives an external agent CLI (Claude Code, OpenAI
Codex, Google Gemini, aider) for the **subscription-CLI route**. Everything here
lives in the Foundation-only `GruxAgentCore` target, so the Studio (app side) can
call it without any new app dependency.

## The three pieces

| Type | Role |
|---|---|
| `AgentCLIRegistry` (actor) | Detects which CLIs are installed, cached (24h TTL, JSON snapshot at `~/.grux/agent-cli-cache.json`). Hands back the `AgentAdapter` for a chosen CLI. |
| `AgentAdapter` (protocol) | Per-CLI recipe: `buildInvocation(prompt:cwd:model:extraArgs:)` and `makeStreamParser()`. Concrete: `ClaudeCodeAdapter`, `CodexAdapter`, `GeminiAdapter`, `AiderAdapter`. |
| `AgentBridgeRunner` (actor) | Spawns ONE `AdapterInvocation` under `/usr/bin/sandbox-exec`, streams `AdapterEvent`s to a weak observer, enforces wall + idle TTLs, returns `BridgeRunResult`. |

The flow is: **detect -> pick adapter -> buildInvocation -> run -> fold events**.

## Detection (once, at Studio boot or first design run)

```swift
let registry = AgentCLIRegistry()            // default roster: claude, codex, gemini, aider
let available = await registry.availableAdapters()   // honors the 24h cache
// available is [any AgentAdapter] for the CLIs actually installed on this Mac.
```

Detection results are DATA. Nothing is executed beyond each CLI's `--version`
probe. Choosing to delegate to a detected CLI is the Studio's explicit decision.

## Driving one design run (the `DesignAgentDelegating` seam)

The Studio owns the delegate protocol (its `DesignStudioEngine` calls it). Here is
a complete bridge-backed implementation. Two things are load-bearing:

1. **The observer is WEAK-retained by the runner.** Keep the sink strong for the
   whole `await runner.run()` or steps silently vanish (same rule as
   `SwarmWorkerObserver` / `RDRunSink`).
2. **The run `cwd` must be a sanctioned writable root** or the sandbox confines
   the worker to temp-only writes. Sanctioned: anything under
   `~/Documents/Grux/design`, `~/Documents/Grux/studio`, `~/Documents/Grux/swarms`,
   `~/Projects/GruxApps`, or any path with a `.worktrees/` segment. To touch a
   real brand repo, branch a sibling `.worktrees/` checkout (auto-sanctioned) and
   land via git, never write the live tree.

```swift
import GruxAgentCore

// The Studio's own outcome type (maps from BridgeRunResult).
struct DesignAgentOutcome {
    let success: Bool
    let finalText: String
    let touchedFiles: [String]     // from .fileArtifact events (plain-text CLIs)
    let costUSD: Double?
    let note: String?
}

// Strongly-retained observer that folds AdapterEvents into the Studio's run log.
// Hop to the Studio's MainActor here if the log store is @MainActor (mirror
// AgentServiceBridge's @unchecked Sendable hop, or RDRunSink's injected closure).
final class DesignRunSink: AgentBridgeObserver {
    private let onEvent: @Sendable (AdapterEvent) -> Void
    init(onEvent: @escaping @Sendable (AdapterEvent) -> Void) { self.onEvent = onEvent }
    func bridgeRun(_ runId: String, didEmit event: AdapterEvent) async { onEvent(event) }
}

struct BridgeDesignAgentDelegate: DesignAgentDelegating {
    let registry: AgentCLIRegistry

    /// - cliID: "claude" for the subscription route; or a user-chosen CLI id.
    /// - cwd:   a sanctioned Studio workspace dir (see rule 2 above).
    func runDesignAgent(
        prompt: String,
        cwd: String,
        cliID: String,
        model: String?
    ) async -> DesignAgentOutcome {
        guard let adapter = await registry.adapter(id: cliID) else {
            return DesignAgentOutcome(success: false, finalText: "",
                                      touchedFiles: [], costUSD: nil,
                                      note: "no adapter for CLI '\(cliID)'")
        }
        // Confirm it is actually installed (cache-honoring).
        guard let probe = await registry.detect(adapterId: cliID), probe.isAvailable else {
            return DesignAgentOutcome(success: false, finalText: "",
                                      touchedFiles: [], costUSD: nil,
                                      note: "\(adapter.displayName) is not installed")
        }

        // Claude's adapter strips API-billing env inside buildInvocation, so the
        // subscription route stays on Claude.ai OAuth (never metered API).
        let invocation = adapter.buildInvocation(prompt: prompt, cwd: cwd, model: model, extraArgs: [])

        var touched: [String] = []
        let sink = DesignRunSink { event in
            switch event {
            case .fileArtifact(let path, _, _): touched.append(path)
            case .limitSignal:                  break   // Studio can surface a pause card here
            default:                            break
            }
            // ... also append the event to the Studio's private run log / UI stream ...
        }

        // `sink` MUST outlive the run (weak observer). This local `let` does that.
        let runner = AgentBridgeRunner(adapter: adapter, invocation: invocation, observer: sink)
        let result = await runner.run(ttlSeconds: 1800)
        _ = sink   // keep the sink alive until here

        return DesignAgentOutcome(
            success: result.success,
            finalText: result.finalText,
            touchedFiles: touched,
            costUSD: result.costUSD,       // always render as "estimated" (subscription)
            note: result.note
        )
    }
}
```

## Notes for the integrator

- **Private run log, not the Agents tab.** Keep Studio design runs out of the
  general Agents feed: fold events into a Studio-owned store (the
  `CommandV2AgentBridge` private-`AgentStore(rootDir:)` pattern), e.g. under
  `~/Documents/Grux/studio/<runId>/`.
- **Cost is always "estimated".** `BridgeRunResult.costUSD` is informational for
  every route (subscription CLIs have no real per-run charge). Render via the
  existing `FoundryCostMeter` label.
- **Cancellation.** `AgentBridgeRunner` is an actor; hold the instance and call
  `await runner.cancel()` to terminate the subprocess (sets the flag +
  `proc.terminate()`, read loop exits next iteration).
- **TTLs.** Wall TTL is the `ttlSeconds` arg (default 1800). Idle TTL defaults to
  600s and honors `GRUX_WORKER_IDLE_TTL_SECONDS`, same as `SwarmWorker`.
- **Limit handling.** The Claude adapter folds `LimitSignal.detect` into its
  parser and emits `.limitSignal`; the runner sets `success = false` and returns
  `note: "paused: subscription usage limit"`. Treat like `SwarmWorker`'s
  `.pausedForAuth` (offer an account switch / resume), do not classify as failed.
- **ACP route (separate).** For agents that speak Agent Client Protocol rather
  than a one-shot stream, use `ACPConnection` (bidirectional JSON-RPC over
  stdio). Inject an `ACPServerRequestHandler` so agent-initiated requests
  (permission prompts, `fs/read_text_file`) are answered by Studio logic:

  ```swift
  let acp = ACPConnection(command: "some-acp-agent", args: ["--stdio"]) { method, params in
      switch method {
      case "fs/read_text_file":
          let path = params?["path"]?.stringValue ?? ""
          let body = (try? String(contentsOfFile: path)) ?? ""
          return .result(.object(["content": .string(body)]))
      case "session/request_permission":
          return .result(.object(["outcome": .string("allow")]))   // or gate via a card
      default:
          return .error(code: -32601, message: "unsupported")
      }
  }
  try await acp.start()
  let reply = try await acp.request(method: "session/prompt",
                                    params: .object(["prompt": .string(goal)]))
  ```

## Migrating the duplicate resolvers (follow-up, not done here)

`AgentCLIRegistry.oauthSafeEnvironment(base:)` and
`AgentCLIRegistry.resolveExecutablePath(for:)` are the consolidation targets for
the three copy-pasted `resolveClaudeBinary()` / env-strip blocks
(`SwarmWorker.swift`, `AccountSwitcher.swift`, `TerminalFocusState.swift`). They
were left in place to keep this workstream's blast radius to `GruxAgentCore`;
migrating each caller to the registry is a clean, separate change.
