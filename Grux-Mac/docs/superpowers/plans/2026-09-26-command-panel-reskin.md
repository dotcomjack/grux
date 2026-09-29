# Command Panel Reskin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 240pt sidebar shell with a 420pt Command Panel that shows one input, a relevance-ranked "Now" list, an Optimize Grux hub with four doors, and opens any of the 37 existing surfaces as a single pane on demand.

**Architecture:** A new root view (`CommandPanelRoot`) owns the pane selection and hosts the panel column and an optional pane column. The 37-case surface switch moves out of `LaunchRootView` into `SurfacePane`, which both roots share. What appears in Now is decided by one pure function, `Relevance.now`, over a plain value struct assembled from stores that already exist. Optimize Grux becomes a card with four doors; the new door writes a secret-stripped handoff bundle. Design-token adoption is enforced by a ratchet script that only lets hardcode counts fall.

**Tech Stack:** Swift 6, SwiftUI on macOS 14+, AppKit for the window, XCTest, Python 3 for the ratchet script, SwiftPM (`swift build`, `swift test`).

**Spec:** `docs/superpowers/specs/2026-09-26-command-panel-reskin-design.md`

## Global Constraints

- Branch `reskin/command-panel` off `main` `7fab663`. Commit each task. Push freely (the pre-push hook runs a release build; on this Mac `swift build -c release` takes minutes the first time).
- Never delete a surface, a `Tab` case, a tab key, or a registry row. `TabAdoptionTests` must keep reporting 37.
- The `--open-tab=<key>`, `~/.grux/fire-open-tab`, `grux open <key>` and `~/.grux/rendered-tab.txt` contracts stay exactly as they are, plus one new rendered value `panel`.
- No em dashes (U+2014) and no en dashes (U+2013) anywhere: code, comments, tests, docs, commit messages. Dollar amounts as `$50`. Times as `7:30 PM`.
- Colors, type, spacing and radii in every NEW file come only from `GruxTheme`, `GruxType`, `GruxSpacing`, `GruxLayout` and `GruxTheme.Radius`. No `.font(.system(size:))`, no `Color.white.opacity`, no numeric `.padding(`, no numeric `.cornerRadius(` outside `Sources/Grux/DesignSystem/`.
- Every new test is red-proven: run it against the missing or broken code, watch it fail for the stated reason, then make it pass.
- `swift test` is run in full after every task, and the executed count must not fall below 3147 (the measured floor on 2026-09-26). New tests raise it.
- Persisted config gains one key, `legacyShell`. Existing `config.json` files must decode with it absent (default false).
- Nothing new leaves the Mac. `opens.jsonl` is a local file.
- Multi-line commit messages go through `git commit -F <file>`, never `-m`.

## Review Focus

Inputs the spec implies but no task's tests would otherwise exercise, most likely to bite first:

1. **A pane request arrives while onboarding is presenting.** Expected: the request is honored after onboarding finishes, not dropped and not rendered over the onboarding screen. Pinned by `CommandPanelRootTests.test_aTabRequestedDuringOnboardingOpensAfterIt` (Task 5).
2. **The same tab is requested twice with a close in between.** `requestedTab` is a `String` and `onChange` fires only on change, so "chat", close, "chat" would not reopen. Expected: it reopens. Pinned by `CommandPanelRootTests.test_closingAPaneResetsTheRequestSoTheSameTabCanReopen` (Task 5).
3. **`Relevance.now` receives more than 7 needs-you items.** Expected: exactly 7 rows, all needs-you, in source order, nothing from a lower class. Pinned by `RelevanceTests.test_theCapNeverPromotesALowerClass` (Task 2).
4. **The handoff bundle meets a nested secret** (a secret-shaped key inside an object inside `config.json`, not at the top level). Expected: stripped. Pinned by `HandoffBundleTests.test_aNestedSecretIsStripped` (Task 9).
5. **The window is narrower than the panel plus a pane** when a pane opens (the user shrank it). Expected: the window grows to fit, never clips the pane off the right edge. Pinned by `LaunchWindowSizingTests.test_openingAPaneRaisesTheMinimumAndTheWidth` (Task 6).

---

## File map

Created:

| File | Responsibility |
|---|---|
| `Sources/Grux/Shell/Relevance.swift` | `PanelItem`, `PanelAction`, `RelevanceState`, `Relevance.now`. Pure. |
| `Sources/Grux/Shell/RelevanceState+Live.swift` | `RelevanceState.live()`: reads the stores into the value struct. |
| `Sources/Grux/Shell/OpensLog.swift` | Appends `{ts,key,via}` to `opens.jsonl`. |
| `Sources/Grux/Shell/SurfacePane.swift` | The 37-case switch, the folds, the rendered-tab hook, the activity strip. |
| `Sources/Grux/Shell/CommandPanelRoot.swift` | The new root: panel column plus optional pane column, selection, window resize. |
| `Sources/Grux/Shell/CommandPanel/PanelHead.swift` | Orb, wordmark, badges. |
| `Sources/Grux/Shell/CommandPanel/PanelInput.swift` | The one input and its mic. |
| `Sources/Grux/Shell/CommandPanel/PanelNowList.swift` | Renders `[PanelItem]`. |
| `Sources/Grux/Shell/CommandPanel/PanelFoot.swift` | Recent strip, Watching, listening, approvals, Settings. |
| `Sources/Grux/Shell/CommandPanel/PanelCopy.swift` | Every string the panel shows. |
| `Sources/Grux/Optimize/OptimizeHubCard.swift` | The card with four doors. |
| `Sources/Grux/Optimize/HandoffBundle.swift` | Writes the bundle; strips secrets. |
| `scripts/design-ratchet.py`, `scripts/design-ratchet-baseline.json` | The hardcode ratchet. |
| `Tests/GruxTests/RelevanceTests.swift`, `OpensLogTests.swift`, `SurfacePaneTests.swift`, `CommandPanelRootTests.swift`, `LaunchWindowSizingTests.swift`, `FirstRunPanelCaptureTests.swift`, `PaletteCoverageTests.swift`, `OptimizeHubTests.swift`, `HandoffBundleTests.swift`, `PanelReachabilityTests.swift`, `DesignRatchetTests.swift` | Per task below. |

Modified:

| File | Change |
|---|---|
| `Sources/Grux/DesignSystem/DesignTokens.swift` | Five panel layout tokens. |
| `Sources/Grux/Models.swift` | `legacyShell` key. |
| `Sources/Grux/LaunchRootView.swift` | Switch moves out; the rest stays as the legacy shell. |
| `Sources/Grux/GruxApp.swift` | Root choice, window sizing, cold-boot landing, `setLaunchWindowContentWidth`. |
| `Sources/Grux/ChatView.swift` | `hostedInPane` folds the threads sidebar. |
| `Sources/Grux/Shell/OrbCommandPalette.swift` | Rail labels, missing destinations, recents once. |
| `Sources/Grux/Optimize/OptimizeGruxView.swift` | Copy shared with the hub; the pill stays for the legacy shell. |
| `Sources/Grux/Optimize/WorkOrder.swift` | Station count made consistent. |
| `Sources/Grux/Onboarding/OnboardingSteps.swift`, `OnboardingModel.swift` | Wayfinding copy, landing. |
| `Sources/Grux/SettingsView.swift` | "Hand setup to your agent" links to the hub; "Classic sidebar" switch. |
| `tools/grux-tab-keys-check.sh` | Accepts `panel`. |
| `docs/feature-registry.md` | Section 9, how each row is reached. |
| `.github/workflows/ci.yml` | Ratchet step. |
| `CLAUDE.md`, `CHANGELOG.md`, `docs/superpowers/plans/2026-09-20-grux-3-0-worklog.md` | Landing, keys, entry. |
| Tests listed in Task 12. | Rewritten. |

---

### Task 1: Layout tokens and the `legacyShell` key

**Files:**
- Modify: `Sources/Grux/DesignSystem/DesignTokens.swift:39-45` (inside `enum GruxLayout`, after `windowFloorHeight`)
- Modify: `Sources/Grux/Models.swift:731` (after `developerSurfacesUnlocked`), `:895` (CodingKeys), `:952` (init parameter), `:1028` (assignment), `:1160` (decode)
- Test: `Tests/GruxTests/LayoutTokenTests.swift`, `Tests/GruxTests/ConfigLegacyShellTests.swift`

**Interfaces:**
- Produces: `GruxLayout.panelWidth: CGFloat = 420`, `GruxLayout.paneWidth: CGFloat = 680`, `GruxLayout.panelMinWidth: CGFloat = 380`, `GruxLayout.panelMinHeight: CGFloat = 480`, `GruxLayout.panelIdealHeight: CGFloat = 560`, `GruxLayout.paneBarHeight: CGFloat = 36`, `GruxConfig.legacyShell: Bool`.

- [ ] **Step 1: Write the failing token tests**

Append to `Tests/GruxTests/LayoutTokenTests.swift` inside the class:

```swift
    // MARK: - Command Panel (3.0 reskin)

    func testThePanelPlusAPaneIsWiderThanTheOldWindowFloor() {
        XCTAssertGreaterThanOrEqual(GruxLayout.panelWidth + GruxLayout.paneWidth, GruxLayout.windowFloorWidth,
                                    "a pane beside the panel must never be narrower than the old detail pane budget")
    }

    func testThePaneIsAtLeastTheWidestSurfaceMinimum() {
        // Chat is the widest surface at 560 (ChatView.frame(minWidth:)).
        XCTAssertGreaterThanOrEqual(GruxLayout.paneWidth, 560)
    }

    func testThePanelFloorsAreBelowTheirIdeals() {
        XCTAssertLessThan(GruxLayout.panelMinWidth, GruxLayout.panelWidth)
        XCTAssertLessThan(GruxLayout.panelMinHeight, GruxLayout.panelIdealHeight)
    }
```

Create `Tests/GruxTests/ConfigLegacyShellTests.swift`:

```swift
import XCTest
@testable import Grux

/// `legacyShell` keeps the 240pt sidebar for one release. A fresh install and
/// an install that predates the key both get the panel, so the decode fallback
/// and the init default AGREE here, unlike `developerSurfacesUnlocked`.
final class ConfigLegacyShellTests: XCTestCase {
    func test_aFreshConfigUsesThePanel() {
        XCTAssertFalse(GruxConfig().legacyShell)
    }

    func test_aConfigWrittenBeforeTheKeyExistedUsesThePanel() throws {
        var full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GruxConfig())) as! [String: Any]
        full.removeValue(forKey: "legacyShell")
        let data = try JSONSerialization.data(withJSONObject: full)
        XCTAssertFalse(try JSONDecoder().decode(GruxConfig.self, from: data).legacyShell)
    }

    func test_theKeyRoundTrips() throws {
        var c = GruxConfig()
        c.legacyShell = true
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.legacyShell)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter 'LayoutTokenTests|ConfigLegacyShellTests' 2>&1 | tail -20`
Expected: compile errors naming `panelWidth`, `paneWidth`, `legacyShell` as missing members.

- [ ] **Step 3: Add the tokens**

In `DesignTokens.swift`, after `static let windowFloorHeight: CGFloat = 560`, add:

```swift
    // MARK: Command Panel (3.0 reskin)
    //
    // The panel is the resting form: one column, no sidebar. A surface opens
    // beside it as ONE pane, and the window grows by `paneWidth` to hold it.
    // `windowFloorWidth` and `navRail` above describe the legacy shell and
    // stay until `legacyShell` is removed.

    /// 420pt: the panel column. Wide enough for a seven-row Now list with a
    /// glyph, a title and one action per row at the body size.
    static let panelWidth: CGFloat = 420
    /// 680pt: the pane beside it. Above chat's 560 minimum with room for the
    /// pane bar's close control; matches the old window's detail budget.
    static let paneWidth: CGFloat = 680
    /// 380pt: the panel's floor. 16pt padding per side leaves 348pt, the same
    /// narrowest readable form row `sheetMin` is derived from.
    static let panelMinWidth: CGFloat = 380
    /// 480pt: the panel's height floor. Head, input, four Now rows, the
    /// collapsed Optimize row and the foot, at the row heights below.
    static let panelMinHeight: CGFloat = 480
    /// 560pt: the resting height.
    static let panelIdealHeight: CGFloat = 560
    /// 36pt: the bar across the top of an open pane (name and close).
    static let paneBarHeight: CGFloat = 36
```

- [ ] **Step 4: Add the config key**

In `Models.swift`:

After line 731 (`var developerSurfacesUnlocked: Bool`) add:

```swift
    /// The 240pt sidebar shell instead of the Command Panel. One release
    /// only; the panel is the shell. Default false for every install, new or
    /// old, which is why the decode fallback below also says false.
    var legacyShell: Bool
```

In `CodingKeys` (line 895 area), after `case developerSurfacesUnlocked` add:

```swift
        case legacyShell
```

In the memberwise `init` parameter list (line 952 area), after `developerSurfacesUnlocked: Bool = false,` add:

```swift
         legacyShell: Bool = false,
```

In the assignments (line 1028 area), after `self.developerSurfacesUnlocked = developerSurfacesUnlocked` add:

```swift
        self.legacyShell = legacyShell
```

In `init(from decoder:)` (line 1160 area), after the `developerSurfacesUnlocked` decode add:

```swift
        legacyShell = try c.decodeIfPresent(Bool.self, forKey: .legacyShell) ?? false
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter 'LayoutTokenTests|ConfigLegacyShellTests' 2>&1 | tail -5`
Expected: `Executed 20 tests, with 0 failures` (14 existing plus 6 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/Grux/DesignSystem/DesignTokens.swift Sources/Grux/Models.swift Tests/GruxTests/LayoutTokenTests.swift Tests/GruxTests/ConfigLegacyShellTests.swift
git commit -F - <<'MSG'
Panel layout tokens and the legacyShell key

Five GruxLayout tokens for the Command Panel and its pane, and one config
key that keeps the old sidebar for one release. The key defaults false on
decode as well as on init, so nobody is opted into the old shell by age.
MSG
```

---

### Task 2: `Relevance.now`, the pure function

**Files:**
- Create: `Sources/Grux/Shell/Relevance.swift`
- Test: `Tests/GruxTests/RelevanceTests.swift`

**Interfaces:**
- Produces:

```swift
struct PanelItem: Equatable, Identifiable {
    enum Class: Int, Comparable { case needsYou = 0, running, next, suggested }
    let id: String; let cls: Class; let icon: String; let title: String; let detail: String; let action: PanelAction
}
enum PanelAction: Equatable {
    case open(tabKey: String); case openApprovals; case openWorkOrder(id: String); case setup(featureId: String); case openOptimize
}
struct RelevanceState: Equatable {
    var approvalsPending: Int = 0
    var reviewsWaiting: [WorkOrderReview] = []
    var mail: [TodayModel.MailSummary] = []; var mailTotal: Int = 0
    var jobsRunning: Int = 0; var jobsWaitingOnYou: Int = 0
    var workflowRunning: String? = nil
    var next: TodayModel.Next? = nil
    var setupGaps: [SetupGap] = []
    var proposals: Int = 0
    var hasBrand: Bool = false
}
enum Relevance { static func now(_ s: RelevanceState, cap: Int = 7) -> [PanelItem] }
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/GruxTests/RelevanceTests.swift`:

```swift
import XCTest
@testable import Grux

/// What the panel's Now list shows, decided by one pure function. Every rule
/// in spec section 4.2 is a test here, and the function takes a value struct
/// so none of these needs a store.
final class RelevanceTests: XCTestCase {

    private func next(_ title: String) -> TodayModel.Next {
        TodayModel.Next(kind: .task, title: title, when: "", tab: "tasks", then: [])
    }

    func test_nothingInGivesNothingOut() {
        XCTAssertEqual(Relevance.now(RelevanceState()), [])
    }

    func test_everyRowCarriesAnAction() {
        var s = RelevanceState()
        s.approvalsPending = 1
        s.mail = [TodayModel.MailSummary(id: "m1", from: "Ana", subject: "Invoice")]
        s.jobsRunning = 2
        s.next = next("Write the plan")
        s.proposals = 1
        s.setupGaps = [SetupGap(featureId: "mailbox", label: "Mail", missing: "an IMAP account")]
        for item in Relevance.now(s) {
            switch item.action {
            case .open, .openApprovals, .openWorkOrder, .setup, .openOptimize: break
            }
        }
        XCTAssertEqual(Relevance.now(s).count, 7)
    }

    func test_classesComeInOrder_needsYouRunningNextSuggested() {
        var s = RelevanceState()
        s.proposals = 1                              // suggested
        s.next = next("Call Sam")                    // next
        s.jobsRunning = 1                            // running
        s.approvalsPending = 2                       // needsYou
        let classes = Relevance.now(s).map(\.cls)
        XCTAssertEqual(classes, [.needsYou, .running, .next, .suggested])
    }

    func test_approvalsCollapseToOneRowWhateverTheCount() {
        var s = RelevanceState()
        s.approvalsPending = 9
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "9 approvals waiting")
        XCTAssertEqual(rows.first?.action, .openApprovals)
    }

    func test_oneApprovalReadsInTheSingular() {
        var s = RelevanceState()
        s.approvalsPending = 1
        XCTAssertEqual(Relevance.now(s).first?.title, "1 approval waiting")
    }

    func test_aWorkOrderAtAReviewIsNeedsYou_andOpensThatOrder() {
        var s = RelevanceState()
        s.reviewsWaiting = [WorkOrderReview(id: "wo-abc123", request: "Make the accent red")]
        let row = Relevance.now(s)[0]
        XCTAssertEqual(row.cls, .needsYou)
        XCTAssertEqual(row.action, .openWorkOrder(id: "wo-abc123"))
        XCTAssertTrue(row.title.contains("Make the accent red"))
    }

    func test_mailRowsKeepTheirSourceOrderAndOpenMail() {
        var s = RelevanceState()
        s.mail = [TodayModel.MailSummary(id: "a", from: "Ana", subject: "One"),
                  TodayModel.MailSummary(id: "b", from: "Bo", subject: "Two")]
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.title), ["Ana: One", "Bo: Two"])
        XCTAssertEqual(rows.map(\.action), [.open(tabKey: "mailbox"), .open(tabKey: "mailbox")])
    }

    func test_theCapIsSeven_andAParameter() {
        var s = RelevanceState()
        s.mail = (0..<10).map { TodayModel.MailSummary(id: "\($0)", from: "F\($0)", subject: "S") }
        XCTAssertEqual(Relevance.now(s).count, 7)
        XCTAssertEqual(Relevance.now(s, cap: 3).count, 3)
    }

    func test_theCapNeverPromotesALowerClass() {
        var s = RelevanceState()
        s.mail = (0..<9).map { TodayModel.MailSummary(id: "\($0)", from: "F\($0)", subject: "S") }
        s.next = next("Should not appear")
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.cls == .needsYou })
        XCTAssertEqual(rows.map(\.id), (0..<7).map { "mail.\($0)" }, "source order inside the class")
    }

    func test_runningJobsAndAWorkflowAreRunning() {
        var s = RelevanceState()
        s.jobsRunning = 3
        s.workflowRunning = "smoke-hello-world"
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.cls), [.running, .running])
        XCTAssertEqual(rows[0].title, "3 agent jobs running")
        XCTAssertEqual(rows[0].action, .open(tabKey: "agents"))
        XCTAssertEqual(rows[1].action, .open(tabKey: "workflows"))
    }

    func test_jobsWaitingOnYouAreNeedsYouNotRunning() {
        var s = RelevanceState()
        s.jobsWaitingOnYou = 1
        XCTAssertEqual(Relevance.now(s).first?.cls, .needsYou)
        XCTAssertEqual(Relevance.now(s).first?.action, .open(tabKey: "agents"))
    }

    func test_nextOpensTheTabItNames() {
        var s = RelevanceState()
        s.next = TodayModel.Next(kind: .event, title: "Standup", when: "At 9:30 AM", tab: "calendar", then: [])
        let row = Relevance.now(s)[0]
        XCTAssertEqual(row.cls, .next)
        XCTAssertEqual(row.action, .open(tabKey: "calendar"))
        XCTAssertEqual(row.detail, "At 9:30 AM")
    }

    func test_setupGapsAndProposalsAreSuggested() {
        var s = RelevanceState()
        s.setupGaps = [SetupGap(featureId: "calendar", label: "Calendar", missing: "calendar access")]
        s.proposals = 2
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.cls), [.suggested, .suggested])
        XCTAssertEqual(rows[0].action, .setup(featureId: "calendar"))
        XCTAssertEqual(rows[0].title, "Calendar needs calendar access")
        XCTAssertEqual(rows[1].action, .open(tabKey: "selfUpgrade"))
    }

    func test_brandScopedRowsNeedABrand() {
        var s = RelevanceState()
        s.setupGaps = [SetupGap(featureId: "metaAds", label: "Meta Ads", missing: "an ad account"),
                       SetupGap(featureId: "social", label: "Social", missing: "a brand")]
        XCTAssertEqual(Relevance.now(s), [], "brand-scoped gaps without a brand")
        s.hasBrand = true
        XCTAssertEqual(Relevance.now(s).count, 2)
    }

    func test_idsAreStableAndDistinct() {
        var s = RelevanceState()
        s.approvalsPending = 1; s.jobsRunning = 1; s.next = next("x"); s.proposals = 1
        s.mail = [TodayModel.MailSummary(id: "m", from: "f", subject: "s")]
        let ids = Relevance.now(s).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Relevance.now(s).map(\.id), ids, "same input, same ids")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RelevanceTests 2>&1 | tail -5`
Expected: compile errors, `cannot find 'Relevance' in scope`, `cannot find type 'RelevanceState'`.

- [ ] **Step 3: Write `Relevance.swift`**

Create `Sources/Grux/Shell/Relevance.swift`:

```swift
import Foundation

// What the Command Panel's Now list shows. One pure function over a value
// struct, so the rules in spec section 4.2 are tests and not opinions. The
// panel assembles `RelevanceState` from the stores (RelevanceState+Live.swift)
// and never decides anything itself.

/// One row of Now. Every row carries an action; there are no informational rows.
struct PanelItem: Equatable, Identifiable {
    /// Ordered by urgency. The raw value is the sort key.
    enum Class: Int, Comparable {
        case needsYou = 0, running, next, suggested
        static func < (a: Class, b: Class) -> Bool { a.rawValue < b.rawValue }
    }
    let id: String
    let cls: Class
    let icon: String
    let title: String
    let detail: String
    let action: PanelAction
}

enum PanelAction: Equatable {
    /// Open a surface by its locked tab key.
    case open(tabKey: String)
    case openApprovals
    /// Expand the Optimize hub on this order.
    case openWorkOrder(id: String)
    /// Open the setup card for a registry row.
    case setup(featureId: String)
    case openOptimize
}

/// A work order stopped at one of its three reviews.
struct WorkOrderReview: Equatable {
    let id: String
    let request: String
}

/// A feature the person picked that is missing something.
struct SetupGap: Equatable {
    let featureId: String
    let label: String
    /// Human words for the first missing thing, already lowercased.
    let missing: String
}

/// Everything Now is decided from. Counts and arrays only, no live objects.
struct RelevanceState: Equatable {
    var approvalsPending: Int = 0
    var reviewsWaiting: [WorkOrderReview] = []
    var mail: [TodayModel.MailSummary] = []
    var mailTotal: Int = 0
    var jobsRunning: Int = 0
    var jobsWaitingOnYou: Int = 0
    /// The display name of a CommandsV2 run in flight, if one is.
    var workflowRunning: String? = nil
    var next: TodayModel.Next? = nil
    var setupGaps: [SetupGap] = []
    var proposals: Int = 0
    var hasBrand: Bool = false
}

enum Relevance {
    /// Keys whose rows exist only once a brand does.
    static let brandScoped: Set<String> = ["metaAds", "social"]

    static func now(_ s: RelevanceState, cap: Int = 7) -> [PanelItem] {
        var out: [PanelItem] = []

        // needsYou, in this order: approvals, reviews, jobs waiting, mail.
        if s.approvalsPending > 0 {
            out.append(PanelItem(id: "approvals", cls: .needsYou, icon: "checkmark.seal.fill",
                                 title: TodayModel.plural(s.approvalsPending, "approval", "approvals") + " waiting",
                                 detail: "", action: .openApprovals))
        }
        for r in s.reviewsWaiting {
            out.append(PanelItem(id: "review.\(r.id)", cls: .needsYou, icon: "wand.and.stars",
                                 title: "Your review: \(r.request)", detail: "Optimize Grux",
                                 action: .openWorkOrder(id: r.id)))
        }
        if s.jobsWaitingOnYou > 0 {
            out.append(PanelItem(id: "jobs.waiting", cls: .needsYou, icon: "pause.circle",
                                 title: TodayModel.plural(s.jobsWaitingOnYou, "agent job", "agent jobs") + " waiting on you",
                                 detail: "", action: .open(tabKey: "agents")))
        }
        for m in s.mail {
            out.append(PanelItem(id: "mail.\(m.id)", cls: .needsYou, icon: "envelope.fill",
                                 title: "\(m.from): \(m.subject)", detail: "Needs you",
                                 action: .open(tabKey: "mailbox")))
        }

        // running
        if s.jobsRunning > 0 {
            out.append(PanelItem(id: "jobs.running", cls: .running, icon: "cpu",
                                 title: TodayModel.plural(s.jobsRunning, "agent job", "agent jobs") + " running",
                                 detail: "", action: .open(tabKey: "agents")))
        }
        if let w = s.workflowRunning {
            out.append(PanelItem(id: "workflow.running", cls: .running, icon: "play.circle.fill",
                                 title: "Running \(w)", detail: "Workflow",
                                 action: .open(tabKey: "workflows")))
        }

        // next
        if let n = s.next {
            out.append(PanelItem(id: "next", cls: .next, icon: n.kind == .event ? "calendar" : "checkmark.circle",
                                 title: n.title, detail: n.when, action: .open(tabKey: n.tab)))
        }

        // suggested
        for g in s.setupGaps where s.hasBrand || !brandScoped.contains(g.featureId) {
            out.append(PanelItem(id: "setup.\(g.featureId)", cls: .suggested, icon: "circle.dotted",
                                 title: "\(g.label) needs \(g.missing)", detail: "Set up",
                                 action: .setup(featureId: g.featureId)))
        }
        if s.proposals > 0 {
            out.append(PanelItem(id: "proposals", cls: .suggested, icon: "hammer.fill",
                                 title: TodayModel.plural(s.proposals, "improvement", "improvements") + " to review",
                                 detail: "Foundry", action: .open(tabKey: "selfUpgrade")))
        }

        // Stable sort: class first, insertion order inside a class.
        let ordered = out.enumerated().sorted {
            $0.element.cls != $1.element.cls ? $0.element.cls < $1.element.cls : $0.offset < $1.offset
        }.map(\.element)
        return Array(ordered.prefix(max(0, cap)))
    }
}
```

`TodayModel.Next.kind` is `enum Kind { case event, task }` (see `TodayModel.swift:30-40`); `TodayModel.MailSummary` has `id`, `from`, `subject`. Both are already `Equatable`.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter RelevanceTests 2>&1 | tail -5`
Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/Shell/Relevance.swift Tests/GruxTests/RelevanceTests.swift
git commit -F - <<'MSG'
Relevance.now: what the panel shows, as one pure function

Four classes (needs you, running, next, suggested), source order inside a
class, a cap that is a parameter, approvals as one row, brand-scoped rows
only with a brand. Fifteen tests, one per rule.
MSG
```

---

### Task 3: `RelevanceState.live()` and the opens log

**Files:**
- Create: `Sources/Grux/Shell/RelevanceState+Live.swift`, `Sources/Grux/Shell/OpensLog.swift`
- Test: `Tests/GruxTests/OpensLogTests.swift`, `Tests/GruxTests/RelevanceLiveTests.swift`

**Interfaces:**
- Consumes: `RelevanceState`, `WorkOrderReview`, `SetupGap` (Task 2).
- Produces: `RelevanceState.live() -> RelevanceState` (`@MainActor`), `OpensLog.record(key: String, via: OpensLog.Via)`, `OpensLog.Via` with cases `now, recent, palette, trigger, cli, input, hub`, `OpensLog.fileURL`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GruxTests/OpensLogTests.swift`:

```swift
import XCTest
@testable import Grux

/// The one usage counter the reskin adds. Local, append-only, one JSON object
/// per line, so a later version can rank Recent on real use. Nothing reads it
/// in 3.0.
final class OpensLogTests: XCTestCase {
    private func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opens-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("opens.jsonl")
    }

    func test_eachOpenIsOneJSONLine() throws {
        let file = temp()
        let log = OpensLog(fileURL: file)
        log.record(key: "mailbox", via: .now)
        log.record(key: "chat", via: .input)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["key"] as? String, "mailbox")
        XCTAssertEqual(first["via"] as? String, "now")
        XCTAssertNotNil(first["ts"] as? String)
    }

    func test_theSharedLogLivesInSupportUnderTest() {
        XCTAssertTrue(OpensLog.shared.fileURL.path.hasPrefix(Persistence.supportDir.path),
                      "the suite must never write the operator's opens.jsonl")
    }

    func test_anUnwritableFileIsIgnored() {
        let log = OpensLog(fileURL: URL(fileURLWithPath: "/dev/null/impossible/opens.jsonl"))
        log.record(key: "chat", via: .cli)   // must not throw or crash
    }
}
```

Create `Tests/GruxTests/RelevanceLiveTests.swift`:

```swift
import XCTest
@testable import Grux

/// `RelevanceState.live()` reads the stores. Under the suite's clean state it
/// must produce an empty struct apart from setup gaps, and never touch the
/// operator's data.
@MainActor
final class RelevanceLiveTests: XCTestCase {
    func test_aCleanInstallHasNoNeedsYouAndNoRunning() {
        let s = RelevanceState.live()
        XCTAssertEqual(s.approvalsPending, 0)
        XCTAssertEqual(s.reviewsWaiting, [])
        XCTAssertEqual(s.mail, [])
        XCTAssertEqual(s.jobsRunning, 0)
        XCTAssertNil(s.workflowRunning)
    }

    func test_setupGapsNameOnlyPickedFeatures() {
        // The suite's onboarding picked nothing, so no gap may be suggested.
        XCTAssertEqual(RelevanceState.live().setupGaps, [])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'OpensLogTests|RelevanceLiveTests' 2>&1 | tail -5`
Expected: compile errors, `cannot find 'OpensLog'`, `type 'RelevanceState' has no member 'live'`.

- [ ] **Step 3: Write `OpensLog.swift`**

```swift
import Foundation

/// The reskin's only usage counter: which surface opened, and through which
/// door. One JSON object per line in `opens.jsonl` under the support folder.
/// Local, never sent anywhere, and nothing in 3.0 reads it; it exists so the
/// next version can rank Recent on real use instead of on recency alone.
final class OpensLog {
    enum Via: String { case now, recent, palette, trigger, cli, input, hub }

    static let shared = OpensLog(fileURL: Persistence.supportDir.appendingPathComponent("opens.jsonl"))

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.gruxai.grux.opens-log")
    private var warnedOnce = false

    init(fileURL: URL) { self.fileURL = fileURL }

    func record(key: String, via: Via) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "{\"ts\":\"\(ts)\",\"key\":\"\(key)\",\"via\":\"\(via.rawValue)\"}\n"
        queue.async { [self] in
            do {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL)
                }
                let h = try FileHandle(forWritingTo: fileURL)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: Data(line.utf8))
            } catch {
                if !warnedOnce {
                    warnedOnce = true
                    NSLog("OpensLog: cannot write \(fileURL.path): \(error)")
                }
            }
        }
    }
}
```

Keys are tab keys (`[a-zA-Z]+`) and `via` is an enum, so the hand-built JSON cannot contain a quote.

- [ ] **Step 4: Write `RelevanceState+Live.swift`**

```swift
import Foundation

extension RelevanceState {
    /// This Mac, right now, from the stores Home already reads. The mapping
    /// mirrors `HomeBriefingModel.buildToday` so Now and the Today pane never
    /// disagree about what is next or what needs you.
    @MainActor
    static func live(now: Date = Date()) -> RelevanceState {
        var s = RelevanceState()
        let app = AppState.shared

        s.approvalsPending = ApprovalQueue.shared.pendingCount
        s.reviewsWaiting = WorkOrderStore.shared.orders
            .filter { $0.progress.stage.isReview }
            .map { WorkOrderReview(id: $0.id, request: $0.request) }

        let mail = TodayModel.mailThatNeedsYou(MailStore.shared.messages)
        s.mail = mail.items
        s.mailTotal = mail.total

        let jobs = AgentService.shared.jobs.filter { !$0.isTerminal }
        let paused = jobs.filter { $0.status == .waiting || $0.status == .paused }.count
        s.jobsRunning = jobs.count - paused
        s.jobsWaitingOnYou = paused

        s.workflowRunning = CommandV2Engine.shared.activeRuns.first
            .flatMap { run in CommandV2Engine.shared.definitions.first { $0.id == run.definitionId }?.displayName }

        let focused = app.currentTask
        let open = app.activeTasks.filter { $0.parentId == nil && $0.priority != .later }
        let ordered = (focused.map { [$0] } ?? [])
            + open.filter { $0.id != focused?.id && $0.priority == .now }
            + open.filter { $0.id != focused?.id && $0.priority == .next }
        let lines = ordered.map { TodayModel.TaskLine(id: $0.id, title: $0.title, dueAt: nil) }
        s.next = TodayModel.next(tasks: lines, events: CalendarService.shared.todaysAgenda(), now: now)

        s.setupGaps = FeatureRegistry.featuresNeedingSetup
            .filter { OnboardingModel.shared.pickedFeatureIds.contains($0.id) }
            .compactMap { row in
                guard let first = FeatureRegistry.missing(for: row).first else { return nil }
                return SetupGap(featureId: row.id, label: row.label, missing: first.humanNoun)
            }

        s.proposals = ProposalStore.shared.ranked().count
        s.hasBrand = !BrandRoster.brands.isEmpty
        return s
    }
}
```

Three names above must be checked against the tree before this compiles, and adapted in place if they differ; each is a one-line lookup:

- `CommandV2Engine.shared.activeRuns` and `run.definitionId`: grep `CommandV2Engine.swift` for the published array of in-flight runs (`grep -n "@Published" Sources/Grux/CommandsV2/CommandV2Engine.swift`). If the array is named differently, use that name; the shape needed is "runs not finished, each knowing its definition id".
- `CalendarService.shared.todaysAgenda()`: `HomeBriefingModel.swift:452-460` shows how Home gets `agenda: [CalendarService.EventSummary]`. Copy that exact call.
- `OnboardingModel.shared.pickedFeatureIds` and `FeatureRegistry.missing(for:)` with `.humanNoun`: `grep -n "picked\|selectedFeatures" Sources/Grux/Onboarding/OnboardingModel.swift` and `grep -n "static func missing\|func remediation\|var noun" Sources/Grux/Onboarding/FeatureRegistry.swift Sources/Grux/Onboarding/CapabilityContract.swift`. Use the existing set of picked ids and the existing "what is missing, in words" accessor; if the words come as a sentence, lowercase its first letter with `lowercasedFirst` (already in `TodayModel.swift:223`).

- [ ] **Step 5: Run the tests**

Run: `swift test --filter 'OpensLogTests|RelevanceLiveTests' 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Grux/Shell/RelevanceState+Live.swift Sources/Grux/Shell/OpensLog.swift Tests/GruxTests/OpensLogTests.swift Tests/GruxTests/RelevanceLiveTests.swift
git commit -F - <<'MSG'
RelevanceState.live and the opens log

The panel's inputs, read from the same stores Home reads, and a local
append-only log of which surface opened through which door.
MSG
```

---

### Task 4: `SurfacePane`, the switch moved out of `LaunchRootView`

**Files:**
- Create: `Sources/Grux/Shell/SurfacePane.swift`
- Modify: `Sources/Grux/LaunchRootView.swift:137-248` (the `Group { switch selection ... }` block and the `.task(id:)`, `.id(theme.revision)` and `ActivityStripView` under it)
- Modify: `Tests/GruxTests/RenderedTabHookTests.swift:9-17`
- Test: `Tests/GruxTests/SurfacePaneTests.swift`

**Interfaces:**
- Produces: `struct SurfacePane: View { init(selection: Binding<LaunchRootView.Tab>) }`. It renders exactly what the switch rendered, writes `RenderedTab.note(LaunchRootView.tabKey(for: selection))` after the pane updates, rebuilds on `ThemeConfig.shared.revision`, and appends `ActivityStripView` which sets `selection` to `.selfUpgrade` or `.agents`.
- `LaunchRootView.hostedBy`, `host(of:)`, `tab(forKey:)`, `tabKey(for:)`, `tasksSurfaces`, `meetingsSurfaces`, `schedulesSurfaces`, `studioSurfaces` stay on `LaunchRootView` unchanged (tests reference them by that name).

- [ ] **Step 1: Write the failing tests**

Create `Tests/GruxTests/SurfacePaneTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Grux

/// The 37-case switch lives in one place and both shells host it.
@MainActor
final class SurfacePaneTests: XCTestCase {
    private func sources(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_theSwitchLeftLaunchRootView() throws {
        let root = try sources("Sources/Grux/LaunchRootView.swift")
        XCTAssertFalse(root.contains("case .reactor: ReactorView()"), "the surface switch is still in LaunchRootView")
        XCTAssertTrue(root.contains("SurfacePane(selection: $selection)"), "the legacy shell does not host SurfacePane")
    }

    func test_everyTabCaseIsRenderedBySurfacePane() throws {
        let pane = try sources("Sources/Grux/Shell/SurfacePane.swift")
        for item in SidebarIA.allItems {
            let tab = try XCTUnwrap(LaunchRootView.tab(forKey: item.key))
            let name = LaunchRootView.tabKey(for: tab)
            XCTAssertTrue(pane.contains(".\(name)"), "SurfacePane never mentions .\(name)")
        }
        XCTAssertTrue(pane.contains("case .labs"))
        XCTAssertTrue(pane.contains("case .tuning"))
    }

    func test_itRendersWithoutAWindow() {
        var sel = LaunchRootView.Tab.settings
        let binding = Binding(get: { sel }, set: { sel = $0 })
        let host = NSHostingView(rootView: SurfacePane(selection: binding).environmentObject(AppState.shared)
            .frame(width: 680, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width > 0, true)
    }
}
```

Update `Tests/GruxTests/RenderedTabHookTests.swift:9-17` so the source it reads is `Sources/Grux/Shell/SurfacePane.swift` and the expected snippet is:

```swift
        XCTAssertTrue(src.contains(".task(id: selection) {\n            await Task.yield()\n            RenderedTab.note(LaunchRootView.tabKey(for: selection))"),
                      "the rendered-tab hook moved or stopped keying on the selection")
```

(12-space indent, because the hook now sits one level shallower.) The `AppTriggers` assertion stays as is.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'SurfacePaneTests|RenderedTabHookTests' 2>&1 | tail -8`
Expected: `cannot find 'SurfacePane' in scope`, and `RenderedTabHookTests` fails to open the new path.

- [ ] **Step 3: Create `SurfacePane.swift`**

Move the whole `Group { switch selection { ... } }` block, its four modifiers (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`, `.task(id: selection)`, `.id(theme.revision)`) and the `ActivityStripView` call from `LaunchRootView.swift:138-248` into this file, verbatim apart from the three substitutions noted below:

```swift
import SwiftUI

/// The surface a tab key names, rendered. One switch, hosted by both shells:
/// the Command Panel opens it as the pane beside the panel, and the legacy
/// sidebar shell fills its detail column with it. Every `case` here is a
/// locked `--open-tab` key, and `RenderedTab.note` reports which one drew.
struct SurfacePane: View {
    @Binding var selection: LaunchRootView.Tab
    @ObservedObject private var theme = ThemeConfig.shared

    init(selection: Binding<LaunchRootView.Tab>) {
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selection {
                // ... the 37 cases exactly as they were in LaunchRootView,
                // with these three substitutions:
                //   Self.tasksSurfaces      -> LaunchRootView.tasksSurfaces
                //   (same for meetingsSurfaces, schedulesSurfaces, studioSurfaces)
                //   Self.tab(forKey: key)   -> LaunchRootView.tab(forKey: key)
                //   Self.tabKey(for:)       -> LaunchRootView.tabKey(for:)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: selection) {
                await Task.yield()
                RenderedTab.note(LaunchRootView.tabKey(for: selection))
            }
            .id(theme.revision)

            ActivityStripView { kind in
                selection = (kind == .foundry) ? .selfUpgrade : .agents
            }
        }
    }
}
```

Keep every comment that was on the cases (they explain gating decisions). The `.labs` case calls `AppDelegate.shared?.openPhonePairingWindow()` exactly as before.

- [ ] **Step 4: Replace the block in `LaunchRootView`**

`LaunchRootView.swift:137-248` becomes:

```swift
            SurfacePane(selection: $selection)
```

Remove the now-unused `@ObservedObject private var theme = ThemeConfig.shared` only if nothing else in `LaunchRootView` reads `theme` (grep first; the sidebar hero may). Leave `RenderedTab` enum at the bottom of `LaunchRootView.swift` where it is.

- [ ] **Step 5: Build, run the two test files, then the full suite**

Run: `swift build 2>&1 | grep -E "error|warning: unused" | head; swift test --filter 'SurfacePaneTests|RenderedTabHookTests' 2>&1 | tail -5`
Expected: build clean, `Executed 5 tests, with 0 failures`.

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: at least 3147 executed, 0 failures (plus the tests from Tasks 1 to 3).

- [ ] **Step 6: Commit**

```bash
git add Sources/Grux/Shell/SurfacePane.swift Sources/Grux/LaunchRootView.swift Tests/GruxTests/SurfacePaneTests.swift Tests/GruxTests/RenderedTabHookTests.swift
git commit -F - <<'MSG'
SurfacePane: the 37-case switch moves out of LaunchRootView

Both shells host it. The rendered-tab hook, the theme rebuild key and the
activity strip travel with it, so the legacy shell renders exactly what it
did and the Command Panel can open any surface as a pane.
MSG
```

---

### Task 5: `CommandPanelRoot` and the panel views

**Files:**
- Create: `Sources/Grux/Shell/CommandPanelRoot.swift`, `Sources/Grux/Shell/CommandPanel/PanelCopy.swift`, `PanelHead.swift`, `PanelInput.swift`, `PanelNowList.swift`, `PanelFoot.swift`
- Modify: `Sources/Grux/GruxApp.swift:1409-1480` (`openLaunchWindow`), `:1119-1123` (cold boot)
- Test: `Tests/GruxTests/CommandPanelRootTests.swift`

**Interfaces:**
- Consumes: `SurfacePane` (Task 4), `Relevance`, `RelevanceState.live()`, `OpensLog` (Tasks 2, 3), `GruxLayout.panel*` (Task 1).
- Produces: `struct CommandPanelRoot: View { init(defaultTab: String = PanelKeys.none) }`, `enum PanelKeys { static let none = "panel" }`, `PanelModel` (`@MainActor final class ... ObservableObject`) with `@Published var pane: LaunchRootView.Tab?`, `@Published var now: [PanelItem]`, `func open(_ tab: LaunchRootView.Tab, via: OpensLog.Via)`, `func openKey(_ key: String, via: OpensLog.Via)`, `func closePane()`, `func perform(_ action: PanelAction)`, `func refreshNow()`. `AppDelegate.setLaunchWindowContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool)`.
- The Optimize hub slot in the panel is a placeholder `OptimizeGruxButton()` until Task 8 replaces it with `OptimizeHubCard()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GruxTests/CommandPanelRootTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Grux

@MainActor
final class CommandPanelRootTests: XCTestCase {

    func test_theLandingIsThePanelWithNoPane() {
        let m = PanelModel()
        m.applyRequested(PanelKeys.none)
        XCTAssertNil(m.pane)
    }

    func test_aLockedKeyOpensItsPane() {
        let m = PanelModel()
        m.applyRequested("mailbox")
        XCTAssertEqual(m.pane, .mailbox)
        m.applyRequested("foundry")
        XCTAssertEqual(m.pane, .selfUpgrade, "the foundry alias still resolves")
    }

    func test_anUnknownKeyOpensNothing() {
        let m = PanelModel()
        m.applyRequested("mailbox")
        m.applyRequested("no-such-surface")
        XCTAssertEqual(m.pane, .mailbox, "an unknown key must not close or change the pane")
    }

    func test_closingAPaneResetsTheRequestSoTheSameTabCanReopen() {
        let m = PanelModel()
        AppState.shared.requestedTab = "chat"
        m.applyRequested("chat")
        XCTAssertEqual(m.pane, .chat)
        m.closePane()
        XCTAssertNil(m.pane)
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none,
                       "requestedTab is a String and onChange fires only on change; a close must reset it")
    }

    func test_aTabRequestedDuringOnboardingOpensAfterIt() {
        let m = PanelModel()
        m.onboardingPresenting = true
        m.applyRequested("calendar")
        XCTAssertNil(m.pane, "nothing opens over onboarding")
        m.onboardingPresenting = false
        XCTAssertEqual(m.pane, .calendar, "the request is honored once onboarding is done")
    }

    func test_openingRecordsARecentAndAnOpen() {
        let m = PanelModel()
        m.open(.notes, via: .palette)
        XCTAssertEqual(SidebarStateStore.shared.recents.first, "notes")
    }

    func test_actionsRoute() {
        let m = PanelModel()
        m.perform(.open(tabKey: "calendar"))
        XCTAssertEqual(m.pane, .calendar)
        m.perform(.openApprovals)
        XCTAssertTrue(ApprovalsTrayState.shared.isOpen)
        m.perform(.openWorkOrder(id: "wo-x"))
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
        XCTAssertEqual(OptimizeHubState.shared.highlightedOrder, "wo-x")
        m.perform(.setup(featureId: "mailbox"))
        XCTAssertEqual(m.pane, .mailbox, "a setup gap opens the surface, whose gate shows the card")
    }

    func test_theRootRendersAt420x560WithNoPane() {
        OnboardingModel.shared.finish(skippedFirstLook: true)
        let host = NSHostingView(rootView: CommandPanelRoot().environmentObject(AppState.shared)
            .frame(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, GruxLayout.panelWidth)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CommandPanelRootTests 2>&1 | tail -5`
Expected: `cannot find 'PanelModel' in scope`, `cannot find 'PanelKeys'`, `cannot find 'OptimizeHubState'`.

- [ ] **Step 3: `PanelCopy.swift`**

```swift
import Foundation

/// Every string the Command Panel shows, in one place, so first-run copy,
/// the palette and the panel cannot drift.
enum PanelCopy {
    static let placeholder = "Say it or type it"
    static let placeholderMuted = "Type it, or unmute to say it"
    static let nothingNeedsYou = "Nothing needs you."
    static let paletteHint = "\(PaletteHotkeyConfig.spokenShortcut) reaches everything."
    static let firstRunUnderInput = "Start here, or say what you want."
    static let nowHeading = "Now"
    static let recentHeading = "Recent"
    static let closePane = "Back"
    static let settings = "Settings"
}
```

- [ ] **Step 4: `PanelModel` and `CommandPanelRoot.swift`**

```swift
import SwiftUI
import AppKit

/// The tab key that means "no pane, just the panel".
enum PanelKeys {
    static let none = "panel"
}

/// Selection and Now for the Command Panel. A class rather than view state so
/// the tests can drive it without a window, and so a request that arrives
/// during onboarding can be held and honored afterwards.
@MainActor
final class PanelModel: ObservableObject {
    @Published var pane: LaunchRootView.Tab? = nil
    @Published var now: [PanelItem] = []
    /// Set by the root from `OnboardingModel.isPresenting`. While true, a
    /// requested tab is held, not opened.
    var onboardingPresenting = false {
        didSet { if !onboardingPresenting, let held { self.held = nil; applyRequested(held) } }
    }
    private var held: String? = nil
    private var lastRefresh = Date.distantPast

    func applyRequested(_ key: String) {
        if onboardingPresenting { held = key; return }
        if key == PanelKeys.none { pane = nil; return }
        guard let tab = LaunchRootView.tab(forKey: key) else { return }
        open(tab, via: .trigger)
    }

    func open(_ tab: LaunchRootView.Tab, via: OpensLog.Via) {
        pane = tab
        let key = LaunchRootView.tabKey(for: tab)
        SidebarStateStore.shared.recordRecent(key)
        OpensLog.shared.record(key: key, via: via)
    }

    func openKey(_ key: String, via: OpensLog.Via) {
        guard let tab = LaunchRootView.tab(forKey: key) else { return }
        open(tab, via: via)
    }

    func closePane() {
        pane = nil
        AppState.shared.requestedTab = PanelKeys.none
    }

    func perform(_ action: PanelAction) {
        switch action {
        case .open(let key): openKey(key, via: .now)
        case .openApprovals: ApprovalsTrayState.shared.isOpen = true
        case .openWorkOrder(let id):
            OptimizeHubState.shared.highlightedOrder = id
            OptimizeHubState.shared.isExpanded = true
        case .setup(let featureId):
            if let key = FeatureRegistry.tabKey(forRowId: featureId) { openKey(key, via: .now) }
        case .openOptimize: OptimizeHubState.shared.isExpanded = true
        }
    }

    /// At most once a second; the stores publish far more often than that.
    func refreshNow(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) >= 1 else { return }
        lastRefresh = Date()
        now = Relevance.now(RelevanceState.live())
    }
}

/// The Command Panel shell: one column at rest, one pane beside it on demand.
struct CommandPanelRoot: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = PanelModel()
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var theme = ThemeConfig.shared
    @ObservedObject private var approvals = ApprovalQueue.shared
    @ObservedObject private var mail = MailStore.shared
    @ObservedObject private var agents = AgentService.shared
    @ObservedObject private var orders = WorkOrderStore.shared
    var defaultTab: String = PanelKeys.none
    @State private var didApplyLaunchTab = false

    var body: some View {
        content.destructiveConfirmHost()
    }

    @ViewBuilder
    private var content: some View {
        if onboarding.isPresenting {
            OnboardingView().environmentObject(state)
                .onAppear { model.onboardingPresenting = true }
                .onDisappear { model.onboardingPresenting = false }
        } else {
            shell
        }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            panel
                .frame(width: GruxLayout.panelWidth)
                .layoutPriority(1)
            if let tab = model.pane {
                Divider()
                paneColumn(tab)
                    .frame(minWidth: GruxLayout.detailContentMin, idealWidth: GruxLayout.paneWidth, maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: GruxLayout.panelMinWidth, minHeight: GruxLayout.panelMinHeight)
        .tint(GruxTheme.accentPrimary)
        .background(GruxTheme.base)
        .task(id: model.pane) {
            // The panel reports itself when no pane is open, so sweeps that
            // read rendered-tab.txt can tell "closed" from "never opened".
            if model.pane == nil { await Task.yield(); RenderedTab.note(PanelKeys.none) }
            AppDelegate.shared?.setLaunchWindowContentWidth(
                model.pane == nil ? GruxLayout.panelWidth : GruxLayout.panelWidth + GruxLayout.paneWidth,
                minWidth: model.pane == nil ? GruxLayout.panelMinWidth : GruxLayout.panelWidth + GruxLayout.detailContentMin,
                animated: true)
        }
        .onAppear {
            guard !didApplyLaunchTab else { return }
            didApplyLaunchTab = true
            model.applyRequested(defaultTab)
            model.refreshNow(force: true)
        }
        .onChange(of: state.requestedTab) { _, new in model.applyRequested(new) }
        .onChange(of: approvals.pendingCount) { _, _ in model.refreshNow() }
        .onChange(of: mail.messages.count) { _, _ in model.refreshNow() }
        .onChange(of: agents.jobs.count) { _, _ in model.refreshNow() }
        .onChange(of: orders.orders) { _, _ in model.refreshNow() }
        .onReceive(NotificationCenter.default.publisher(for: .gruxOpenAgentJobWindow)) { note in
            if let jobId = note.userInfo?["jobId"] as? String {
                AppDelegate.shared?.openAgentJobWindow(jobId)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: GruxSpacing.l) {
            PanelHead(onOptimize: { OptimizeHubState.shared.isExpanded = true })
            PanelInput(onSend: { text in
                model.open(.chat, via: .input)
                Task { await ChatService.shared.send(userText: text) }
            })
            PanelNowList(items: model.now, onAction: { model.perform($0) })
            OptimizeGruxButton()   // replaced by OptimizeHubCard() in Task 8
            Spacer(minLength: 0)
            PanelFoot(onOpen: { key in model.openKey(key, via: .recent) },
                      onSettings: { model.open(.settings, via: .recent) })
        }
        .padding(GruxSpacing.l)
        .id(theme.revision)
    }

    private func paneColumn(_ tab: LaunchRootView.Tab) -> some View {
        let binding = Binding<LaunchRootView.Tab>(
            get: { model.pane ?? tab },
            set: { model.pane = $0 })
        return VStack(spacing: 0) {
            HStack(spacing: GruxSpacing.s) {
                Button {
                    model.closePane()
                } label: {
                    Label(PanelCopy.closePane, systemImage: "chevron.left")
                        .font(GruxType.caption)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Text(SidebarIA.railLabel(forKey: LaunchRootView.tabKey(for: LaunchRootView.host(of: tab))))
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, GruxSpacing.l)
            .frame(height: GruxLayout.paneBarHeight)
            Divider()
            SurfacePane(selection: binding)
                .environment(\.hostedInPane, true)
        }
    }
}
```

Two helpers this needs, added in this task:

In `SidebarModel.swift`, inside `extension SidebarIA` after `brandScopedOrder`:

```swift
    /// The label the rail shows for a key ("Mail", "Studio"), falling back to
    /// the legacy table's label. Both shells and the palette read this one.
    static func railLabel(forKey key: String) -> String {
        if let r = railOrder.first(where: { $0.key == key }) { return r.label }
        if let b = brandScopedOrder.first(where: { $0.key == key }) { return b.label }
        if key == "settings" { return "Settings" }
        return item(forKey: key)?.label ?? key
    }
```

In a new file `Sources/Grux/Shell/HostedInPane.swift`:

```swift
import SwiftUI

/// True when a surface is drawn inside the Command Panel's pane. Chat reads
/// it to fold its threads sidebar (Task 7).
private struct HostedInPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hostedInPane: Bool {
        get { self[HostedInPaneKey.self] }
        set { self[HostedInPaneKey.self] = newValue }
    }
}
```

`AppDelegate.openAgentJobWindow(_:)`: `LaunchRootView` used `@Environment(\.openWindow)` with id `"agent-job"`. If no such method exists on `AppDelegate`, use `@Environment(\.openWindow) private var openWindow` in `CommandPanelRoot` and call `openWindow(id: "agent-job", value: jobId)` exactly as `LaunchRootView.swift:288-292` does.

`OptimizeHubState` is created in Task 8; for this task to compile, create the minimal version now in `Sources/Grux/Optimize/OptimizeHubCard.swift`:

```swift
import SwiftUI

/// Whether the Optimize hub card is expanded, and which order it should show
/// first. Shared so a Now row, the palette and a trigger can all open it.
@MainActor
final class OptimizeHubState: ObservableObject {
    static let shared = OptimizeHubState()
    @Published var isExpanded = false
    @Published var highlightedOrder: String? = nil
}
```

- [ ] **Step 5: `PanelHead.swift`**

```swift
import SwiftUI

/// Orb, wordmark, and the two badges that draw nothing when idle.
struct PanelHead: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var micHealth = MicHealth.shared
    @ObservedObject private var shellBus = ShellStateBus.shared
    var onOptimize: () -> Void

    private var listeningTell: ListeningTell {
        ListeningTell.resolve(mode: state.config.listeningModeInEffect,
                              micMuted: state.micMuted,
                              isSpeaking: speech.isSpeaking || speech.isBuffering,
                              isThinking: state.isThinking,
                              notHearing: micHealth.notHearing)
    }

    private var orbState: GruxOrbState {
        if shellBus.current.mode == .alert { return ShellMode.alert.orbState }
        if listeningTell == .off { return shellBus.current.mode.orbState }
        return listeningTell.orbState
    }

    var body: some View {
        HStack(spacing: GruxSpacing.m) {
            GruxOrb(state: orbState, size: 44)
                .onTapGesture { MicController.toggle(source: "orb") }
                .contextMenu {
                    Button(TuningCopy.title) { AppState.shared.requestedTab = "tuning" }
                    Button(OptimizeCopy.title) { onOptimize() }
                }
                .accessibilityLabel("Grux orb, \(listeningTell.label)")
            Text("GRUX OS")
                .font(GruxType.microCaps)
                .kerning(2)
                .foregroundStyle(GruxTheme.textSecondary)
            Spacer()
            FoundryStatusBadge { AppState.shared.requestedTab = "selfUpgrade" }
            ActivitySwarmBadge { AppState.shared.requestedTab = "agents" }
        }
    }
}
```

`GruxOrb(state:size:)`: the sidebar hero at `LaunchRootView.swift:452-465` draws the orb; copy the exact view name and initializer it uses (grep `orbState` there). If it takes a fixed 68pt, pass 44 through whatever size parameter it exposes, or wrap in `.frame(width: 44, height: 44)` with `.scaleEffect(44/68)`.

- [ ] **Step 6: `PanelInput.swift`**

```swift
import SwiftUI

/// The one input. Enter sends through ChatService (workflow triggers, the PIM
/// intents and chat all fast-path there already). The mic is the ambient
/// listening toggle, the same control the old foot had, wearing the shared tell.
struct PanelInput: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var micHealth = MicHealth.shared
    @FocusState private var focused: Bool
    @State private var draft = ""
    var onSend: (String) -> Void

    private var tell: ListeningTell {
        ListeningTell.resolve(mode: state.config.listeningModeInEffect, micMuted: state.micMuted,
                              isSpeaking: false, isThinking: false, notHearing: micHealth.notHearing)
    }

    var body: some View {
        HStack(spacing: GruxSpacing.s) {
            TextField(tell == .muted || tell == .off ? PanelCopy.placeholderMuted : PanelCopy.placeholder,
                      text: $draft)
                .textFieldStyle(.plain)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textPrimary)
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel("Say it or type it")
            Button {
                MicController.toggle(source: "panel")
            } label: {
                Image(systemName: tell == .muted || tell == .off ? "mic.slash.fill" : "mic.fill")
                    .font(GruxType.caption)
                    .foregroundStyle(tell == .muted || tell == .off ? GruxTheme.textTertiary : GruxTheme.accentPrimary)
            }
            .buttonStyle(.plain)
            .help(tell.label)
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.vertical, GruxSpacing.s)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).fill(GruxTheme.textTertiary.opacity(0.12)))
        .onAppear { focused = true }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        onSend(t)
    }
}
```

- [ ] **Step 7: `PanelNowList.swift`**

```swift
import SwiftUI

/// Renders what `Relevance.now` decided. One line, a glyph, one action.
struct PanelNowList: View {
    let items: [PanelItem]
    var onAction: (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text(PanelCopy.nowHeading.uppercased())
                .font(GruxType.microCaps)
                .kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            if items.isEmpty {
                Text(PanelCopy.nothingNeedsYou)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.vertical, GruxSpacing.s)
            } else {
                ForEach(items) { item in
                    Button { onAction(item.action) } label: {
                        HStack(spacing: GruxSpacing.s) {
                            Image(systemName: item.icon)
                                .font(GruxType.caption)
                                .foregroundStyle(color(for: item.cls))
                                .frame(width: GruxSpacing.l)
                            Text(item.title)
                                .font(GruxType.body)
                                .foregroundStyle(GruxTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: GruxSpacing.s)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, GruxSpacing.s)
                        .padding(.horizontal, GruxSpacing.m)
                        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).fill(GruxTheme.textTertiary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                }
            }
        }
    }

    private func color(for cls: PanelItem.Class) -> Color {
        switch cls {
        case .needsYou: return GruxTheme.warnAmber
        case .running: return GruxTheme.accentPrimary
        case .next: return GruxTheme.textPrimary
        case .suggested: return GruxTheme.textSecondary
        }
    }
}
```

- [ ] **Step 8: `PanelFoot.swift`**

Move the Watching/Paused control and `listeningFoot` from `LaunchRootView.swift:684-721` into this view verbatim (they read `AppState` and `MicController` the same way), and add the Recent strip and Settings:

```swift
import SwiftUI

/// Recent surfaces, the Watching and listening controls, approvals when any
/// wait, and Settings. The old sidebar foot moved down one level.
struct PanelFoot: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var sidebarStore = SidebarStateStore.shared
    var onOpen: (String) -> Void
    var onSettings: () -> Void

    /// Up to five, pinned first, then most recent, never a duplicate.
    static func chips(pinned: [String], recents: [String], cap: Int = 5) -> [String] {
        var out: [String] = []
        for k in pinned + recents where !out.contains(k) && k != "settings" { out.append(k) }
        return Array(out.prefix(cap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            let chips = Self.chips(pinned: sidebarStore.pinned, recents: sidebarStore.recents)
            if !chips.isEmpty {
                Text(PanelCopy.recentHeading.uppercased())
                    .font(GruxType.microCaps).kerning(1.2)
                    .foregroundStyle(GruxTheme.textTertiary)
                HStack(spacing: GruxSpacing.xs) {
                    ForEach(chips, id: \.self) { key in
                        Button { onOpen(key) } label: {
                            Label(SidebarIA.railLabel(forKey: key), systemImage: SidebarIA.item(forKey: key)?.icon ?? "square")
                                .font(GruxType.caption)
                                .padding(.horizontal, GruxSpacing.s).padding(.vertical, GruxSpacing.xs)
                                .background(Capsule().fill(GruxTheme.textTertiary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if sidebarStore.isPinned(key) {
                                Button("Unpin") { sidebarStore.unpin(key) }
                            } else {
                                Button("Pin") { sidebarStore.pin(key) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: GruxSpacing.s) {
                watchingControl        // moved from LaunchRootView.statusBar
                listeningFoot          // moved from LaunchRootView.listeningFoot
                ApprovalsTrayButton()
                Spacer()
                Button { onSettings() } label: {
                    Image(systemName: "gearshape.fill").font(GruxType.caption)
                }
                .buttonStyle(.plain)
                .help(PanelCopy.settings)
                .accessibilityLabel(PanelCopy.settings)
            }
        }
    }
}
```

When moving `watchingControl` and `listeningFoot`, replace their `.font(.system(size: 9, weight: .bold))` and `.font(.caption2)` with `GruxType.microCaps` and `GruxType.caption`, and `Color.green` with `GruxTheme.successMint`. That is the shell hardcode cleanup the spec names.

- [ ] **Step 9: Window sizing and root choice in `GruxApp.swift`**

In `openLaunchWindow(tab:)` (line 1409), replace the hosting construction and the min-size block with:

```swift
        if NSApp.isHidden { NSApp.unhide(nil) }
        let legacy = AppState.shared.config.legacyShell
        let hosting: NSViewController
        if legacy {
            hosting = NSHostingController(rootView: LaunchRootView(defaultTab: tab).environmentObject(AppState.shared))
        } else {
            let h = NSHostingController(rootView: CommandPanelRoot(defaultTab: tab).environmentObject(AppState.shared))
            // The root resizes the window itself when a pane opens; the
            // hosting controller must not fight it with its own ideal size.
            h.sizingOptions = []
            hosting = h
        }
        let win = NSWindow(contentViewController: hosting)
        win.title = "Grux OS"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        let minContent = legacy
            ? NSSize(width: GruxLayout.windowFloorWidth, height: GruxLayout.windowFloorHeight)
            : NSSize(width: GruxLayout.panelMinWidth, height: GruxLayout.panelMinHeight)
        win.contentMinSize = minContent
        var frame = win.frame
        let chrome = frame.size.width - win.contentLayoutRect.size.width
        win.minSize = NSSize(width: minContent.width + chrome, height: minContent.height + (frame.size.height - win.contentLayoutRect.size.height))
        let argv = CommandLine.arguments
        func argValue(_ flag: String) -> Double? {
            guard let a = argv.first(where: { $0.hasPrefix(flag + "=") }) else { return nil }
            return Double(a.dropFirst(flag.count + 1))
        }
        let defaultW: Double = legacy ? 1040 : GruxLayout.panelWidth
        let defaultH: Double = legacy ? 700 : GruxLayout.panelIdealHeight
        let initW = max(minContent.width, argValue("--win-w") ?? defaultW)
        let initH = max(minContent.height, argValue("--win-h") ?? defaultH)
        win.setContentSize(NSSize(width: initW, height: initH))
```

Keep everything after `win.setContentSize` in that method as it is (the `win.center()`, `launchWindow = win`, the re-apply of size) but wrap the re-apply in `if legacy { ... }` so the panel is not pushed back to 1040.

Add to `AppDelegate`:

```swift
    /// The Command Panel grows the window to hold a pane and shrinks it back.
    /// Anchored at the top-left so the panel does not walk across the screen.
    /// The minimum moves with it, so a user cannot drag the pane off the edge.
    func setLaunchWindowContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool) {
        guard let win = launchWindow else { return }
        let chrome = win.frame.size.width - win.contentLayoutRect.size.width
        win.contentMinSize.width = minWidth
        win.minSize.width = minWidth + chrome
        let current = win.contentLayoutRect.size.width
        guard abs(current - width) > 0.5 else { return }
        var f = win.frame
        let delta = width - current
        f.size.width += delta
        // Keep the window on screen when it grows to the right.
        if let screen = win.screen?.visibleFrame, f.maxX > screen.maxX {
            f.origin.x = max(screen.minX, screen.maxX - f.size.width)
        }
        win.setFrame(f, display: true, animate: animated && !GruxTheme.reduceMotion)
    }
```

Cold boot (`GruxApp.swift:1119-1123`): change `self.openLaunchWindow(tab: "home")` to

```swift
                self.openLaunchWindow(tab: AppState.shared.config.legacyShell ? "home" : PanelKeys.none)
```

`AppState.requestedTab` starts as `"chat"` (`AppState.swift:62`). Leave it; the panel's `onAppear` applies `defaultTab` and later changes fire `onChange`.

- [ ] **Step 10: Build and run the tests**

Run: `swift build 2>&1 | grep -E "error" | head -20`
Fix any name that differs from the tree (the `GruxOrb` view, `openAgentJobWindow`, `MicController.toggle(source:)`) by reading the call site named beside each.

Run: `swift test --filter CommandPanelRootTests 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 11: Launch it and look**

Run: `./build.sh 2>&1 | tail -3` (this quits and relaunches `/Applications/Grux.app`; on the Mini it is forbidden until the loop's S1 is proven, so run this step on the MacBook).
Then: `swift tools/winid.swift Grux | head -3` and `screencapture -o -x -l<id> /tmp/panel-rest.png`, open the PNG and confirm: no sidebar, four regions, 420 wide. Then `print -n "mailbox" > ~/.grux/fire-open-tab`, capture again, confirm the window widened and Mail rendered beside the panel. `cat ~/.grux/rendered-tab.txt` must read `mailbox`; after clicking Back it must read `panel`.

- [ ] **Step 12: Commit**

```bash
git add Sources/Grux/Shell/CommandPanelRoot.swift Sources/Grux/Shell/CommandPanel Sources/Grux/Shell/HostedInPane.swift Sources/Grux/Optimize/OptimizeHubCard.swift Sources/Grux/DesignSystem/SidebarModel.swift Sources/Grux/GruxApp.swift Tests/GruxTests/CommandPanelRootTests.swift
git commit -F - <<'MSG'
CommandPanelRoot: one 420pt panel, one pane on demand

Head, input, Now, the Optimize slot and the foot in one column. A locked
key opens its surface as a pane beside it and the window grows to hold it;
Back shrinks it. A request during onboarding is held, and closing a pane
resets requestedTab so the same key can open again. The legacy shell stays
behind config.legacyShell.
MSG
```

---

### Task 6: Window sizing tests and the first-run capture

**Files:**
- Create: `Tests/GruxTests/LaunchWindowSizingTests.swift`, `Tests/GruxTests/FirstRunPanelCaptureTests.swift`
- Modify: `Tests/GruxTests/FirstRunRailCaptureTests.swift` (gate on `legacyShell`)

**Interfaces:**
- Consumes: `AppDelegate.setLaunchWindowContentWidth` (Task 5), `CommandPanelRoot`.

- [ ] **Step 1: Write the failing tests**

`Tests/GruxTests/LaunchWindowSizingTests.swift`:

```swift
import XCTest
import AppKit
@testable import Grux

/// The pane must never clip off the right edge: opening one raises both the
/// width and the minimum, closing lowers both.
@MainActor
final class LaunchWindowSizingTests: XCTestCase {
    func test_openingAPaneRaisesTheMinimumAndTheWidth() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let sizer = LaunchWindowSizer(window: win)
        sizer.setContentWidth(GruxLayout.panelWidth + GruxLayout.paneWidth,
                              minWidth: GruxLayout.panelWidth + GruxLayout.detailContentMin, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth + GruxLayout.paneWidth, accuracy: 1)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth + GruxLayout.detailContentMin)
        sizer.setContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelMinWidth, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth, accuracy: 1)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelMinWidth)
    }

    func test_aWindowAlreadyAtTheWidthIsLeftAlone() {
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 560),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let before = win.frame
        LaunchWindowSizer(window: win).setContentWidth(420, minWidth: 380, animated: false)
        XCTAssertEqual(win.frame, before)
    }
}
```

This pins the logic in a small `LaunchWindowSizer` struct so the test needs no `AppDelegate`. Refactor Task 5's `setLaunchWindowContentWidth` to delegate:

```swift
struct LaunchWindowSizer {
    let window: NSWindow
    func setContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool) { /* body from Task 5 step 9 */ }
}
// in AppDelegate:
func setLaunchWindowContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool) {
    guard let win = launchWindow else { return }
    LaunchWindowSizer(window: win).setContentWidth(width, minWidth: minWidth, animated: animated)
}
```

`Tests/GruxTests/FirstRunPanelCaptureTests.swift` (modeled on `FirstRunRailCaptureTests`):

```swift
import XCTest
import SwiftUI
@testable import Grux

/// The first-run panel, in pixels, on the suite's clean state. Writes the
/// capture the evidence file cites when GRUX_FIRST_RUN_PANEL_CAPTURE is set.
@MainActor
final class FirstRunPanelCaptureTests: XCTestCase {
    func test_theFirstRunPanelHasNoRecentChipsAndTheHubExpanded() throws {
        let state = AppState.shared
        XCTAssertFalse(state.config.legacyShell)
        XCTAssertTrue(SidebarStateStore.shared.recents.isEmpty, "the suite's state already has recents")
        OnboardingModel.shared.finish(skippedFirstLook: true)
        XCTAssertEqual(OnboardingModel.shared.stage, .done)
        XCTAssertTrue(OptimizeHubState.shared.isExpanded, "first run lands with the hub open")

        let host = NSHostingView(rootView: CommandPanelRoot().environmentObject(state)
            .frame(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["GRUX_FIRST_RUN_PANEL_CAPTURE"] {
            try png.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }
}
```

`OptimizeHubState.isExpanded` on first run is set by `OnboardingModel.finish` in Task 10; until then this assertion is red, which is the point. Leave it red-committed only if Task 10 is next in the same session; otherwise add the one line `OptimizeHubState.shared.isExpanded = true` to `OnboardingModel.finish` now and let Task 10 own the copy.

`FirstRunRailCaptureTests.test_theFirstRunRailIsFourteenRows_inPixels` renders `LaunchRootView` directly. That view still exists (it is the legacy shell) and still shows 14 rows, so the test stays green as written. Rename it `test_theLegacyRailIsFourteenRows_inPixels` so its name says which shell it captures. Never skip it.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'LaunchWindowSizingTests|FirstRunPanelCaptureTests' 2>&1 | tail -5`
Expected: `cannot find 'LaunchWindowSizer'`; the capture test fails on `isExpanded`.

- [ ] **Step 3: Implement the sizer and the first-run flag, run, commit**

Run: `swift test --filter 'LaunchWindowSizingTests|FirstRunPanelCaptureTests|FirstRunRailCaptureTests' 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

```bash
git add Sources/Grux/GruxApp.swift Sources/Grux/Onboarding/OnboardingModel.swift Tests/GruxTests/LaunchWindowSizingTests.swift Tests/GruxTests/FirstRunPanelCaptureTests.swift Tests/GruxTests/FirstRunRailCaptureTests.swift
git commit -F - <<'MSG'
Window sizing is a struct a test can drive, and the panel has its capture

Opening a pane raises the width and the minimum together so nothing can be
dragged off the edge; closing lowers both. The first-run panel is rendered
on the suite's clean state the way the rail was.
MSG
```

---

### Task 7: Chat inside a pane

**Files:**
- Modify: `Sources/Grux/ChatView.swift:85-110` (the `HStack` with `ChatThreadsSidebar`), `:53-56` (init)
- Test: `Tests/GruxTests/ChatPaneFoldTests.swift`

**Interfaces:**
- Consumes: `\.hostedInPane` (Task 5).
- Produces: `ChatView` reads `@Environment(\.hostedInPane)`; when true, the threads sidebar is a popover behind a `threadsButton` in the hero header.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Grux

/// Chat is one column beside the panel: the threads sidebar folds behind a
/// button when hosted in a pane, and stays a column in the legacy shell.
@MainActor
final class ChatPaneFoldTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
    }

    func test_chatReadsHostedInPane() throws {
        XCTAssertTrue(try source().contains("@Environment(\\.hostedInPane)"))
    }

    func test_theThreadsColumnIsConditional() throws {
        let src = try source()
        XCTAssertTrue(src.contains("if !hostedInPane {\n            ChatThreadsSidebar()"),
                      "the threads sidebar must be a column only outside a pane")
        XCTAssertTrue(src.contains("threadsPopover"), "no folded threads control")
    }

    func test_thePaneMinimumIsBelowThePaneWidth() throws {
        // 560 was threads 210 + conversation 350. Folded, the conversation
        // alone must fit the pane budget with room to spare.
        XCTAssertLessThanOrEqual(ChatView.paneMinWidth, GruxLayout.paneWidth - GruxSpacing.xl)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ChatPaneFoldTests 2>&1 | tail -5`
Expected: `type 'ChatView' has no member 'paneMinWidth'`, and the two source assertions fail.

- [ ] **Step 3: Fold the sidebar**

In `ChatView`:

```swift
    @Environment(\.hostedInPane) private var hostedInPane
    @State private var threadsPopover = false
    /// The conversation alone, when the threads column is folded.
    static let paneMinWidth: CGFloat = 350
```

Replace the `HStack` body (lines 86-110) with:

```swift
        HStack(spacing: 0) {
            if !hostedInPane {
            ChatThreadsSidebar()
                .environmentObject(state)
            Rectangle()
                .fill(GruxTheme.iridescentRim.opacity(0.4))
                .frame(width: 1)
            }
            ZStack {
                // ... unchanged ...
            }
        }
        .frame(minWidth: hostedInPane ? Self.paneMinWidth : 560, minHeight: 520)
```

In `heroHeader`, add at the leading edge, only when hosted:

```swift
            if hostedInPane {
                Button { threadsPopover.toggle() } label: {
                    Image(systemName: "sidebar.left").font(GruxType.caption)
                }
                .buttonStyle(.plain)
                .help("Threads")
                .popover(isPresented: $threadsPopover, arrowEdge: .bottom) {
                    ChatThreadsSidebar().environmentObject(state)
                        .frame(width: GruxLayout.listColumnIdeal, height: 420)
                }
            }
```

- [ ] **Step 4: Run the tests, then the full suite (Chat has 20 first-run tests that must stay green)**

Run: `swift test --filter 'ChatPaneFoldTests|FirstRunChatTests' 2>&1 | tail -5`
Expected: 23 executed, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/ChatView.swift Tests/GruxTests/ChatPaneFoldTests.swift
git commit -F - <<'MSG'
Chat folds its threads sidebar when it is a pane

One column beside the panel; the threads list is a popover behind a button
in the header. The legacy shell keeps the column.
MSG
```

---

### Task 8: The Optimize hub card with four doors, and the station count

**Files:**
- Modify: `Sources/Grux/Optimize/OptimizeHubCard.swift` (the minimal state from Task 5 grows into the card), `Sources/Grux/Optimize/OptimizeGruxView.swift:12-19` (copy), `Sources/Grux/Optimize/WorkOrder.swift:17`, `Sources/Grux/Shell/CommandPanelRoot.swift` (swap the slot), `Sources/Grux/Triggers/AppTriggers.swift` (`fire-optimize` also expands the hub)
- Test: `Tests/GruxTests/OptimizeHubTests.swift`, `Tests/GruxTests/OptimizeGruxTests.swift:49` (rename and pin the count)

**Interfaces:**
- Consumes: `OptimizeHubState` (Task 5), `WorkOrderStore`, `OptimizeClipboard`, `WorkOrderContext.live`.
- Produces: `struct OptimizeHubCard: View`, `enum OptimizeDoor: String, CaseIterable { case tune, change, handOver, improve }` with `title`, `body`, `icon`, `HandoffBundle` is Task 9 (the door calls `HandoffBundle.writeLive()`; stub it in this task as a method that returns `.failure(HandoffBundle.Error.notYet)` so the card compiles, Task 9 replaces it).

- [ ] **Step 1: Write the failing tests**

`Tests/GruxTests/OptimizeHubTests.swift`:

```swift
import XCTest
@testable import Grux

/// One umbrella, four doors. The copy is the contract: a stranger reads the
/// four titles and knows which door is theirs.
@MainActor
final class OptimizeHubTests: XCTestCase {
    func test_fourDoorsInThisOrder() {
        XCTAssertEqual(OptimizeDoor.allCases.map(\.title),
                       ["Tune it", "Change it", "Hand it over", "Let it improve itself"])
    }

    func test_everyDoorHasABodyAndAnIcon() {
        for d in OptimizeDoor.allCases {
            XCTAssertFalse(d.body.isEmpty, d.rawValue)
            XCTAssertFalse(d.icon.isEmpty, d.rawValue)
        }
    }

    func test_theCardCollapsesAndAReviewExpandsIt() {
        let s = OptimizeHubState()
        XCTAssertFalse(s.isExpanded)
        s.noteReviewsWaiting(0)
        XCTAssertFalse(s.isExpanded)
        s.noteReviewsWaiting(1)
        XCTAssertTrue(s.isExpanded, "a work order at a review pops the card")
    }

    func test_theHeadCaptionNamesTheHandoff() {
        XCTAssertEqual(OptimizeCopy.hubCaption, "Make it yours, then hand it to your agent.")
    }

    func test_tuneOpensTuning_improveOpensTheFoundry() {
        let s = OptimizeHubState()
        s.enter(.tune)
        XCTAssertEqual(AppState.shared.requestedTab, "tuning")
        s.enter(.improve)
        XCTAssertEqual(AppState.shared.requestedTab, "selfUpgrade")
    }
}
```

In `OptimizeGruxTests.swift:49`, rename `test_theLineHasElevenStationsAndThreeReviews_inTheFactoryOrder` to `test_theLineHasFourteenStationsAndThreeReviews_inTheFactoryOrder` and add these two assertions at its top:

```swift
        XCTAssertEqual(WorkOrderStage.line.count, 14, "the line moved; update WorkOrder.swift's header comment and this name together")
        XCTAssertEqual(WorkOrderStage.line.filter(\.isReview).count, 3)
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'OptimizeHubTests|OptimizeGruxTests' 2>&1 | tail -6`
Expected: `cannot find 'OptimizeDoor'`, `has no member 'hubCaption'`, `noteReviewsWaiting`, `enter`.

- [ ] **Step 3: Fix the station comment**

`WorkOrder.swift:17`: replace `/// Eleven stations in four phases, with a review by the person between` with `/// Fourteen stations in five phases, with a review by the person between` and the next line's list to `/// phases: preflight; requirements and analysis; review the plan; design, architecture and governance; review the design; build and validate; review the result; install, verify and monitor.` Also fix `OptimizeGruxView.swift:173` `/// The ten stations and three reviews` to `/// The eleven stations and three reviews`. (Fourteen entries in `line`: eleven stations plus three reviews.)

- [ ] **Step 4: Grow `OptimizeHubCard.swift`**

```swift
import SwiftUI
import AppKit

@MainActor
final class OptimizeHubState: ObservableObject {
    static let shared = OptimizeHubState()
    @Published var isExpanded = false
    @Published var highlightedOrder: String? = nil
    private var lastReviews = 0

    /// A work order reaching a review pops the card open once per rise.
    func noteReviewsWaiting(_ n: Int) {
        if n > lastReviews { isExpanded = true }
        lastReviews = n
    }

    func enter(_ door: OptimizeDoor) {
        switch door {
        case .tune: AppState.shared.requestedTab = "tuning"
        case .change: isExpanded = true
        case .handOver: isExpanded = true
        case .improve: AppState.shared.requestedTab = "selfUpgrade"
        }
    }
}

enum OptimizeDoor: String, CaseIterable, Identifiable {
    case tune, change, handOver, improve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tune: return "Tune it"
        case .change: return "Change it"
        case .handOver: return "Hand it over"
        case .improve: return "Let it improve itself"
        }
    }
    var body: String {
        switch self {
        case .tune: return "How sure Grux must be, how often it interrupts, what it spends and remembers."
        case .change: return "Say what you want different. Grux writes a work order your coding agent builds."
        case .handOver: return "Export your settings, theme and macros as a bundle your agent can read and apply."
        case .improve: return "Grux proposes its own upgrades. You choose how far that goes."
        }
    }
    var icon: String {
        switch self {
        case .tune: return "slider.horizontal.3"
        case .change: return "wand.and.stars"
        case .handOver: return "shippingbox.fill"
        case .improve: return "hammer.fill"
        }
    }
}

extension OptimizeCopy {
    static let hubCaption = "Make it yours, then hand it to your agent."
    static let handoffWritten = "Bundle written. The setup prompt is on your clipboard."
}

/// The card in the panel: collapsed to one row, or expanded to four doors
/// with the Change door's work-order field inline.
struct OptimizeHubCard: View {
    @ObservedObject private var hub = OptimizeHubState.shared
    @ObservedObject private var store = WorkOrderStore.shared
    @State private var request = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Button { hub.isExpanded.toggle() } label: {
                HStack(spacing: GruxSpacing.s) {
                    Image(systemName: "wand.and.stars").font(GruxType.caption).foregroundStyle(GruxTheme.accentPrimary)
                    Text(OptimizeCopy.title).font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                    if store.waitingOnYou > 0 {
                        Circle().fill(GruxTheme.warnAmber).frame(width: GruxSpacing.s, height: GruxSpacing.s)
                            .accessibilityLabel("\(store.waitingOnYou) waiting on your review")
                    }
                    Spacer()
                    Image(systemName: hub.isExpanded ? "chevron.up" : "chevron.down")
                        .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hub.isExpanded {
                Text(OptimizeCopy.hubCaption).font(GruxType.caption).foregroundStyle(GruxTheme.textSecondary)
                ForEach(OptimizeDoor.allCases) { door in
                    doorRow(door)
                    if door == .change { changeInline }
                }
                if !store.orders.isEmpty { ordersList }
            }
        }
        .padding(GruxSpacing.l)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(GruxTheme.accentPrimary.opacity(0.08)))
        .onChange(of: store.waitingOnYou) { _, n in hub.noteReviewsWaiting(n) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if store.hasActive { store.reload() }
            }
        }
    }

    private func doorRow(_ door: OptimizeDoor) -> some View {
        Button { hub.enter(door); if door == .handOver { handOver() } } label: {
            HStack(alignment: .top, spacing: GruxSpacing.s) {
                Image(systemName: door.icon).font(GruxType.caption).foregroundStyle(GruxTheme.accentPrimary)
                    .frame(width: GruxSpacing.l)
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    Text(door.title).font(GruxType.body).foregroundStyle(GruxTheme.textPrimary)
                    Text(door.body).font(GruxType.caption).foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(door.title)
    }

    private var changeInline: some View {
        HStack(spacing: GruxSpacing.s) {
            TextField(OptimizeCopy.placeholder, text: $request)
                .textFieldStyle(.plain).font(GruxType.body)
                .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).fill(GruxTheme.textTertiary.opacity(0.12)))
                .onSubmit(copyNew)
            Button("Copy work order", action: copyNew)
                .disabled(WorkOrderPrompt.clean(request) == nil)
        }
        .padding(.leading, GruxSpacing.l + GruxSpacing.s)
    }

    private var ordersList: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Divider()
            if !confirmation.isEmpty {
                Text(confirmation).font(GruxType.caption).foregroundStyle(GruxTheme.successMint)
            }
            ForEach(store.orders.prefix(3)) { order in
                WorkOrderRow(order: order, store: store) { confirmation = OptimizeCopy.copied(order.id) }
                    .background(order.id == hub.highlightedOrder
                                ? RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).fill(GruxTheme.warnAmber.opacity(0.10))
                                : nil)
            }
        }
    }

    private func copyNew() {
        guard let order = store.create(request: request, context: { WorkOrderContext.live(orderDir: $0) }),
              let text = store.workOrderText(order) else { return }
        OptimizeClipboard.copy(text)
        confirmation = OptimizeCopy.copied(order.id)
        request = ""
    }

    private func handOver() {
        switch HandoffBundle.writeLive() {
        case .success(let url):
            confirmation = OptimizeCopy.handoffWritten + " " + url.path
        case .failure(let error):
            confirmation = "Could not write the bundle: \(error.localizedDescription)"
        }
    }
}
```

Add to `Sources/Grux/Optimize/HandoffBundle.swift` (stub; Task 9 fills it):

```swift
import Foundation

enum HandoffBundle {
    enum Error: Swift.Error { case notYet }
    @MainActor static func writeLive() -> Result<URL, Swift.Error> { .failure(Error.notYet) }
}
```

Swap the slot in `CommandPanelRoot.panel`: `OptimizeGruxButton()` becomes `OptimizeHubCard()`. In `AppTriggers.swift` where `"fire-optimize"` sets `OptimizeState.shared.isOpen = true`, also set `OptimizeHubState.shared.isExpanded = true`.

- [ ] **Step 5: Run, look, commit**

Run: `swift test --filter 'OptimizeHubTests|OptimizeGruxTests' 2>&1 | tail -5`
Expected: 20 executed, 0 failures.

Launch (`./build.sh`) on the MacBook and confirm the card renders collapsed, expands on click, and typing a sentence plus Enter puts a work order on the clipboard (`pbpaste | head -3`).

```bash
git add Sources/Grux/Optimize/OptimizeHubCard.swift Sources/Grux/Optimize/HandoffBundle.swift Sources/Grux/Optimize/OptimizeGruxView.swift Sources/Grux/Optimize/WorkOrder.swift Sources/Grux/Shell/CommandPanelRoot.swift Sources/Grux/Triggers/AppTriggers.swift Tests/GruxTests/OptimizeHubTests.swift Tests/GruxTests/OptimizeGruxTests.swift
git commit -F - <<'MSG'
Optimize Grux is one card with four doors

Tune it, Change it (the work order, inline), Hand it over, Let it improve
itself. Collapsed to a row until something inside wants you. The station
count now agrees with itself in the comment, the view and the test.
MSG
```

---

### Task 9: The handoff bundle

**Files:**
- Modify: `Sources/Grux/Optimize/HandoffBundle.swift` (replace the stub)
- Modify: `Sources/Grux/SettingsView.swift:535-548` ("Hand setup to your agent" becomes a link to the hub)
- Test: `Tests/GruxTests/HandoffBundleTests.swift`

**Interfaces:**
- Consumes: `AgentHandoff.prompt()`, `Persistence.supportDir`, `Persistence.gruxDir`, `WorkOrderStore.shared.orders`.
- Produces:

```swift
enum HandoffBundle {
    static let secretKeyPattern: NSRegularExpression   // (?i)(apikey|api_key|token|secret|password|credential)
    static func stripSecrets(_ json: Any) -> Any
    static func write(to root: URL, config: Data, theme: Data?, macros: Data?, orders: [WorkOrderStore.Order], setupPrompt: String, now: Date = Date()) -> Result<URL, Swift.Error>
    @MainActor static func writeLive() -> Result<URL, Swift.Error>
}
```

The spec asked for the secret-key list as a data file. `Package.swift` declares no resources, so a bundled file would be a new build concern; the list is a regular expression over key names plus a test that scans `GruxConfig.CodingKeys` and fails if any key that looks like a secret is not matched. Same guarantee, no bundling.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Grux

/// The bundle an agent reads to apply "my Grux" elsewhere. Secrets never
/// survive it, and that is proven by planting them.
final class HandoffBundleTests: XCTestCase {
    private func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoff-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let planted = ["anthropicApiKey": "sk-ant-PLANTED-1",
                           "elevenLabsApiKey": "el-PLANTED-2",
                           "someToken": "tok-PLANTED-3",
                           "webhookSecret": "whs-PLANTED-4",
                           "imapPassword": "pw-PLANTED-5"]

    private func config(extra: [String: Any] = [:]) throws -> Data {
        var dict: [String: Any] = ["model": "deepseek", "listeningMode": "alwaysOn"]
        for (k, v) in planted { dict[k] = v }
        for (k, v) in extra { dict[k] = v }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    func test_everyPlantedSecretIsGone_andTheRestSurvives() throws {
        let root = temp()
        let url = try HandoffBundle.write(to: root, config: config(), theme: Data("{\"hue\":12}".utf8), macros: nil,
                                          orders: [], setupPrompt: "CONTEXT\nhello").get()
        let all = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for (_, v) in planted { XCTAssertFalse(all.contains(v), "\(v) leaked") }
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("config.json"))) as! [String: Any]
        XCTAssertEqual(cfg["model"] as? String, "deepseek")
        XCTAssertNil(cfg["anthropicApiKey"])
    }

    func test_aNestedSecretIsStripped() throws {
        let root = temp()
        let url = try HandoffBundle.write(to: root,
                                          config: config(extra: ["accounts": [["host": "imap.x", "password": "pw-NESTED-9"]]]),
                                          theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let text = try String(contentsOf: url.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("pw-NESTED-9"))
        XCTAssertTrue(text.contains("imap.x"))
    }

    func test_theBundleHasTheSixFiles_andGRUXmdNamesEachOne() throws {
        let root = temp()
        let url = try HandoffBundle.write(to: root, config: config(), theme: Data("{}".utf8), macros: Data("[]".utf8),
                                          orders: [], setupPrompt: "p").get()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        XCTAssertEqual(names, ["GRUX.md", "config.json", "theme.json", "macros.json", "work-orders.json", "setup-prompt.md"])
        let readme = try String(contentsOf: url.appendingPathComponent("GRUX.md"), encoding: .utf8)
        for n in names where n != "GRUX.md" { XCTAssertTrue(readme.contains("`\(n)`"), "GRUX.md does not explain \(n)") }
        XCTAssertTrue(readme.contains("Sources/Grux/DesignSystem"), "the rules did not travel")
    }

    func test_absentThemeAndMacrosAreNotInvented() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(), theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        XCTAssertFalse(names.contains("theme.json"))
        XCTAssertFalse(names.contains("macros.json"))
    }

    func test_aFailedWriteLeavesNoPartialFolder() throws {
        let root = URL(fileURLWithPath: "/dev/null/nope")
        let r = HandoffBundle.write(to: root, config: try config(), theme: nil, macros: nil, orders: [], setupPrompt: "")
        guard case .failure = r else { return XCTFail("wrote into /dev/null") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_everyConfigKeyThatLooksSecretIsMatched() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Models.swift"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"^\s+var ([A-Za-z0-9_]+): String"#, options: .anchorsMatchLines)
        let names = re.matches(in: models, range: NSRange(models.startIndex..., in: models))
            .map { String(models[Range($0.range(at: 1), in: models)!]) }
        let suspicious = names.filter { $0.range(of: "(?i)(key|token|secret|password|credential)", options: .regularExpression) != nil }
        XCTAssertFalse(suspicious.isEmpty, "the scan found no string config keys at all; the regex is broken")
        for n in suspicious {
            XCTAssertTrue(HandoffBundle.isSecretKey(n), "\(n) looks like a secret and would survive the bundle")
        }
    }

    func test_theSharedWriterUsesTheSuiteSupportDir() {
        XCTAssertTrue(HandoffBundle.liveRoot.path.hasPrefix(Persistence.gruxDir.path))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter HandoffBundleTests 2>&1 | tail -5`
Expected: `type 'HandoffBundle' has no member 'write'`, `isSecretKey`, `liveRoot`.

- [ ] **Step 3: Implement**

Replace `HandoffBundle.swift`:

```swift
import Foundation

/// The "Hand it over" door: everything that makes this Grux yours, as files an
/// agent can read and apply on another Mac. Secrets are stripped by key
/// shape, recursively, before anything is written.
enum HandoffBundle {
    enum Error: Swift.Error, LocalizedError {
        case cannotCreate(String)
        var errorDescription: String? {
            switch self { case .cannotCreate(let p): return "cannot create \(p)" }
        }
    }

    static var liveRoot: URL { Persistence.gruxDir.appendingPathComponent("handoff", isDirectory: true) }

    private static let secretPattern = try! NSRegularExpression(
        pattern: "(?i)(api_?key|token|secret|password|passphrase|credential)")

    static func isSecretKey(_ key: String) -> Bool {
        secretPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// Recursively drops any dictionary entry whose key looks like a secret.
    static func stripSecrets(_ json: Any) -> Any {
        if let dict = json as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !isSecretKey(k) { out[k] = stripSecrets(v) }
            return out
        }
        if let arr = json as? [Any] { return arr.map(stripSecrets) }
        return json
    }

    static func write(to root: URL, config: Data, theme: Data?, macros: Data?,
                      orders: [WorkOrderStore.Order], setupPrompt: String, now: Date = Date()) -> Result<URL, Swift.Error> {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = root.appendingPathComponent(f.string(from: now), isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(Error.cannotCreate(dir.path))
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: config)
            let stripped = try JSONSerialization.data(withJSONObject: stripSecrets(parsed), options: [.prettyPrinted, .sortedKeys])
            try stripped.write(to: dir.appendingPathComponent("config.json"))
            if let theme { try theme.write(to: dir.appendingPathComponent("theme.json")) }
            if let macros { try macros.write(to: dir.appendingPathComponent("macros.json")) }
            let index: [[String: Any]] = orders.map {
                ["id": $0.id, "request": $0.request,
                 "created": ISO8601DateFormatter().string(from: $0.created),
                 "lastStation": $0.progress.stage.rawValue]
            }
            try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
                .write(to: dir.appendingPathComponent("work-orders.json"))
            try Data(setupPrompt.utf8).write(to: dir.appendingPathComponent("setup-prompt.md"))
            try Data(readme(hasTheme: theme != nil, hasMacros: macros != nil).utf8).write(to: dir.appendingPathComponent("GRUX.md"))
            return .success(dir)
        } catch {
            try? fm.removeItem(at: dir)
            return .failure(error)
        }
    }

    static func readme(hasTheme: Bool, hasMacros: Bool) -> String {
        var lines = [
            "# This Grux, handed over",
            "",
            "You are this person's coding agent. This folder is how their Grux is set up, exported by Grux itself with every secret removed. Apply it to a Grux install on this or another Mac.",
            "",
            "## Files",
            "",
            "- `config.json`: the settings Grux reads at start, with every key that looks like a secret removed. Merge it into `~/Library/Application Support/Grux/config.json`; never replace that file, and never add a secret back from memory.",
            "- `setup-prompt.md`: what still needs setting up on the target Mac, split into what you may do and what only the person may do. Read it before touching anything.",
            "- `work-orders.json`: every change they have asked Grux for so far, with where it stopped. Context, not instructions.",
        ]
        if hasTheme { lines.append("- `theme.json`: accent and appearance. Copy it beside config.json.") }
        else { lines.append("- `theme.json`: not present, the person never changed the theme.") }
        if hasMacros { lines.append("- `macros.json`: their voice macros. Copy it beside config.json.") }
        else { lines.append("- `macros.json`: not present, they have no macros.") }
        lines += [
            "",
            "## Rules that come with Grux",
            "",
            "- The smallest change that does it. If a setting already does what was asked, changing the setting IS the work: no code.",
            "- Colours, type, spacing and radii come from `Sources/Grux/DesignSystem`. Never hard code one in a view.",
            "- Nothing new leaves the Mac: no telemetry, no new network calls, no keys in code.",
            "- Anything that sends, deletes or spends still goes through Approvals.",
            "- Quit Grux before editing its files, then `open -a Grux`.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func writeLive() -> Result<URL, Swift.Error> {
        let support = Persistence.supportDir
        guard let config = try? Data(contentsOf: support.appendingPathComponent("config.json")) else {
            return .failure(Error.cannotCreate("config.json is missing"))
        }
        let theme = try? Data(contentsOf: support.appendingPathComponent("theme.json"))
        let macros = try? Data(contentsOf: support.appendingPathComponent("macros.json"))
        let result = write(to: liveRoot, config: config, theme: theme, macros: macros,
                           orders: WorkOrderStore.shared.orders, setupPrompt: AgentHandoff.prompt())
        if case .success(let dir) = result {
            OptimizeClipboard.copy(AgentHandoff.prompt())
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
        return result
    }
}
```

Add `import AppKit` for `NSWorkspace`.

In `SettingsView.swift:535-548`, replace the "Hand setup to your agent" copy button's action with:

```swift
                    Button("Hand setup to your agent") {
                        OptimizeHubState.shared.isExpanded = true
                        AppState.shared.requestedTab = PanelKeys.none
                    }
                    Text("Now under Optimize Grux, as the Hand it over door.")
                        .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
```

Keep the existing `AgentHandoff.prompt()` copy path reachable from the CLI (`grux handoff`), which is unchanged.

- [ ] **Step 4: Red-prove the strip, then run**

Temporarily change `for (k, v) in dict where !isSecretKey(k)` to `for (k, v) in dict` and run `swift test --filter HandoffBundleTests`: `test_everyPlantedSecretIsGone_andTheRestSurvives` and `test_aNestedSecretIsStripped` must fail with the planted strings named. Restore the line; `git diff Sources/Grux/Optimize/HandoffBundle.swift` shows only the intended file.

Run: `swift test --filter HandoffBundleTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/Optimize/HandoffBundle.swift Sources/Grux/SettingsView.swift Tests/GruxTests/HandoffBundleTests.swift
git commit -F - <<'MSG'
Hand it over: the handoff bundle

Six files an agent can read: a secret-stripped config, theme and macros if
present, the work-order index, the setup prompt and a GRUX.md that explains
them and carries the rules. Stripping is by key shape, recursive, and
red-proven with planted values. Settings links here instead of copying.
MSG
```

---

### Task 10: Onboarding lands on the panel, and the wayfinding copy

**Files:**
- Modify: `Sources/Grux/Onboarding/OnboardingModel.swift:556-566` (`finish`), `Sources/Grux/Onboarding/OnboardingSteps.swift:166-182` (`wayfinding`)
- Test: `Tests/GruxTests/OnboardingNamesRealTabsTests.swift`, `Tests/GruxTests/TodayIsNamedTodayTests.swift`, `Tests/GruxTests/FirstRunHonestyTests.swift` (read each; update the assertions that name "the button under the Grux name", "sidebar doors" or the Chat landing)

- [ ] **Step 1: Write the failing test additions**

Append to `OnboardingNamesRealTabsTests`:

```swift
    func test_wayfindingNamesThePanelNotTheSidebar() {
        let titles = HowItWorksStep.wayfinding.map(\.title)
        XCTAssertEqual(titles.prefix(3), [OptimizeCopy.title, "Now", "The command palette"])
        for w in HowItWorksStep.wayfinding {
            XCTAssertFalse(w.body.lowercased().contains("sidebar"), "\(w.title) still says sidebar")
            XCTAssertFalse(w.body.contains("button under the Grux name"), "\(w.title) describes the old pill")
        }
    }

    func test_finishingLandsOnThePanelWithTheHubOpen() {
        OnboardingModel.shared.finish(skippedFirstLook: true)
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none)
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OnboardingNamesRealTabsTests 2>&1 | tail -5`
Expected: the prefix assertion fails (second title is `TuningCopy.title`), and `requestedTab` is `"chat"`.

- [ ] **Step 3: Update the copy and the landing**

`OnboardingSteps.wayfinding` becomes:

```swift
        [
            Wayfinding(title: OptimizeCopy.title,
                       body: "The card in the panel. Four doors: tune how Grux behaves, say what you want changed and Grux writes a work order your own coding agent builds, hand your setup to that agent as a bundle, or let Grux propose its own upgrades."),
            Wayfinding(title: "Now",
                       body: "The short list under the input. Only things with an action: an approval, mail that needs you, a job running, the next thing on your day, something left to set up. Empty means nothing needs you."),
            Wayfinding(title: "The command palette",
                       body: "Press \(PaletteHotkeyConfig.spokenShortcut) anywhere: every surface, the microphone and your workflows, a few letters away. Anything you open earns a spot in Recent at the foot of the panel."),
            Wayfinding(title: TuningCopy.title,
                       body: "How sure Grux must be before it acts, how often it may interrupt you, what it may spend and what it remembers, on one page. The first door under Optimize Grux, or right click the orb."),
            Wayfinding(title: HowItWorksCopy.decisionsKeyTitle, body: HowItWorksCopy.decisionsKeyBody),
            Wayfinding(title: "The Developer door", body: DoorsCopy.developer.body + " Reach it from the palette."),
            Wayfinding(title: "The Labs door", body: DoorsCopy.labs.body + " Reach it from the palette."),
        ]
```

If `DoorsCopy.*.body` mentions "sidebar", edit those two strings in `FirstPrompt.swift:49` to say "the palette" instead.

`OnboardingModel.finish` (line 565): replace `AppState.shared.requestedTab = "chat"` with:

```swift
            AppState.shared.requestedTab = AppState.shared.config.legacyShell ? "chat" : PanelKeys.none
            OptimizeHubState.shared.isExpanded = true
```

- [ ] **Step 4: Run the onboarding suites**

Run: `swift test --filter 'OnboardingNamesRealTabsTests|TodayIsNamedTodayTests|FirstRunHonestyTests|FirstRunChatTests|NoOverlaysDuringOnboardingTests' 2>&1 | tail -8`
Expected: 0 failures. Any failure names a string that still describes the sidebar; fix the copy, not the test, unless the test itself asserts the old shell.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/Onboarding/OnboardingModel.swift Sources/Grux/Onboarding/OnboardingSteps.swift Sources/Grux/Onboarding/FirstPrompt.swift Tests/GruxTests/OnboardingNamesRealTabsTests.swift
git commit -F - <<'MSG'
First run ends on the panel with Optimize open

The wayfinding screen names the card, Now, the palette and Tuning instead
of the sidebar and its doors.
MSG
```

---

### Task 11: The palette reaches everything, by rail name

**Files:**
- Modify: `Sources/Grux/Shell/OrbCommandPalette.swift:176-233`
- Test: `Tests/GruxTests/PaletteCoverageTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Grux

/// The palette is the way to anything that has not earned a Recent chip, so
/// it has to reach everything and call things what the panel calls them.
@MainActor
final class PaletteCoverageTests: XCTestCase {
    private var actions: [PaletteAction] { PaletteActionProvider.actions() }

    func test_everyLockedKeyIsListedOnce_byItsRailLabel() {
        let titles = actions.filter { $0.id.hasPrefix("tab-") }.map(\.title)
        for item in SidebarIA.allItems {
            let label = SidebarIA.railLabel(forKey: item.key)
            XCTAssertEqual(titles.filter { $0 == label }.count, 1, "\(item.key) as \(label)")
        }
        XCTAssertFalse(titles.contains("Open Mailbox"))
        XCTAssertTrue(titles.contains("Mail"))
    }

    func test_recentsAreNotRepeatedInTheFullList() {
        SidebarStateStore.shared.recordRecent("notes")
        let notes = actions.filter { $0.title == "Notes" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.id, "recent-notes")
    }

    func test_theMissingDestinationsAreThere() {
        let ids = Set(actions.map(\.id))
        XCTAssertTrue(ids.contains("labs-shelf"))
        XCTAssertTrue(ids.contains("approvals"))
        XCTAssertTrue(ids.contains("pair-iphone"))
        XCTAssertTrue(ids.contains("hud-toggle"))
        for pane in SettingsPane.allCases {
            XCTAssertTrue(ids.contains("settings-\(pane.rawValue)"), pane.rawValue)
        }
    }

    func test_everyRegistryRowIsReachableThroughThePalette() {
        let ids = Set(actions.map(\.id))
        for row in FeatureRegistry.rows where row.disposition != .ripped {
            guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { continue }
            XCTAssertTrue(ids.contains("tab-\(key)") || ids.contains("recent-\(key)"), "\(row.id) -> \(key)")
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter PaletteCoverageTests 2>&1 | tail -5`
Expected: `Open Mailbox` present, `labs-shelf` absent, Notes listed twice.

- [ ] **Step 3: Rewrite the destinations block**

Replace lines 176-205 (recents and tabs loops) with:

```swift
        let recents = SidebarStateStore.shared.recents
        for key in recents {
            guard let item = SidebarIA.item(forKey: key) else { continue }
            out.append(PaletteAction(id: "recent-\(item.key)", title: SidebarIA.railLabel(forKey: item.key),
                                     subtitle: "Recent", systemImage: item.icon) {
                AppDelegate.shared?.openLaunchWindow(tab: item.key)
                OpensLog.shared.record(key: item.key, via: .palette)
            })
        }
        for item in SidebarIA.allItems where !recents.contains(item.key) {
            out.append(PaletteAction(id: "tab-\(item.key)", title: SidebarIA.railLabel(forKey: item.key),
                                     subtitle: "Open", systemImage: item.icon) {
                AppDelegate.shared?.openLaunchWindow(tab: item.key)
                OpensLog.shared.record(key: item.key, via: .palette)
            })
        }
        out.append(PaletteAction(id: "labs-shelf", title: "Labs", subtitle: "The shelf of experiments", systemImage: "flask.fill") {
            AppDelegate.shared?.openLaunchWindow(tab: "labs")
        })
        out.append(PaletteAction(id: "approvals", title: ApprovalsTray.panelTitle, subtitle: ApprovalsTray.help, systemImage: "checkmark.seal.fill") {
            AppDelegate.shared?.openLaunchWindow(tab: PanelKeys.none)
            ApprovalsTrayState.shared.isOpen = true
        })
        out.append(PaletteAction(id: "pair-iphone", title: "Pair iPhone", subtitle: "The phone companion", systemImage: "iphone") {
            AppDelegate.shared?.openPhonePairingWindow()
        })
        out.append(PaletteAction(id: "hud-toggle", title: AmbientState.shared.ambientHUDVisible ? "Hide the HUD" : "Show the HUD",
                                 subtitle: "The ambient panel", systemImage: "rectangle.on.rectangle") {
            AmbientState.shared.toggleHUD()
        })
        for pane in SettingsPane.allCases {
            out.append(PaletteAction(id: "settings-\(pane.rawValue)", title: "Settings: \(pane.label)", subtitle: "Open Settings there",
                                     systemImage: pane.systemImage) {
                AppState.shared.requestedSettingsTab = pane.rawValue
                AppDelegate.openSettings()
            })
        }
```

`AmbientState.shared.ambientHUDVisible`: read the actual published name at `AmbientState.swift:251`. The tab-key check tool and `RenderedTabHookTests` are unaffected: `tab-` ids still cover every key that is not a recent, and recents cover the rest.

- [ ] **Step 4: Run and commit**

Run: `swift test --filter 'PaletteCoverageTests|PaletteFuzzy' 2>&1 | tail -5`
Expected: 0 failures.

```bash
git add Sources/Grux/Shell/OrbCommandPalette.swift Tests/GruxTests/PaletteCoverageTests.swift
git commit -F - <<'MSG'
The palette calls surfaces what the panel calls them, and reaches the rest

Rail labels, recents listed once, and the destinations it missed: Labs,
approvals, Pair iPhone, the HUD and each Settings pane.
MSG
```

---

### Task 12: Retire the rail tests into panel tests, the tool, and the registry doc

**Files:**
- Modify: `Tests/GruxTests/SidebarRowCountTests.swift` (rename the file and class to `PanelReachabilityTests`; keep the pure `SidebarIA.rail` tests that still hold for the legacy shell, drop nothing that still passes)
- Modify: `Tests/GruxTests/RailReachabilityTests.swift:41-63` (reachability now includes the palette)
- Modify: `Tests/GruxTests/BetaBadgeTests.swift:193-212`
- Modify: `Tests/GruxTests/OptimizeGruxTests.swift:209-231`
- Modify: `tools/grux-tab-keys-check.sh`
- Modify: `docs/feature-registry.md` (new section 9), `Tests/GruxTests/FeatureRegistryContractTests.swift`

- [ ] **Step 1: `PanelReachabilityTests`**

`git mv Tests/GruxTests/SidebarRowCountTests.swift Tests/GruxTests/PanelReachabilityTests.swift`, rename the class, keep every existing test (they exercise `SidebarIA.rail`, which the legacy shell still renders, so they are still true), and add:

```swift
    /// The panel shows no surface rows at all. Every registry row is reached
    /// through Now, Recent, the hub or the palette, and the palette alone
    /// covers all of them.
    func test_everyRegistryRowIsReachableFromThePanel() {
        let ids = Set(PaletteActionProvider.actions().map(\.id))
        var missing: [String] = []
        for row in FeatureRegistry.rows where row.disposition != .ripped {
            guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { continue }
            if !(ids.contains("tab-\(key)") || ids.contains("recent-\(key)")) { missing.append("\(row.id) -> \(key)") }
        }
        XCTAssertTrue(missing.isEmpty, "not reachable from the panel: \(missing)")
    }

    func test_aFreshInstallShowsNoRecentChips() {
        XCTAssertEqual(PanelFoot.chips(pinned: [], recents: []), [])
    }

    func test_chipsArePinnedFirstThenRecent_cappedAtFive_neverSettings() {
        let chips = PanelFoot.chips(pinned: ["notes"], recents: ["settings", "chat", "notes", "mailbox", "calendar", "tasks", "documents"])
        XCTAssertEqual(chips, ["notes", "chat", "mailbox", "calendar", "tasks"])
    }
```

- [ ] **Step 2: `RailReachabilityTests`**

In `reachableKeys(dev:brands:)`, after the rail loop, add the palette:

```swift
        for a in PaletteActionProvider.actions() {
            if a.id.hasPrefix("tab-") { keys.insert(String(a.id.dropFirst(4))) }
            if a.id.hasPrefix("recent-") { keys.insert(String(a.id.dropFirst(7))) }
        }
```

and update the class comment's first line to "EVERY SURFACE IS REACHABLE FROM THE UI: the panel's palette, or the legacy rail."

- [ ] **Step 3: `BetaBadgeTests.testTheWidestLabsRowStillFitsTheNavRail`**

The 240pt rail is legacy. Keep the test, add a second assertion on the panel's Recent chip budget: the widest chip label ("Integrations" with its icon) plus padding must fit `GruxLayout.panelWidth - 2 * GruxSpacing.l` five times over with gaps. Concretely:

```swift
    func testFiveRecentChipsFitThePanel() {
        let widest = Self.fittingWidth(Label("Integrations", systemImage: "link.circle.fill").font(GruxType.caption)
            .padding(.horizontal, GruxSpacing.s))
        let needed = widest * 5 + GruxSpacing.xs * 4
        XCTAssertLessThan(needed, GruxLayout.panelWidth - 2 * GruxSpacing.l,
                          "five chips at \(widest)pt each overflow the panel; drop the cap or shorten the label")
    }
```

If this fails, lower `PanelFoot.chips` cap to 4 and the spec's "up to 5" becomes "up to 4", recorded in the worklog line.

- [ ] **Step 4: `OptimizeGruxTests` wiring**

Replace `test_itIsReachableFromTheSidebarThePaletteAndATrigger_andNamedAtFirstRun` body's first two assertions with:

```swift
        let root = try sourcesFile("Sources/Grux/Shell/CommandPanelRoot.swift")
        XCTAssertTrue(root.contains("OptimizeHubCard()"), "the hub left the panel")
```

and replace `test_theButtonIsNotARailRow` with:

```swift
    func test_theHubIsAPanelCardNotARailRow() {
        let rail = SidebarIA.rail(developerUnlocked: false, brands: [])
        XCTAssertFalse(rail.contains { $0.label == OptimizeCopy.title })
        XCTAssertEqual(OptimizeDoor.allCases.count, 4)
    }
```

- [ ] **Step 5: The tool**

In `tools/grux-tab-keys-check.sh`, after the loop, add a panel check:

```zsh
rm -f $G/rendered-tab.txt
print -n "panel" > $G/fire-open-tab
got=""; for i in {1..50}; do sleep 0.1; [[ -f $G/rendered-tab.txt ]] && got=$(<$G/rendered-tab.txt) && [[ "$got" == "panel" ]] && break; done
if [[ "$got" == "panel" ]]; then (( pass++ )); print "ok    panel (closed)"; else (( fail++ )); failed+=("panel:$got"); print "FAIL  panel (rendered: ${got:-nothing})"; fi
```

and change the final `print -n "home"` to `print -n "panel"`. `AppTriggers.swift:1610` sets `requestedTab = tab` for any string, so `panel` reaches `PanelModel.applyRequested` with no trigger change.

- [ ] **Step 6: The registry doc**

Append to `docs/feature-registry.md`, before section 8 (so section numbers stay), a new section:

```markdown
## 7.6 How each row is reached in 3.0

The Command Panel shows no surface rows. Every row below is reached through the
palette (`Cmd+Shift+P`), and additionally through the door named here.

| id | reached through |
|---|---|
| chat | input, now, palette |
| mailbox | now, palette |
| ... one line per row in section 5, values from: input, now, recent, hub, palette, window |
```

Fill every row from `FeatureRegistry.rows` (38). Rows with a `.folds` disposition read `palette` (their parent's key opens them). Rows opening a window (`FeatureRegistry.rowsOpeningAWindow`) read `window`. `selfUpgrade` and `tuning`-adjacent rows read `hub`.

Add to `FeatureRegistryContractTests`:

```swift
    func testEveryRowSaysHowItIsReached() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/feature-registry.md"), encoding: .utf8)
        let section = try XCTUnwrap(doc.range(of: "## 7.6 How each row is reached"))
        let body = String(doc[section.upperBound...])
        for row in FeatureRegistry.rows where row.disposition != .ripped {
            XCTAssertTrue(body.contains("| \(row.id) |"), "\(row.id) has no reached-through line")
        }
        let allowed: Set<String> = ["input", "now", "recent", "hub", "palette", "window"]
        for line in body.split(separator: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| id") && !line.hasPrefix("|---") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            for v in cells[1].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                XCTAssertTrue(allowed.contains(v), "\(cells[0]): \(v)")
            }
        }
    }
```

Run `python3 scripts/check-contract.py` afterwards: the checker parses section 5's tables by heading, and a 7.x subsection must not break it. If it does, the new table goes under section 7.5's level and the test's heading string moves with it.

- [ ] **Step 7: Run the full suite**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -5`
Expected: 0 failures, executed count above 3147 plus every test added so far (Tasks 1 to 12 add about 75).

- [ ] **Step 8: Commit**

```bash
git add Tests/GruxTests/PanelReachabilityTests.swift Tests/GruxTests/RailReachabilityTests.swift Tests/GruxTests/BetaBadgeTests.swift Tests/GruxTests/OptimizeGruxTests.swift Tests/GruxTests/FeatureRegistryContractTests.swift tools/grux-tab-keys-check.sh docs/feature-registry.md
git commit -F - <<'MSG'
The IA tests describe the panel, and the registry says how each row is reached

Rail tests stay true for the legacy shell and gain the panel's claims:
every row reachable from the palette, no chips on a fresh install, five
chips fit. The tab-keys tool checks the closed panel too.
MSG
```

---

### Task 13: The design token ratchet

**Files:**
- Create: `scripts/design-ratchet.py`, `scripts/design-ratchet-baseline.json`
- Modify: `.github/workflows/ci.yml` (a step after Contract check in the "Build and test" job), `Sources/Grux/Shell/OrbCommandPalette.swift` (its 11, 13, 14pt literals), `Sources/Grux/LaunchRootView.swift:351,434-437,689` (the shell hardcodes that still live there)
- Test: `Tests/GruxTests/DesignRatchetTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

/// The ratchet only lets hardcode counts fall. This test runs the script the
/// way CI does and proves it fails when a count rises.
final class DesignRatchetTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func run(_ args: [String], in dir: URL) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [root.appendingPathComponent("scripts/design-ratchet.py").path] + args
        p.currentDirectoryURL = dir
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func test_theTreeIsAtOrBelowItsBaseline() throws {
        let r = try run(["--check"], in: root)
        XCTAssertEqual(r.status, 0, r.out)
    }

    func test_aRiseFails_andAFallLowersTheBaseline() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ratchet-\(UUID().uuidString.prefix(6))")
        let src = tmp.appendingPathComponent("Sources/Grux/Feature")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let file = src.appendingPathComponent("A.swift")
        try "Text(\"x\").font(.system(size: 12)).padding(8)\n".write(to: file, atomically: true, encoding: .utf8)
        var r = try run(["--write-baseline"], in: tmp)
        XCTAssertEqual(r.status, 0, r.out)
        try "Text(\"x\").font(.system(size: 12)).font(.system(size: 13)).padding(8)\n".write(to: file, atomically: true, encoding: .utf8)
        r = try run(["--check"], in: tmp)
        XCTAssertEqual(r.status, 1, "a rise passed: \(r.out)")
        XCTAssertTrue(r.out.contains("fonts: 2 > 1"), r.out)
        try "Text(\"x\").font(GruxType.body).padding(8)\n".write(to: file, atomically: true, encoding: .utf8)
        r = try run(["--check"], in: tmp)
        XCTAssertEqual(r.status, 0, r.out)
        let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent("scripts/design-ratchet-baseline.json"))) as! [String: Int]
        XCTAssertEqual(baseline["fonts"], 0, "a fall did not lower the floor")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DesignRatchetTests 2>&1 | tail -5`
Expected: both fail, the script does not exist.

- [ ] **Step 3: Write the script**

`scripts/design-ratchet.py`:

```python
#!/usr/bin/env python3
"""Design token ratchet. Counts hardcoded fonts, colors, paddings and radii in
Sources/Grux outside DesignSystem/, and only ever lets the counts fall.

  --check           exit 1 if any count is above scripts/design-ratchet-baseline.json;
                    rewrite the baseline downward for any count that fell.
  --write-baseline  record the current counts as the baseline (first run only).

Run from the Grux-Mac folder. CI runs --check beside swift test.
"""
import json, os, re, sys

ROOT = os.getcwd()
SRC = os.path.join(ROOT, "Sources", "Grux")
EXCLUDE = os.path.join(SRC, "DesignSystem")
BASELINE = os.path.join(ROOT, "scripts", "design-ratchet-baseline.json")

PATTERNS = {
    "fonts": re.compile(r"\.font\(\.system\(size:|\.font\(\.(largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?)\b"),
    "colors": re.compile(r"Color\.(white|black)\.opacity\(|Color\(red:|\.foregroundStyle\(\.(secondary|tertiary|primary)\)|Color\.(green|red|blue|orange|yellow|gray|purple|pink)\b"),
    "paddings": re.compile(r"\.padding\((\.[a-zA-Z]+, *)?\d"),
    "radii": re.compile(r"\.cornerRadius\(\d|RoundedRectangle\(cornerRadius: *\d"),
}

def count():
    totals = {k: 0 for k in PATTERNS}
    for dirpath, _, files in os.walk(SRC):
        if dirpath.startswith(EXCLUDE):
            continue
        for f in files:
            if not f.endswith(".swift"):
                continue
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                text = fh.read()
            for k, rx in PATTERNS.items():
                totals[k] += len(rx.findall(text))
    return totals

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    now = count()
    if mode == "--write-baseline":
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        with open(BASELINE, "w") as fh:
            json.dump(now, fh, indent=2, sort_keys=True); fh.write("\n")
        print("baseline written:", now)
        return 0
    with open(BASELINE) as fh:
        base = json.load(fh)
    bad = [(k, now[k], base.get(k, 0)) for k in PATTERNS if now[k] > base.get(k, 0)]
    fell = {k: now[k] for k in PATTERNS if now[k] < base.get(k, 0)}
    for k, n, b in bad:
        print(f"design-ratchet: {k}: {n} > {b} (hardcoded {k} went UP; use the DesignSystem tokens)")
    if fell:
        base.update(fell)
        with open(BASELINE, "w") as fh:
            json.dump(base, fh, indent=2, sort_keys=True); fh.write("\n")
        print("design-ratchet: floor lowered:", fell)
    print("design-ratchet:", now)
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Baseline, then the first downward move**

Run: `python3 scripts/design-ratchet.py --write-baseline` and commit the JSON. Then fix the shell hardcodes named in the spec:

- `OrbCommandPalette.swift`: every `.font(.system(size: 11...` becomes `GruxType.caption`, `13` becomes `GruxType.body`, `14` becomes `GruxType.body` (or `GruxType.title` for the query field).
- `LaunchRootView.swift:351` `.background(Color.black.opacity(0.25))` becomes `.background(GruxTheme.base.opacity(0.6))`; `:434-437` `.font(.caption2.weight(.heavy))` becomes `.font(GruxType.microCaps)`; `:689` `Color.green` becomes `GruxTheme.successMint` (if it was not already moved in Task 5).

Run `python3 scripts/design-ratchet.py --check`: it must print `floor lowered` and exit 0. Commit the lowered baseline with the code.

- [ ] **Step 5: CI**

In `.github/workflows/ci.yml`, in the "Build and test" job after the "Contract check" step, add:

```yaml
      - name: Design token ratchet
        working-directory: Grux-Mac
        run: python3 scripts/design-ratchet.py --check
```

Match the `working-directory` form the neighbouring steps use (read them; some `cd Grux-Mac` in `run:`).

- [ ] **Step 6: Run and commit**

Run: `swift test --filter DesignRatchetTests 2>&1 | tail -5`
Expected: 2 executed, 0 failures.

```bash
git add scripts/design-ratchet.py scripts/design-ratchet-baseline.json .github/workflows/ci.yml Sources/Grux/Shell/OrbCommandPalette.swift Sources/Grux/LaunchRootView.swift Tests/GruxTests/DesignRatchetTests.swift
git commit -F - <<'MSG'
Design token ratchet: hardcode counts may only fall

Counts fonts, colors, paddings and radii outside DesignSystem, fails CI
when any rises, lowers its own floor when one falls. The palette and the
legacy shell's own literals are the first move down.
MSG
```

---

### Task 14: The classic-sidebar switch, docs, and the whole-tree verification

**Files:**
- Modify: `Sources/Grux/SettingsView.swift:514` area (beside "Sidebar doors"), `Sources/Grux/Settings/SettingsSearchRegistry.swift` (alias `classic`, `sidebar`, `legacy`)
- Modify: `CLAUDE.md` (landing tab, the 37-key list gains `panel` as a non-tab key), `CHANGELOG.md` `[3.0.0]`, `docs/superpowers/plans/2026-09-20-grux-3-0-worklog.md`
- Test: `Tests/GruxTests/SettingsDeepLinkTests.swift` (one alias assertion)

- [ ] **Step 1: The switch and its alias test**

Append to `SettingsDeepLinkTests`:

```swift
    func test_classicSidebarIsAddressable() {
        for tag in ["classic", "sidebar", "legacy"] {
            XCTAssertEqual(SettingsTabAliases.map[tag]?.anchor, "general.shell", tag)
        }
    }
```

Run it red, then add to `SettingsView` General, beside the "Sidebar doors" section:

```swift
                GruxFormSection("Shell") {
                    Toggle("Classic sidebar", isOn: Binding(
                        get: { state.config.legacyShell },
                        set: { state.config.legacyShell = $0; state.saveConfig() }))
                    Text("The 240pt sidebar from before 3.0. Takes effect the next time the window opens. Goes away in the release after this one.")
                        .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
                }
                .id("general.shell")
```

and the three aliases to `SettingsTabAliases.map` pointing at `SettingsLocation(pane: .general, anchor: "general.shell")`, plus the keywords to `SettingsSearchRegistry` for General. Use whatever anchoring modifier the neighbouring sections use (`.id(...)` or a named anchor helper); read `SettingsAnchorTests` for the mechanism.

- [ ] **Step 2: Docs**

`CLAUDE.md`: in the section that says Chat is the landing tab, replace with "The Command Panel is the landing (3.0). `panel` is the rendered-tab value for 'no pane'. Today and Chat are panes." Add `panel` to the key table as "not a tab; closes the pane".

`CHANGELOG.md` `[3.0.0]`: add under Changed:

```
- The shell is a 420pt Command Panel: one input, a Now list of what needs
  you, Optimize Grux as a card with four doors (Tune it, Change it, Hand it
  over, Let it improve itself), and any surface as one pane beside it. The
  sidebar is gone as the default frame; `legacyShell` in config.json keeps
  it for one release. New: the handoff bundle under ~/.grux/handoff, a local
  opens.jsonl, and a design token ratchet in CI.
```

Worklog: one row, "P-U-1 Command Panel reskin, spec 2026-09-26, plan 2026-09-26, PROVEN by <the capture paths and the suite count from step 4>".

- [ ] **Step 3: Full suite, release build, ratchet, tool**

Run each and paste the last line of each into the worklog row:

```
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
swift build -c release --arch arm64 2>&1 | tail -1
python3 scripts/design-ratchet.py --check | tail -1
python3 scripts/check-contract.py | tail -1
./build.sh 2>&1 | tail -1                  # MacBook only
tools/grux-tab-keys-check.sh | tail -1     # against the running build: 36 keys, all ok
GRUX_FIRST_RUN_PANEL_CAPTURE=docs/superpowers/visuals/2026-09-26-panel-first-run.png swift test --filter FirstRunPanelCaptureTests
```

Expected: 0 failures, executed at or above 3147 + the new tests; release build `Compiling` then `Build complete`; ratchet exit 0; contract exit 0; tab keys `36 keys: 36 rendered as asked, 0 did not`.

Then two live captures with `screencapture -o -x -l<id>`: the resting panel and the panel with Mail open, saved as `docs/superpowers/visuals/2026-09-26-panel-rest.png` and `2026-09-26-panel-mail-pane.png`. Open both and check: no sidebar, four regions, pane bar reads "Mail" with Back.

- [ ] **Step 4: Stranger measurement**

On a second macOS user account (or the Mini, once the loop's S1 silence switch is in and merged), install the build, run onboarding, and count interactions to (a) a work order on the clipboard and (b) a handoff bundle on disk. Record both counts in the worklog row. Target: 3 or fewer each after onboarding. If either is higher, the fix is copy or a default in the hub, not a new surface.

- [ ] **Step 5: Commit and push**

```bash
git add Sources/Grux/SettingsView.swift Sources/Grux/Settings/SettingsSearchRegistry.swift Tests/GruxTests/SettingsDeepLinkTests.swift CLAUDE.md CHANGELOG.md docs/superpowers/plans/2026-09-20-grux-3-0-worklog.md docs/superpowers/visuals/2026-09-26-panel-first-run.png docs/superpowers/visuals/2026-09-26-panel-rest.png docs/superpowers/visuals/2026-09-26-panel-mail-pane.png
git commit -F - <<'MSG'
Classic sidebar switch, docs, and the reskin's evidence

Settings > General > Shell keeps the old frame for one release. CLAUDE.md
and the changelog say the panel is the landing. Captures and the suite
count are in the worklog row.
MSG
git push
```

---

## Sequencing and dependencies

```
1 tokens+config ─┬─> 2 Relevance ─> 3 live+log ─┐
                 └─> 4 SurfacePane ──────────────┼─> 5 CommandPanelRoot ─> 6 sizing+capture
                                                 │         │
                                                 │         ├─> 7 chat fold
                                                 │         ├─> 8 hub card ─> 9 handoff bundle
                                                 │         ├─> 10 onboarding
                                                 │         └─> 11 palette ─> 12 IA tests + doc
                                                 └─────────────────────────> 13 ratchet ─> 14 switch + docs + verify
```

Tasks 2 and 4 are independent of each other and can run in parallel. Tasks 7, 8, 10 and 11 are independent of each other once 5 is in. Task 13 can start any time after 4 but its baseline must be written after every other code task, so it runs last but one.

## Edge cases the tasks pin, by name

| Case | Where |
|---|---|
| Request during onboarding | Task 5 test 5 |
| Same tab twice with a close between | Task 5 test 4 |
| Unknown tab key | Task 5 test 3 |
| More than 7 needs-you rows | Task 2 `test_theCapNeverPromotesALowerClass` |
| Brand-scoped gap without a brand | Task 2 `test_brandScopedRowsNeedABrand` |
| Nested secret in config | Task 9 `test_aNestedSecretIsStripped` |
| A config key that looks secret but is new | Task 9 `test_everyConfigKeyThatLooksSecretIsMatched` |
| Partial bundle on write failure | Task 9 `test_aFailedWriteLeavesNoPartialFolder` |
| Window narrower than panel plus pane | Task 6 sizing test |
| Reduce Motion on | Task 5 step 9 (`animate:` honors `GruxTheme.reduceMotion`) |
| Unwritable opens.jsonl | Task 3 `test_anUnwritableFileIsIgnored` |
| Five chips overflow the panel | Task 12 step 3 |
| Old config.json without `legacyShell` | Task 1 |
| Ratchet count rises | Task 13 |
| `rendered-tab.txt` when no pane is open | Task 5 step 4 (`panel`), Task 12 step 5 |
