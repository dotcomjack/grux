# Grux 3.0 Phase D: Home becomes Today

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home stops being a dashboard about Grux and becomes Today: the person's name, the three things that actually matter this morning, one line inviting them to just say it, and the briefing underneath.

**Architecture:** `Home/HomeView.swift` (505 lines) and `Home/HomeHeroView.swift` (195) already render a time-aware hero and a stack of cards. Phase D replaces what those cards are, not how they are drawn. Each card gets a pure model that a test can drive with fixtures, because "what is next" is a judgment and a judgment rendered inline in a view cannot be tested. `Jax/BriefingEngine.swift` (890) gains one line reading `DecisionUsageSummary`, which already exists and is already tested.

**Tech Stack:** Swift, SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` section 4. Ledger: row P-D-1 and gate G-D.

## Global Constraints

- Build worktree, branch `main`. Lane branches `lane/P-D-1`; only the operator merges and runs `./build.sh`.
- Test floor: 2653 executed, 0 failures.
- No em dashes and no en dashes. Dollar amounts as numerals with the symbol. **Standard time (`7:30 PM`), never 24 hour**, and one formatter for the whole surface. A briefing that renders `19:30` is the single most likely copy defect in this phase.
- Design tokens unchanged. Chat stays the landing tab; Today is where you go, not where you land.
- Miles and feet on any distance, never kilometres or metres.

## Depends on

- **Phase B Task B14** already put the person's real name on Home. D uses it; it does not redo it.
- **`DecisionUsageSummary`** (P-A10-1, shipped `af7bab8`) already produces the count, mean latency and spend line. The briefing reads it rather than recomputing.
- The mail needs-you score is packet **P-A9-6**. If A9-6 has not landed, the Mail card renders whatever the current score returns and the card is still correct; it just ranks worse. Do not block on it.

---

## P-D-1: Today

### Task D1: The Today model, so every card is testable

**Files:**
- Create: `Sources/Grux/Home/TodayModel.swift`
- Test: `Tests/GruxTests/TodayModelTests.swift`

**Interfaces:**
- Produces: `TodayModel.next(tasks:calendar:now:) -> TodayModel.Next?`, `.mailThatNeedsYou(_:) -> [MailSummary]`, `.watching(_:) -> [WatchItem]`, and `TodayModel.sayItLine`.

- [ ] **Step 1: Write the failing test.** Cover the cases that actually go wrong:
  - The next thing is the next *calendar event* when one is sooner than the next task, and the next task otherwise.
  - An event that already started is still "next" until it ends, because a meeting you are in is the most relevant thing on the screen.
  - An all-day event never beats a timed event an hour away.
  - With nothing at all, `next` is nil and the card says so rather than rendering an empty row.
  - Times render as `7:30 PM`, never `19:30`, asserted on the formatted string.

- [ ] **Step 2: Run it to verify it fails.**

- [ ] **Step 3: Write the model.** Pure, no singletons, everything passed in. The view resolves `AppState.shared` and hands it over.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Red-prove it.** Make `next` prefer the task unconditionally and make the time formatter 24 hour. Expect at least 3 red. Restore and `diff`.

- [ ] **Step 6: Commit.** Message: `Today decides what is next in a type a test can drive`.

### Task D2: The three cards

**Files:** `Sources/Grux/Home/HomeView.swift`.

Next, Mail that needs you, Watching. Each card:
- Renders from the model in Task D1.
- Has an empty state that says what the card is for and one thing to do, never a blank box.
- Is one tap from the surface it summarises.

- [ ] Test the empty-state copy as data (a `Copy` struct like `ListeningSection.copy`), not by rendering a view.

### Task D3: Start my day, and the say-it line

**Files:** `Sources/Grux/Home/HomeView.swift`.

One line inviting the person to just say it. It must be honest about the listening state, the same way Phase B Task B10 made the composer placeholder honest: with listening off it invites them to turn it on, and does not pretend Grux is listening.

- [ ] Drive the copy from `ListeningTell` and test that mapping. Reuse the tell; do not add a second source of truth about the microphone.

### Task D4: The briefing carries the daily decision and cost line

**Files:** `Sources/Grux/Jax/BriefingEngine.swift`.

One line, from `DecisionUsageSummary.today(DecisionLedger.shared.recent).line`, reading for example `24 decisions today, 500 ms average, under $0.01`.

- [ ] **Step 1: Write the failing test.** The briefing contains the line when there were decisions, and **omits it entirely** when there were none. A briefing that says "no decisions yet today" at 7 AM every morning is noise, and the summary's own `isEmpty` already answers this.

- [ ] **Step 2 to 5** as the standard shape. Red-prove by always emitting the line and asserting the empty-day case goes red.

- [ ] **Step 6: Commit.** Message: `The briefing says what the day's decisions cost`.

### Task D5: Home is Today everywhere it is named

**Files:** `LaunchRootView.swift`, `SidebarModel.swift`, onboarding copy.

The rail row, the tab title and every mention in onboarding read the same word. Phase C computes the rail, so if C has landed this is a label change in the registry row, not a change in two places.

---

## G-D: the phase gate

1. Every task checked, committed and pushed.
2. `swift build` exit 0. `swift test` exit 0, count at or above 2653, 0 failures.
3. Every test introduced red-proven once, planted failure named, restore proven byte-identical by `diff`.
4. A sweep of Home captured with `tools/grux-sweep.sh`, running pid start equal to the installed binary mtime, showing the real name, all three cards and the say-it line.
5. **The briefing renders the decision line from the ledger**, captured as text, with the matching row count from `decisions.jsonl` quoted beside it so the number is provably the ledger's and not a placeholder.
6. A capture of every card's empty state. The empty states are the half that ships broken, because the person building it always has data.

## Notes for whoever executes this

- The three cards are a judgment about what matters, and judgments belong in `TodayModel` where a fixture can drive them. If you find yourself writing `if` inside the card body, that logic is in the wrong file.
- `19:30` is the defect to watch for. One formatter, at the edge, used by every card and the briefing.
