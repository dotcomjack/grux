# Foundry Proposal Book 001

Kickoff cycle, run by hand on 2026-06-10 exactly as the engine will run nightly. Sensed over: roadmap-dashboard/events.ndjson (354 mission events), groundtruth.json, verify/results.ndjson (36 checks), the branch git log (47 commits with two hardening rounds), LATER.md, the live Application Support/Grux logs and spend state, and the blueprint (Batches 1 and 2 pre-agreed). All costs are estimated API-equivalent spend; the engine runs on subscriptions, nothing here is billed dollars.

Proposals: 22 total. By lane: capability 3, codeHealth 4, cost 2, performance 1, reliability 7, uxPolish 5. By domain: mac 19, phone 1, site 1, mini 1.

Every proposal starts at Tier 0 (propose): you approve the build. Nothing in this book touches a protected zone, so no proposal is pinned protected.

## Ranked table

| # | Title | Lane | Domain | Gain | Risk | Est. cost |
|---|-------|------|--------|------|------|-----------|
| 1 | Sidebar IA: four collapsible groups plus pinned favorites | uxPolish | mac | 0.86 | medium | $8 estimated |
| 2 | Activity Strip: persistent swarm job bar with phase dots and estimated-cost ticker | capability | mac | 0.84 | medium | $9 estimated |
| 3 | Voice-first PIM: add to calendar, take a note, draft an email by voice with HUD confirmation | capability | mac | 0.80 | medium | $8 estimated |
| 4 | Design primitives: extract GruxListDetailScaffold, GruxEmptyState, GruxToolbar, GruxFormSection and sweep the PIM tabs | codeHealth | mac | 0.78 | medium | $10 estimated |
| 5 | Settings consolidation: 12 tabs down to 5 with a search filter | uxPolish | mac | 0.75 | medium | $7 estimated |
| 6 | Semantic memory store: 40MB pretty-printed JSON rewritten wholesale on every flush | performance | mac | 0.74 | medium | $5 estimated |
| 7 | Notification triage: interrupt, batch, or silent via a Haiku priority classifier | capability | mac | 0.72 | medium | $6 estimated |
| 8 | The v1-feel sweep: screenshot every tab and fix the top 20 paper cuts | uxPolish | mac | 0.70 | low | $12 estimated |
| 9 | Swarm session-limit resilience: checkpoint and auto-resume when the Claude session cap hits | reliability | mac | 0.68 | medium | $6 estimated |
| 10 | Fix the two pre-existing baseline test failures so the verify gate is trustworthy | codeHealth | mac | 0.66 | low | $3 estimated |
| 11 | Shell motion spec: duration and curve tokens for orb, glow, HUD, and Stage | uxPolish | mac | 0.60 | low | $4 estimated |
| 12 | fs-audit signal source reads a dead log: writes stopped 2026-05-08 | reliability | mac | 0.58 | low | $3 estimated |
| 13 | YouTube transcripts: retire the dead timedtext path and harden the yt-dlp fallback | reliability | mac | 0.56 | low | $3 estimated |
| 14 | Self-Upgrade tab visual verification and first-render polish | uxPolish | mac | 0.55 | low | $3 estimated |
| 15 | Route low-stakes classifier calls to local Ollama models when available | cost | mac | 0.52 | medium | $4 estimated |
| 16 | Remote host probes: wire remote service checks into the Foundry verify gates | reliability | mini | 0.50 | low | $3 estimated |
| 17 | Log rotation for wake.log and the other unbounded Application Support logs | reliability | mac | 0.48 | low | $2 estimated |
| 18 | Phone verify rail: pick the best available simulator instead of assuming one exists | reliability | phone | 0.46 | low | $2 estimated |
| 19 | Site verify gate: automated render and preview-clip probe for gruxai.com | reliability | site | 0.45 | low | $3 estimated |
| 20 | DashScope spend is invisible: 13 generations priced at $0 in the spend tracker | cost | mac | 0.44 | low | $2 estimated |
| 21 | Application Support hygiene: retire stale sibling backups and legacy stores | codeHealth | mac | 0.40 | low | $2 estimated |
| 22 | Deterministic snapshot guard: enforce sortedKeys on every digest encoder | codeHealth | mac | 0.38 | low | $2 estimated |

## Proposals

### 1. Sidebar IA: four collapsible groups plus pinned favorites

Lane uxPolish | domain mac | expected gain 0.86 | risk medium | $8 estimated | tier required: Propose

Evidence:
- manual: blueprint section 02: eighteen flat sidebar entries collapse into Command / Workspace / Intelligence / Ambient groups with a pinned-favorites row
- transcript: the owner: it just feels very v1, hard to prefer using Grux over claude code; sidebar overload named as a primary driver
- screenshot: verify/app-main.png shows the flat 18-entry sidebar with no grouping

Touched paths: `Grux-Mac/Sources/Grux/LaunchRootView.swift`, `Grux-Mac/Sources/Grux/Shell/OrbCommandPalette.swift`, `Grux-Mac/Sources/Grux/SidebarPrefsStore.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 2. Activity Strip: persistent swarm job bar with phase dots and estimated-cost ticker

Lane capability | domain mac | expected gain 0.84 | risk medium | $9 estimated | tier required: Propose

Evidence:
- manual: blueprint section 03: a slim persistent bar with live swarm jobs as phase dots, an estimated-cost ticker, click-through to the job, orb badge count, mirrored to the phone
- swarm: roadmap events.ndjson shows 354 agent events across the mission with no in-app surface to watch them; the owner tracked progress via an external HTML dashboard
- transcript: you never dig for what your agents are doing again is the stated acceptance bar

Touched paths: `Grux-Mac/Sources/Grux/Foundry/`, `Grux-Mac/Sources/Grux/Shell/`, `Grux-Mac/Sources/Grux/Agents/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 3. Voice-first PIM: add to calendar, take a note, draft an email by voice with HUD confirmation

Lane capability | domain mac | expected gain 0.80 | risk medium | $8 estimated | tier required: Propose

Evidence:
- manual: blueprint section 03: the tools already exist (calendar, notes, email, documents); wire IntentClassifier routes plus a confirmation card in the HUD with spoken acknowledgment, end to end, phone included
- transcript: add that to my calendar just works is the stated acceptance bar

Touched paths: `Grux-Mac/Sources/Grux/Voice/`, `Grux-Mac/Sources/Grux/Shell/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 4. Design primitives: extract GruxListDetailScaffold, GruxEmptyState, GruxToolbar, GruxFormSection and sweep the PIM tabs

Lane codeHealth | domain mac | expected gain 0.78 | risk medium | $10 estimated | tier required: Propose

Evidence:
- manual: blueprint section 02: every PIM tab reinvented the list + detail split; extract the scaffolds and stop hand-rolling
- screenshot: verify screenshots app-notes.png, app-documents.png, app-schedules.png, app-mailbox.png each show a hand-rolled list-detail split with inconsistent empty states and toolbars

Touched paths: `Grux-Mac/Sources/Grux/DesignSystem/`, `Grux-Mac/Sources/Grux/ThemeConfig.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 5. Settings consolidation: 12 tabs down to 5 with a search filter

Lane uxPolish | domain mac | expected gain 0.75 | risk medium | $7 estimated | tier required: Propose

Evidence:
- manual: blueprint section 02: General, Voice & Ambient, Models, Appearance, Data & Security; Models absorbs api, offline, endpoints, presets, MCP; Data & Security absorbs backup, security, upgrades
- screenshot: verify/app-settings.png shows an 11-tab settings bar: Focus Terminal Ambient Appearance Voice Presets Upgrades Backup Model-and-API Security About
- swarm: verify results 2026-06-10: settings sub-tab automation initially skipped because the TabView had no programmatic selection binding; the --open-settings-tab seam shipped in f2f689e and must keep working

Touched paths: `Grux-Mac/Sources/Grux/SettingsView.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 6. Semantic memory store: 40MB pretty-printed JSON rewritten wholesale on every flush

Lane performance | domain mac | expected gain 0.74 | risk medium | $5 estimated | tier required: Propose

Evidence:
- fs-audit: ~/Library/Application Support/Grux/semantic_memory.json is 40MB on disk and is encoded with prettyPrinted plus sortedKeys on every save
- swarm: c7f380c added a SemanticMemory flush on app termination, so the full 40MB encode now sits on the quit path
- crash: a slow termination flush risks SIGKILL mid-write during logout or shutdown, exactly the dataloss class the flush was added to prevent

Touched paths: `Grux-Mac/Sources/Grux/Memory/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 7. Notification triage: interrupt, batch, or silent via a Haiku priority classifier

Lane capability | domain mac | expected gain 0.72 | risk medium | $6 estimated | tier required: Propose

Evidence:
- manual: blueprint section 03: every notification routes through a priority classifier; interrupt speaks plus banner, batch folds into the hourly or daily recap, silent logs only; one matrix screen plus quiet hours
- transcript: notification noise named in the CX wave as a core v1-feel complaint

Touched paths: `Grux-Mac/Sources/Grux/Notifications/`, `Grux-Mac/Sources/Grux/SettingsView.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 8. The v1-feel sweep: screenshot every tab and fix the top 20 paper cuts

Lane uxPolish | domain mac | expected gain 0.70 | risk low | $12 estimated | tier required: Propose

Evidence:
- manual: blueprint section 03: the UX lane screenshots every tab, critiques against the design tokens, and files the top twenty paper cuts; fixing them is how the UX lane earns Tier 1
- screenshot: UXAuditSource shipped in Phase A and can drive --open-tab plus screencapture plus vision today

Touched paths: `Grux-Mac/Sources/Grux/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 9. Swarm session-limit resilience: checkpoint and auto-resume when the Claude session cap hits

Lane reliability | domain mac | expected gain 0.68 | risk medium | $6 estimated | tier required: Propose

Evidence:
- swarm: events.ndjson 2026-06-10T00:03: orchestrator paused Phase 5 on a Claude session limit and queued a manual resume for the 10:40pm reset
- manual: blueprint cadence section: the governor watches session limits (the AccountSwitcher seam) and yields instantly

Touched paths: `Grux-Mac/Sources/Grux/Agents/`, `Grux-Mac/Sources/Grux/Foundry/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 10. Fix the two pre-existing baseline test failures so the verify gate is trustworthy

Lane codeHealth | domain mac | expected gain 0.66 | risk low | $3 estimated | tier required: Propose

Evidence:
- swarm: integrator report: 634 tests executed, 2 failures are exactly the pre-existing baseline failures SemanticMemoryKindsFilterTests.test_retrievedAsSystemBlock_honorsKindsFilter and SwarmAgentCoreTests.testScaffoldEmptyWhenAllStripped
- manual: hard rail: full test suite at baseline before any install; a baseline that contains failures weakens every future Foundry verify gate

Touched paths: `Grux-Mac/Tests/GruxTests/`, `Grux-Mac/Sources/Grux/Memory/`, `Grux-Mac/Sources/Grux/Agents/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 11. Shell motion spec: duration and curve tokens for orb, glow, HUD, and Stage

Lane uxPolish | domain mac | expected gain 0.60 | risk low | $4 estimated | tier required: Propose

Evidence:
- manual: blueprint section 02: one motion spec; duration and curve tokens on ThemeConfig, orb-state to glow-hue mapping documented as a single table, Stage entrances standardized
- swarm: ecf7723 wired reduceMotion into orb, glow, and stage animations; durations and curves remain hand-tuned per call site

Touched paths: `Grux-Mac/Sources/Grux/ThemeConfig.swift`, `Grux-Mac/Sources/Grux/Shell/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 12. fs-audit signal source reads a dead log: writes stopped 2026-05-08

Lane reliability | domain mac | expected gain 0.58 | risk low | $3 estimated | tier required: Propose

Evidence:
- fs-audit: ~/Library/Application Support/Grux/fs-audit.log last entry is 2026-05-08T14:39; the audit writer has been silent for a month while the app ran daily
- swarm: SignalHarvester ships an fs-audit source that will harvest stale data forever without noticing

Touched paths: `Grux-Mac/Sources/Grux/Foundry/Signals/`, `Grux-Mac/Sources/Grux/Tools/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 13. YouTube transcripts: retire the dead timedtext path and harden the yt-dlp fallback

Lane reliability | domain mac | expected gain 0.56 | risk low | $3 estimated | tier required: Propose

Evidence:
- swarm: live verify 2026-06-10: Strategy A gets HTTP 200 plus a 0-byte timedtext body for ALL videos due to YouTube POT-token enforcement; every transcript now rides the yt-dlp fallback
- swarm: f6e7b1f salvages the json3 file on nonzero yt-dlp exit and drops the auto-translated track glob; the primary path is still dead weight and yt-dlp is an unmanaged external dependency

Touched paths: `Grux-Mac/Sources/Grux/Research/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 14. Self-Upgrade tab visual verification and first-render polish

Lane uxPolish | domain mac | expected gain 0.55 | risk low | $3 estimated | tier required: Propose

Evidence:
- manual: integrator report unverified item: visual rendering of the Self-Upgrade tab not exercised in a running app, compile and unit-test verified only
- screenshot: no verify/*.png exists for the selfUpgrade tab; every other surface has one

Touched paths: `Grux-Mac/Sources/Grux/Foundry/SelfUpgradeView.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 15. Route low-stakes classifier calls to local Ollama models when available

Lane cost | domain mac | expected gain 0.52 | risk medium | $4 estimated | tier required: Propose

Evidence:
- posthog: llm spend state: anthropic 301 generations $1.88 estimated over 30d versus ollama 145 generations at $0.02 estimated; the local lane is proven and nearly free
- manual: upcoming notification triage and transcript-correction detection add recurring classifier calls that do not need a frontier model

Touched paths: `Grux-Mac/Sources/Grux/Backend/ModelRegistry.swift`, `Grux-Mac/Sources/Grux/Foundry/Signals/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 16. Remote host probes: wire remote service checks into the Foundry verify gates

Lane reliability | domain mini | expected gain 0.50 | risk low | $3 estimated | tier required: Propose

Evidence:
- manual: blueprint stage 4: health probes for Mini are a named verify gate; nothing implements them yet
- swarm: the mini domain has zero signal sources today, so the TrustLedger mini lanes can never earn streaks

Touched paths: `Grux-Mac/Sources/Grux/Foundry/Signals/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 17. Log rotation for wake.log and the other unbounded Application Support logs

Lane reliability | domain mac | expected gain 0.48 | risk low | $2 estimated | tier required: Propose

Evidence:
- fs-audit: ~/Library/Application Support/Grux/wake.log is 14MB and append-only with no rotation; security-audit.log and music-ranking.log grow the same way
- crash: unbounded logs slow grep-based debugging and inflate every backup archive

Touched paths: `Grux-Mac/Sources/Grux/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 18. Phone verify rail: pick the best available simulator instead of assuming one exists

Lane reliability | domain phone | expected gain 0.46 | risk low | $2 estimated | tier required: Propose

Evidence:
- swarm: verify 2026-06-10: phone sim build needed a manual destination override because no iPhone 15 Pro Max simulator exists on this machine; iPhone 16 Pro Max was used by hand
- manual: the Foundry phone verify gate will run unattended at 2am; a hardcoded device name fails the whole gate

Touched paths: `Grux-Mac/Sources/Grux/Foundry/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 19. Site verify gate: automated render and preview-clip probe for gruxai.com

Lane reliability | domain site | expected gain 0.45 | risk low | $3 estimated | tier required: Propose

Evidence:
- swarm: e691504 shipped real product preview clips on the site; verify 2026-06-10 confirmed playback manually (readyState 4, time advancing) with no automated re-check since
- manual: blueprint stage 4 names a render check for site as a verify gate; the site domain currently has no signal source so its TrustLedger lanes are dead

Touched paths: `Grux-Mac/Sources/Grux/Foundry/Signals/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 20. DashScope spend is invisible: 13 generations priced at $0 in the spend tracker

Lane cost | domain mac | expected gain 0.44 | risk low | $2 estimated | tier required: Propose

Evidence:
- posthog: llm-spend-state.json providerTotals30d: dashscope 13 generations, usd 0; the pricing table has no dashscope rates so estimated spend underreports
- manual: the Foundry budget governor reads estimated spend; blind spots in the table skew nightly budget decisions

Touched paths: `Grux-Mac/Sources/Grux/Telemetry/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 21. Application Support hygiene: retire stale sibling backups and legacy stores

Lane codeHealth | domain mac | expected gain 0.40 | risk low | $2 estimated | tier required: Propose

Evidence:
- fs-audit: 8 macros.*.bak.json siblings (Apr 21 to May 9), chat.legacy.json (Apr 24), and events.json (296KB, stale since Apr 25) sit loose in Application Support/Grux
- manual: loose ad hoc backups predate BackupManager (222b4eb, 5ab24e6) which now owns archival; the loose files inflate every backup zip

Touched paths: `Grux-Mac/Sources/Grux/Backup/`, `Grux-Mac/Sources/Grux/Persistence.swift`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 22. Deterministic snapshot guard: enforce sortedKeys on every digest encoder

Lane codeHealth | domain mac | expected gain 0.38 | risk low | $2 estimated | tier required: Propose

Evidence:
- swarm: verify 2026-06-10: surface digest determinism flake root-caused to unsorted JSON keys, fixed in e15f030 after 5 consecutive full-suite runs were needed to confirm
- manual: any future digest or snapshot encoder without sortedKeys reintroduces the same flake class silently

Touched paths: `Grux-Mac/Sources/Grux/Persistence.swift`, `Grux-Mac/Tests/GruxTests/`

Proposal id: `%s`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

## Addendum: papercut sweep 2026-06-10 (foundry-papercuts lane)

First live UX audit: all 26 sidebar tabs plus the 5 settings panes were driven via --open-tab / --open-settings-tab, CGWindow-screenshot, and read against the design system. 10 paper cuts were fixed on the spot (commits 19dadc3, 068bd67, ce12e13, 54f8d2f): root violet tint for system controls, a 39-string em dash sweep, token headers for Tasks / Focus Log / Agents Jobs, the Terminal Focus popup-width overflow that clipped the sidebar off-screen, ghost placeholders for the Compare and Research prompt boxes, and empty-priority-bucket hints on the Task Stack. The 10 below are the filed remainder.

### 23. Workflows: drop the Cancel button on terminal-state runs

Lane uxPolish | domain mac | expected gain 0.55 | risk low | $2 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-workflows.png: every Recent Runs row shows Cancel + Drill in, including runs already CANCELED, FAILED, or DONE
- manual: a Cancel affordance on a finished run promises an action that cannot happen; only in-flight runs are cancellable

Touched paths: `Grux-Mac/Sources/Grux/CommandsV2/CommandsV2View.swift`

Proposal id: `F0606052-1BB5-463D-BEFE-BABE53926C5C`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 24. Schedules: collapse the double empty state

Lane uxPolish | domain mac | expected gain 0.45 | risk low | $2 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-schedules.png: list column shows 'No schedules yet' + voice hint while the detail pane simultaneously shows 'Select a schedule or create one' + CTA + the same voice hint
- manual: two empty states shouting the same instruction side by side reads as noise; blueprint 02 wants exactly one GruxEmptyState per situation

Touched paths: `Grux-Mac/Sources/Grux/CommandsV2/UserCronEditorView.swift`

Proposal id: `8CD085E6-A850-4488-AB22-769CCEA6A53B`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 25. Calendar: month-grid event chips truncate to uselessness

Lane uxPolish | domain mac | expected gain 0.50 | risk low | $3 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-calendar.png: day-15 chip renders 'Appoint...' and day-20 'Alex R...'; neither is readable
- manual: chips need a .help tooltip with the full title, tail truncation, and the time dropped from the chip when width is tight

Touched paths: `Grux-Mac/Sources/Grux/Calendar/CalendarView.swift`

Proposal id: `DF552185-B697-4C5B-9C7D-1EAAC1A538DE`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 26. Repo-wide em dash purge: logs, comments, smoke tests

Lane uxPolish | domain mac | expected gain 0.40 | risk medium | $4 estimated | tier required: Propose

Evidence:
- manual: papercut sweep fixed 39 user-visible strings; grep still finds 100+ em dashes in WakeLog lines, SmokeTest copy, comments, and ChatService prompt text
- manual: global house rule (locked 2026-05-22) bans em and en dashes in all copy, code, and comments

Touched paths: `Grux-Mac/Sources/Grux`

Proposal id: `B22DF64D-B190-4925-AA14-C85990EFBA6A`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 27. Tasks: swap .roundedBorder fields for the frosted input style

Lane uxPolish | domain mac | expected gain 0.50 | risk low | $3 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-tasks.png: New task / Project fields render light system .roundedBorder chrome that clashes with the dark frosted surfaces every other tab uses
- manual: GruxSearchField in DesignSystem/GruxToolbar.swift is the canonical frosted field; the add-task row predates it

Touched paths: `Grux-Mac/Sources/Grux/LaunchRootView.swift`, `Grux-Mac/Sources/Grux/DesignSystem/GruxToolbar.swift`

Proposal id: `FC23DA9C-7E3D-4DE1-A57F-07D806862059`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 28. Agents: job-row metrics column alignment and tokens

Lane uxPolish | domain mac | expected gain 0.45 | risk low | $3 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-agents.png: per-row done/failed counts and $ figures ragged-align left under titles; greens/reds are raw system colors instead of successMint/destructiveRose
- manual: right-aligned monospaced money column would make the list scannable; GruxTheme already defines the semantic colors

Touched paths: `Grux-Mac/Sources/Grux/AgentsView.swift`

Proposal id: `49FCFE98-B44A-4DFF-BB72-DBE65A07F83B`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 29. Mailbox: Unread checkbox becomes a filter chip

Lane uxPolish | domain mac | expected gain 0.40 | risk low | $2 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-mailbox.png: bare system checkbox labeled Unread floats in the toolbar next to styled pill buttons (Sync, Compose, Accounts)
- manual: a toggleable GruxChip-style pill matches the adjacent chrome and reads as a filter, not a form control

Touched paths: `Grux-Mac/Sources/Grux/Email/Imap/MailboxView.swift`

Proposal id: `D4A30459-5675-4D7B-BAB0-20C5909096F2`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 30. Integrations: instructional paragraphs into GruxFormSection cards

Lane uxPolish | domain mac | expected gain 0.50 | risk low | $5 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-integrations.png: Slack and Notion setup paragraphs run full-width with inline links, secure fields + Show buttons render default chrome, section spacing is ad hoc
- manual: GruxFormSection (DesignSystem/GruxFormSection.swift) is the canonical card for grouped controls; the pane predates it

Touched paths: `Grux-Mac/Sources/Grux/Integrations/IntegrationsView.swift`

Proposal id: `9BC5021E-B045-4014-B6E1-B85E1C6D67B6`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 31. Settings: General pane onto GruxFormSection with aligned active-hours rows

Lane uxPolish | domain mac | expected gain 0.45 | risk low | $4 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep settings-general.png: checkboxes, quiet-hours toggle, and active-hours sliders sit in a plain Form; Start/End value labels jump width as the value changes
- manual: five-pane restructure landed the chrome but General still uses bare Sections; monospacedDigit value labels with fixed width stop the slider jitter

Touched paths: `Grux-Mac/Sources/Grux/SettingsView.swift`

Proposal id: `0803BCAB-5746-48F3-ADB2-61AF5756EBCC`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.

### 32. Cookbook: model spec columns onto a fixed grid

Lane uxPolish | domain mac | expected gain 0.40 | risk low | $3 estimated | tier required: Propose

Evidence:
- screenshot: papercut sweep tab-cookbook.png: TAG / DISK / MEMORY / CONTEXT spec values eyeball-align across model cards but drift by text width; a Grid with fixed column alignment would lock them
- manual: pure layout swap, HStack to Grid, zero behavior

Touched paths: `Grux-Mac/Sources/Grux/LocalModelCookbook/CookbookView.swift`

Proposal id: `220F803D-765B-406F-875B-A411DDA2AEAB`. The full ready-to-fire Claude Code prompt is stored on the proposal in `~/Library/Application Support/Grux/foundry/proposals.json` and in `docs/foundry/proposal-book-001.json`.
