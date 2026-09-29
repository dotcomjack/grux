import XCTest
import AppKit
@testable import Grux

/// The palette is the way to anything that has not earned a Recent chip, so
/// it has to reach everything and call things what the panel calls them.
@MainActor
final class PaletteCoverageTests: XCTestCase {
    private var actions: [PaletteAction] { PaletteActionProvider.actions() }

    private var savedRecents: [String] = []
    private var savedPins: [String] = []
    private var savedRequest = ""
    private var savedLegacy = false

    override func setUp() async throws {
        let store = SidebarStateStore.shared
        savedRecents = store.recents
        savedPins = store.pinned
        store.replaceRecents([])
        store.replacePins([])
        savedRequest = AppState.shared.requestedTab
        savedLegacy = AppState.shared.config.legacyShell
        OpensLog.shared.nextVia = nil
    }

    override func tearDown() async throws {
        let store = SidebarStateStore.shared
        store.replaceRecents(savedRecents)
        store.replacePins(savedPins)
        AppState.shared.requestedTab = savedRequest
        AppState.shared.config.legacyShell = savedLegacy
        OpensLog.shared.nextVia = nil
        OptimizeState.shared.isOpen = false
        OptimizeHubState.shared.isExpanded = false
    }

    private func action(_ id: String) throws -> PaletteAction {
        try XCTUnwrap(actions.first { $0.id == id }, "no palette action \(id)")
    }

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

    /// A palette open is counted by the panel, as a palette open, and never
    /// by the palette itself. The classic shell counts nothing, so there the
    /// palette leaves no door pending for a later open to inherit.
    func test_aPaletteOpenNamesThePaletteAsTheDoor_andRecordsNothingItself() throws {
        OpensLog.shared.flush()
        let before = (try? String(contentsOf: OpensLog.shared.fileURL, encoding: .utf8)) ?? ""
        AppState.shared.config.legacyShell = false
        AppState.shared.requestedTab = PanelKeys.none
        try action("tab-mailbox").run()
        XCTAssertEqual(OpensLog.shared.nextVia, .palette)
        OpensLog.shared.flush()
        let after = (try? String(contentsOf: OpensLog.shared.fileURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(after, before, "the palette wrote an open itself")

        OpensLog.shared.nextVia = nil
        AppState.shared.config.legacyShell = true
        try action("tab-mailbox").run()
        XCTAssertNil(OpensLog.shared.nextVia, "the classic shell was left a pending door")
    }

    /// The approvals tray hangs off the foot, which shows with a pane open,
    /// so picking Approvals keeps the pane the person is reading, in both
    /// shells.
    func test_approvalsKeepsTheOpenPane() throws {
        let savedDelegate = AppDelegate.shared
        let delegate = AppDelegate()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelMinHeight),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        delegate.launchWindow = win
        AppDelegate.shared = delegate
        defer {
            win.orderOut(nil)
            AppDelegate.shared = savedDelegate
            ApprovalsTrayState.shared.isOpen = false
        }
        for legacy in [false, true] {
            AppState.shared.config.legacyShell = legacy
            AppState.shared.requestedTab = "mailbox"
            ApprovalsTrayState.shared.isOpen = false
            try action("approvals").run()
            XCTAssertEqual(AppState.shared.requestedTab, "mailbox", "Approvals closed the open pane (legacy: \(legacy))")
            XCTAssertTrue(ApprovalsTrayState.shared.isOpen, "the tray did not open (legacy: \(legacy))")
        }
    }

    /// In the panel shell Optimize is the hub card, and the popover's anchor
    /// is not on screen; the classic shell keeps the popover.
    func test_optimizeExpandsTheHubInThePanel_andOpensThePopoverInTheClassicShell() throws {
        AppState.shared.config.legacyShell = false
        AppState.shared.requestedTab = "mailbox"
        try action("optimize-grux").run()
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none, "a pane stayed open over the hub")
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
        XCTAssertFalse(OptimizeState.shared.isOpen, "the popover opened with no anchor on screen")

        OptimizeHubState.shared.isExpanded = false
        AppState.shared.config.legacyShell = true
        try action("optimize-grux").run()
        XCTAssertTrue(OptimizeState.shared.isOpen)
        XCTAssertFalse(OptimizeHubState.shared.isExpanded)
    }
}
