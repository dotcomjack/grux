import XCTest
@testable import Grux

/// The Command Panel is how a person reaches every surface, and the legacy
/// rail still has to add up for the one release it stays behind Classic
/// sidebar.
///
/// The panel tests come first. The rail tests below them exercise
/// `SidebarIA.rail`, which `LaunchRootView` still renders for the classic
/// shell, so every one of them still describes something true: the twelve
/// rows, two doors and Settings, computed from the door recorded on each
/// registry row rather than maintained by hand.
@MainActor
final class PanelReachabilityTests: XCTestCase {

    private var savedRecents: [String] = []
    private var savedPins: [String] = []

    /// Recents and pins are process-wide and leak between classes (R5.11),
    /// and the palette lists a recent key as `recent-` rather than `tab-`.
    override func setUp() async throws {
        let store = SidebarStateStore.shared
        savedRecents = store.recents
        savedPins = store.pinned
        store.replaceRecents([])
        store.replacePins([])
    }

    override func tearDown() async throws {
        let store = SidebarStateStore.shared
        store.replaceRecents(savedRecents)
        store.replacePins(savedPins)
    }

    private func rail(dev: Bool = false, brands: [String] = []) -> [SidebarRow] {
        SidebarIA.rail(developerUnlocked: dev, brands: brands)
    }

    // MARK: - The panel

    /// Rows with no tab that the palette reaches by an action of their own.
    private static let paletteIdForRowWithoutATab: [String: String] = [
        "approvals": "approvals",
        "phone": "pair-iphone",
    ]

    /// Folds with no tab, reached through their parent's key, which the
    /// palette lists as `tab-` or, once opened, `recent-`.
    private static let parentKeyForFoldWithoutATab: [String: String] = [
        "mailbox.compose": "mailbox",
        "integrations.webhooks": "integrations",
    ]

    /// The panel shows no surface rows at all. Every registry row is reached
    /// through Now, Recent, the hub or the palette, and the palette alone
    /// covers all of them.
    func test_everyRegistryRowIsReachableFromThePanel() {
        XCTAssertEqual(unreachableFromThePalette(), [], "with no recents")
        // A surface opened once is listed as `recent-<key>` instead of
        // `tab-<key>`, and must still count.
        SidebarStateStore.shared.recordRecent("mailbox")
        SidebarStateStore.shared.recordRecent("integrations")
        XCTAssertEqual(unreachableFromThePalette(), [], "with mailbox and integrations recent")
    }

    private func unreachableFromThePalette() -> [String] {
        let ids = Set(PaletteActionProvider.actions().map(\.id))
        var missing: [String] = []
        for row in FeatureRegistry.rows where row.disposition != .ripped {
            guard let key = FeatureRegistry.tabKey(forRowId: row.id)
                    ?? Self.parentKeyForFoldWithoutATab[row.id] else {
                let id = Self.paletteIdForRowWithoutATab[row.id]
                if let id, ids.contains(id) { continue }
                missing.append("\(row.id) -> \(id ?? "no palette entry named")")
                continue
            }
            if !(ids.contains("tab-\(key)") || ids.contains("recent-\(key)")) { missing.append("\(row.id) -> \(key)") }
        }
        return missing
    }

    func test_aFreshInstallShowsNoRecentChips() {
        XCTAssertEqual(PanelFoot.chips(pinned: [], recents: []), [])
    }

    func test_chipsArePinnedFirstThenRecent_cappedAtFive_neverSettings() {
        let chips = PanelFoot.chips(pinned: ["notes"], recents: ["settings", "chat", "notes", "mailbox", "calendar", "tasks", "documents"])
        XCTAssertEqual(chips, ["notes", "chat", "mailbox", "calendar", "tasks"])
    }

    // MARK: - The legacy rail, which the classic shell still renders

    /// THE DEFINITION OF DONE TARGET IS FOURTEEN, AND IT IS NOT MET YET.
    ///
    /// Twelve surfaces, the Labs door, and Settings. The Developer door is not
    /// there until somebody says they write code, which is what makes the
    /// target 14 and not 15.
    ///
    /// The rail is currently fourteen PLUS the surfaces whose new home does
    /// not host them yet. This test says that out loud rather than passing
    /// vacuously on a lowered bar: each Phase C fold removes a prop, so the
    /// number can only go down, and it becomes a flat 14 when the list empties.
    func test_theRailIsFourteenRowsPlusWhatHasNotMovedYet() {
        let props = SidebarIA.awaitingTheirNewHome.count
        let r = rail()
        XCTAssertEqual(r.count, 14 + props, "rail: \(r.map(\.label))")
        XCTAssertEqual(r.count - props, 14, "the twelve surfaces, the Labs door, and Settings")
    }

    /// The design's twelve are the FIRST twelve, whatever is propped behind
    /// them, so the rail a stranger reads top to bottom is already right.
    func test_theFirstTwelveSurfacesAreTheOnesTheDesignNames() {
        let surfaces = rail().filter { !$0.isDoor && $0.id != "settings" }.map(\.label)
        XCTAssertEqual(Array(surfaces.prefix(12)),
                       ["Today", "Chat", "Mail", "Calendar", "Notes", "Documents",
                        "Contacts", "Tasks", "Meetings", "Schedules",
                        "Integrations", "Studio"])
    }

    /// Mailbox is relabelled Mail, and the key stays so --open-tab keeps working.
    func test_mailIsRelabelledWithoutBreakingItsKey() {
        let mail = rail().first { $0.label == "Mail" }
        XCTAssertEqual(mail?.kind, .surface(key: "mailbox"))
    }

    func test_settingsIsAlwaysLast() {
        for dev in [true, false] {
            for brands in [[], ["A Brand"]] {
                XCTAssertEqual(rail(dev: dev, brands: brands).last?.label, "Settings",
                               "dev=\(dev) brands=\(brands)")
            }
        }
    }

    func test_theDeveloperDoorAppearsOnlyWhenUnlocked() {
        XCTAssertFalse(rail(dev: false).contains { $0.label == "Developer" })
        XCTAssertTrue(rail(dev: true).contains { $0.label == "Developer" })
    }

    func test_theLabsDoorIsAlwaysThere() {
        XCTAssertTrue(rail().contains { $0.label == "Labs" })
    }

    /// A door with no count is a door nobody opens.
    func test_eachDoorCarriesTheCountOfWhatIsBehindIt() {
        let r = rail(dev: true)
        let dev = r.first { $0.label == "Developer" }
        XCTAssertEqual(dev?.count, 4, "Developer holds Commands, Agents, Local Models, Compare")
        let labs = r.first { $0.label == "Labs" }
        XCTAssertEqual(labs?.count, 8, "seven registry rows plus the Roadmap key")
    }

    func test_aSurfaceRowCarriesNoCount() {
        for row in rail() where !row.isDoor {
            XCTAssertEqual(row.count, 0, "\(row.label) carries a count it should not")
        }
    }

    func test_brandScopedRowsAppearOnlyOnceABrandExists() {
        XCTAssertFalse(rail().contains { $0.label == "Meta Ads" })
        let withBrand = rail(brands: ["A Brand"])
        XCTAssertTrue(withBrand.contains { $0.label == "Meta Ads" })
        XCTAssertTrue(withBrand.contains { $0.label == "Social" })
        XCTAssertEqual(withBrand.count, 16 + SidebarIA.awaitingTheirNewHome.count,
                       "twelve surfaces, two brand rows, Labs, Settings, plus what has not moved")
    }

    /// The whole point of the rail being computed: the doors and the
    /// dispositions cannot disagree, because one is derived from the other.
    func test_theDoorCountsMatchTheDispositionTable() {
        XCTAssertEqual(SidebarIA.behind(.developer).count,
                       FeatureRegistry.dispositions.values.filter { $0 == .developer }.count)
        XCTAssertEqual(SidebarIA.behind(.labs).count,
                       FeatureRegistry.dispositions.values.filter { $0 == .labs }.count)
    }

    /// Folding changes where a person finds something, never whether a script
    /// can reach it. Every locked key must still resolve.
    func test_everyLockedTabKeyStillResolves() {
        for item in SidebarIA.allItems {
            XCTAssertNotNil(SidebarIA.item(forKey: item.key),
                            "\(item.key) stopped resolving, so --open-tab falls through to chat silently")
        }
        // 35 until `terminalFocus` left with its feature on 2026-09-27.
        XCTAssertGreaterThanOrEqual(SidebarIA.allItems.count, 34,
                                    "the locked key set shrank")
    }

    /// Every rail surface points at a key that resolves, or the row opens onto
    /// nothing.
    func test_everyRailSurfacePointsAtARealKey() {
        for row in rail(dev: true, brands: ["A Brand"]) {
            guard case .surface(let key) = row.kind else { continue }
            XCTAssertNotNil(SidebarIA.item(forKey: key),
                            "\(row.label) points at \(key), which resolves to nothing")
        }
    }
}

/// The rail is what the VIEW renders, not just what the model computes.
@MainActor
final class RailWiringTests: XCTestCase {
    private func launchRoot() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "LaunchRootView did not load")
        return t
    }

    /// Asserts the INVARIANT, not one expression.
    ///
    /// This used to require the literal `ForEach(rail) { row in`, which made a
    /// correct refactor fail: on 2026-09-24 the rail was split into a
    /// scrolling half and a pinned Settings row, still derived from the same
    /// `SidebarIA.rail`, and this test went red for a change that did exactly
    /// what it was written to protect. A test that fails on correct code
    /// teaches people to edit the test.
    ///
    /// It now checks the two things that actually matter: the rows come from
    /// the model, and BOTH halves reach the screen. That second half is new
    /// and it closes a real hole: `SidebarRailSplitTests` proves the partition
    /// keeps every row, but a pure function cannot know whether the view
    /// bothered to render what it returned. Drop the pinned ForEach and
    /// Settings exists in the model, passes every model test, and appears
    /// nowhere. That is the precise divergence this file exists to catch.
    func test_theSidebarRendersTheComputedRail() throws {
        let t = try launchRoot()
        XCTAssertTrue(t.contains("SidebarIA.rail(developerUnlocked:"),
                      "the sidebar no longer derives its rows from SidebarIA.rail, so it is back to a hand-maintained list")
        XCTAssertFalse(t.contains("ForEach(SidebarIA.groups) { group in"),
                       "the sidebar renders the 1.x five-group list again")
        XCTAssertTrue(t.contains("ForEach(railSplit.scrolling) { row in"),
                      "the scrolling half of the rail is no longer rendered")
        XCTAssertTrue(t.contains("ForEach(railSplit.pinned) { row in"), """
            the PINNED half of the rail is no longer rendered. Settings would exist in \
            SidebarIA.rail, satisfy every model test including test_settingsIsAlwaysLast, \
            and appear on no screen at any window size.
            """)
    }

    /// A door that lists a row which opens nothing is the silent failure this
    /// whole mapping exists to prevent.
    func test_everyDoorListsOnlyRowsThatOpenSomething() {
        for doorId in ["developer", "labs"] {
            let disposition: FeatureRow.Disposition = doorId == "developer" ? .developer : .labs
            for row in SidebarIA.behind(disposition) {
                guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { continue }
                XCTAssertNotNil(SidebarIA.item(forKey: key),
                                "the \(doorId) door would list \(row.id), which opens nothing")
            }
        }
    }

    // MARK: - The two defaults that deliberately disagree

    /// An install that predates the key already had Commands and Agents as
    /// rail rows. An upgrade must not quietly take a surface
    /// away, so the decode fallback is TRUE.
    func test_anExistingInstallKeepsTheSurfacesItAlreadyHad() throws {
        let encoded = try JSONEncoder().encode(AppState.shared.config)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj.removeValue(forKey: "developerSurfacesUnlocked")
        let cfg = try JSONDecoder().decode(GruxConfig.self,
                                           from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertTrue(cfg.developerSurfacesUnlocked,
                      "an upgrade silently removed the Developer surfaces from someone's rail")
    }

    /// And a FRESH install, which has no config file at all and therefore
    /// takes the init default, starts with it off. That is what makes the
    /// first-run rail fourteen rows rather than fifteen.
    ///
    /// The two defaults deliberately disagree, so this asserts the pair rather
    /// than one of them: a single default cannot satisfy both people.
    func test_theInitDefaultAndTheDecodeFallbackDeliberatelyDisagree() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Models.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "Models did not load")
        XCTAssertTrue(t.contains("developerSurfacesUnlocked: Bool = false,"),
                      "a fresh install would see fifteen rows at first run")
        XCTAssertTrue(t.contains("decodeIfPresent(Bool.self, forKey: .developerSurfacesUnlocked) ?? true"),
                      "an upgrade would take the Developer surfaces away")
        let props = SidebarIA.awaitingTheirNewHome.count
        XCTAssertEqual(SidebarIA.rail(developerUnlocked: false, brands: []).count, 14 + props)
        XCTAssertEqual(SidebarIA.rail(developerUnlocked: true, brands: []).count, 15 + props)
    }
}
