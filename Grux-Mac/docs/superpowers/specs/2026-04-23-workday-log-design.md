# Workday Log: Design Doc (v1)

**Status:** approved · **Owner:** the owner + Claude Opus 4.7 · **Platform:** macOS 14+ / ARM64

## Problem

Grux already captures four independent signals of what you do during a day
(Focus, Terminal Focus, chat logs, hearing logs), but each is siloed and
ephemeral. Nothing on disk answers "what did you actually ship and talk about
during yesterday's workday?" in an organized, queryable way. You want a
daily archival artifact, one per 24-hour workday window (6:00am → 5:59:59am
local), that is both human-readable (re-read anywhere) and machine-readable
(future Grux features query it).

## Non-goals (v1)

- Editing or annotating past logs.
- Cross-day aggregations ("show me every week I shipped more than 5 commits").
- Backfilling workdays from before install.
- Pushing logs to Notion / Linear / PostHog / the memory store at
  `~/.claude/projects/.../memory/`.
- Screenshots, video, or audio embeds.
- Replacing `DailyRecap`. `DailyRecap` stays as the 10:00 PM spoken narrative
  vibe-check. `WorkdayLog` is the canonical record.

## Behavior

| Attribute         | Value                                                            |
| ----------------- | ---------------------------------------------------------------- |
| Window            | 6:00:00 local → 5:59:59 next day local (24h, anchored at 6am)    |
| Trigger           | Auto: 6:00 AM local checked each minute, 6 to 10 grace. Manual: any time. |
| Artifact          | Structured JSON (local) + rendered Markdown mirror (iCloud)      |
| Coexists with     | `DailyRecap` (10:00 PM narrative); does NOT replace              |
| Scope categories  | completed tasks, code shipped, conversations, commitments, focus stats, insights |
| UI                | Menubar "Workday Log…" opens glass-takeover panel with day list  |
| Voice             | "show today's log" / "what did I do yesterday" opens panel       |
| Chat integration  | New `read_workday_log(date:)` tool so Claude-in-chat grounds answers in logs |

## Architecture

```
Read-only sources                      Hourly (all day, while ambient on):
├─ AppState.completedTasks    (a)      AmbientHourlySummarizer (new)
├─ git repos touched in window (b)       ↓ 60-min timer
├─ ~/.claude/projects/*.jsonl (b)        ↓ dedupe last-hour chunks, Claude summary
├─ AppState.chat              (c)        ↓ append NDJSON line
├─ AmbientState.memories      (d)      ~/Library/Application Support/Grux/
├─ AppState.events            (e)        ambient-summaries/YYYY-MM-DD.ndjson
└─ ambient-summaries/*.ndjson (c)
                                       6:00am (local), checked each minute:
                                       WorkdayLogScheduler (new)
                                         ↓ fires once per dayKey, 6 to 10am grace
                                       WorkdayLogAssembler (new)
                                         ↓ gather sources in closed window
                                         ↓ 3 Claude calls: narrative+insights,
                                         ↓   per-session outcomes, conv. summaries
                                         ↓ produce WorkdayLog struct
                                       WorkdayLogStore.save(log) (new)
                                         → workday-logs/YYYY-MM-DD.json (local, canonical)
                                         → workday-logs/index.json (append)
                                         → iCloud/GruxAI/workday-logs/YYYY-MM-DD.md
                                         → NSNotification for UI refresh
```

### New files

| Path                                                          | Responsibility                                             |
| ------------------------------------------------------------- | ---------------------------------------------------------- |
| `Sources/Grux/WorkdayLog/WorkdayLogModels.swift`              | Codable types (`WorkdayLog`, `LoggedTask`, etc.).          |
| `Sources/Grux/WorkdayLog/WorkdayLogScheduler.swift`           | 6am cron with 4h grace, same pattern as `DailyRecapScheduler`. |
| `Sources/Grux/WorkdayLog/WorkdayLogAssembler.swift`           | Gather sources in window, call Claude, build `WorkdayLog`. |
| `Sources/Grux/WorkdayLog/WorkdayLogStore.swift`               | JSON + iCloud MD persistence, index append, load helpers.  |
| `Sources/Grux/WorkdayLog/WorkdayLogRenderer.swift`            | `WorkdayLog` → Markdown string. Pure function.             |
| `Sources/Grux/WorkdayLog/WorkdayLogView.swift`                | SwiftUI browser (left rail of days + right rendered log).  |
| `Sources/Grux/WorkdayLog/WorkdayLogPanelController.swift`     | Glass-takeover panel wrapper, matches `DailyRecapPanelController`. |
| `Sources/Grux/Ambient/AmbientHourlySummarizer.swift`          | Hourly timer + Claude summarization + NDJSON append.       |
| `Sources/GruxShellCore/GitWindowScanner.swift`                | `git log --since --until --numstat` wrapper, parses output. |
| `Tests/GruxTests/WorkdayLogAssemblerTests.swift`              | Window boundary, cross-day commit, missing-summary fallback. |
| `Tests/GruxTests/AmbientHourlySummarizerTests.swift`          | Hour bucket edges, empty-hour skip.                        |
| `Tests/GruxTests/WorkdayLogStoreTests.swift`                  | Index append, markdown render stability, round-trip.       |

### Modified files

| Path                                         | Change                                                        |
| -------------------------------------------- | ------------------------------------------------------------- |
| `Sources/Grux/Persistence.swift`             | `workdayLogsDir`, `ambientSummariesDir`, `iCloudMirrorDir`.   |
| `Sources/Grux/GruxApp.swift`                 | Start/stop `WorkdayLogScheduler` + `AmbientHourlySummarizer`. |
| `Sources/Grux/MenuBarView.swift`             | "Workday Log…" item and "Generate today's log now" action.   |
| `Sources/Grux/ChatService.swift`             | Register `read_workday_log(date:)` tool.                      |
| `Sources/Grux/VoiceMacros.swift`             | "show today's log" / "what did I do yesterday" phrases.       |

## Data model

```swift
struct WorkdayLog: Codable, Identifiable {
    // Deterministic UUIDv5-style derivation from `dayKey` so repeated rollups
    // for the same day overwrite rather than duplicate. Implementation can
    // SHA-1-hash the dayKey and format the first 16 bytes as a UUID.
    let id: UUID
    let dayKey: String                    // "2026-04-22", 6am anchor date
    let windowStart: Date                 // 2026-04-22 06:00:00 local
    let windowEnd: Date                   // 2026-04-23 05:59:59 local
    let generatedAt: Date
    let schemaVersion: Int                // = 1

    var completedTasks: [LoggedTask]      // category a
    var codeShipped: [CodeShipment]       // category b
    var conversations: [ConversationSummary] // category c
    var commitments: CommitmentsBreakdown // category d
    var focusStats: FocusStats            // category e
    var insights: [String]                // category i, Claude-generated, 3 to 7 bullets

    var narrative: String                 // 200 to 400 words, Claude-generated
    var tags: [String]                    // distinct project names referenced
    var totalProductiveMinutes: Int       // onTask + drifting (not offTask)
}

struct LoggedTask: Codable {
    let title: String
    let project: String
    let completedAt: Date
    let source: String                    // "chat" | "voice" | "manual"
}

struct CodeShipment: Codable {
    let project: String                   // cwd basename / repo name
    let gitBranch: String?
    let commits: [LoggedCommit]
    let claudeSessions: [LoggedClaudeSession]
}

struct LoggedCommit: Codable {
    let sha: String                       // full 40-char
    let message: String                   // first line of commit msg
    let timestamp: Date
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
}

struct LoggedClaudeSession: Codable {
    let sessionId: String                 // UUID from JSONL filename
    let cwd: String                       // absolute path
    let turns: Int                        // user message count
    let totalCost: Double                 // USD, from existing rate table
    let totalTokens: Int                  // input + cache-creation + output
    let outcomeSummary: String            // Claude-generated, 1 sentence
}

struct ConversationSummary: Codable {
    let timestamp: Date                   // start of the conversation
    let source: ConvSource                // .chat | .ambient
    let durationMinutes: Int
    let summary: String                   // Claude-generated, 1 to 2 sentences
    let topics: [String]
}

enum ConvSource: String, Codable { case chat, ambient }

struct CommitmentsBreakdown: Codable {
    var made: [String]                    // new commitments first seen today
    var kept: [String]                    // matched to completedTasks by fuzzy title
    var stillOpen: [String]               // older commitments still unresolved
}

struct FocusStats: Codable {
    var onTaskMinutes: Int
    var driftingMinutes: Int
    var offTaskMinutes: Int
    var perAppMinutes: [String: Int]      // "Xcode": 213
    var perProjectMinutes: [String: Int]  // inferred via KnownProjects match
}
```

## Ambient retention fix

`AmbientState.recentChunks` is ring-buffered at 200 chunks. A full workday of
chatter evicts most of the morning before the 6am rollup runs. Fix (per Q5
= option C, summarize-then-drop):

- New `AmbientHourlySummarizer` runs a 60-min repeating timer.
- Each tick collects chunks from the last hour, dedupes, sends to Claude with
  prompt: "In 1 to 2 sentences, what did the owner talk about between HH:00 and
  HH:59? Name people/projects if mentioned. If the hour was silent/filler, reply
  'quiet'."
- Summarizer appends one NDJSON line per non-empty hour:
  `{ "hourStart": "2026-04-22T14:00:00Z", "hourEnd": "...", "summary": "...", "chunkCount": 23 }`
- File: `~/Library/Application Support/Grux/ambient-summaries/YYYY-MM-DD.ndjson`
- Raw chunks stay ring-buffered at 200 (unchanged).
- `WorkdayLogAssembler` reads that day's NDJSON for conversation content;
  `AppState.chat` is still read directly (it's already unbounded).
- Claude failure → fallback writes the joined raw chunk text (≤ 500 chars)
  as the summary. Lossy but not dropped.

## Repo-touched derivation (no hardcoded list)

1. Pull distinct `cwd` values from every Claude Code JSONL line whose
   timestamp falls in window. (`ClaudeSessionIndex` already enumerates.)
2. Union with project paths resolved from `AppState.events[*].windowTitle`
   via `KnownProjects`.
3. For each candidate path that is a git repo (has `.git/`), run:
   `git log --since=<ISO8601 windowStart> --until=<ISO8601 windowEnd> --numstat --format=%H|%s|%aI`
   via `GruxShellCore`. Shell-quote paths. Swallow non-zero exit with warning.
4. Parse stdout into `[LoggedCommit]`.

`GitWindowScanner` exposes a single `scan(repoPath: URL, window: ClosedRange<Date>) async throws -> [LoggedCommit]`.

## Storage layout

| Path | Role |
|------|------|
| `~/Library/Application Support/Grux/workday-logs/YYYY-MM-DD.json` | Canonical `WorkdayLog` JSON |
| `~/Library/Application Support/Grux/workday-logs/index.json` | `[{dayKey, generatedAt, tags, narrativeSnippet}]` for cheap list UI |
| `~/Library/Application Support/Grux/ambient-summaries/YYYY-MM-DD.ndjson` | Hourly summary lines |
| `~/Library/Mobile Documents/com~apple~CloudDocs/GruxAI/workday-logs/YYYY-MM-DD.md` | Human-readable mirror |

The `.md` mirror renders sections: `# 2026-04-22 Workday` → `## Narrative` →
`## Shipped` (tasks then code, grouped by project) → `## Conversations` →
`## Commitments` (made/kept/missed subsections) → `## Focus` (table: app, min,
verdict-split) → `## Insights` (bullet list).

`iCloudMirrorDir` returns `nil` if `ubiquityContainer(nil)` is unavailable; in
that case the MD mirror step is skipped with a WakeLog warning and the local
JSON is still saved.

## Triggering

- `WorkdayLogScheduler` polls every 60s, mirroring `DailyRecapScheduler`.
- At each tick: compute current-local `hour` and `dayKey`. Fire when
  `6 <= hour < 10` and `lastFiredDayKey != dayKey`. The 4-hour grace window
  handles a closed laptop. On boot, fires immediately if the window was
  missed earlier the same morning.
- `lastFiredDayKey` persisted to `UserDefaults` key `grux.workdayLog.lastFiredDayKey`.
- Exposes `generateWorkdayLogNow(for dayKey: String) async -> WorkdayLog`, which
  bypasses guard. Bound to menubar "Generate today's log" and voice phrase.
  When run before 6am, generates the still-open window from its start to
  "now" (clearly labeled as partial).

## Claude calls per rollup (3 total, cached system prompt)

1. **Per-session outcomes**: one call batched across all Claude Code
   sessions touched in window. Input: `(sessionId, firstUserMsg, lastAssistantText, uniqueToolUseNames)` per session. Output: 1-sentence outcome keyed
   by sessionId. Failure → outcomeSummary = `""`.
2. **Conversation summaries**: chat messages chunked by 30-min gaps; ambient
   hourly summaries already summarized → passed through with light
   normalization (group consecutive ambient hours into a single
   `ConversationSummary`). Input: chunked buckets. Output: 1 to 2 sentence
   summary + topics array per bucket. Failure → summary = joined chunk text
   truncated to 200 chars, topics = `[]`.
3. **Narrative + insights**: final call. Input: the fully assembled
   structured data (tasks, code shipments, conversations, commitments, focus
   stats). Output: `{ narrative: String, insights: [String] }`. Failure →
   fallback template narrative built from counts (see `DailyRecap.defaultNarrative`
   for pattern) and `insights = []`.

System prompts held static for prompt-caching; user prompts carry
day-specific data.

## UI surface

- **Menubar**: new item **"Workday Log…"** under the GRUX menu, opens
  `WorkdayLogPanelController`. Second item **"Generate today's log now"**
  fires on-demand rollup for the current (still-open) window.
- **Panel** (`WorkdayLogView`): left rail = `index.json` entries newest
  first; right pane = `WorkdayLogRenderer.renderMarkdown(log)` rendered in
  SwiftUI (same glass-card style as `DailyRecapView`). A "reveal in Finder"
  button opens the iCloud `.md`.
- **Voice**: existing `VoiceMacros.swift` gets two phrase mappings →
  `show today's log` / `what did I do yesterday` → open panel at matching
  dayKey.
- **Chat**: `ChatService` registers a `read_workday_log(date: String)` tool.
  Returns the JSON log for that day to the model for grounded answers.

## Error handling

- **Claude API unavailable** at rollup → structured data still written;
  narrative = fallback template; insights = `[]`. Log saves.
- **Ambient summaries file missing or partial hours** → narrative notes it;
  conversations list has whatever hours exist.
- **iCloud not mounted / write failure** → WakeLog warning; local JSON
  saves. Next scheduler tick retries the MD mirror.
- **Git scan failure on a repo** (not a repo, permission denied) → skip,
  warn, no commits listed for that project.
- **Scheduler fires twice same day** → guard via `lastFiredDayKey` in
  `UserDefaults`.
- **Boundary commit at 5:59:45am** → belongs to prior day's log. Filter
  semantics: window is the half-open interval `[windowStart, windowStart + 24h)`.
  `git log` is invoked with `--since=<windowStart>` and `--until=<windowStart + 24h>`.
  The `windowEnd` stored on the `WorkdayLog` struct is the inclusive human-
  readable `5:59:59` for display only; every time-filter in code uses the
  exclusive 6am-of-next-day upper bound to keep boundary semantics consistent
  across sources (commits, chunks, focus events, JSONL entries).
- **Sandbox**: Grux is already sandbox-off. No new entitlements.

## Persistence (UserDefaults + files)

- `grux.workdayLog.lastFiredDayKey`: last dayKey for which the 6am scheduler fired.
- `grux.workdayLog.dailyRecapMigration`: `Int` version marker (currently 1)
  in case future schemas need fixups.
- `workday-logs/` and `ambient-summaries/` directories created lazily in
  `Persistence` extension, same pattern as `Persistence.ambientDir`.

## Testing

- `AmbientHourlySummarizerTests`: hour bucket boundary (chunk timestamp =
  HH:59:59.999 → belongs to HH hour), empty hours skipped, Claude failure
  falls back to joined raw text.
- `WorkdayLogAssemblerTests`: window boundary (commit at 5:59:45am included
  in prior day, commit at 6:00:01am excluded), cross-day Claude session
  (session spans midnight → contributes to whichever day its entries
  timestamp into), missing ambient summaries file → empty conversations
  from that source, no API key → template narrative + saves log.
- `WorkdayLogStoreTests`: index append preserves ordering (newest first),
  markdown render is stable (golden file), JSON → struct → JSON round-trip
  is identity.

## E2E verification results (2026-04-23 bring-up)

**Automated:**
- `swift test`: 40/40 passing (24 pre-existing + 16 new: 8 assembler, 4 hourly summarizer, 4 store).
- `./build.sh`: signs + installs `/Applications/Grux.app` cleanly. Build time ~31s incremental / ~350s clean.
- Launch: `workdayLog scheduler: started` and `ambientHourlySummarizer: scheduled, first tick in <N>s` both emitted within 1s of process start.

**CLI-trigger manual rollup (`touch ~/.grux/fire-workday-log`):**
- Trigger consumed within 1 poll tick; `workdayLog manual: <dayKey>` emitted.
- Assembly end-to-end latency: ~48 seconds (covers 60 Claude Code JSONL file parses, git-log across distinct cwds, and three Claude API calls).
- Artifacts produced:
  - Local JSON: `~/Library/Application Support/Grux/workday-logs/2026-04-23.json` (13 KB).
  - Index: `~/Library/Application Support/Grux/workday-logs/index.json` (upsert by dayKey).
  - iCloud MD mirror: `~/Library/Mobile Documents/com~apple~CloudDocs/GruxAI/workday-logs/2026-04-23.md` (7 KB, renders narrative + all sections).
- JSON schema: all 15 expected top-level fields present. Narrative is 5 paragraphs, grounded in real shipments (Product A + product-b.example work) and real code activity. 7 insights generated.

**Perf fix landed during bring-up:**
- Initial run hit an N² re-scan in `sampleTextFor` (per-session `ClaudeSessionIndex.recentSessions(limit: 100)` call × N sessions). Resident memory climbed to 6.7 GB and the assembly didn't complete in 2 min.
- Fix: sample text (first user + last assistant + distinct tool names) is now extracted once during `collectClaudeSessions` and cached in `sessionSampleCache`. Post-fix run: memory peak ~1.2 GB, assembly in ~48s.

**Known v1 gaps (acceptable for ship):**
- Commitments breakdown read 0/0/0 on bring-up: the owner had no ambient-extracted `.commitment` memories today. Logic is exercised in unit tests (`test_breakdownCommitments_classifies`).
- `tags` can contain casing/alias duplicates (e.g. `ProductA` and `producta`). Canonicalization via `KnownProjects` can be added in v2.

## Open questions (deferred to v2)

- **Backfill.** Could reconstruct historical workdays from existing chat log
  + focus events + Claude Code JSONLs. Useful but meaningful engineering
  (conflict with current ambient ring-buffer limits for days before install).
- **Monthly rollups.** v2 could aggregate `index.json` into monthly summaries.
- **Edits to past logs.** Annotate/correct after the fact. Punted to keep
  v1 read-only.
- **Compression.** `ambient-summaries/*.ndjson` is tiny (text, ~dozens of
  lines per day). Gzip-on-month-close can happen in v2 if files grow.
