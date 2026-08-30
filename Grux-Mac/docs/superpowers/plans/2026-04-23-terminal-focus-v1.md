# Terminal Focus v1, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the v1 scope of Terminal Focus: a 60×60 centered floating overlay that tails `~/.claude/projects/*/*.jsonl`, shows 4 corner labels of live Claude-session context, with manual slot mapping, global hotkey, and menubar toggle.

**Architecture:** Extend the existing `TerminalFocus*.swift` scaffolding. New data source (`ClaudeSessionTailer`) swaps out the legacy `.grux/focus/*.activity.jsonl` reader. Pure parser + mapper are unit-tested. Panel geometry + event handling rewritten. Settings tab added. Hotkey registered in `applicationDidFinishLaunching`.

**Tech stack:** Swift 5.9, SwiftPM, macOS 14+, AppKit + SwiftUI. Carbon API for the global hotkey.

---

## Task 1, Design doc + plan

**Files:**
- Create: `docs/specs/terminal-focus-design.md`
- Create: `docs/superpowers/plans/2026-04-23-terminal-focus-v1.md` (this file)

Committed first so the rest of the work references a fixed spec.

## Task 2, JSONL parser + SPM test target

**Files:**
- Create: `Sources/Grux/ClaudeSession/ClaudeSessionJSONL.swift`
- Create: `Tests/GruxTests/ClaudeSessionJSONLTests.swift`
- Modify: `Package.swift` (add `.testTarget(name: "GruxTests", dependencies: ["Grux"], path: "Tests/GruxTests")`)

TDD: write test vectors first that decode a full JSONL stream and yield a `ClaudeSessionSnapshot` with asserted values for `totalInputTokens`, `totalOutputTokens`, `totalCostUSD` (Opus 4.7 rates), `currentTool` (a tool-use with no subsequent assistant-text), and `lastAssistantSummary` (truncated, first-line-only). Then implement.

Pricing table is hardcoded: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`, extend as needed, unknown models cost $0.

## Task 3, Slot mapper + tests

**Files:**
- Create: `Sources/Grux/ClaudeSession/ClaudeSessionSlotMapper.swift`
- Create: `Tests/GruxTests/ClaudeSessionSlotMapperTests.swift`

Pure function: `static func map(config: SlotMapping, snapshots: [String: ClaudeSessionSnapshot]) -> [OverlayCorner: ClaudeSessionSnapshot]`. Stale / missing sessionIDs map to nothing (omitted from output). Unit tests cover empty config, partial, full, and stale-mapping scenarios.

## Task 4, Index + tailer

**Files:**
- Create: `Sources/Grux/ClaudeSession/ClaudeSessionIndex.swift`
- Create: `Sources/Grux/ClaudeSession/ClaudeSessionTailer.swift`

`ClaudeSessionIndex.recentSessions(limit: 50)` scans `~/.claude/projects/*/*.jsonl`, sorts by mtime desc, and returns `[(sessionId, fileURL, title, cwd, lastActiveAt)]` by reading just enough of each file to get cwd + last user/assistant timestamp. `ClaudeSessionTailer` owns per-file offsets and a `Timer` (2s), re-parses only newly-appended bytes, publishes `@Published var snapshotsBySessionId: [String: ClaudeSessionSnapshot]`.

## Task 5, Persistence + config

**Files:**
- Create: `Sources/Grux/TerminalFocusConfig.swift`
- Modify: `Sources/Grux/Persistence.swift` (add `terminalFocusConfigURL`)

Codable struct shape documented in `docs/specs/terminal-focus-design.md`. `TerminalFocusConfig.load()` / `.save()` static helpers over `Persistence.load/save`.

## Task 6, State integration

**Files:**
- Modify: `Sources/Grux/TerminalFocusState.swift`

Add `@Published var cornerSnapshots: [OverlayCorner: ClaudeSessionSnapshot] = [:]`, own a `ClaudeSessionTailer` instance, subscribe to its changes + the `TerminalFocusConfig.slotMapping` to recompute `cornerSnapshots` on every refresh. Also publish `overlayVisible` (bound to config) and rework `toggleOverlay()` to flip it + show/hide the panel. Legacy `.grux/focus` code stays intact but is not wired to the new corner rendering.

## Task 7, Panel geometry + behavior

**Files:**
- Modify: `Sources/Grux/TerminalFocusPanel.swift`

New frame: centered on the screen hosting the mouse, 60% × 60% of `visibleFrame`. `NSWindow.Level.floating`. `ignoresMouseEvents = true` whenever the panel is not the key window AND no NSTrackingArea is hovered. Add a hosting NSView subclass with a full-frame tracking area; entering → `ignoresMouseEvents = false` + opacity 1.0; exiting → `ignoresMouseEvents = true` + opacity 0.7 (animated 0.15s).

## Task 8, Corner label view

**Files:**
- Modify: `Sources/Grux/TerminalFocusView.swift` (add `CornerLabel` + swap the 2×2 grid body for the new snapshot-driven layout)

SwiftUI view bound to `ClaudeSessionSnapshot?`. Layout: title+branch on top, relative-time + current-tool in middle, tokens/cost line, truncated latest assistant summary on bottom. Unmapped state shows dim `, unassigned ,` text. Styled with `GruxTheme` tokens only (no hardcoded colors).

## Task 9, Settings tab

**Files:**
- Modify: `Sources/Grux/TerminalFocusSettingsView.swift`
- Modify: `Sources/Grux/SettingsView.swift`

Add new "Claude session mapping" section: 4 `Picker`s (one per corner) populated from `ClaudeSessionIndex.recentSessions()`. Below it, a "Hotkey" section with a `HotkeyRecorder` view that captures `NSEvent` modifier + keyCode. Saves to `TerminalFocusConfig`. Add as a new tab in `SettingsView.swift` between "Focus" and "Ambient".

## Task 10, Global hotkey

**Files:**
- Create: `Sources/Grux/GlobalHotkey.swift`
- Modify: `Sources/Grux/GruxApp.swift` (register after `TerminalFocusState.shared.start()`)

Thin Carbon wrapper: `RegisterEventHotKey` + `InstallEventHandler`. `GlobalHotkey.register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void)`, single-instance, calls `unregister()` first. Registration flip occurs when the user changes the combo in settings.

## Task 11, Build + verify

**Files:**
- None modified, verification only.

Run `./build.sh` (must emit a `build/Grux.app`). Run `swift test` from repo root (must be green). Launch the app manually and walk the manual-test checklist in the design doc.
