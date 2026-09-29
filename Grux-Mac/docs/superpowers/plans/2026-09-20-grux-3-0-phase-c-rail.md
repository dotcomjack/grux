# Grux 3.0 Phase C: the rail every surface has a door into

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar becomes twelve rows computed from a disposition recorded on every registry row, with Developer and Labs as collapsed counted doors and Settings last, and a test proves no capability in the app is orphaned.

**Architecture:** Today the sidebar is a hand-written list of 35 keys in 5 groups (`SidebarIA.groups`) that has no relationship to the 39-row feature registry beyond both being edited by hand. Phase C makes the registry the source of truth: each `FeatureRow` gains a `Disposition`, `SidebarModel` computes the rail from those dispositions, and `RegistryReachabilityTests` fails if any row has no door. The rail stops being a list somebody maintains and becomes a projection of a decision that is written down.

**Tech Stack:** Swift, SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` section 3. Roadmap: `2026-09-20-grux-3-0-roadmap.md`. Ledger: `2026-09-20-grux-3-0-worklog.md` rows P-C-1 to P-C-4 and gate G-C.

## Global Constraints

- Build worktree, branch `main`. Lanes branch `lane/P-C-n`; only the operator merges and only the operator runs `./build.sh`.
- Test floor: 2653 executed, 0 failures (measured 2026-09-20 at `39029ec`).
- **Phase B lands first.** B and C both write `SidebarModel.swift`, `LaunchRootView.swift` and `ChatView.swift`. Never run a B lane and a C lane at the same time.
- No em dashes and no en dashes anywhere. Dollar amounts as numerals with the symbol.
- Design tokens unchanged. A fold moves a surface; it never restyles it.
- The 35 tab keys in `LaunchRootView.swift:33` are LOCKED strings used by `--open-tab=` and by `~/.grux/fire-open-tab`. **A folded surface keeps its key working.** Folding changes where a person finds something, never whether a script can still reach it.
- A packet closes only when its test has been red-proven and the restore proven byte-identical by `diff`.

## The disposition table, reconciled to exactly 39 rows

Transcribed from the approved design spec section 3 and the decision record. Counts reconcile: **12 + 3 + 9 + 5 + 7 + 2 + 1 = 39.**

**Rail, direct (12).** These are the twelve rows, in this order:
`home`, `chat`, `mailbox` (relabelled **Mail**), `calendar`, `notes`, `documents`, `contacts`, `tasks`, `meetings`, `schedules`, `integrations`, then the **Studio** row, then `settings` last.

**Hosted by the Studio row (3).** `design.studio`, `creative` (Media Studio), `research`. Studio is a rail row with three surfaces behind it; it is not a new registry row.

**Folds into a parent (9).**

| Row | Folds into |
|---|---|
| `speakers` | Meetings |
| `workflows` | Schedules |
| `integrations.webhooks` | Integrations |
| `mailbox.compose` | Mail, behind its own credential |
| `projects` | Tasks, as the grouping it already is |
| `folders` | Settings, as the files allowlist |
| `skills` | Chat, as a composer picker |
| `approvals` | A global tray with a badge, no rail row |
| `focus` | A Today card |

**Developer door (5).** `commands`, `terminal.focus`, `agents`, `cookbook` (Local Models, picker also stays in onboarding), `compare`.

**Labs door (7).** `reactor`, `jax.hq`, `jax.command`, `cognition.map`, `feature.review`, `self.upgrade`, `phone`. Plus the sidebar-only `roadmap` key, which has no registry row and goes to Labs with them.

> **The cluster call overrides three per-row answers.** The decision record answered Cognition Map as a Chat side panel, and Feature Review and Self-Upgrade as Developer. The spec then decided the whole app-about-itself cluster together and says so in as many words: those three go to **Labs**. The spec is the later artifact and the plans argue from it. Do not "correct" this back from the decision record.

**Brand-scoped (2).** `meta.ads`, `social`. The rows appear only once a brand exists; onboarding names "Add a brand". Outreach is brand-scoped inside Mail and has no registry row of its own.

**Ripped (1).** `domains` (Domain monitor).

---

## P-C-1: A disposition on every row, and the test that no row is orphaned

### Task C1: The Disposition type and the 39 values

**Files:**
- Modify: `Sources/Grux/Onboarding/FeatureRegistry.swift` (add the column, fill all 39)
- Create: `Tests/GruxTests/RegistryReachabilityTests.swift`
- Test: `Tests/GruxTests/FeatureRegistryContractTests.swift` (existing, must stay green)

**Interfaces:**
- Produces: `FeatureRow.Disposition` and `FeatureRow.disposition`.

```swift
extension FeatureRow {
    /// The ONE door this surface is reachable through. Exactly one, which is
    /// what makes the reachability test meaningful: a row with two doors is a
    /// decision nobody finished making, and a row with none is a deleted
    /// feature with dead code behind it.
    enum Disposition: Equatable {
        case rail                       // its own row
        case studio                     // behind the Studio rail row
        case folds(into: String)        // a parent feature id, or a named surface
        case developer                  // behind the Developer door
        case labs                       // behind the Labs door
        case brandScoped                // a row once a brand exists
        case ripped                     // gone, and the code with it
    }
}
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

/// NOTHING SHIPS OFF AND UNDISCOVERABLE.
///
/// The lock in CLAUDE.md says a feature that is off and unfindable is a
/// deleted feature with dead code behind it. The registry is the list of
/// everything Grux can do, so every row in it must have exactly one door.
final class RegistryReachabilityTests: XCTestCase {

    func test_everyRegistryRowHasExactlyOneDisposition() {
        for row in FeatureRegistry.rows {
            XCTAssertNotNil(row.disposition, "\(row.id) has no recorded door")
        }
    }

    /// The counts from the approved design, so a row cannot quietly change
    /// door without somebody deciding to.
    func test_theDispositionsReconcileToTheApprovedCounts() {
        let rows = FeatureRegistry.rows
        XCTAssertEqual(rows.count, 39, "the registry changed size; re-derive the counts below")
        func count(_ match: (FeatureRow.Disposition) -> Bool) -> Int {
            rows.filter { match($0.disposition) }.count
        }
        XCTAssertEqual(count { $0 == .rail }, 12)
        XCTAssertEqual(count { $0 == .studio }, 3)
        XCTAssertEqual(count { if case .folds = $0 { return true }; return false }, 9)
        XCTAssertEqual(count { $0 == .developer }, 5)
        XCTAssertEqual(count { $0 == .labs }, 7)
        XCTAssertEqual(count { $0 == .brandScoped }, 2)
        XCTAssertEqual(count { $0 == .ripped }, 1)
    }

    func test_everyFoldNamesAParentThatActuallyExists() {
        let ids = Set(FeatureRegistry.rows.map(\.id))
        let namedSurfaces: Set<String> = ["approvals.tray", "today.card"]
        for row in FeatureRegistry.rows {
            guard case .folds(let parent) = row.disposition else { continue }
            XCTAssertTrue(ids.contains(parent) || namedSurfaces.contains(parent),
                          "\(row.id) folds into \(parent), which is nothing")
        }
    }

    func test_aRippedRowHasNoRemainingTab() {
        for row in FeatureRegistry.rows where row.disposition == .ripped {
            XCTAssertNil(SidebarIA.item(forKey: row.id),
                         "\(row.id) is ripped but still has a sidebar row")
        }
    }

    /// The one that catches the real failure: a row nobody decided about.
    func test_noRowIsReachableOnlyBySourceReading() {
        for row in FeatureRegistry.rows where row.disposition != .ripped {
            XCTAssertNotEqual(row.disposition, .ripped)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails.** Expected: compile error, `FeatureRow` has no `disposition`.

- [ ] **Step 3: Add the column and fill all 39** from the table above. Fill them literally, one per row, in registry order. Do not compute them from the tier: `tier` says whether a feature is labs-quality, and `disposition` says where a person finds it. They are different questions and conflating them is what put seven BETA pills on the rail.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Red-prove it.** Change one fold's parent to `"nowhere"` and one row's disposition to `.ripped`. Expect at least 3 red. Restore and `diff`.

- [ ] **Step 6: Commit.** Message: `Every capability in the registry records the one door it is behind`.

---

## P-C-2: The twelve-row rail, computed

### Task C2: SidebarModel reads the registry

**Files:**
- Modify: `Sources/Grux/DesignSystem/SidebarModel.swift:26-72`
- Modify: `Sources/Grux/LaunchRootView.swift` (render the doors)
- Create: `Tests/GruxTests/SidebarRowCountTests.swift`

**Interfaces:**
- Produces: `SidebarIA.rail(developerUnlocked:brands:) -> [SidebarRow]` where a row is a surface, the Developer door, the Labs door, or Settings.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class SidebarRowCountTests: XCTestCase {

    /// The Definition of Done item: a stranger on a clean Mac sees at most 14
    /// rows. Twelve surfaces, the Labs door, and Settings. The Developer door
    /// is NOT there until they say they write code, which is what makes 14 the
    /// number rather than 15.
    func test_firstRunShowsAtMostFourteenRows() {
        let rail = SidebarIA.rail(developerUnlocked: false, brands: [])
        XCTAssertLessThanOrEqual(rail.count, 14, "first run rail: \(rail.map(\.label))")
    }

    func test_theTwelveSurfacesAreTheOnesTheDesignNames() {
        let rail = SidebarIA.rail(developerUnlocked: false, brands: [])
        let surfaces = rail.compactMap { if case .surface(let s) = $0.kind { return s.label } else { return nil } }
        XCTAssertEqual(surfaces, ["Home", "Chat", "Mail", "Calendar", "Notes", "Documents",
                                  "Contacts", "Tasks", "Meetings", "Schedules", "Integrations", "Studio"])
    }

    func test_settingsIsAlwaysLast() {
        for dev in [true, false] {
            let rail = SidebarIA.rail(developerUnlocked: dev, brands: [])
            XCTAssertEqual(rail.last?.label, "Settings")
        }
    }

    func test_theDeveloperDoorAppearsOnlyWhenUnlocked() {
        XCTAssertFalse(SidebarIA.rail(developerUnlocked: false, brands: []).contains { $0.label == "Developer" })
        XCTAssertTrue(SidebarIA.rail(developerUnlocked: true, brands: []).contains { $0.label == "Developer" })
    }

    func test_eachDoorCarriesTheCountOfWhatIsBehindIt() {
        let rail = SidebarIA.rail(developerUnlocked: true, brands: [])
        let dev = try? XCTUnwrap(rail.first { $0.label == "Developer" })
        XCTAssertEqual(dev?.count, 5)
        let labs = try? XCTUnwrap(rail.first { $0.label == "Labs" })
        XCTAssertEqual(labs?.count, 8, "seven registry rows plus the Roadmap key")
    }

    func test_brandScopedRowsAppearOnlyOnceABrandExists() {
        XCTAssertFalse(SidebarIA.rail(developerUnlocked: false, brands: []).contains { $0.label == "Meta Ads" })
        let withBrand = SidebarIA.rail(developerUnlocked: false, brands: ["A Brand"])
        XCTAssertTrue(withBrand.contains { $0.label == "Meta Ads" })
    }

    /// The pill count is a Definition of Done item and it is zero.
    func test_noRailRowCarriesABetaPill() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "LaunchRootView did not load")
        XCTAssertFalse(t.contains("BetaBadge()"), "a per-row BETA pill is back on the rail")
    }
}
```

- [ ] **Step 2: Run it to verify it fails.**

- [ ] **Step 3: Compute the rail.** `SidebarIA.groups` stops being the source of truth for what renders and becomes, at most, icon and ordering data. The rail comes from dispositions. Keep `item(forKey:)` working for every one of the 35 locked keys, including folded and doored ones, because `--open-tab=` and the sweep depend on it.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Sweep every door.** `GRUX_SWEEP_OUT=/tmp/shots-c2 tools/grux-sweep.sh home chat mailbox calendar notes documents contacts tasks meetings schedules integrations settings` and read every capture.

- [ ] **Step 6: Red-prove it.** Add a thirteenth surface to the rail and put a `BetaBadge()` back on a row. Expect 2 red. Restore and `diff`.

- [ ] **Step 7: Commit.** Message: `The rail is computed from the registry, not maintained by hand`.

---

## P-C-3: The folds

### Task C3 to C11: nine folds, one per task

Each fold is its own task and its own commit, because each one can be reviewed and rejected on its own. The shape is the same for all nine:

1. The child surface renders inside the parent, in the place the design named.
2. The child's locked tab key still resolves and still opens the parent at the right place.
3. A test asserts both: that the child is reachable from the parent, and that the key still works.
4. Sweep the parent and read the capture.

| Task | Fold | The place inside the parent |
|---|---|---|
| C3 | `speakers` into Meetings | A section in the meeting detail, where the voices already are |
| C4 | `workflows` into Schedules | A tab or section alongside schedules |
| C5 | `integrations.webhooks` into Integrations | A section at the foot of Integrations |
| C6 | `mailbox.compose` into Mail | Behind its own credential, so the door is honest about needing one |
| C7 | `projects` into Tasks | The grouping Tasks already has |
| C8 | `folders` into Settings | The files allowlist, which is what it actually is |
| C9 | `skills` into Chat | A composer picker |
| C10 | `approvals` into a global tray | A badge reachable from anywhere, no rail row |
| C11 | `focus` into a Today card | A card, built for real in Phase D; C11 removes the rail row and leaves the surface reachable |

**The trap, and it has already produced one silent breakage in this repo:** `--open-tab=` falls back to `chat` on an unknown key, silently. A fold that drops a key does not fail, it quietly sends every script and every sweep to Chat and reports success. Every fold task asserts its key.

---

## P-C-4: Brand scoping, the rip, and the first-run count

### Task C12: Meta Ads, Social and Outreach appear only with a brand

**Files:** `Sources/Grux/Onboarding/*`, the rail computation from C2.
Onboarding names "Add a brand" so the rows are discoverable before they exist, which is what the never-ship-it-hidden lock requires. With no brand, the rows are absent rather than empty.

### Task C13: Domain monitor is ripped, and it is NOT the small job it looks

**ATTEMPTED AND REVERTED 2026-09-20.** Read this before trying again.

The registry row's own note says "no page of its own yet, so do not send
anyone looking for it", and there is no tab key and no enum case, which reads
like a row with nothing behind it. It is not.

What the attempt actually hit, in the order it surfaced:

1. **A five-test blast radius**, not a clean deletion: the labs-set contract,
   the credentials-offered contract, `FeatureSelectionTests`, the contract
   row-count literal, and a dedicated `DomainMonitorCapabilityTests`.
2. **`key.godaddy` is read by SHIPPING CODE.** `CredentialsOfferedTests` failed
   with "read by shipping code but Settings no longer offers a field for it",
   because the Settings credential fields are derived from registry rows.
   Removing the row orphaned a live credential.
3. **There IS a surface.** `Empire/EmpireDashboardWindow.swift:280` links to the
   GoDaddy portfolio. The note was true about TABS and false about the app.
4. **It reaches the Keychain.** `KeychainStore.Key` carries `goDaddyApiKey` and
   `goDaddyApiSecret`. This repo is emphatic that Keychain identifiers are part
   of an item's primary key and that removing one does not delete the
   credential, it makes it unreachable while it sits in the login keychain,
   which is worse than deletion because nothing surfaces to say where it went.

**So the rip is its own packet with its own care**, in this order: remove the
Empire dashboard's domain section, decide what happens to the two stored
credentials (a migration, or deliberately leaving them), update the credentials
contract, delete `DomainMonitorCapabilityTests`, then the registry row and the
document together, then the counts. State every count and reconcile.

Do not attempt it as part of a broader pass. The reason this is written down is
that it looked mechanical and was not.

### Task C14: The first-run count, proven on a clean state

Not a unit test. Reset to a first-run state, launch, capture the rail, count the rows in the capture, and record the number with the screenshot path. The unit test in C2 asserts the model; this asserts the pixels.

---

## G-C: the phase gate

1. Every task checked, committed and pushed.
2. `swift build` exit 0. `swift test` exit 0, executed count at or above 2653, 0 failures.
3. `RegistryReachabilityTests` and `SidebarRowCountTests` both red-proven, with the planted failure named and the restore proven byte-identical.
4. A sweep of **every door**: the twelve rail rows, the Developer door open, the Labs door open, and each of the nine folded surfaces inside its parent. One capture each, listed in the evidence file with its path.
5. All 35 locked tab keys still resolve. Prove it by firing each one through `~/.grux/fire-open-tab` and asserting the tab that actually rendered, not the ack. **The ack fires before SwiftUI repaints**, which is trap 1 in the sweep harness and has already produced a confidently mislabelled capture in this repo.
6. The first-run rail count stated as a number with its screenshot.

## Notes for whoever executes this

- The disposition column is the deliverable of C1, and everything else is a consequence of it. If a disposition looks wrong while you are building C2, fix the registry and let the rail follow. Never special-case a row in the rail computation: that is how the hand-maintained list came back.
- `tier` and `disposition` answer different questions. A `labs` tier row can sit behind the Developer door and a `core` row can sit in Labs. Do not derive one from the other.
- Folding is a move, not a deletion. If a fold means a surface loses a capability it had as its own tab, that is a defect, not a simplification, and it goes in the evidence file as one.
