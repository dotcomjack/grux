# Design Studio (WS-A Studio Core) integration

This workstream landed the Design Studio core: the split chat + live preview tab,
the streaming artifact pipeline, folder-level version history, and the design
chat tools. Everything is self-contained under `Sources/Grux/DesignStudio/` and
`Tests/GruxTests/`, wired to sibling workstreams only through seams. It does NOT
touch `Package.swift`, `ChatService.swift`, `ChatView.swift`, `SidebarModel.swift`,
`LaunchRootView.swift`, `SettingsView.swift`, `GruxApp.swift`, or any other
workstream's files. Apply the snippets below to activate it.

`swift build --target Grux` is green. `DesignProjectStoreTests` (15) and
`DesignArtifactParserTests` (11) pass.

## Files created

- `Sources/Grux/DesignStudio/DesignArtifactParser.swift` : chunk-safe streaming extractor of `<grux-artifact path="site/...">` blocks into fileStarted/fileChunk/fileCompleted/passthrough events; rejects traversal + non-site paths.
- `Sources/Grux/DesignStudio/DesignProjectStore.swift` : `@MainActor` store singleton, `~/Documents/Grux/design/<slug>/` layout, full-folder version snapshots, chat transcript, index-drift self-heal, `extension Persistence { static var designDir }`, plus the `DesignChatMessage` type.
- `Sources/Grux/DesignStudio/DesignStudioEngine.swift` : `@MainActor` engine singleton owning the generation run (routing, own system prompt, streaming, file writes, per-run snapshot); defines the seams `DesignSystemProviding`, `DesignCritiquing`, `DesignRunEstimating`, `DesignAgentDelegating`, plus `DesignEstimateContext` and `DesignStudioError`.
- `Sources/Grux/DesignStudio/DesignPreviewView.swift` : sandboxed WKWebView (non-persistent store, cached no-network content rules, nav allowlist, fenced loadFileURL, isolated-world inspector seam); plus `InspectorScriptProvider.script` and `StudioContentRules`.
- `Sources/Grux/DesignStudio/DesignStudioView.swift` : the `DesignStudioView` tab (HSplitView: project list + transcript + composer + run controls; preview + version strip).
- `Sources/Grux/DesignStudio/DesignTools.swift` : `enum DesignTools` chat tool family (create / generate / list / open / restore).
- `Tests/GruxTests/DesignProjectStoreTests.swift`, `Tests/GruxTests/DesignArtifactParserTests.swift`.

## 1. SidebarModel.swift (intelligence group)

Append the Design Studio item to the `intelligence` group and relabel the
existing `creative` item to "Media Studio" (label change only, the key stays
`creative` per the naming-collision rule). In `SidebarIA.groups`, intelligence
group:

```swift
SidebarGroupDef(id: "intelligence", title: "Intelligence", items: [
    SidebarItem(key: "research", label: "Research", icon: "text.magnifyingglass"),
    SidebarItem(key: "skills", label: "Skills", icon: "graduationcap.fill"),
    SidebarItem(key: "compare", label: "Compare", icon: "rectangle.split.2x1.fill"),
    SidebarItem(key: "cookbook", label: "Local Models", icon: "cpu.fill"),
    SidebarItem(key: "creative", label: "Media Studio", icon: "wand.and.sparkles"),        // relabeled from "Studio"
    SidebarItem(key: "designStudio", label: "Design Studio", icon: "paintbrush.pointed.fill")  // NEW
]),
```

## 2. LaunchRootView.swift (four places, all required)

The key string `"designStudio"` MUST match verbatim in all four or navigation
silently falls back to chat.

a. `enum Tab` (L28): add `designStudio`:
```swift
enum Tab: Hashable { case home, reactor, chat, ..., creative, ..., designStudio, ..., settings }
```

b. Detail switch (near L68, beside `case .creative: CreativeStudioView()`):
```swift
case .designStudio: DesignStudioView()
```

c. `tab(forKey:)` (near L275, beside `case "creative": return .creative`):
```swift
case "designStudio": return .designStudio
```

d. `tabKey(for:)` (near L316, beside `case .creative: return "creative"`):
```swift
case .designStudio: return "designStudio"
```

## 3. ChatService.swift (register + dispatch the DesignTools)

a. Registration in `allTools()` (beside L892 `tools.append(contentsOf: DocumentTools.claudeTools())`):
```swift
tools.append(contentsOf: DesignTools.claudeTools())
```

b. Dispatch in `dispatchTool(name:input:)` (beside L1448 the DocumentTools case):
```swift
case _ where DesignTools.toolNames.contains(name):
    return await DesignTools.dispatch(name: name, input: input)
```

Optional but recommended: claim the `design_` prefix in a `PresetToolGroup` (a
new case or a `memberPrefixes` entry in `Presets/PresetModels.swift`) so the
Design Studio tools are preset-filterable rather than fail-open core plumbing.

## 4. Seam bindings (sibling workstreams)

The engine runs today with all seams unbound (empty design system, no critique,
hidden cost line, subscriptionCLI returns a clear "not wired yet" message). Bind
the real implementations once, on the main actor at app startup (e.g. in
`GruxApp` init or a `setupServices()` call). All hooks are `@MainActor` static
vars on `DesignStudioEngine`:

```swift
DesignStudioEngine.designSystemProvider = MyDesignSystemProvider()   // DesignSystemProviding: activeSystemMarkdown(brandSlug:) -> String?
DesignStudioEngine.critic              = MyDesignCritic()            // DesignCritiquing: critique(html:brandSlug:) async -> String?
DesignStudioEngine.estimator           = MyRunEstimator()           // DesignRunEstimating: estimate(for: DesignEstimateContext) -> DesignRunEstimate?
DesignStudioEngine.agentDelegate       = MyAgentBridge()            // DesignAgentDelegating: runGeneration(projectId:brief:config:) async throws  (subscriptionCLI route)
```

- The estimator drives the composer's "estimated $N" line (rendered only when
  bound; every rendering already carries the word "estimated").
- The iteration workstream replaces `InspectorScriptProvider.script` (in
  DesignPreviewView.swift) with the real element-picker JS and consumes
  `DesignStudioEngine.shared.lastInspectPayload`.

## Residual gaps / notes for integrators

- **subscriptionCLI route**: not implemented here by design. Until
  `DesignStudioEngine.agentDelegate` is bound, selecting the "Claude Code
  subscription" route surfaces a clear notImplemented message in the transcript
  (the composer also shows an amber caption). The API and Local routes work now.
- **No settings pane** was added; not required by the core. If wanted, follow
  the UI contract section 3 (prefer a sub-pane / anchored section over a 6th tab).
- **Live byte streaming into the preview** is intentionally deferred: the engine
  writes files on `.fileCompleted` and posts `.gruxDesignArtifactsUpdated`; the
  preview reloads on the revision bump. Per-keystroke streaming of file bytes is
  the iteration workstream's job (the `.fileChunk` events are already emitted).
- **Backup coverage** is automatic: `~/Documents/Grux/design/` sits under
  BackupManager's `documentsRoot`. `versions/` snapshots are regenerable-ish but
  small; no exclusion added. Revisit if project trees get large.
- **Transcript refresh** in the view is driven by the engine's `@Published`
  state plus the artifacts-updated notification (the store's transcript is on
  disk, not `@Published`); this is adequate for the run boundaries but a chatty
  live-token transcript would want a published mirror.
- Tests run against the `init(rootDir:)` seam; the store's `init(rootDir:)` also
  runs `reindexIfDriftDetected()` so drift recovery is exercisable.
