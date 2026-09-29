# Grux 3.0 Phase B: the finished face

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every rough edge measured in the shipped 1.2.1 build is finished, Chat first, so that a stranger opening Grux sees a product rather than a developer tool with its internals showing.

**Architecture:** Nothing here is a style change and nothing touches design tokens. Each item is copy, a state, or noise removed. The pattern throughout: pull the judgment out of the view into a pure type that a test can drive, fix it there, and let the view render it. `Chat/ChatTitleHygiene.swift`, `Chat/ErrorBubbleGrouping.swift`, `Chat/ComposerFooter.swift` and `DesignSystem/VendorGlyph.swift` are the four new pure types; everything else is a call-site change.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` sections 6 and 7. Roadmap: `2026-09-20-grux-3-0-roadmap.md`. Ledger: `2026-09-20-grux-3-0-worklog.md` rows P-B-1 to P-B-5 and gate G-B.

## Global Constraints

- Build worktree, branch `main`. Lanes branch `lane/P-B-n`; only the operator merges and only the operator runs `./build.sh`.
- Test floor: 2653 executed, 10 skipped, 0 failures (measured 2026-09-20 at `39029ec`). The count never goes down.
- No em dashes (U+2014) and no en dashes (U+2013) anywhere, in code, comments, copy or commits. Dollar amounts as numerals with the symbol.
- Design tokens, palette, radii, motion and typography are unchanged. If a fix seems to need a new token, it is the wrong fix.
- Chat is the face. Every visual change lands on Chat with the full treatment.
- Nothing ships off and undiscoverable: named at first run, a permanent Settings home, its off state explained.
- `NoTelemetryInSourcesTests` and `NoPersonalIdentityTests` stay green.
- A packet closes only when its test has been red-proven: plant the failure it guards, watch it go red, restore, `diff` to prove the file is byte-identical.

## What is already true, so nobody rebuilds it

Measured on the running app 2026-09-20, capture `/tmp/shots-a8/home-chat.png`:

- The listening state is already one word across the orb, the menu bar, the HUD and Chat (`ListeningTell`, shipped in P-A8-1). Finish-list item "one listening state across orb, menu bar, HUD" is DONE. Do not redo it.
- The thread sidebar already has a "Filter threads" field. Finish-list item "Find a chat" may already be satisfied. **Task B9 verifies before building.**
- `ChatMessage.isNotice` already exists and `AppState.toCompact` already filters on it. Reuse it; do not invent a second notion of a system message.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Grux/Chat/ChatTitleHygiene.swift` (new) | Pure. Decides whether a generated thread title is fit to show, and what to show instead. |
| `Sources/Grux/Chat/ErrorBubbleGrouping.swift` (new) | Pure. Collapses a run of repeated notices into one card with a count and a fix. |
| `Sources/Grux/Chat/ComposerFooter.swift` (new) | Pure. Builds the composer footer line from routing and estimate, in plain words. |
| `Sources/Grux/DesignSystem/VendorGlyph.swift` (new) | One component. A vendor name one size smaller, collapsing to a small "ai" glyph that expands on hover. |
| `Sources/Grux/AppState.swift` | `autoTitleIfNeeded` filters notices and runs the hygiene check. |
| `Sources/Grux/ChatView.swift` | Header, footer, empty state, composer placeholder, error card. |
| `Sources/Grux/Chat/ChatThreadsSidebar.swift` | Compact thread becomes a menu item; empty threads auto discard. |
| `Sources/Grux/Home/*` | The person's real name. |
| `Sources/Grux/SettingsView.swift` | Plain language copy; the setup badge home. |
| `Sources/Grux/AgentsView.swift` | Failed jobs group into one line with retry. |
| `Sources/Grux/LaunchRootView.swift` | Per-row BETA pills go; the needs-you count arrives. |
| `Tests/GruxTests/JargonInTheFaceTests.swift` (new) | The scan that keeps all of it from coming back. |

---

## P-B-1: Chat finish list, part 1

### Task B1: A thread title is never a status code

**Files:**
- Create: `Sources/Grux/Chat/ChatTitleHygiene.swift`
- Modify: `Sources/Grux/AppState.swift:553-573` (`autoTitleIfNeeded`)
- Test: `Tests/GruxTests/ChatTitleHygieneTests.swift`

**Interfaces:**
- Produces: `ChatTitleHygiene.isFitToShow(_:) -> Bool`, `ChatTitleHygiene.clean(generated:firstUserLine:) -> String`.

Measured on the running app: two threads in the sidebar are titled from error text, `big teets and http 400` and a thread whose preview is `That turn was rejected as malformed (HTTP 400)`. The cause is `autoTitleIfNeeded` handing `thread.messages` to the title generator including notice bubbles, so the model dutifully titles the conversation after the error.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class ChatTitleHygieneTests: XCTestCase {
    func test_aStatusCodeIsNeverFitToShow() {
        XCTAssertFalse(ChatTitleHygiene.isFitToShow("big teets and http 400"))
        XCTAssertFalse(ChatTitleHygiene.isFitToShow("Malformed conversation (HTTP 400)"))
        XCTAssertFalse(ChatTitleHygiene.isFitToShow("429 rate limited"))
        XCTAssertFalse(ChatTitleHygiene.isFitToShow("Error: 500"))
    }

    func test_anOrdinaryTitleIsFine() {
        XCTAssertTrue(ChatTitleHygiene.isFitToShow("Filament order for the printer"))
        // A number that is not a status code is not a status code.
        XCTAssertTrue(ChatTitleHygiene.isFitToShow("Plan for the 400 unit run"))
    }

    func test_aRejectedTitleFallsBackToWhatThePersonSaid() {
        let out = ChatTitleHygiene.clean(generated: "Malformed conversation (HTTP 400)",
                                         firstUserLine: "can you look at the filament order")
        XCTAssertEqual(out, "Can you look at the filament order")
    }

    func test_withNothingToFallBackOnItStaysTheNeutralDefault() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "HTTP 500", firstUserLine: ""), "New chat")
    }

    func test_aLongFallbackIsTrimmedToSomethingThatFitsARail() {
        let long = String(repeating: "a very long opening line ", count: 8)
        let out = ChatTitleHygiene.clean(generated: "HTTP 500", firstUserLine: long)
        XCTAssertLessThanOrEqual(out.count, ChatTitleHygiene.maxLength)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ChatTitleHygieneTests`
Expected: compile error, no such type `ChatTitleHygiene`.

- [ ] **Step 3: Write the type**

```swift
import Foundation

/// A thread title is the one piece of a conversation a person sees in a list
/// for months. It must never be the app's internal account of what went wrong.
///
/// Measured 2026-09-20 on the running app: two threads were titled from error
/// text, because the title generator is handed the whole thread including the
/// notice bubbles and dutifully summarises the failure.
enum ChatTitleHygiene {
    static let maxLength = 60

    /// A number that reads as an HTTP status: three digits in the 100 to 599
    /// range, next to a word that frames it as one. A bare "400 unit run" is
    /// not a status code and must survive.
    private static let statusPattern = try? NSRegularExpression(
        pattern: "(?i)\\b(http|https|status|code|error|err|rate limited|timeout)\\b[^a-z0-9]{0,12}[1-5][0-9]{2}\\b"
            + "|\\b[1-5][0-9]{2}\\b[^a-z0-9]{0,12}(?i)(error|status|response)\\b")

    static func isFitToShow(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if let re = statusPattern,
           re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)) != nil {
            return false
        }
        return true
    }

    /// The generated title when it is fit, the person's own opening line when
    /// it is not, and the neutral default when there is nothing to fall back on.
    static func clean(generated: String, firstUserLine: String) -> String {
        if isFitToShow(generated) { return trimmed(generated) }
        let fallback = firstUserLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, isFitToShow(fallback) else { return "New chat" }
        return trimmed(fallback.prefix(1).uppercased() + fallback.dropFirst())
    }

    private static func trimmed(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLength else { return t }
        return String(t.prefix(maxLength - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ChatTitleHygieneTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Use it at the one call site**

In `AppState.autoTitleIfNeeded`, the messages handed to the generator exclude notices, and the result goes through the hygiene check:

```swift
        let visible = thread.messages.filter { !$0.isNotice }
        let userTurns = visible.filter { $0.role == .user }.count
        guard userTurns >= 2 else { return }
        ...
        guard let title = await ChatCompactor.generateTitle(
            messages: visible,
            backend: routing.backend,
            model: routing.modelId,
            apiKey: routing.apiKey
        ) else { return }
        let firstUserLine = visible.first(where: { $0.role == .user })?.content ?? ""
        let clean = ChatTitleHygiene.clean(generated: title, firstUserLine: firstUserLine)
        guard clean != "New chat" else { return }
        await MainActor.run {
            _ = ChatThreadStore.shared.rename(id: threadId, title: clean)
            self.threads = ChatThreadStore.shared.list()
        }
```

- [ ] **Step 6: Red-prove it**

Change `isFitToShow` to `return true` unconditionally. Run the filter. Expect at least 3 red. Restore and `diff` against a copy taken before the edit to prove the file is byte-identical.

- [ ] **Step 7: Commit**

```bash
git add Sources/Grux/Chat/ChatTitleHygiene.swift Sources/Grux/AppState.swift Tests/GruxTests/ChatTitleHygieneTests.swift
git commit -F /tmp/b1.txt
```

Message: `A thread is never titled after the error that broke it`.

---

### Task B2: Repeated error bubbles become one card with a fix

**Files:**
- Create: `Sources/Grux/Chat/ErrorBubbleGrouping.swift`
- Modify: `Sources/Grux/ChatView.swift` (the message list)
- Test: `Tests/GruxTests/ErrorBubbleGroupingTests.swift`

**Interfaces:**
- Consumes: `ChatMessage.isNotice` from `Models.swift`.
- Produces: `ErrorBubbleGrouping.group(_: [ChatMessage]) -> [ErrorBubbleGrouping.Row]` where `Row` is `.message(ChatMessage)` or `.repeatedNotice(ChatMessage, count: Int)`.

A person who hits the same failure five times should see it once with a way out, not five identical red bubbles.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class ErrorBubbleGroupingTests: XCTestCase {
    private func notice(_ text: String) -> ChatMessage {
        var m = ChatMessage(role: .assistant, content: text)
        m.isNotice = true
        return m
    }
    private func real(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text)
    }

    func test_aRunOfTheSameNoticeCollapsesToOneRowWithACount() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), notice("no model"), notice("no model")])
        XCTAssertEqual(rows.count, 1)
        guard case .repeatedNotice(let m, let n) = rows[0] else { return XCTFail("not grouped") }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(m.content, "no model")
    }

    func test_oneNoticeIsStillJustOneNotice() {
        let rows = ErrorBubbleGrouping.group([notice("no model")])
        guard case .repeatedNotice(_, let n) = rows[0] else { return XCTFail("not grouped") }
        XCTAssertEqual(n, 1)
    }

    func test_differentNoticesDoNotCollapseIntoEachOther() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), notice("no key")])
        XCTAssertEqual(rows.count, 2)
    }

    func test_arealMessageBreaksTheRun() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), real("hello"), notice("no model")])
        XCTAssertEqual(rows.count, 3, "a run must be consecutive, or the transcript reorders itself")
    }

    func test_ordinaryConversationIsUntouched() {
        let msgs = [real("a"), real("b"), real("c")]
        let rows = ErrorBubbleGrouping.group(msgs)
        XCTAssertEqual(rows.count, 3)
        for r in rows { guard case .message = r else { return XCTFail("a real message was grouped") } }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Expected: compile error, no such type.

- [ ] **Step 3: Write the type**

```swift
import Foundation

/// Five identical red bubbles say nothing the first one did not, and they push
/// the conversation off the screen. A run of the same notice is one row with a
/// count and a way out.
enum ErrorBubbleGrouping {
    enum Row: Identifiable {
        case message(ChatMessage)
        case repeatedNotice(ChatMessage, count: Int)

        var id: UUID {
            switch self {
            case .message(let m): return m.id
            case .repeatedNotice(let m, _): return m.id
            }
        }
    }

    /// Consecutive notices with identical content collapse. Consecutive is
    /// load-bearing: grouping across a real message would reorder the
    /// transcript and show an error before the turn that caused it.
    static func group(_ messages: [ChatMessage]) -> [Row] {
        var out: [Row] = []
        var index = 0
        while index < messages.count {
            let m = messages[index]
            guard m.isNotice else {
                out.append(.message(m)); index += 1; continue
            }
            var run = 1
            while index + run < messages.count,
                  messages[index + run].isNotice,
                  messages[index + run].content == m.content { run += 1 }
            out.append(.repeatedNotice(m, count: run))
            index += run
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

- [ ] **Step 5: Render it**

In `ChatView.messagesScroll`, replace `ForEach(state.chat) { m in MessageBubble(message: m).id(m.id) }` with a ForEach over `ErrorBubbleGrouping.group(state.chat)`, rendering `.message` as today and `.repeatedNotice` as one card carrying the text, `"\(count) times"` when count is above 1, and the fix affordance already present on the recovery banner (Settings, or Retry when `state.chatRecovery` offers one).

- [ ] **Step 6: Red-prove it**

Delete the `messages[index + run].content == m.content` clause so unrelated notices merge. Expect `test_differentNoticesDoNotCollapseIntoEachOther` red. Restore and `diff`.

- [ ] **Step 7: Commit**

Message: `The same failure five times is one card with a way out`.

---

### Task B3: The thread title is the header, and the current task lives in Tasks

**Files:**
- Modify: `Sources/Grux/ChatView.swift:151-200` (`heroHeader`)
- Test: `Tests/GruxTests/ChatHeaderTests.swift`

Measured: the Chat header reads `CURRENT TASK / No current task. Ask me what to work on.` on a tab whose job is the conversation. The current task has a home, and it is Tasks.

- [ ] **Step 1: Write the failing test** (source contract, in the house style used by `DecisionTellsTests`)

```swift
import XCTest
@testable import Grux

final class ChatHeaderTests: XCTestCase {
    private func chatView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "ChatView did not load")
        return t
    }

    func test_theHeaderNamesTheConversationRatherThanTheTaskStack() throws {
        let t = try chatView()
        XCTAssertFalse(t.contains("\"CURRENT TASK\""),
                       "Chat still leads with the task stack, which has its own tab")
        XCTAssertFalse(t.contains("No current task. Ask me what to work on."),
                       "the task empty state is still on the face of Chat")
    }
}
```

- [ ] **Step 2: Run it to verify it fails.** Expected: both assertions red.

- [ ] **Step 3: Replace the header block**

The title block becomes the active thread's title (falling back to `New chat`), with the listening and voice chips on their own row exactly as they are today. Keep the row split: it exists because at the 840pt window floor a shared row truncated both chips to two characters.

- [ ] **Step 4: Run the test to verify it passes**

- [ ] **Step 5: Sweep it.** `GRUX_SWEEP_OUT=/tmp/shots-b3 tools/grux-sweep.sh home chat` and read the capture. The header must name the thread.

- [ ] **Step 6: Red-prove it.** Put `Text("CURRENT TASK")` back. Expect red. Restore and `diff`.

- [ ] **Step 7: Commit.** Message: `Chat leads with the conversation, not the task stack`.

---

### Task B4: A system message never renders as the person

**Files:**
- Modify: `Sources/Grux/Chat/MessageBubble.swift`
- Test: `Tests/GruxTests/SystemMessageRenderingTests.swift`

- [ ] **Step 1: Write the failing test.** Assert that a message with `role == .system` renders on the assistant side and never carries the `YOU` label or the user bubble tint. Drive it through whatever pure helper `MessageBubble` uses for alignment; if there is none, extract one (`MessageBubble.side(for:) -> Side`) as the first step, because a view that decides this inline cannot be tested.

- [ ] **Step 2: Run it to verify it fails.**

- [ ] **Step 3: Implement.** `side(for:)` returns `.assistant` for anything that is not `.user`.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Red-prove** by returning `.user` for `.system`. Restore and `diff`.

- [ ] **Step 6: Commit.** Message: `A system message never wears the person's face`.

---

## P-B-2: Chat finish list, part 2

### Task B5: State chips replace vendor chips

**Files:**
- Modify: `Sources/Grux/ChatView.swift:965` (`modelChip`)
- Test: extend `Tests/GruxTests/DecisionTellsTests.swift`

The header already carries the listening tell. The second chip reads `SYSTEM TTS` or `ELEVEN LABS`, which is a vendor, not a state. It becomes the state (`SPEAKING`, `SILENT`, `VOICE OFF`) and the vendor moves behind the `VendorGlyph` from Task B12.

- [ ] Steps follow the same five-beat shape. Red-prove by restoring the vendor string to the chip and asserting the jargon test from Task B13 catches it.

### Task B6: A plain footer instead of model ids and token counts

**Files:**
- Create: `Sources/Grux/Chat/ComposerFooter.swift`
- Modify: `Sources/Grux/ChatView.swift:1043-1055`
- Test: `Tests/GruxTests/ComposerFooterTests.swift`

Measured on the running app, the footer reads: `llama3.2:3b | est $0.0294 for this send | i...ok | cheaper: qwen3.5:4b free`. Four pieces of internal accounting on the most looked-at surface in the app.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class ComposerFooterTests: XCTestCase {
    func test_theFooterNamesNoModelIdentifier() {
        let line = ComposerFooter.line(modelDisplayName: "Llama 3.2",
                                       modelIdentifier: "llama3.2:3b",
                                       estimatedUSD: 0.0294,
                                       cheaperName: "Qwen 3.5", cheaperUSD: 0)
        XCTAssertFalse(line.contains("llama3.2:3b"), "the raw model identifier is on the face")
        XCTAssertFalse(line.contains(":"), "an identifier-shaped token is on the face")
    }

    func test_aFreeSendSaysFreeRatherThanZeroDollars() {
        XCTAssertTrue(ComposerFooter.line(modelDisplayName: "Llama 3.2", modelIdentifier: "x:y",
                                          estimatedUSD: 0, cheaperName: nil, cheaperUSD: nil)
            .lowercased().contains("free"))
    }

    func test_aPricedSendShowsMoneyAsNumeralsWithTheSymbol() {
        let line = ComposerFooter.line(modelDisplayName: "Sonnet", modelIdentifier: "x:y",
                                       estimatedUSD: 0.03, cheaperName: nil, cheaperUSD: nil)
        XCTAssertTrue(line.contains("$0.03"), "line was \(line)")
    }

    func test_aSubCentSendDoesNotRenderAsAStringOfZeros() {
        let line = ComposerFooter.line(modelDisplayName: "Sonnet", modelIdentifier: "x:y",
                                       estimatedUSD: 0.0004, cheaperName: nil, cheaperUSD: nil)
        XCTAssertFalse(line.contains("$0.00"), "line was \(line)")
    }
}
```

- [ ] Steps 2 to 7 as the shape above. The line reads `Llama 3.2 | free` or `Sonnet | about $0.03`, and the cheaper-alternative nudge moves to the model picker where a person can act on it.

### Task B7: Compact thread becomes a menu item

**Files:** `Sources/Grux/Chat/ChatThreadsSidebar.swift:285`. Measured: it is a full-width gradient button pinned under the thread list, which gives an occasional maintenance action the most prominent affordance in the column. It moves into the thread's context menu and the thread overflow menu.

### Task B8: Empty threads discard themselves

**Files:** `Sources/Grux/Chat/ChatThreadStore.swift`, `ChatThreadsSidebar.swift`. Measured on the running app: two of the eight visible threads are `New chat` with 2 messages and one is empty. A thread with no user turn is discarded when it stops being active. Test the pure rule (`ChatThreadStore.shouldDiscard(_:)`), not the view.

### Task B9: Find a chat, verify before building

**Files:** `Sources/Grux/Chat/ChatThreadsSidebar.swift`.

The capture shows a `Filter threads` field already present. **Verify it first:** open Chat, type a word that appears only in one thread's body, and see whether the list narrows on title only or on content too. If it searches content, tick this item with the capture as evidence and write only the regression test. If it searches titles only, extend it to content and say so.

### Task B10: The composer placeholder invites speech

**Files:** `Sources/Grux/ChatView.swift` (the composer). The placeholder names the thing that makes 3.0 different: talking to it. Copy: `Ask me anything, or just say it out loud.` Falls back to `Ask me anything` when listening is off, because inviting speech from a Mac that is not listening is a lie. Drive the choice from `ListeningTell`, and test that pure mapping.

### Task B11: Plain empty states

**Files:** `Sources/Grux/ChatView.swift:434` (`emptyState`) and the folded views' empty states. Each one says what the surface is for and the one thing to do next. No dead ends: an empty state with no action is a wall.

---

## P-B-3: The vendor glyph

### Task B12: One component wherever a vendor shows

**Files:**
- Create: `Sources/Grux/DesignSystem/VendorGlyph.swift`
- Modify: every site that renders a vendor name (find them with `grep`, and **state the count found and the count changed** in the commit message)
- Test: `Tests/GruxTests/VendorGlyphTests.swift`

A vendor name is true and it is not the point. One size smaller, collapsing to a small `ai` glyph that expands on hover. One component, reused. Do not over-engineer it: it takes a name and renders it, and that is all.

- [ ] The test asserts the component exists, that it renders the name it is given, and that the collapsed state carries an accessibility label naming the vendor (a glyph nobody can read is worse than the word).

---

## P-B-4: The jargon test

### Task B13: A test fails on internals in the face

**Files:**
- Create: `Tests/GruxTests/JargonInTheFaceTests.swift`

**What it bans, in view files only:** HTTP status codes, raw model identifiers (anything matching `[a-z0-9.]+:[a-z0-9.]+` in a user-facing string), and internal identifiers (`tab:`, `macro:`, `say:chat`, `not_a_command`, `__replay_tool`).

**What it allows, deliberately:** vendor names. The spec is explicit that they stay; this test is about internals, not about pretending Grux has no suppliers.

**Where it does not apply:** Settings detail lines and Developer surfaces, which are where a person goes precisely to see internals. The exemption list is a data file beside the test, not a hardcoded array, and a second test fails the day an exemption stops matching anything, so the list cannot rot.

- [ ] **Red-prove it by planting one of each of the three kinds** in a view file, watching three go red, restoring, and `diff`ing. A jargon test that has never caught a planted `HTTP 400` is decoration.

---

## P-B-5: The rest of the finish list

### Task B14: The person's real name on Home
`Sources/Grux/Home/*`. The name comes from the identity already captured at onboarding. With no name, the greeting has no name in it rather than a placeholder.

### Task B15: The setup nag becomes a Settings badge
Measured: the sidebar foot reads `5 features need setup` permanently. It becomes a badge on the Settings row. `LaunchRootView.swift:514`.

### Task B16: MOVED TO PHASE C, and here is why

This task originally said: remove the six per-row `BETA` pills now, and let
Phase C add the single badge at the Labs door.

**That was wrong, and an existing test caught it.** `BetaBadgeTests` guards a
promise onboarding makes to the user: experimental features are labelled,
because an unlabelled empty shell is indistinguishable from a broken tab.
Removing the label before its replacement exists breaks that promise for
however long Phase C takes, and makes onboarding lie in the meantime.

A gap between a removal and its replacement is a regression even when both
halves are planned. **The pills move in Phase C task C2, where both halves land
in one change.** Nothing to do here.

### Task B17: The needs-you count in the rail
The Mail row carries the count of what needs the person, not the unread count. Measured today the rail shows `245`, which is an inbox size and tells nobody anything. The scoring itself is packet P-A9-6; this task is the plumbing and the copy, and it reads whatever the score currently returns.

### Task B18: Listening and Mute in the foot
Both reachable without opening Settings, using `ListeningTell` so the words match every other surface.

### Task B19: Failed jobs group into one line with retry
`Sources/Grux/AgentsView.swift`. Same shape as Task B2: a pure grouping function, tested, then rendered.

### Task B20: Plain language Settings copy, and one setup card shape
`Sources/Grux/SettingsView.swift` (2,271 lines). Sweep every user-facing string. **State the count of strings reviewed and the count changed**, and reconcile the gap by name; "tidied the copy" with no count is how nine of twelve ship.

### Task B21: The composer surface, found by looking
Measured in `/tmp/shots-a8/home-chat.png`: the composer renders as a large light grey block against the dark theme, with an unexplained blue circular control at its top left. Neither reads as deliberate. Identify the cause (most likely an unstyled `NSTextView` background showing through), fix it, and capture before and after. This item is not on the accepted finish list; it is on this plan because it is on the face of the app and the list says "there's likely dozens more, include all your RECs".

---

## G-B: the phase gate

The phase closes when all of the following have an artifact in `2026-09-20-grux-3-0-evidence.md`:

1. Every task above checked, each committed and pushed.
2. `swift build` exit 0. `swift test` exit 0, executed count at or above 2653, 0 failures.
3. Every test introduced in Phase B red-proven once, with the planted failure named and the restore proven byte-identical by `diff`.
4. A Chat sweep captured with `tools/grux-sweep.sh`, with the running pid's start time equal to the installed binary's mtime, matching the accepted finished face **item by item**: a list of the finish-list items with a tick and the pixel evidence for each, not a single "looks right".
5. The jargon test red-proven on all three kinds of internal it bans.
6. Counts stated and reconciled for the two sweep tasks (B12 vendor sites, B20 Settings strings).

## Notes for whoever executes this

- Phase B and Phase C touch the same three files (`SidebarModel.swift`, `LaunchRootView.swift`, `ChatView.swift`). B lands first so the face is finished before the rail moves under it. **Never run a B lane and a C lane at the same time.**
- Task B21 exists because somebody looked at a screenshot. Keep doing that. The finish list is a floor, not a ceiling, and the decision record says so in as many words.
- If a fix seems to need a new design token, stop: the tokens are fixed for 3.0 and the fix is wrong.
