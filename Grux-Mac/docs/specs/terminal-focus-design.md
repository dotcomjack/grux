# Terminal Focus, Design Doc (v1)

**Status:** in progress · **Owner:** the owner / Claude Opus 4.7 · **Platform:** macOS 14+ / ARM64

## Problem

When 4 Claude Code terminal windows are tiled into the screen corners, the
center "5th position" is empty. You want a floating SwiftUI overlay that
fills that center gap and gives at-a-glance awareness of what the 4
surrounding Claude sessions are doing, without interrupting the work you are
focused on in the center terminal.

## Non-goals (v1)

- Auto-detecting which session belongs in which corner (v2, geometry match).
- Click-to-open-session-in-terminal (v2).
- Token / cost sparkline + heatmap (v2).
- Any interactivity beyond the ⌥⌘T toggle + hover-to-focus.

## Behavior

| Attribute            | Value                                                      |
| -------------------- | ---------------------------------------------------------- |
| Geometry             | 60% × 60%, centered on the active screen                   |
| Level                | `NSWindow.Level.floating`, joins all Spaces                |
| Opacity              | 0.7 when not focused; 1.0 on hover / when key              |
| Mouse                | `ignoresMouseEvents = true` when unfocused (click-through) |
| Hotkey               | ⌥⌘T (configurable)                                         |
| Menubar              | Toggle item alongside existing Terminal-Focus menu         |
| Per-corner rendering | title/cwd · last-message ts · current tool · in/out tokens · $cost · 1-line assistant summary |

## Architecture

Existing work (~2600 LOC across `TerminalFocus*.swift`) is kept and extended.
The swap is the **data source**: instead of a Claude Code PostToolUse hook
writing to `~/.grux/focus/*.activity.jsonl`, v1 tails Claude's own
`~/.claude/projects/<slug>/<session-uuid>.jsonl` files directly. No hook
install required.

```
┌───────────────────────────┐    ┌────────────────────────────────┐
│ ~/.claude/projects/<slug>/│    │  TerminalFocusConfig.json       │
│   <sessionUUID>.jsonl     │    │  (slotMapping, hotkey, visible) │
└──────────────┬────────────┘    └────────────────┬───────────────┘
               │ tail + parse                     │ load/save
               ▼                                  ▼
  ┌───────────────────────────┐        ┌──────────────────────────┐
  │ ClaudeSessionTailer       │◀──────▶│ ClaudeSessionSlotMapper  │
  │  (per-file offset)        │        │  Corner → SessionID      │
  └──────────────┬────────────┘        └──────────────┬───────────┘
                 │ [SessionID: Snapshot]              │
                 ▼                                    │
            ┌──────────────────────────────────────┐  │
            │ TerminalFocusState (existing)        │◀─┘
            │  + @Published cornerSnapshots        │
            │  + start / stop bridge               │
            └──────────────┬───────────────────────┘
                           │
                           ▼
       ┌───────────────────────────────────────────┐
       │ TerminalFocusPanel (60×60 floating NSPanel)│
       │   hosts TerminalFocusView                  │
       │     → 4× CornerLabel(snapshot)             │
       └────────────────────────────────────────────┘
                ▲                     ▲
                │ show/hide/toggle    │ ⌥⌘T
       MenuBarView (existing)   GlobalHotkey
```

### New files

| Path                                                        | Responsibility                                             |
| ----------------------------------------------------------- | ---------------------------------------------------------- |
| `Sources/Grux/ClaudeSession/ClaudeSessionJSONL.swift`       | Parse one JSONL line → typed entry; fold into Snapshot.    |
| `Sources/Grux/ClaudeSession/ClaudeSessionIndex.swift`       | Enumerate `~/.claude/projects/*/*.jsonl`, return recent.   |
| `Sources/Grux/ClaudeSession/ClaudeSessionTailer.swift`      | Per-file offset map; incremental read on 2s timer.         |
| `Sources/Grux/ClaudeSession/ClaudeSessionSlotMapper.swift`  | Pure mapping Corner→Snapshot (unit-testable).              |
| `Sources/Grux/TerminalFocusConfig.swift`                    | Codable struct + URL extension on Persistence.             |
| `Sources/Grux/GlobalHotkey.swift`                           | Carbon `RegisterEventHotKey` wrapper.                      |
| `Tests/GruxTests/ClaudeSessionJSONLTests.swift`             | Parser test vectors (user / assistant / tool_use / usage). |
| `Tests/GruxTests/ClaudeSessionSlotMapperTests.swift`        | Mapping edge cases.                                        |

### Modified files

| Path                                         | Change                                                   |
| -------------------------------------------- | -------------------------------------------------------- |
| `Package.swift`                              | Add `GruxTests` test target depending on `Grux`.         |
| `Sources/Grux/Persistence.swift`             | `terminalFocusConfigURL` property.                       |
| `Sources/Grux/TerminalFocusState.swift`      | Own ClaudeSessionTailer, publish `cornerSnapshots`.      |
| `Sources/Grux/TerminalFocusPanel.swift`      | 60×60 centered geometry + hover-driven opacity/click-through. |
| `Sources/Grux/TerminalFocusView.swift`       | Render `ClaudeSessionSnapshot` into CornerLabel.         |
| `Sources/Grux/TerminalFocusSettingsView.swift` | Session-picker dropdowns + hotkey capture.             |
| `Sources/Grux/SettingsView.swift`            | New "Terminal" tab hosting `TerminalFocusSettingsView`.  |
| `Sources/Grux/GruxApp.swift`                 | Register/unregister `GlobalHotkey` in lifecycle.         |

## Data model

```swift
// Parsed JSONL entry (discriminated union on `type`).
enum ClaudeSessionEntry {
    case user(ts: Date, text: String)
    case assistant(ts: Date, text: String?, toolUse: String?, usage: Usage?)
    case attachment(ts: Date?)       // mostly ignored
    case permissionMode(sessionId: String)
    case unknown
}

struct Usage {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
}

// Rolled-up per-session view, computed from parsed entries.
struct ClaudeSessionSnapshot {
    var sessionId: String
    var cwd: String?                 // full absolute path from last user entry
    var gitBranch: String?
    var title: String                // derived: cwd basename, or first 60 chars of last user msg
    var lastMessageAt: Date
    var currentTool: String?         // last assistant tool_use name (nil once assistant finalizes)
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCostUSD: Double         // priced via model rate table; 0 if model unknown
    var lastAssistantSummary: String // first line of last assistant `text` content, trimmed to 120 chars
    var model: String?
}
```

Cost estimation uses a static rate table keyed by `message.model`; unknown
models yield `$0.00` and render as `,`. Token counters sum `input_tokens +
cache_creation_input_tokens` and `output_tokens` across all assistant entries.

## Persistence

`~/Library/Application Support/Grux/terminal-focus.json` holds:

```json
{
  "slotMapping": {
    "topLeft": "2f6ef6a9-ebca-47e0-8bc9-d0e816b36353",
    "topRight": "<session-uuid>",
    "bottomLeft": "<session-uuid>",
    "bottomRight": "<session-uuid>"
  },
  "hotkey": { "keyCode": 17, "modifiers": 2304 },
  "overlayVisible": true
}
```

Modifier bit layout follows Carbon flags (`cmdKey | optionKey`). Default
⌥⌘T = `cmdKey | optionKey` with `keyCode=17` (T).

## Sandbox / entitlements

Grux is already **sandbox-off** (`Grux.entitlements` line 21,22). Reading
`~/.claude/projects/` works under the existing file-access model. Paths are
confined to the user's home directory and passed through a fixed prefix
check; no new entitlement required. `LSUIElement=true` is preserved, the
overlay runs inside the existing menubar process.

## Open questions (deferred to v2)

- **Auto slot detection.** v1 is manual. v2 will geometry-match Terminal
  windows → sessions via window bounds + the cwd written to the title bar
  plus the session's cwd.
- **Live streaming of partial assistant turns.** v1 refreshes only on
  finalized JSONL lines (every ~2s). For typing-animation-grade freshness we
  would need to tail in 100ms ticks or hook into Claude Code's writer,   not worth the complexity for v1.

---

## E2E verification results (2026-04-23 bring-up)

**Automated:**
- `swift test`, 24/24 passing (parser: 16, slot mapper: 8).
- `./build.sh`, signs + installs `/Applications/Grux.app` cleanly.
- App launch, `TerminalFocusState.start()` completes, `updateVisibility()`
  fires with `shouldBeVisible=true`, `isVisible` flips to `true`.
- CoreGraphics window enumeration of the running app shows the overlay at
  `frame=(346, 250, 1037, 650)` on a `1728×1117` display, exactly 60% × 60%
  of `visibleFrame`, centered. `layer=3` (NSWindow.Level.floating),
  `alpha=0.71` (matches the 0.7 unfocused default).

**Known gotcha, on first run after this change:** if the legacy
`~/.grux/focus/grux-focus-config.json` exists with `"userHidden": true`
(from a prior dismiss of the old HUD), the overlay will stay parked until
the user explicitly re-summons it via the menubar item, the `⌥⌘T` hotkey,
or the voice macro. This is the intended reuse of the existing user-
dismiss surface; v1 does **not** force-show on launch when the user had
previously dismissed.

## Manual test checklist

Run `./build.sh` first. The checklist assumes 4 Claude Code sessions are
already running in 4 corner terminals, with at least one having produced a
handful of tool calls.

- [ ] `build/Grux.app` builds cleanly, no warnings in the Terminal Focus
      files.
- [ ] `swift test` passes for `GruxTests` target (JSONL + SlotMapper).
- [ ] Launching `build/Grux.app`:
    - [ ] No Dock icon (LSUIElement respected).
    - [ ] Menubar item "GRUX" appears.
- [ ] Menubar menu "Show Terminal Focus Overlay" opens a centered floating
      window that is 60% × 60% of the main screen's visible frame.
- [ ] The overlay stays above the active Terminal window at first, then
      recedes behind clicked Terminal windows (level `.floating`, non-activating).
- [ ] With focus elsewhere, overlay renders at opacity ≈ 0.7.
- [ ] Moving the mouse over the overlay bumps opacity to 1.0; leaving
      restores ≈ 0.7.
- [ ] While unfocused, clicks pass through to underlying windows
      (click-through).
- [ ] Moving the mouse onto the overlay makes it clickable (the × close
      affordance works, buttons respond).
- [ ] Pressing ⌥⌘T anywhere toggles the overlay.
- [ ] Open Grux Settings → **Terminal** tab.
    - [ ] 4 corner dropdowns list recent sessions labeled by `cwd`
          basename + relative timestamp.
    - [ ] Picking a session per corner is persisted across relaunch.
    - [ ] Hotkey field shows ⌥⌘T by default; capturing a new combo
          updates the registration (old combo stops working).
- [ ] Each corner label renders (when a session is mapped):
    - [ ] Project title (cwd basename) + gitBranch if present.
    - [ ] `Last: Xs/Xm/Xh` relative timestamp that updates over time.
    - [ ] Current tool name while an assistant turn is in flight.
    - [ ] Token / cost line e.g. `14.2k in · 3.1k out · $0.12`.
    - [ ] 1-line latest assistant summary, truncated at 120 chars.
- [ ] Unmapped corner renders a subtle ", unassigned ," placeholder.
- [ ] Quitting Grux unregisters the ⌥⌘T hotkey (pressing it after quit
      does nothing).
- [ ] Relaunching restores: overlay visibility, slot mapping, hotkey.
