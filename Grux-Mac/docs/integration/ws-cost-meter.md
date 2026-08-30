# WS-B Cost Meter, integration notes

Workstream: the pre-run cost estimator (sev-5 "TRUE COST BEFORE RUN"), the
first-class model picker (sev-4), and the consolidation of the three drifting
rate tables. Branch `ws/cost-meter`. Everything below builds green
(`swift build --target Grux`) and the tests below pass.

## What shipped

New (`Sources/Grux/Pricing/`):
- `ModelRates.swift` : THE canonical USD/MTok table, prefix-keyed, `nonisolated static` pure. `rates(forModelID:)` (cheapest-known fallback for unknown), `knownRates(forModelID:)` (nil for unknown, zero for local), `estimatedUSD(...)`.
- `TokenEstimator.swift` : pure chars/4 estimation over JSON-serialized system blocks + messages + tools (`estimateInputTokens(systemBlocks:messages:tools:)`, `estimateTokens(text:)`), image payloads skipped. Optional live path `liveInputTokens(...)` (Anthropic `/v1/messages/count_tokens`, 5s timeout, nil on any failure) that the pure path and the tests never touch.
- `CostMeter.swift` : `@MainActor ObservableObject`, `CostMeter.shared`, `@Published var chatEstimate: ChatRunEstimate?`. Pure `static estimate(...)` core, `routeComparison(...)`, `recordActual(...)` + `calibrationFactor()`. Value types `ChatRunEstimate`, `CheaperAlternative`, `CalibrationRow`.

Edited (behavior preserved except the documented Haiku correction):
- `Sources/Grux/ChatService.swift` : extracted `struct PendingTurnContext` + `func assemblePendingContext(state:)` from the old inline L182-247 assembly; `send()` now calls it (turn loop unchanged). Publishes `CostMeter.shared.publishChatEstimate(...)` right before the hop loop; folds `CostMeter.shared.recordActual(...)` at the usage-log site (first hop only).
- `Sources/Grux/ChatView.swift` : composer gained a `modelChip` (Menu over cloud defaults + `ModelRegistry.localTags` + `CustomEndpointStore.endpoints`; selection writes `config.model` / `config.offlineLLMModel` then `saveConfig()`, same as Settings) and a `composerMetaRow` cost line from `CostMeter.shared.chatEstimate`.
- `Sources/Grux/Usage/UsageQuery.swift` : `AnthropicModelTier.rates` delegates to `ModelRates`.
- `Sources/Grux/Foundry/FoundryGovernor.swift` : `FoundryCostMeter.rates(forModelID:)` delegates to `ModelRates` (public shape + label behavior unchanged).
- `Sources/Grux/ClaudeSession/ClaudeSessionJSONL.swift` : `ClaudeModelPricing.matchRate` delegates to `ModelRates.knownRates` (keeps the nil-for-unknown contract so replay bills $0).

New tests: `Tests/GruxTests/CostMeterTests.swift` (22 cases).

## Haiku 4.5 rate decision (the drift resolution)

The three old tables disagreed: UsageQuery + FoundryCostMeter said `0.80 / 4.00`,
ClaudeModelPricing said `1.00 / 5.00`. Anthropic's current published Haiku 4.5
price is **$1.00 / MTok input, $5.00 / MTok output** (cacheRead $0.10, cacheWrite
$1.25); `0.80 / 4.00` was stale Haiku 3.5 pricing. The canonical table adopts
`1.00 / 5.00`. Consequence for integrators: the in-app **Usage card's Haiku
figure ticks UP** to the correct number. No Settings/UI code change is required
for that, it flows through `AnthropicModelTier.rates` automatically. Session
replay cost (`ClaudeModelPricing`) is unchanged because its exact-id values
already matched the canonical table.

Unknown-model policy (mirrors the old FoundryCostMeter default): an unrecognized
PAID id resolves to the cheapest known rate (Haiku) so it can never inflate a
figure; local ids (ollama/qwen/llama/gemma/... prefixes) resolve to zero.

## Wiring CostMeter as the Design Studio's DesignRunEstimating seam

The studio owns `DesignRunEstimate` / `DesignRouteCost` / `ExecutionRoute`
(`DesignStudio/DesignStudioModels.swift`). CostMeter produces the priced routes;
the studio wraps them. Suggested adapter (studio side, do NOT add it here, this
workstream must not touch `DesignStudio/`):

```swift
// inputTokens: estimate over the studio megaprompt with the shared heuristic.
let inputTokens = TokenEstimator.estimateTokens(text: megaprompt)   // or estimateInputTokens(...)
let maxOut = /* studio's output ceiling for this artifact kind */
let routes = CostMeter.routeComparison(inputTokens: inputTokens,
                                       maxOutputTokens: maxOut,
                                       modelId: runConfig.modelId ?? "claude-fable-5")
// routes is [api, subscriptionCLI, localModel], each a DesignRouteCost.
let primary = routes.first { $0.route == runConfig.route } ?? routes[0]
let alternatives = routes.filter { $0.route != primary.route }
let estimate = DesignRunEstimate(inputTokens: inputTokens,
                                 maxOutputTokens: maxOut,
                                 primary: primary,
                                 alternatives: alternatives)
```

`routeComparison` is `nonisolated static` and pure, so the studio can call it off
the MainActor. Every `DesignRouteCost.label` already carries "estimated"
(subscription/local render "$0 estimated"), satisfying the Foundry labeling rule.

If the studio wants live cost on a running Design Studio job, feed each hop's
real usage into the same Activity Strip fold the chat path uses; CostMeter's
`recordActual` is chat-scoped (it reconciles against `chatEstimate`), so the
studio should NOT call `recordActual` for its own runs unless it first publishes
its own estimate through an equivalent path.

## Calibration

`recordActual` appends `{estimatedTokens, actualTokens, date}` to
`Application Support/Grux/cost-meter-calibration.json` (capped 500 rows, most
recent kept). `calibrationFactor()` is the median of actual/estimated (default
1.0), applied to the input-token estimate before pricing. No migration, no
Settings surface; the file self-creates on the first real send.

## Residual gaps / deliberate choices

- The model chip is a native `Menu` over the combined source list (cloud +
  local + custom), not a free-text search box. macOS `Menu` has no built-in
  search; a text-filter popover would be a follow-up if the list grows large.
- The cost line renders only AFTER the first send of a session (pre-send publish
  only, per contract, no live estimate on composer keystrokes). If a live
  estimate is wanted, call `assemblePendingContext(state:)` +
  `publishChatEstimate(...)` on a debounced composer `onChange`; the machinery is
  already there and cheap except for `buildSystemBlocks`.
- `recordActual` folds the FIRST hop only. Later hops append tool_result content
  the pre-send estimate never saw, so folding them would bias the calibration
  factor. This is intentional; the call site is still "after each hop" per the
  contract, guarded by `if hops == 1`.
- Selecting a local tag / custom endpoint writes `config.offlineLLMModel` (the
  field Settings uses); it only routes to local when offline mode / a local pin
  is active, exactly as before. The chip does not itself flip offline mode.

## Gates run

- `swift build --target Grux` : green.
- `swift test --filter CostMeterTests` : 22 pass.
- `swift test --filter ModelBackendTests` : pass (proves the ChatService
  extraction kept the assembly intact).
- `swift test --filter ChatServiceSystemBlocksTests` : pass (proves
  `composeSystemBlocks` block order / cache_control is byte-identical).
