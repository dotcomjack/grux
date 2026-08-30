# WS-F Integration: Export, Interop, MCP Server

Workstream: export pipeline, competitor importers, design-to-code, and the
standalone read-only MCP server. Branch `ws/export-mcp`.

## Files created

- `Sources/Grux/DesignStudio/Export/ExportPipeline.swift`: @MainActor ExportPipeline (PDF, PNG, ZIP, Markdown) with the injectable `HTMLRendering` seam and the WebKit live renderer.
- `Sources/Grux/DesignStudio/Export/CodeExport.swift`: design-to-code (Astro component + first-pass SwiftUI) plus the tolerant `HTMLMiniParser`.
- `Sources/Grux/DesignStudio/Export/MCPServerLogic.swift`: tested reference of the read-only MCP server core (app target, so `swift test` covers it).
- `Sources/Grux/DesignStudio/Import/ClaudeDesignImporter.swift`: import a competitor design-export ZIP into a new project, plus shared `DesignImportSupport`.
- `Sources/Grux/DesignStudio/Import/ODProjectImporter.swift`: import a competitor project directory (DESIGN.md staging + HTML artifacts).
- `Sources/GruxMCPServer/MCPServerCore.swift`: standalone Foundation-only copy of the server core (the shipped binary logic).
- `Sources/GruxMCPServer/main.swift`: `grux-mcp` executable entry point (stdin/stdout).
- `Tests/GruxTests/CodeExportTests.swift`: Astro + SwiftUI transforms, incl. unrecognized-element comment.
- `Tests/GruxTests/ImporterTests.swift`: ZIP importer (archive built in-test) + OD directory importer.
- `Tests/GruxTests/MCPServerCoreTests.swift`: framing seam, handshake, tools/list, tools/call happy + unknown-tool error, string-id echo.

## Test status

`swift build --target Grux` is green. All three new filters are green:

```
swift test --filter CodeExportTests --filter ImporterTests --filter MCPServerCoreTests
# Executed 25 tests, with 0 failures
```

The standalone binary was build-verified by temporarily registering the target
(reverted before commit) and driven over stdio: initialize, tools/list, and a
tools/call round-trip all returned correct frames, string ids echoed verbatim.

## Package.swift snippet (REQUIRED for the MCP server to build in CI)

The `GruxMCPServer` sources are committed but NOT registered in `Package.swift`
(the workstream is forbidden from editing it). Until this snippet is applied the
standalone server does not compile in CI, which is expected; the app target and
all tests are unaffected. Add, inside `products:`:

```swift
.executable(name: "GruxMCPServer", targets: ["GruxMCPServer"])
```

and inside `targets:`:

```swift
// Standalone stdio MCP server (grux-mcp). Foundation-only, no AppKit, does
// not depend on the Grux app target. Exposes read-only Grux design data to
// external MCP clients.
.executableTarget(
    name: "GruxMCPServer",
    path: "Sources/GruxMCPServer"
),
```

### Why the server core is duplicated (and how to de-dupe post-integration)

The tested core lives in the app target (`MCPServerLogic.swift`) because the
test target only sees the app module without a `Package.swift` edit, and the
standalone executable cannot import the app target (it pulls in AppKit and
WebKit). Both copies are Foundation-only and JSONSerialization-based so they
stay byte-for-byte comparable. The clean follow-up once `Package.swift` can be
touched: extract the core into a Foundation-only library target
(`GruxMCPCore`), make both `Grux` and `GruxMCPServer` depend on it, and delete
`Sources/GruxMCPServer/MCPServerCore.swift`. Until then, keep the two in sync.

## Install helper: register grux-mcp with Claude Code

Build a release binary and register it once:

```bash
cd Grux-Mac
swift build -c release --product GruxMCPServer
BIN="$(pwd)/.build/release/GruxMCPServer"
# Optionally copy to a stable location so rebuilds do not move it:
#   cp "$BIN" ~/.grux/grux-mcp && BIN=~/.grux/grux-mcp
claude mcp add grux -- "$BIN"
```

It is read-only: it reads the same on-disk stores the Grux app writes
(`~/Documents/Grux/design`, `~/Documents/Grux/design-systems`,
`~/Library/Application Support/Grux/skills.json`,
`~/Library/Application Support/Grux/projects-cache.json`) and never modifies
them. Tools exposed: `grux_list_design_projects`, `grux_get_design_project`,
`grux_list_design_systems`, `grux_get_design_system`, `grux_list_skills`,
`grux_list_brands`.

## Engine wiring for the export menu actions

The Design Studio engine/store (studio-core) owns each project's folder at
`~/Documents/Grux/design/<slug>/`. Build an `ExportPipeline.Request` from it and
call the pipeline (all four run for the active project; PDF/PNG are async and
MainActor, ZIP is async, Markdown is sync):

```swift
let request = ExportPipeline.Request(
    projectDir: store.projectDir(for: project),   // ~/Documents/Grux/design/<slug>
    slug: project.slug,
    brandSlug: project.brandSlug
)
let pdfURL = try await ExportPipeline.exportPDF(request)   // vector, offscreen WKWebView
let pngURL = try await ExportPipeline.exportPNG(request)   // full-content snapshot
let zipURL = try await ExportPipeline.exportZIP(request)   // whole project, minus versions/
let mdURL  = try ExportPipeline.exportMarkdown(request)     // readable transcription
```

All outputs land in `<project>/exports/<slug>-<yyyyMMdd-HHmmss>.<ext>`, brand
prefixed when `brandSlug` is set. Tests inject a fake renderer via the optional
`renderer:` parameter on `exportPDF`/`exportPNG`; production passes nil and gets
the live WebKit renderer.

Design-to-code (pure, synchronous, no store needed):

```swift
let astro   = CodeExport.astroComponent(html: html, css: css, name: project.title)
let swiftUI = CodeExport.swiftUIView(html: html, name: project.title)
```

Importers (return the created slug so the store can select the new project):

```swift
let zipResult = try ClaudeDesignImporter.importArchive(at: droppedZipURL)
// -> zipResult.slug, then store.reindexIfDriftDetected() to pick it up

let odResult = try ODProjectImporter.importProject(at: droppedDirURL)
// -> odResult.slug (nil if no HTML), odResult.designSystemFiles staged under
//    ~/Documents/Grux/design-systems/incoming/ for the design-system store to ingest
```

Both importers default their roots to the real `~/Documents/Grux/...` paths and
take injectable roots for tests. They deliberately do NOT declare
`Persistence.designDir`/`designSystemsDir` extensions to avoid colliding with
the store's own declaration; they compute the default paths inline.

Optional: expose the exporters and importers as Claude tools by adding a
`DesignExportTools` adapter (claudeTools/toolNames/dispatch) to
`ChatService.allTools()` and `dispatchTool` the same way DocumentTools is wired.
Left to studio-core so there is one owner of the DesignTools surface.

## Residual gaps

- MP4 export is deferred (needs a frame-capture + encode path; not in this pass).
- PPTX / deck export is deferred.
- The OD importer does NOT parse the competitor tool's proprietary SQLite
  metadata (schema undocumented and unstable in v1); it takes only the portable
  DESIGN.md files and rendered HTML artifacts. Documented in the file header.
- The SwiftUI code export is an explicit first pass: it recognizes headings,
  paragraphs, images, buttons/links, and flex-hinted div stacks, and marks
  everything else as a comment. It is a labeled starting point, not production
  SwiftUI.
- The two server-core copies must be kept in sync until the shared-library
  refactor above lands.
```
