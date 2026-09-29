# Grux 3.0 Command Panel: the reskin

**Status:** approved in conversation 2026-09-26, spec for review.
**Branch:** `reskin/command-panel` off `main` (`7fab663`).
**Ships in:** 3.0. The announcement waits for this.

## 1. Why

A stranger who installs Grux today lands on a 240pt sidebar with 14 rows, two collapsed
doors, a 37-case main pane, a Chat surface that is three columns on its own, and Settings at
2,191 lines across 13 sub-panes. Nothing tells them what to do first. The thing a builder most
wants, customizing Grux and handing the result to their own agent, is one pill under the
wordmark and three other surfaces that wear the same hat (Tuning, "Hand setup to your agent"
buried in Settings, and the Foundry in Labs).

The goal is a shell that shows only what matters right now, reveals the rest by intent, and
puts Optimize Grux at the front door. Success is a shorter path to the first win and more
people building on Grux.

Decisions taken in conversation, in order:

1. The first win for a new user is running Optimize Grux, not chat, not a brief.
2. Surfaces hide and reveal by intent. Nothing is deleted.
3. The resting form is one small panel, not a full window and not a menu bar item.
4. Optimize Grux becomes one umbrella with four doors.
5. Approach: a new shell on top, existing surfaces underneath, tokens migrating behind a
   ratchet. Not a rebuild of every surface.

## 2. Non-goals

These are out of scope for this spec on purpose. Each is a separate piece of work later.

- Retouching the inside of Mail, Calendar, Notes, Documents, Contacts, Tasks, Meetings,
  Schedules, Integrations, Studio, or any Labs and Developer surface.
- Restructuring Settings beyond moving one control (section 5.3).
- Chat internals (composer, threads, sessions strip, live rail) beyond folding the threads
  sidebar (section 3.4).
- The menu bar item, the Ambient HUD, the Stage, the Focus overlay, the Meeting panel.
- Deleting any surface, tab key, or registry row.
- Usage-based ranking. There is no usage log today; this spec adds the counter (section
  4.5) so a later version can rank on it.

## 3. The Command Panel

### 3.1 Window

One window, titled "Grux OS", resting at 420 x 560 points. Minimum 380 x 480. No sidebar.
`GruxLayout` gains `panelWidth = 420`, `paneWidth = 680`, `panelMinHeight = 480`; the
existing `sidebarWidth = 240` stays until the legacy shell is removed (section 6.2).

### 3.2 Regions, top to bottom

1. **Head.** The orb at 44pt and the "GRUX OS" wordmark on one row. Orb click mutes and
   unmutes the mic, orb right-click offers Tune and Optimize, exactly as today. The
   `FoundryStatusBadge` and `ActivitySwarmBadge` sit on the right of the same row and draw
   nothing when idle, as today.
2. **Input.** One text field, placeholder "Say it or type it." Enter calls
   `ChatService.send`, which already fast-paths CommandsV2 triggers, the four PIM intents and
   chat. A sent message opens the Chat pane (section 3.4) so the reply has somewhere to land.
   The mic button on the right of the field is the existing push-to-talk from
   `ChatView.toggleVoice`, lifted into the panel. Voice routing is untouched.
3. **Now.** A list of at most 7 rows from `Relevance.now` (section 4). Each row is one line of
   text, a class glyph, and one action. Empty state is one line of caption text: "Nothing
   needs you."
4. **Optimize Grux.** One card (section 5). Expanded on first run and whenever a work order is
   waiting at a review; otherwise collapsed to a single row that reads "Optimize Grux" with a
   dot when something inside wants attention.
5. **Foot.** The Recent strip (section 4.4), then the Watching/Paused dot and its button, the
   listening button, the `ApprovalsTrayButton` (only when pending, as today), and a Settings
   gear. This is the current sidebar foot moved down one level, plus Recent and Settings.

### 3.3 Panes

Any surface opens in a pane to the right of the panel. Opening a pane animates the window
from `panelWidth` to `panelWidth + paneWidth`; closing it animates back. One pane at a time.
Opening a second surface replaces the pane content, it does not stack.

A pane is `SurfacePane(tab: Tab)`, which hosts the existing `switch selection` block from
`LaunchRootView` (the 37 cases, the `HostedSurfaces` folds, the `capabilityGated` wrapper, the
`ActivityStripView` at the bottom). The views inside are unchanged.

Pane chrome: a 36pt bar with the surface name on the left and a close control on the right.
Esc closes the pane when the pane has focus. The panel stays interactive while a pane is open.

Ways a pane opens: a Now row's action, a Recent chip, a palette result, a `fire-open-tab`
trigger, `grux open <key>`, an `--open-tab=` launch argument, and a sent message (opens
Chat). All of these already resolve to a `Tab` today; they set the same `selection` binding.

`~/.grux/rendered-tab.txt` keeps writing the open pane's key, or `panel` when no pane is open.
`tools/grux-tab-keys-check.sh` and `RenderedTabHookTests` assert against that.

### 3.4 Chat inside a pane

The Chat pane shows the sessions strip, messages, `VoiceLiveRail` and the input bar. The
`ChatThreadsSidebar` is folded behind a threads button in the pane bar, opening as a popover
over the pane. Chat is therefore one column beside the panel. Nothing inside `ChatView`
changes except the fold and the removal of its own duplicate composer mic when hosted in the
pane (the panel's mic is the same control).

### 3.5 Palette

`OrbCommandPalette` stays on Cmd+Shift+P with the same hotkey override keys. Changes:

- It lists every registry row by its rail label ("Mail", "Studio"), not "Open Mailbox" and
  "Open Design Studio".
- It adds what it misses today: the Labs shelf, each Settings sub-pane (from
  `SettingsSearchRegistry`), the approvals tray, Pair iPhone, and the HUD toggle.
- Recents are listed once, in the recents section, and not repeated in the full list.
- A palette result opens a pane.

The palette is the path to any surface that has not earned a Recent chip. It is named in the
panel's empty state on first run ("Cmd+Shift+P reaches everything").

### 3.6 Windows that stay separate

"Grux Settings", "Pair iPhone", "Agent Job" and the Empire dashboard remain their own windows.
Settings opens from the foot gear and from the palette. The "Grux Chat" window stays for the
people who have it pinned, but the panel no longer opens it; Chat is a pane.

## 4. Reveal by intent

### 4.1 The function

`Sources/Grux/Shell/Relevance.swift`:

```swift
struct PanelItem: Equatable, Identifiable {
    enum Class: Int, Comparable { case needsYou = 0, running, next, suggested }
    let id: String
    let cls: Class
    let title: String
    let action: PanelAction
}

enum PanelAction: Equatable {
    case open(Tab)
    case openApprovals
    case openWorkOrder(id: String)
    case startWorkflow(id: String)
    case setup(featureKey: String)
}

enum Relevance {
    static func now(_ s: RelevanceState, cap: Int = 7) -> [PanelItem]
}
```

`RelevanceState` is a plain value assembled by the panel from what already exists:
`TodayModel.next`, `TodayModel.mailThatNeedsYou(limit: 3)`, `TodayModel.watching`, the
approvals pending count, running swarm jobs, Foundry proposals, work orders whose latest
`progress.log` station is a review, and the capability gaps for the features the user picked
in onboarding (`FeatureRegistry` rows with a disposition of rail or fold whose capability is
missing). It is a struct of arrays and counts, no live objects, so the function is pure and the
tests need no app state.

### 4.2 Rules

- A row appears only if it carries an action. There are no informational rows.
- Class order: needsYou (approvals pending, work order at a review, mail that needs you),
  then running (swarm jobs, an active workflow run), then next (the next task or event), then
  suggested (a setup gap for a picked feature, a Foundry proposal).
- Within a class, the order is the source order (mail by needs-you score, jobs by start time,
  gaps by registry order).
- Cap at 7 after ordering. The cap is a parameter so a test can prove it.
- Approvals collapse into one row ("3 approvals waiting") regardless of count.
- Brand-scoped surfaces (Meta Ads, Social) contribute rows only when at least one brand
  exists.
- Developer and Labs doors contribute nothing. They are reached through the palette and the
  Optimize hub.

### 4.3 Refresh

The panel recomputes `Relevance.now` when any of its inputs publishes a change (the same
observers Home uses today) and at most once per second. There is no timer polling beyond the
existing 5 s work-order re-read.

### 4.4 Recent strip

The foot shows up to 5 chips for surfaces the user has opened, most recent first, from the
existing `SidebarStateStore.recents` (already persisted in `sidebar.json`, capped at 6). A
chip is the rail label and icon. Clicking opens the pane. Right-click offers Pin, which moves
the chip to the front and keeps it there (the existing pin store). A fresh install shows no
chips.

### 4.5 The usage counter

`LaunchRootView.swift:280`, the `onChange(of: selection)`, gains one line: append
`{ts, key, via}` to `~/Library/Application Support/Grux/opens.jsonl`, where `via` is one of
`now`, `recent`, `palette`, `trigger`, `cli`, `input`. Nothing reads it in this release. It
exists so the next version can rank on real use. It is local, never sent anywhere, and the
work-order template's "no telemetry" rule is unaffected because it is a local file the user
owns.

## 5. The Optimize Grux hub

One card in the panel with four doors. The card head reads "Optimize Grux" and one caption
line: "Make it yours, then hand it to your agent."

### 5.1 Tune it

Opens the existing Tuning pane (`TuningView`, 7 cards, about 18 dials). No change to Tuning.

### 5.2 Change it

The existing work-order flow, inline in the card:

- A one-line field, placeholder "Make the accent red", the same as today.
- A "Copy work order" button that calls `WorkOrderStore.create`, writes `order.json`,
  `work-order.md` and `progress.log` to `~/.grux/work-orders/<id>/`, and copies the markdown.
- The progress row of station marks per active order, re-read every 5 s, amber at a review.

`WorkOrder.swift` currently describes its station line three ways ("eleven stations in four
phases" at line 17, "ten stations" in the evidence note, "eleven stations and three reviews"
in the test name) while `WorkOrderStage.line` has 14 entries. This pass makes the code, the
comment, the evidence note and the test name agree on the real count, whatever it is once
counted, and adds an assertion that pins it.

### 5.3 Hand it over

New. The piece that makes "customize Grux and hand it to your agent" real.

`Sources/Grux/Optimize/HandoffBundle.swift` writes `~/.grux/handoff/<yyyy-MM-dd-HHmm>/`:

| File | Content |
|---|---|
| `GRUX.md` | What this bundle is, what each file means, how an agent applies it, and the same rules the work order carries (smallest change, settings before code, tokens from `DesignSystem`, Approvals still apply). |
| `config.json` | The live config with every secret-bearing key removed. The list of secret keys is a data file, `Resources/handoff-secret-keys.txt`, not a hardcoded array, so the test and the writer read the same list. |
| `theme.json` | Copied as is. |
| `macros.json` | Copied as is if present. |
| `work-orders.json` | The index of past work orders: id, request, created, last station. |
| `setup-prompt.md` | The output of the existing `AgentHandoff` generator. |

The button copies `setup-prompt.md` to the clipboard, and the card shows the bundle path with
a Reveal in Finder link. "Hand setup to your agent" in Settings > General becomes a link to
this door; the generator itself does not move.

Secret stripping is proven, not assumed. `HandoffBundleTests` plants a config containing a
value shaped like each known key type, writes a bundle, and asserts none of the planted values
appear in any file of the bundle. The test is red-proven during implementation by disabling
the strip and watching it fail.

### 5.4 Let it improve itself

Opens the existing Foundry pane (`SelfUpgradeView`: Proposals, Trust ladder, Timeline) behind
the same trust tiers as today. The door reads its state from `FoundryStatusBadge`'s source so
the door and the head badge never disagree.

### 5.5 First run

Onboarding keeps its flow and its steps. Its last screen lands on the panel with the Optimize
card expanded and a one-line caption under the input: "Start here, or say what you want."
`OnboardingSteps` "How it works" copy is updated to name the panel, Now, the four doors and
the palette instead of the sidebar doors.

## 6. Migration

### 6.1 New root

`Sources/Grux/Shell/CommandPanelRoot.swift` becomes the view `GruxApp` installs in the launch
window. It owns the `selection: Tab?` binding (nil means no pane), the panel column, and the
pane column. `LaunchRootView`'s `HStack` shell, header block, list and foot are moved out:
the `switch selection` block becomes `SurfacePane`, the foot controls become `PanelFoot`, the
orb header becomes `PanelHead`. `LaunchRootView` itself stays as the legacy shell.

### 6.2 Legacy shell flag

`config.legacyShell` (default false) makes `GruxApp` install `LaunchRootView` instead of
`CommandPanelRoot`. It exists for one release so anyone who needs the old frame can get it
back, and so the two can be compared side by side during the e2e loop. It is removed, with
`LaunchRootView`'s sidebar code, in the release after 3.0.

### 6.3 Landing

A cold boot lands on the panel with no pane. This resolves the contradiction between
`GruxApp.swift:1119` (Home) and the 3.0 spec, `CLAUDE.md` and `HomeView.swift:6` (Chat): the
panel is the landing, and both Home ("Today") and Chat are panes. The Today pane keeps its
cards for anyone who opens it; the panel's Now list is built from the same `TodayModel`
functions.

### 6.4 Tests rewritten, not deleted

| Test | Change |
|---|---|
| `SidebarRowCountTests` (16) | Becomes `PanelReachabilityTests`: every registry row with a rail, fold, Studio, Developer or Labs disposition is reachable through the palette; the first-run panel shows zero Recent chips and the Optimize card expanded. |
| `FirstRunRailCaptureTests` (1) | Captures the panel at 420 x 560 and asserts the four regions in pixels. |
| `BetaBadgeTests` (15) | The 240pt width assertions move to `panelWidth`. |
| `RailReachabilityTests` (6) | Re-pointed at the pane. |
| `RenderedTabHookTests` (2) | Adds the `panel` value. |
| `OptimizeGruxTests` (15) | `test_theButtonIsNotARailRow` becomes `test_theHubIsAPanelCard`; reachability covers panel, palette, trigger, first run. |
| `OnboardingNamesRealTabsTests`, `TodayIsNamedTodayTests` | Updated copy. |
| `TabAdoptionTests` (5) | Unchanged, still 37. |
| `LayoutTokenTests` (14) | Adds the three new layout tokens. |

New: `RelevanceTests` (each rule in 4.2 as its own test, the cap, the empty state, the
brand gate), `HandoffBundleTests` (5.3), `PaletteCoverageTests` (every `SettingsSearchRegistry`
entry, the Labs shelf, approvals and the HUD toggle appear in the palette list),
`OpensLogTests` (4.5).

`docs/feature-registry.md` gains a "reached through" column with values `now`, `recent`,
`palette`, `hub`, and `FeatureRegistryContractTests` checks it.

### 6.5 Design token ratchet

`scripts/design-ratchet.py` counts, outside `Sources/Grux/DesignSystem/`:

- `.font(.system(size:` and SwiftUI semantic fonts (`.font(.title)`, `.caption` and so on)
- `Color.white.opacity`, `Color.black.opacity`, `Color(red:`, system named colors
- numeric `.padding(` arguments
- numeric `.cornerRadius(` and `RoundedRectangle(cornerRadius:` arguments

The baseline lives beside it in `scripts/design-ratchet-baseline.json`. The script exits 1
when any count is above its baseline, and rewrites the baseline downward when a count falls
(so the floor only moves down). It runs in CI beside `swift test`. The panel, hub, pane chrome
and palette are written on tokens only, and the shell's own hardcodes (`Color.green` at
`LaunchRootView.swift:689`, `Color.black.opacity(0.25)` at 351, `.caption2.heavy` at 434 to
437, the palette's 11, 13 and 14pt literals) go in this pass, which is the first downward move
of the baseline.

### 6.6 Sequencing with the e2e loop

The e2e verification loop on the Mini works on `loop/e2e-3.0` and touches engine paths: the
silence facade, the ambient inject seam, workflow dry-run, decision surfaces. This spec touches
the shell. The two branches merge to `main` independently; the loop then re-runs its full
matrix against the merged tree before the 3.0 announcement. Any shell path the loop drives
(`fire-open-tab`, `rendered-tab.txt`, `grux open`) keeps its contract (section 3.3), so the
loop's checks stay valid.

## 7. Error handling

- `Relevance.now` cannot throw. A missing input is an empty array or zero, which produces no
  row.
- `HandoffBundle.write` returns a `Result`. On failure the card shows the error inline and
  nothing is copied to the clipboard. A partial bundle directory is removed before the error
  is shown.
- Opening a pane whose surface is capability-gated shows the gate inside the pane, as today.
- If `opens.jsonl` cannot be written, the failure is logged once and ignored.

## 8. Testing the whole

- `swift test` at or above the current floor, with the rewritten and new tests above.
- The e2e loop's matrix (voice commands, workflows, decision surfaces) run against the merged
  tree on the Mini.
- A stranger run on a clean account following
  `docs/superpowers/evidence/2026-09-21-p-f-1/g-f-clean-vm-runbook.md`, updated for the panel,
  measuring: interactions to the first work order copied, and interactions to the first
  handoff bundle written. Targets: 3 or fewer for each after onboarding.
- Pixel capture of the resting panel and one open pane at 420 x 560 and 1100 x 560, checked
  into `docs/superpowers/visuals/`.

## 9. Open questions resolved here

- Should "Today" survive as a surface? Yes, as a pane. Its cards are useful in full; the
  panel's Now is the short form.
- Should Recent chips be learned or curated? Learned, from opens only, for this release.
- What about people who liked the sidebar? `config.legacyShell` for one release.
