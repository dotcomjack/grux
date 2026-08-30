# Workday Log v1, Implementation Plan

> **For agentic workers:** Execute tasks in order. Each task ends in a commit. Do not skip the `swift test` / `./build.sh` verification steps at the end.

**Goal:** Ship `WorkdayLog`: a 6am-anchored daily archival artifact assembled from Focus/TerminalFocus/chat/ambient sources, persisted as local JSON + iCloud Markdown.

**Architecture:** New `Sources/Grux/WorkdayLog/` subsystem + a new `Ambient/AmbientHourlySummarizer.swift` to fix the ring-buffer retention gap. Scheduler polls every 60s, fires once in the 6,10am window for the just-closed 24h window. Three Claude calls per rollup (narrative, per-session outcomes, conversation summaries). Read-only data mining of existing `AppState`, `AmbientState`, `~/.claude/projects`, and `git log`.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (NSPanel for takeover), ClaudeClient (existing), GruxShellCore for `git log`, `Persistence` helpers.

**Spec:** `docs/superpowers/specs/2026-04-23-workday-log-design.md`

---

## Task 1, Persistence dirs + models

**Files:**
- Modify: `Sources/Grux/Persistence.swift`, add `workdayLogsDir`, `ambientSummariesDir`, `iCloudMirrorDir`.
- Create: `Sources/Grux/WorkdayLog/WorkdayLogModels.swift`, all `Codable` types from spec.

- [ ] Add 3 dir helpers to `Persistence`. Each creates-if-missing and returns `URL?` (nil for iCloud when ubiquity unavailable).
- [ ] Create `WorkdayLogModels.swift` with the Swift types from the spec `Data model` section verbatim.
- [ ] Add `WorkdayLog.id` derivation via SHA-1 of `dayKey` as UUID bytes (import `CryptoKit`).
- [ ] Commit.

## Task 2, GitWindowScanner

**Files:**
- Create: `Sources/GruxShellCore/GitWindowScanner.swift`, async `scan(repoPath:window:) -> [LoggedCommit]`.

- [ ] Shell out to `git` via `Process`, `--since`/`--until` with ISO8601 dates, `--numstat --format='%H%x09%s%x09%aI'`.
- [ ] Parse: header line `sha<TAB>msg<TAB>iso`, then numstat lines `insertions<TAB>deletions<TAB>path` until blank.
- [ ] Handle binary files (numstat emits `-<TAB>-<TAB>path`, count as 0/0).
- [ ] Return empty on missing `.git/`, missing `git` binary, non-zero exit.
- [ ] Commit.

## Task 3, AmbientHourlySummarizer

**Files:**
- Create: `Sources/Grux/Ambient/AmbientHourlySummarizer.swift`, hourly timer + Claude call + NDJSON append.

- [ ] `@MainActor final class`, singleton, `start()` / `stop()`.
- [ ] Timer: `Timer.scheduledTimer(withTimeInterval: 3600, repeats: true)` aligned to the top of the next hour.
- [ ] At each tick: compute `hourStart = floor(now, to: .hour) - 1h`, `hourEnd = hourStart + 1h`. Pull chunks from `AmbientState.shared.recentChunks` whose `timestamp` falls in `[hourStart, hourEnd)`.
- [ ] Skip (no write) if `chunks.count < 2`.
- [ ] Build summarization prompt; call `ClaudeClient.complete` with `haiku-4-5` for cost.
- [ ] On failure: `summary = chunks.map{$0.text}.joined(separator:" ").prefix(500)`.
- [ ] Append one NDJSON line to `ambient-summaries/<dayKey>.ndjson` where `dayKey` is the 6am-anchored date of `hourStart` (i.e. if `hourStart` is between 00:00 and 05:59, attribute it to the previous dayKey).
- [ ] Commit.

## Task 4, WorkdayLogStore (+ renderer)

**Files:**
- Create: `Sources/Grux/WorkdayLog/WorkdayLogStore.swift`, save/load/list + index maintenance + iCloud mirror.
- Create: `Sources/Grux/WorkdayLog/WorkdayLogRenderer.swift`, pure `WorkdayLog → String` markdown.

- [ ] `save(_ log: WorkdayLog)`: writes JSON to `workday-logs/<dayKey>.json` (pretty sorted), appends to `index.json` (upserting by `dayKey`), writes MD mirror to iCloud if available, posts `.gruxWorkdayLog` notification.
- [ ] `load(dayKey:) -> WorkdayLog?`, `list() -> [IndexEntry]`.
- [ ] `IndexEntry` struct inside file: `dayKey`, `generatedAt`, `tags`, `narrativeSnippet` (first 140 chars).
- [ ] Renderer: `renderMarkdown(_ log) -> String`. H1 `# YYYY-MM-DD Workday`, H2 sections: Narrative / Shipped (Tasks subsection, Code subsection grouped by project) / Conversations / Commitments (Made/Kept/Open) / Focus (table) / Insights.
- [ ] Commit.

## Task 5, WorkdayLogAssembler

**Files:**
- Create: `Sources/Grux/WorkdayLog/WorkdayLogAssembler.swift`, async `build(for: dayKey) -> WorkdayLog`.

- [ ] Compute `windowStart` = 6:00 local of dayKey; `windowEnd` (for display) = windowStart + 24h - 1s; internal filter upper bound = `windowStart + 24h`.
- [ ] **Tasks (a):** filter `AppState.shared.completedTasks` by `completedAt ∈ [windowStart, windowEnd_excl)`. Map to `LoggedTask(source: "manual")` (real source field requires new AppState plumbing, YAGNI, hardcode "manual" for v1).
- [ ] **Code shipped (b):** collect cwd set from Claude Code JSONL entries whose `ts ∈ window` using `ClaudeSessionIndex` + re-parsing touched files. Group sessions by cwd. For each distinct cwd that exists + is a git repo, run `GitWindowScanner.scan`. Build `CodeShipment` per project.
- [ ] **Conversations (c):** (i) read `AppState.shared.chat` messages in window, split on ≥30 min gaps, each group → 1 `ConversationSummary(.chat)`. (ii) Read `ambient-summaries/<dayKey>.ndjson`, collapse consecutive hours into groups of ≤3 hours, each → 1 `ConversationSummary(.ambient)` using the already-summarized hour texts concatenated.
- [ ] **Commitments (d):** partition `AmbientState.memories` of kind `.commitment` by timestamp: `made` = introduced today; `kept` = title fuzzy-matches a task completed today; `stillOpen` = before today, still not matched.
- [ ] **Focus stats (e):** sample `AppState.events` in window; approximate minutes by pairing each event with its successor's timestamp (or `windowEnd_excl` for the last). Sum per verdict + per app. Per-project inferred by matching `event.windowTitle` against `KnownProjects.displayNames()` (case-insensitive substring).
- [ ] **3 Claude calls:** (1) per-session outcomes (one call batched, JSON response `{sessionId: oneLiner}`). (2) conversation summaries (one call batched). (3) narrative + insights (final call, JSON response `{narrative, insights:[String]}`). All with fallbacks if no API key or call fails.
- [ ] Compose final `WorkdayLog`, compute `totalProductiveMinutes = onTask + drifting`, `tags = Set(codeShipped.project ∪ completedTasks.project).sorted()`.
- [ ] Commit.

## Task 6, WorkdayLogScheduler

**Files:**
- Create: `Sources/Grux/WorkdayLog/WorkdayLogScheduler.swift`, 60s poller, fires once per dayKey in 6,10am window.

- [ ] Mirror `DailyRecapScheduler` structure. `lastFiredDayKey` persisted to `UserDefaults` (`grux.workdayLog.lastFiredDayKey`).
- [ ] `fire(for dayKey:)` → `Assembler.build` → `Store.save`.
- [ ] `generateWorkdayLogNow(for dayKey:) async -> WorkdayLog` bypasses guard for menubar/voice trigger.
- [ ] Commit.

## Task 7, UI (panel + view)

**Files:**
- Create: `Sources/Grux/WorkdayLog/WorkdayLogView.swift`, SwiftUI two-pane (list left, rendered MD right via `Text(markdown:)`).
- Create: `Sources/Grux/WorkdayLog/WorkdayLogPanelController.swift`, NSPanel wrapper matching `DailyRecapPanelController` style.

- [ ] View reads `WorkdayLogStore.list()` on appear + on `.gruxWorkdayLog` notification.
- [ ] Right pane: `ScrollView { Text(try! AttributedString(markdown: WorkdayLogRenderer.renderMarkdown(log))) }`.
- [ ] Close button + "Reveal in Finder" button (opens iCloud MD).
- [ ] PanelController: `.floating`, centered, 900×720, can be dismissed.
- [ ] Commit.

## Task 8, Wire into menubar + chat tool + voice + lifecycle

**Files modified:**
- `Sources/Grux/GruxApp.swift`, start schedulers.
- `Sources/Grux/MenuBarView.swift`, add "Workday Log…" + "Generate today's log now".
- `Sources/Grux/ChatService.swift`, register `read_workday_log` tool.
- `Sources/Grux/VoiceMacros.swift`, two phrase mappings.

- [ ] `GruxApp`: after `DailyRecapScheduler.shared.start()` call `WorkdayLogScheduler.shared.start()` and `AmbientHourlySummarizer.shared.start()`.
- [ ] `MenuBarView`: two new buttons. "Workday Log…" presents panel. "Generate today's log now" calls async scheduler.
- [ ] `ChatService.claudeTools` appends a `read_workday_log` tool (input: `{date: "YYYY-MM-DD" | "today" | "yesterday"}`). `dispatchTool` switch adds case that returns JSON-encoded `WorkdayLog` or error string.
- [ ] `VoiceMacros`: add macros "workday_log_today" / "workday_log_yesterday" backed by new `VoiceMacro` that opens the panel with that dayKey selected.
- [ ] Commit.

## Task 9, Tests

**Files:**
- Create: `Tests/GruxTests/WorkdayLogAssemblerTests.swift`
- Create: `Tests/GruxTests/AmbientHourlySummarizerTests.swift`
- Create: `Tests/GruxTests/WorkdayLogStoreTests.swift`

- [ ] Assembler: window boundary (commit at 5:59:45am → included; at 6:00:01am → excluded). No API key → template narrative. Empty inputs → zero-state log still saves. Use a fake `ClaudeClient`-protocol-adapter or test against pure window-filter helpers.
- [ ] Summarizer: `dayKey(forHourStart:)`, 5:00 on 2026-04-23 → `"2026-04-22"` (the 6am anchor previous day); 6:00 → `"2026-04-23"`. Hour-boundary filter inclusivity. Extract the pure date-bucketing logic into a static helper so this can be tested without live timers.
- [ ] Store: JSON round-trip identity. Index append upserts same `dayKey` (does not duplicate). Markdown render is stable against a small fixture (golden string).
- [ ] Commit.

## Task 10, Build + validate

- [ ] `swift test`, all passing (existing + 3 new suites).
- [ ] `./build.sh`, signs + installs `/Applications/Grux.app` cleanly, no warnings in new files.
- [ ] Launch app, verify schedulers start (grep WakeLog).
- [ ] Manual: click menubar "Generate today's log now", verify:
    - `~/Library/Application Support/Grux/workday-logs/<today>.json` exists and parses.
    - `index.json` exists.
    - If iCloud available, MD mirror exists and renders.
    - Panel opens and displays the log.
- [ ] Commit verification results to spec's "E2E verification" section (append).
