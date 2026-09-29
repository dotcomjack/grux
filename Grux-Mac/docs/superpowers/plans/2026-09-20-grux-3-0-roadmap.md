# Grux OS 3.0 Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this roadmap phase by phase. Each phase has, or gets, its own bite-sized plan in this directory before its first commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Grux OS 3.0 as one release: always-armed listening on a typed decision engine, a twelve-row rail with Developer and Labs doors, Home as Today, every rough edge finished, a Tuning surface, and a first run that starts from "What do you want to do with Grux?"

**Architecture:** A new `Decisions` module gives every judgment in the app one shape (`DecisionEngine.decide(state:questions:)`), served by Jev when a TypeSafe key is present and by on-device matching otherwise, with a ledger that records latency, cost and provider for every call. The sidebar becomes a disposition-driven rail computed from the feature registry, so a test can prove every surface has a door. Everything else is copy, states and folds on surfaces that already exist.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, WhisperKit (on device), URLSession for the decision provider, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md`

## Global Constraints

- Build and test only from the build worktree on `main`; commit and push each task the moment it is green.
- Baseline measured 2026-09-20 on `1edb4bf`: `swift build` green; `swift test` executed 2502 tests, 10 skipped, 0 failures. The count never goes below 2502.
- No em dashes or en dashes anywhere, in code, comments, copy or commits. Amounts as numerals with the dollar sign. Standard time.
- Chat is the face: every visual change lands on Chat with the full treatment.
- Nothing ships off and undiscoverable: named at first run, a permanent Settings home, the off state explained, enforced by a test.
- No telemetry. `NoTelemetryInSourcesTests` stays green.
- Both bundle identifiers unchanged. Design tokens unchanged.
- The decision-provider key is read only from `KeychainStore` (`typesafeApiKey`). It is never embedded, never logged, never written to disk by Grux.
- Audio never leaves the machine. Only transcript text reaches the provider, and only when the key is set.
- Destructive actions never execute on a decision alone: `DecisionGate` and `ApprovalQueue` stay in the path.
- Every commit message follows the repo style: a plain sentence saying what changed and why, no prefix tags.
- After any action that raises the app window (`build.sh`, `open -b`, the sweep), run the operator's display keeper if one is configured locally; it is not part of the repo.

---

## Phase order and gates

| Phase | Plan | Ships | Gate before the next phase |
|---|---|---|---|
| A | `2026-09-20-grux-3-0-phase-a-decisions.md` | Decision engine, Jev and local providers, ledger, always-armed routing, hands-free policy, Listening control, tells (HUD, rail, menu bar, banner), orb ARMED, Usage card data, every decision point on the engine | `swift test` green at or above 2502; the destructive-never test red-proven; `mic-status.json` flips with the Listening control; Chat sweep shows LISTENING chip and the live rail |
| B | `2026-09-20-grux-3-0-phase-b-finish.md` | The finish list, Chat first, plus every rough edge found while building; the vendor glyph component; the jargon test | jargon test red-proven; Chat sweep matches the accepted finished face item by item |
| C | `2026-09-20-grux-3-0-phase-c-rail.md` | Disposition on every registry row; the twelve-row rail; Developer and Labs doors with counts; folds (Speakers, Workflows, Webhooks, Compose, Projects, Folders, Skills, Approvals tray, Focus log); brand scoping; Domain monitor ripped; reachability test; 14-row first-run test | reachability and 14-row tests red-proven; sweep of every door |
| D | `2026-09-20-grux-3-0-phase-d-today.md` | Home becomes Today (Next, Mail that needs you, Watching, Start my day, say-it line, briefing with the daily cost line); real name | sweep of Home; briefing renders the decision line from the ledger |
| E | `2026-09-20-grux-3-0-phase-e-tuning.md` | Tuning surface (shape chosen from 1:1 visuals first), holding the execute threshold and every user-tunable behaviour; Labs surface rethought from visuals | visuals accepted before code; sweep |
| F | `2026-09-20-grux-3-0-phase-f-first-run.md` | First run: centered prompt, dynamic onboarding, listening named with its off state, palette and doors named, "Add a brand", "I write code" | clean-VM stranger run: at most 14 rows, no BETA pill, spoken "open my calendar" under 1 s |
| G | `2026-09-20-grux-3-0-phase-g-release.md` | Version 3.0 everywhere, CHANGELOG with the per-gate latency table, site counts re-synced from the registry, `oss-guarantee.sh` PASS, `check-contract.py` clean, release build, notarize; publish waits for the operator's word | every DoD item has evidence in the ledger |

Phases B and C touch the same files (`SidebarModel.swift`, `LaunchRootView.swift`, `ChatView.swift`); B lands first so the face is finished before the rail moves under it.

## Files that change, by phase

**A (new):** `Sources/Grux/Decisions/DecisionModel.swift`, `DecisionProvider.swift`, `JevDecisionProvider.swift`, `LocalDecisionProvider.swift`, `DecisionEngine.swift`, `DecisionLedger.swift`, `VoiceCommandRouter.swift`, `HandsFreePolicy.swift`, `ListeningController.swift`. **A (modified):** `KeychainStore.swift`, `Models.swift` (GruxConfig), `Ambient/AmbientState.swift`, `Ambient/AmbientHUD.swift`, `MicController.swift`, `MenuBarView.swift`, `LaunchRootView.swift` (orb state), `ChatView.swift` (live rail), `SettingsView.swift`, `Integrations/*` (key field), `Chat/IntentClassifier.swift`, `GruxShellCore/ShellSafety.swift` call site, `EmailTriage/EmailTriageEngine.swift`, `Jax/DecisionGate.swift`, `Notifications/TriageClassifier.swift`, `Ambient/AmbientCoach.swift`, `Meeting/*` (moments), `Jax/ApprovalQueue.swift` (risk score). **Tests:** one file per new source file plus `ListeningMigrationTests`, `DestructiveNeverTests`.

**B:** `ChatView.swift`, `Chat/*`, `SettingsView.swift`, `AgentsView.swift`, `Home/*`, `DesignSystem/VendorGlyph.swift` (new), `Tests/GruxTests/JargonInTheFaceTests.swift` (new).

**C:** `Onboarding/FeatureRegistry.swift` (disposition column), `DesignSystem/SidebarModel.swift` (rail computed from dispositions), `LaunchRootView.swift`, the folded views, `Tests/GruxTests/RegistryReachabilityTests.swift`, `SidebarRowCountTests.swift`.

**D:** `Home/*`, `Jax/BriefingEngine.swift`.

**E:** `Tuning/*` (new), `Settings*`.

**F:** `Onboarding/*`.

**G:** `Info.plist`, `npm/package.json`, `CHANGELOG.md`, `README.md`, site sync script.

## Interfaces every phase relies on (defined in Phase A)

```swift
enum DecisionQuestion { case choice(instructions: String, criteria: [String: String])
                        case noul(instructions: String)
                        case score(instructions: String, levels: [String]) }
enum DecisionAnswer   { case choice(String, confidence: Double, probabilities: [String: Double])
                        case noul(Double)
                        case score(Double, confidence: Double) }
struct DecisionResult { let answers: [String: DecisionAnswer]; let latencyMs: Int
                        let inputTokens: Int; let outputTokens: Int; let provider: DecisionProviderKind }
enum DecisionProviderKind: String, Codable { case jev, local }
protocol DecisionProvider { var kind: DecisionProviderKind { get }
                            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult }
final class DecisionEngine { static let shared: DecisionEngine
                             func decide(surface: String, state: String, questions: [String: DecisionQuestion]) async -> DecisionResult }
struct DecisionLedgerEntry: Codable { let surface: String; let provider: DecisionProviderKind; let latencyMs: Int
                                 let inputTokens: Int; let outputTokens: Int; let costUSD: Double; let at: Date
                                 let summary: String }
final class DecisionLedger { static let shared: DecisionLedger
                             var last: DecisionLedgerEntry?; func today() -> (count: Int, avgLatencyMs: Int, costUSD: Double)
                             func record(_ r: DecisionLedgerEntry) }
enum ListeningMode: String, Codable, CaseIterable { case alwaysOn, wakeWord, off }
```

Every later phase reads `DecisionLedger.shared` for the tells and the Usage card, and `AppState.shared.config.listeningMode` for the state pills.

## How each phase closes

1. Its plan's tasks all checked, each committed and pushed.
2. `swift build` exit 0, `swift test` exit 0 with the executed count printed and not below 2502.
3. Every test the phase introduced red-proven once by planting the failure it guards.
4. A sweep capture of the surface it changed, with the running pid's start equal to the installed binary's mtime.
5. A line in `docs/superpowers/plans/2026-09-20-grux-3-0-evidence.md` per gate item with the artifact path or the quoted output.
