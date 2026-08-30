# Design Studio: Iteration Tools integration (WS-E)

This workstream adds the iteration + quality layer for the Design Studio. Every
file lives under `Sources/Grux/DesignStudio/Iteration/` and compiles standalone
against `DesignStudioModels.swift` plus existing app types (QualityGate, FactGuard,
ConfidenceGate, ClaudeClient, AppState, GruxTheme). All public APIs are plain
values or plain SwiftUI views: studio-core wires them, this code never reaches into
the studio engine, store, or preview.

Files:
- `CritiqueGate.swift` : anti-slop 5-dimension design review (returns a `QualityVerdict`).
- `SurgicalEditEngine.swift` : targeted comment-mode patch flow (locate, prompt, splice).
- `InspectorScript.swift` : the isolated-world inspector JS (`InspectorScript.script`).
- `DirectionEngine.swift` : the 5-direction picker fan-out.
- `ClarifyingIntake.swift` : turn-1 clarifying intake helper plus `DesignIntakeFormView`.

Tests: `Tests/GruxTests/{CritiqueGateDeterministicTests,SurgicalEditLocatorTests,DirectionParseTests}.swift`.

---

## 1. CritiqueGate as the studio engine's DesignCritiquing seam

CritiqueGate is an `enum` of statics that returns the SAME `QualityVerdict` /
`DimensionVerdict` types QualityGate returns, so the existing verdict UI
(`FeatureReviewView.gatePanel(_:)`) and the HTML export
(`QualityGateExport.html(...)`) render a design critique for free.

Public entry point (call on the MainActor):

```swift
let verdict: QualityVerdict = await CritiqueGate.run(
    html: currentArtifactHTML,                 // the generated artifact text
    brandSlug: project.brandSlug,              // DesignProject.brandSlug (may be nil)
    designSystemMarkdown: designSystemMarkdown  // loaded from project.designSystemFile
)
```

If studio-core wants a DI seam rather than calling the enum directly, wrap it:

```swift
protocol DesignCritiquing {
    func critique(html: String, brandSlug: String?, designSystemMarkdown: String?) async -> QualityVerdict
}
struct LiveDesignCritique: DesignCritiquing {
    func critique(html: String, brandSlug: String?, designSystemMarkdown: String?) async -> QualityVerdict {
        await CritiqueGate.run(html: html, brandSlug: brandSlug, designSystemMarkdown: designSystemMarkdown)
    }
}
```

Gate publish/export on `.pass` exactly the way `FeatureReviewEngine.implementToMain`
gates on `verdict.status == .pass`:

```swift
guard verdict.status == .pass else {
    // surface verdict.blockingDimensions in the panel, do not mark the artifact done
    return
}
```

What CritiqueGate does internally that studio-core does not need to reimplement:
- Runs a DETERMINISTIC copy-law tier FIRST, zero API calls: it scans the
  tag-stripped text for em/en dashes and spelled-out dollar amounts, and runs
  `FactGuard.audit(brand:artifact:)` when `brandSlug` is a known catalog brand.
  Any hit pre-fills a blocking `copy-law` REFUTE and the model is not asked about
  copy-law. This is the brand-law dimension a generic design tool cannot have.
- Runs the 5 model dimensions (visual-hierarchy, responsiveness, accessibility,
  brand-fit, copy-law) with the QualityGate warm-then-fan-out prompt-cache pattern
  over one shared, byte-identical HTML prefix (`completeCached`, cap 60000 chars,
  spanName `studio.critique.<dim>`, feature `design_studio`).
- Fails closed: no key or empty artifact returns `.error`, never `.pass`. Injected
  `VERDICT:` lines inside the HTML cannot spoof the gate (sentinels plus the reused
  `QualityGate.parseVerdict` last-line-wins parser).

Design system input: pass the brand's design-system markdown (the same doc
ws-design-systems produces) so the brand-fit reviewer can refute off-palette colors,
a wrong type scale, and off-voice copy. It is injected into the shared reviewer
prefix; nil is fine (brand-fit then judges general design quality only).

---

## 2. InspectorScript install into the preview's InspectorScriptProvider

The preview WKWebView (studio-core's `InspectorScriptProvider`, per UI architecture
contract section 4.5) installs the inspector into the ISOLATED content world:

```swift
let world = WKContentWorld.world(name: "gruxInspector")
let userScript = WKUserScript(source: InspectorScript.script,
                              injectionTime: .atDocumentEnd,
                              forMainFrameOnly: true,
                              in: world)
config.userContentController.addUserScript(userScript)
config.userContentController.addScriptMessageHandler(coordinator,      // NSObject, weakly held
                                                     contentWorld: world,
                                                     name: "gruxInspect")
```

The script installs once (guards on `window.__gruxInspectorInstalled`), draws a 2px
accent hover outline with a single absolutely positioned overlay div (it never
mutates the hovered element's own styles), and on click posts to
`window.webkit.messageHandlers.gruxInspect`. Page JS cannot see the isolated world.

Driving the inspector from Swift (same world):
- Snap-to-brand recolor: `window.__gruxInspector.applyRecolor([hex, hex, ...])`
  with the brand palette hexes (for example from the chosen `DesignDirection.paletteHex`):

  ```swift
  let js = "window.__gruxInspector.applyRecolor(\(jsonArrayString(brandHexes)))"
  webView.evaluateJavaScript(js, in: nil, in: WKContentWorld.world(name: "gruxInspector"))
  ```
- Undo overlay + recolor: `window.__gruxInspector.clearInspect()`.
- Toggle select mode: `window.__gruxInspector.setActive(true|false)`.

Remember `removeAllScriptMessageHandlers()` in `dismantleNSView` to break the
WKUserContentController retain cycle (UI contract section 4.5, point 5).

---

## 3. Surgical flow consuming the gruxInspect payload

The message handler receives this payload on the main thread:

```
{ selector: String, rect: {x,y,width,height}, computedStyles: {color,background,fontSize,fontFamily}, textContent: String }
```

The `selector` is exactly what `SurgicalEditEngine.locate` consumes (id, or a
tag.class chain, with an nth-child fallback). Studio-core keeps the last clicked
`selector` and, when you type a comment/instruction for that element and submit:

```swift
let request = SurgicalEditRequest(
    filePath: artifactIndexPath,       // studio-core owns the path
    selector: lastInspectedSelector,   // from the gruxInspect payload
    instruction: ownerComment,         // "make this headline tighter"
    fileContent: currentFileText       // the current artifact text
)

// Show the surgical cost next to a full-regen cost (ws-cost-meter owns the full one):
let surgicalTokens = request.estimatedTokens   // span + ~20 lines context + instruction, chars/4

let result = await SurgicalEditEngine.edit(request, apiKey: AppState.shared.anthropicKey)
switch result {
case .patched(let newContent):
    // studio-core owns the write + the DesignVersion snapshot, then reloads the preview
    try? newContent.write(toFile: artifactIndexPath, atomically: true, encoding: .utf8)
case .needsFullContext(let reason):
    // selector did not locate: degrade to a full regeneration
case .failed(let reason):
    // no key or unparseable patch: leave the file untouched, surface the reason
}
```

The engine performs no I/O: it returns the new full content and the caller owns
writes and version snapshots. The model call uses `ClaudeClient.complete` with
spanName `studio.surgical`, feature `design_studio`, behind the injectable
`SurgicalModelCalling` seam (tests stub it). The prompt carries ONLY the located
span plus about 20 lines of context inside sentinels, and the model returns the
replacement between `GRUX_PATCH_BEGIN` / `GRUX_PATCH_END`, parsed fail-closed.

---

## 4. Direction picker call site

Before committing tokens to a full generation, fan out 5 direction sketches:

```swift
let directions = await DirectionEngine.directions(
    brief: enrichedBrief,
    brandSlug: project.brandSlug,
    designSystemMarkdown: designSystemMarkdown,
    apiKey: AppState.shared.anthropicKey
)
```

Each `DesignDirection` carries `name`, `thesis`, `paletteHex: [String]`,
`headlineFont`, `vibeWords: [String]`. Render them as pickable cards (palette
swatches from `paletteHex`, the thesis line, vibe chips). When a design system is
present, `directions[0]` is always the on-system option using the exact extracted
palette; the rest explore. One cheap-model call (claude-haiku-4-5, 1200 max tokens,
spanName `studio.directions`), parsed fail-soft: a malformed reply or an empty key
falls back to a deterministic set derived from the design-system palette. On
selection, fold the chosen direction into the generation brief / `DesignRunConfig`
(and optionally pass `paletteHex` to `applyRecolor` for a live snap-to-brand).

---

## 5. Turn-1 clarifying intake call site

On a fresh brief, gate generation behind the intake:

```swift
let questions = ClarifyingIntake.questions(
    brief: rawBrief,
    brandSlug: project.brandSlug,
    designSystemMarkdown: designSystemMarkdown
)
if questions.isEmpty {
    // brief is already clear (ConfidenceGate heuristic): go straight to directions/generation
} else {
    // present the compact form; onSubmit returns the enriched brief
    DesignIntakeFormView(brief: rawBrief, questions: questions) { enrichedBrief in
        // feed enrichedBrief into DirectionEngine.directions(...) / generation
    }
}
```

`questions(...)` runs `ConfidenceGate.assessGroundedHeuristic` (nonisolated, free,
no model). It returns [] when the brief is already clear, otherwise up to 4
questions with audience and voice prefilled from the design system's brand and
voice sections, so you answer two things instead of eight. `DesignIntakeFormView`
uses `GruxFormSection` styling and hands back the enriched brief via `onSubmit`.

---

## Gates honored

- `swift build --target Grux` green.
- 3 test filters green: CritiqueGateDeterministicTests, SurgicalEditLocatorTests,
  DirectionParseTests (25 tests, 0 failures, no live model calls).
- Zero em/en dashes (including JS strings and fixtures), `$N` dollars, fail-closed
  verdict parsing, prompt-injection sentinels on every model review, spanName +
  feature `design_studio` on every model call, no secrets.

## Residual gaps for the integrator

- CritiqueGate + FactGuard product-fact grounding is real only for a brand that has
  seeded catalog rows. Other brands get every non-catalog check (dashes, dollars,
  hierarchy, a11y, brand-fit vs the design system); catalog grounding lands when a
  brand gets catalog rows. This matches OutputGate's documented seeded-catalog-only tier.
- The surgical locator is tolerant, not a full DOM. It matches the LAST selector
  segment (ancestor constraints in a chain are not enforced) and treats
  `:nth-child(k)` as the k-th tag+class match. Inspector-generated selectors are
  specific enough for this; a hand-typed ambiguous selector may land on the first
  match. On any miss it returns `.needsFullContext` so the caller degrades safely.
- `DesignIntakeFormView` renders questions and returns an enriched brief; wiring its
  `onSubmit` into the run pipeline (and persisting answers if desired) is studio-core's.
