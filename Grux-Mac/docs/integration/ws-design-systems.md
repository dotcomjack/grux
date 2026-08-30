# INTEGRATION: Design Systems + SKILL.md folder backend (ws/design-systems)

Everything in this workstream is self-contained and already builds green
(`swift build --target Grux`) with the three test suites passing. Nothing here
is wired into `ChatService`, the sidebar, or Settings yet, by design: the lines
below are the exact edits the integrating stream (studio-core / shell) applies
so registration lives in exactly one place.

## Files created

- `Sources/Grux/DesignStudio/DesignSystems/DesignSystemModels.swift` : the 9-section DESIGN.md schema (`DesignSystem`) with `parse(markdown:slug:)`, `render()`, `systemPromptBlock()`, and derived `paletteHex` / `typeScale` tokens. Open Design DESIGN.md compatible.
- `Sources/Grux/DesignStudio/DesignSystems/DesignSystemStore.swift` : `@MainActor` singleton store (test seam `init(rootDir:)`), disk at `~/Documents/Grux/design-systems/<slug>/DESIGN.md` + `index.json`, per-brand active-system map, drift reindex.
- `Sources/Grux/DesignStudio/DesignSystems/BrandSystemGenerator.swift` : generates a DESIGN.md per brand from the registry roster + `BrandStyleLibrary` + `ProductCatalog.contextBlock`, with the baked house law in every system.
- `Sources/Grux/DesignStudio/DesignSystems/DesignSystemTools.swift` : the `DesignSystemTools` chat tool family (list / activate / generate_brand / import). NOT registered in ChatService (see below).
- `Sources/Grux/Memory/Hybrid/SkillFolderBackend.swift` : SKILL.md folder mirror beside `skills.json`, plus the `Persistence.skillsDir` root.

## Files edited (owned)

- `Sources/Grux/Memory/Hybrid/SkillStore.swift` : added an `isDefaultStore` flag, a best-effort `SkillFolderBackend.exportAfterSave` call in `saveNow()` (default store only, so the test seam never touches the real folder tree), and a public `importFromFolders()`. Every existing signature and the debounce/flush semantics are unchanged.

## 1. Register `DesignSystemTools` in ChatService

Registration, next to the other `claudeTools()` appends (around `ChatService.swift:892`, beside `DocumentTools`):

```swift
tools.append(contentsOf: DesignSystemTools.claudeTools())
```

Dispatch, in `dispatchTool` next to the other `toolNames.contains(name)` cases (around `ChatService.swift:1448`):

```swift
case _ where DesignSystemTools.toolNames.contains(name):
    return await DesignSystemTools.dispatch(name: name, input: input)
```

That is the entire wiring for the four tools (`design_system_list`,
`design_system_generate_brand`, `design_system_activate`, `design_system_import`).

## 2. Bind `DesignSystemStore` as the studio's `DesignSystemProviding` seam

The studio engine consumes an active brand system by asking a provider for its
DESIGN.md markdown. The store already exposes the exact method the seam needs:

```swift
func activeSystemMarkdown(brandSlug: String) -> String?
```

When studio-core declares its provider protocol, `DesignSystemStore.shared`
conforms with zero adapter code. The one-line binding on the studio side is:

```swift
// studio-core, where the engine is constructed (all on @MainActor):
protocol DesignSystemProviding { func activeSystemMarkdown(brandSlug: String) -> String? }
extension DesignSystemStore: DesignSystemProviding {}
// ... engine.designSystemProvider = DesignSystemStore.shared
```

Inject the result into a generation/critique system prompt via
`DesignSystem.parse(markdown: md, slug: brandSlug).systemPromptBlock()` for the
compact form, or feed the raw markdown straight through.

To seed systems for the whole empire on first run (registry + curated brands):

```swift
await BrandSystemGenerator().generateAll()   // fetches the registry; writes each to DesignSystemStore.shared
```

`generateAll(projects:into:)` accepts injected fixture projects and a target
store for tests, so it never needs the network there.

## 3. Settings note: SKILL.md folder import

The SKILL.md folder mirror is written automatically by the shared `SkillStore`
on every save. To let you (or a teammate) drop hand-authored `SKILL.md`
folders into `~/Library/Application Support/Grux/skills/<name>/` and pull them
in, add one control in `SkillsView` / Settings that calls:

```swift
SkillStore.shared.importFromFolders()   // merge-not-wipe, newest updatedAt wins, dedupe by name
```

Optionally call `SkillFolderBackend.reindexIfDriftDetected(into: SkillStore.shared)`
on launch to auto-pick-up only brand-new dropped folders without touching
skills the store already tracks.

## 4. Residual gaps

- No sidebar tab or SwiftUI surface for design systems (studio-core owns the tab wiring per the split). The store is `ObservableObject` with `@Published entries`, ready to bind.
- `SkillFolderBackend.export` is additive: deleting a skill does not delete its `SKILL.md` folder, so a later `importFromFolders()` would resurrect it (merge-not-wipe by design). If deletion should propagate, add a prune pass to `export` that removes folders whose front-matter name is absent from the current set, while preserving hand-dropped folders. Left out deliberately so the drift-reindex path stays safe.
- Grounding (`ProductCatalog.contextBlock`) is only rich for a brand that has seeded catalog rows; other brands' `brand` section carries style notes but no product facts until their catalog rows exist (same limitation the grounding stack already has).
- `design_system_generate_brand` uses the live `ProductCatalog` and `BrandStyleLibrary`; a registry brand with no `BrandStyle` gets a clean generic system (still fully lawful), which is the intended behavior.
