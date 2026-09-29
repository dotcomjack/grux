# Grux 3.0 Phase R: the decision backend, rebuilt around one call per event

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Every event Grux judges gets ONE batched Jev call, the fourteen chosen judgments move onto it, credit exhaustion is known rather than guessed, and Grux gets measurably lighter on the machine.

**Decision record:** `questionnaires/_decisions/grux-backend-jev-rethink.md`, kept outside this repository (answered 2026-09-21). Read its Brief and seven acceptance criteria before claiming anything. It supersedes the per-gate shape built in P-A9-1, P-A9-2 and P-A9-4.

**Sequencing (answer 6):** this phase runs BEFORE the rest of Phase A continues. The A packets it absorbs read `MOVED to P-R-n` in the worklog and close when their R packet closes.

## Global constraints (binding on every packet)

- Build worktree `.worktrees/grux-main/Grux-Mac` under the operator's code folder, branch `main`, `./build.sh` only there. Test floor 2766, 0 failures.
- ONE suspension point per event. `send()` is main-actor isolated; an await above the readiness guard let a refused turn reach the network on 2026-09-20 (fact `await-placed-above-readiness-guard`). Match synchronously, suspend once.
- The hand-rolled guard is always the FLOOR. A provider may only raise a verdict. On device a noul answers 0.5, which means "cannot judge" and is never a veto or a raise.
- Destructive-never still stops a 0.99 `rm -rf ~`. A keyless install behaves exactly as today.
- `DecisionEngine.isUnderTest` and `Persistence.isUnderTest` keep the suite off the Keychain, the network and the operator's real state. Never weaken either.
- No em or en dashes. Red-prove every new test by planting what it guards, restore, prove byte-identical with `diff`.

## Measured baseline, 2026-09-21 (the "before" column)

From `~/Library/Application Support/Grux/decisions.jsonl`, 736 rows:

| gate | provider | calls | p50 | p90 | input tokens each |
|---|---|---|---|---|---|
| voice | Jev | 649 | 444 ms | 542 ms | 4,468 |
| voice | on device | 60 | 4 ms | 7 ms | 0 |
| jax.gate | Jev | 13 | 395 ms | 532 ms | 454 |

`chat.intent` and `shell.destructive` have ZERO live rows: wired and tested, never fired on real data. Total spend $0.12 of the $5.00 credit.

Machine load, Grux armed and idle, after 90s uptime, 12 samples 5s apart: **140 MB resident (fine), 23.4% CPU; muted 24.9%, so the load is NOT audio.** `sample` puts ~27% of the main thread in `NSDisplayCycleFlush` into `NSWindow layoutIfNeeded` into `_layoutViewTree` plus `CA::Transaction::commit`: the window re-lays itself out continuously.

## Packets

### P-R-1: the batched turn decision, and the four gates converted
`Decisions/DecisionEngine.swift` gains an event API: gates register questions against an event id, the engine sends them in ONE `decide` call, each gate reads its typed answer synchronously. Convert voice, chat.intent, shell.destructive and jax.gate.

**Corrected 2026-09-21, from the code and the ledger:** the `shell_run` claim below was wrong. `JaxToolGate` queues an unclassified tool for approval and returns, so `ShellTool.secondOpinionSaysDestructive` runs only on the approved replay, which is a separate event; the ledger shows `jax.gate` rows for `shell_start` ending in a queue, never followed by `shell.destructive` on the same dispatch. The real double was a SPOKEN request: the voice decision, then `chat.intent` inside `ChatService.send` on the same words. That is what P-R-1 converted. jax.gate and shell.destructive stay single-gate calls, which the violation detector watches if they ever share an event. Original line, kept for the record: "The live win: a `shell_run` tool dispatch currently pays TWO calls on one event (`JaxToolGate` then `ShellTool.secondOpinionSaysDestructive`); it must pay one."
- Test that FAILS if a gate calls `engine.decide` directly when an event batch is open for its event (this is acceptance criterion 1).
- Test that a batch of N questions records ONE ledger row whose surface names every gate in it, so the latency table stays attributable.
- Keep every existing gate test green unchanged; they are the proof the conversion changed nothing but the call count.

### P-R-2: trim the voice vocabulary (the real cost driver)
Voice sends every tab and every macro as criteria on every chunk: 4,468 input tokens, ten times the Jax gate. Send only plausible candidates (cheap local prefilter: word overlap plus the always-present `say:chat` and `not_a_command`). Measure input tokens before and after on the same injected chunks. Must not reduce accuracy on the television, bystander and addressed-question cases already proven live.

### P-R-3: credits, KNOWN not guessed, for every credit-backed key
Supersedes P-A10-3. Detect exhaustion from the provider's actual response (status and error body), never from a generic failure or a timeout. Fall through to on-device and keep working. Tell the person ONCE: one notification plus one line in the Usage card, blunt about what got worse and how to refill. Only for someone with prior successful calls on that key. One `CreditState` shape reused for Jev, OpenRouter, Replicate and ElevenLabs. Depends on P-A10-2 (the Usage card). Test the "we must know" rule: a 500, a timeout and a malformed body must NOT raise the refill notice.

### P-R-4: driving the computer
Supersedes P-A11-1. Window and app target resolution, screen element disambiguation in `ScreenControlEngine`, scope of a sweeping window command, which app satisfies a spoken intent. Each is a question on the voice event's batch from P-R-1, not a new call.

### P-R-5: attention
Supersedes P-A9-3, P-A9-5 and part of P-A9-6. Mail needs-you (the plumbing is `Email/MailNeedsYou.swift`; swap its judgement, keep the rail reading it). Notification interrupt, batch or silent by REBUILDING `Notifications/TriageClassifier.swift` on content, not a category table. The email triage classify step, with drafting left on a text model. Focus drift and "is now a good moment to interrupt" by REBUILDING `Ambient/AmbientCoach.swift`, which today judges drift from the frontmost app's name.

### P-R-6: work, memory and agents
Supersedes the rest of P-A9-6. Task priority, meeting moment detection, approvals risk score, project attribution for tasks and memories, and whether an agent job is worth starting.

**Built 2026-09-21 on `lane/P-R-6`.** Engine and event files untouched. The surfaces are the names this packet gave; no existing code named any of them otherwise. Every judgment is asked once per NEW item, never per render or list read, and only with a key: a keyless install asks nothing, records no ledger row and stores nothing new, and each has a test proving it. Wording calibrated against the live provider; tables in the evidence file under P-R-6.

| judgment | surface | type | floor (a keyless install is exactly this) | asked once per | consumer | status |
|---|---|---|---|---|---|---|
| task priority | `task.priority` | score later / next / now | the creator's priority; raise only; `.now` only when no task is in focus and no other task is `.now`, else `.next` at most | new top-level task id | `AppState.setPriority` | on the engine, **not started at launch**, see below |
| project attribution, tasks | `project.attribution` | choice: existing projects + none | the creator's project; fills a blank only, never replaces, never invents | same event as priority, one call for both | `AppState.renameTask(project:)` | on the engine, **not started at launch**, see below |
| project attribution, memories | `project.attribution` | same choice | the extractor's tag | `DecisionLog` extraction pass, one call for every untagged record | `DecisionLog` records, which `decision_log_query` searches by project | wired |
| meeting moments | `meeting.moment` | choice per listed item: decision / commitment / action item / not in transcript | the summarizer's items, all kept and shown as before | summary, one call for every item; stored on the record by item text | chip on each action item in `ConversationDetailView` | wired |
| approvals risk | `approvals.risk` | score low / medium / high | no flag | new approval id; stored on the item | `HIGH RISK` chip on the Jax HQ card; never approves, skips, reorders, clears urgent or shows a low score | wired |
| agent job worth starting | `agent.worthStarting` | noul | LIVE starts the job | `GoalPursuitEngine` LIVE dispatch, one event with the held item's `approvals.risk` | holds the plan for one tap exactly as OBSERVE queues it; never starts anything | wired |

**Not wired, with the reason:**
- **Task judgments are not started at launch.** `TaskJudgments` watches `AppState.$tasks` and needs one line, `TaskJudgments.shared.start()`, in `GruxApp.applicationDidFinishLaunching` (next to `_ = ApprovalQueue.shared`). `GruxApp.swift` is off-limits to this lane. `AppState.addTask` is the only choke point every task passes, and it is off-limits too, as are the automatic creators (`ChatService` `add_task`, `Ambient/*`); the allowed ones (meeting import, terminal suggestion) are the person's own taps carrying a project.
- **Ambient memories (`AmbientMemory.project`) are not attributed.** They are written in `Ambient/*`, off-limits to this lane. Memories are covered through `DecisionLog`.
- **`agent.worthStarting` is asked only on the LIVE autonomy path.** Every other way into `AgentService.startSwarm` already carries a decision: the chat tool is queued by the Jax gate and runs only on an approved replay, Foundry builds only accepted proposals, and the MCP `grux_agent` tool is a caller's explicit request. A model second-guessing a yes would lower a person's authority, not raise caution.
- **`approvals.risk` on a Jax-gate queue is a second call after `jax.gate`'s.** Riding `jax.gate`'s call would namespace `jax.gate`'s question names on the wire, which breaks `GateTightenOnlyTests` (they must stay unchanged), and at that call the item may never exist (the gate can still refuse). The risk call runs after the tool has already answered "pending", so nobody waits on it. The held LIVE agent job is the one place both judgments are known up front, and there they share one call. Voice's ask-first items (`VoiceCommandRouter`, off-limits) are judged the same way, one call per new item.

### P-R-7: rips and splits
Rip `CloudflareTunnelManager` (inert since 2026-08-12; keep the `applicationWillTerminate` reap reasoning in the commit message). Rip or surface `Clone/CloneExtractor` (on no page at all). Split the trigger table out of `GruxApp.swift` (3,603 lines). Review `Creative/CreativeEngine.swift` (3,538) and record a keep or split verdict with its reason.

#### P-R-7 verdict on `Creative/CreativeEngine.swift` (recorded 2026-09-21, not acted on here)

**Verdict: split the SwiftUI layer out, in its own packet; keep `CreativeEngine` itself whole.**

What the 3,538 lines are, by the file's own MARKs: domain types (`CreativeBrand`, `CreativeBundle`, workflows, the brand registry; lines 1 to 445), the `CreativeEngine` class (446 to 1951: voice entry, intent inference, the companion render path, the direct model fallback, the Replicate dynamic studio, scp from the companion host, persistence, parsing, library actions, smoke test), errors plus the Claude tool surface (1952 to 2057), and the Studio UI (2058 to 3538: `CreativeStudioView`, its card, the clip player and the detail sheet, about 1,480 lines).

Whether they change together, measured from `git log` (47 commits, each diff hunk placed by that commit's own MARK lines): the engine was touched in 36, the UI in 21, both in 14. The co-changes cluster in the 2026-06-05 build-out, where a new engine capability arrived with its button. Of the last 12 commits, 10 touched only the engine, 2 both, none only the UI.

What a split costs. The UI move is nearly free: the views read only `inbox`, `isWorking`, `lastError`, `lastErrorIsAbsence` and ten internal actions, the four `fileprivate` engine helpers are called only inside the engine, and the private view types move with the views, so zero access modifiers change, and `BackendSweepTests` keeps pointing at the engine file, which is where the model client lives. Splitting the ENGINE is not free: its three render pipelines share private state and helpers (39 `private` or `fileprivate` members, among them `inbox`, `workingCount`, `miniBrandCache`, `postFirstReachable`, `persist`, `fetchRenderedImage`), and Swift `private` does not cross files, so every one a moved pipeline touches would widen to internal, while the audit rounds show a change often crossing pipelines in one commit. The result would be about 1,500 lines of engine, which is fine for one type with one job.

### P-R-8: load, measured the same way before and after
Target acceptance criterion 7: muted idle CPU measurably below 24%. Suspects, in the order the profile ranks them: whatever invalidates the window every frame (start with any `.repeatForever` animation or TimelineView in the orb and the rail); `LaunchRootView.railBadge` calling `MailNeedsYou.count` over every message on EVERY render (a 2026-09-20 regression of mine; memoize on the message set); `MusicWatcher` polling Apple Music by AppleScript on a tick. Prove each fix with a second `sample`, not with a claim.

### P-R-9: music and Mac output lose quality while Grux's mic is open
Reported by the operator 2026-09-21. Evidence already in hand: the same `sample` shows a `com.apple.coreaudio.AUVoiceProcessingIO` thread, and macOS voice processing ducks other apps' output by default. Read `AudioDucker.swift` first, because Grux may be ducking on purpose. Fix path: `AVAudioInputNode.voiceProcessingOtherAudioDuckingConfiguration` (macOS 14+) set to the minimum, or open the input without voice processing when no reply is playing. Verify by ear AND by measurement: play a known track, compare the output level with the mic armed versus muted.

### P-R-10: the latency table
Supersedes P-A9-7. Before and after per gate, from the ledger, into the evidence file and the release notes. Before is the table above.

### G-R: the Phase R gate
All seven acceptance criteria from the decision record have an artifact in the evidence file, the suite is green at or above 2766, and the decision record is set to `verified`.
