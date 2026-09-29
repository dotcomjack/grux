import XCTest
import SwiftUI
@testable import Grux

/// The Command Panel: which pane opens for which request, what an open
/// records, how Now refreshes, and what the root draws. Model tests inject
/// their own `RelevanceState` and never read the live stores for Now: another
/// class leaves approvals in the suite's scratch queue for the whole process.
@MainActor
final class CommandPanelRootTests: XCTestCase {
    private var savedRecents: [String] = []
    private var savedPins: [String] = []
    private var savedRequest = ""
    private var savedStage: OnboardingModel.Stage = .done
    private var savedSkippedFirstLook = false
    private var savedOnboardingBytes: Data?
    private let onboardingURL = Persistence.supportDir.appendingPathComponent("onboarding.json")

    override func setUp() async throws {
        let store = SidebarStateStore.shared
        savedRecents = store.recents
        savedPins = store.pinned
        store.replaceRecents([])
        store.replacePins([])
        savedRequest = AppState.shared.requestedTab
        savedStage = OnboardingModel.shared.stage
        savedSkippedFirstLook = OnboardingModel.shared.skippedFirstLook
        savedOnboardingBytes = try? Data(contentsOf: onboardingURL)
        OpensLog.shared.nextVia = nil
    }

    override func tearDown() async throws {
        // First: finishing onboarding writes the hub, and in the classic
        // shell requestedTab, which the lines below put back.
        restoreOnboarding()
        let store = SidebarStateStore.shared
        store.replaceRecents(savedRecents)
        store.replacePins(savedPins)
        AppState.shared.requestedTab = savedRequest
        ApprovalsTrayState.shared.isOpen = false
        OptimizeHubState.shared.isExpanded = false
        OptimizeHubState.shared.highlightedOrder = nil
        OpensLog.shared.nextVia = nil
        XCTAssertEqual(OnboardingModel.shared.stage, savedStage, "this class left onboarding on another stage")
        XCTAssertEqual(OnboardingModel.shared.skippedFirstLook, savedSkippedFirstLook,
                       "this class left onboarding with another first-look answer")
    }

    /// Puts onboarding back where setUp found it: the stage and the first-look
    /// answer through the model's own transitions (`stage` has no setter),
    /// then the persisted file's bytes, as OnboardingTests does. Several tests
    /// here start or finish the flow, and a later class must not inherit that.
    private func restoreOnboarding() {
        let onboarding = OnboardingModel.shared
        if savedStage == .done {
            if onboarding.stage != .done || onboarding.skippedFirstLook != savedSkippedFirstLook {
                onboarding.finish(skippedFirstLook: savedSkippedFirstLook)
            }
        } else if onboarding.stage != savedStage {
            onboarding.reset()
            var hops = 0
            while onboarding.stage != savedStage, onboarding.stage != .done, hops < 20 {
                onboarding.advance(from: onboarding.stage)
                hops += 1
            }
        }
        if let savedOnboardingBytes {
            try? savedOnboardingBytes.write(to: onboardingURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: onboardingURL)
        }
    }

    /// A model whose Now comes from a hand-built state, never the live stores.
    private func model(_ state: RelevanceState = RelevanceState()) -> PanelModel {
        PanelModel(stateProvider: { state })
    }

    private func sources(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        XCTAssertGreaterThan(text.count, 200, "\(relative) did not load")
        return text
    }

    private func openLines() throws -> [[String: String]] {
        OpensLog.shared.flush()
        guard let text = try? String(contentsOf: OpensLog.shared.fileURL, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
    }

    private func pump(until done: () -> Bool, seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Requests

    func test_theLandingIsThePanelWithNoPane() {
        let m = model()
        m.open(.notes, via: .now)
        m.applyRequested(PanelKeys.none)
        XCTAssertNil(m.pane, "the panel key must close the pane")
    }

    func test_aLockedKeyOpensItsPane() {
        let m = model()
        m.applyRequested("mailbox")
        XCTAssertEqual(m.pane, .mailbox)
        m.applyRequested("foundry")
        XCTAssertEqual(m.pane, .selfUpgrade, "the foundry alias still resolves")
    }

    /// R5.8: the trigger contract is unchanged, and the legacy shell opens
    /// Chat for a key it does not know.
    func test_anUnknownKeyOpensChat() {
        let m = model()
        m.applyRequested("mailbox")
        m.applyRequested("no-such-surface")
        XCTAssertEqual(m.pane, .chat, "an unknown key opens Chat, as LaunchRootView.applyTab does")
    }

    /// R5.18: landing on the panel clears a key the old shell left behind,
    /// so the next request for that key is a change the root sees.
    func test_landingOnThePanelClearsAStaleRequest() {
        let m = model()
        AppState.shared.requestedTab = "settings"
        m.applyRequested(PanelKeys.none)
        XCTAssertNil(m.pane)
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none, "a stale key would swallow the next request")
    }

    /// The mirror of the test above for the other direction: flipping to the
    /// classic sidebar lands on Home, and `requestedTab` must say so. Left on
    /// the pane's key, a later request for that key is no change at all, so
    /// the palette, the CLI and fire-open-tab would open nothing.
    func test_flippingToTheClassicSidebarClearsAStaleRequest() throws {
        let savedLegacy = AppState.shared.config.legacyShell
        defer { AppState.shared.config.legacyShell = savedLegacy }
        AppState.shared.config.legacyShell = false
        AppState.shared.requestedTab = "mailbox"
        let size = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth + GruxLayout.paneWidth, height: GruxLayout.panelIdealHeight)
        let host = NSHostingView(rootView: ShellRootView(defaultTab: "mailbox").environmentObject(AppState.shared)
            .frame(width: size.width, height: size.height))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        pump(until: { false }, seconds: 0.2)
        let opensBefore = try openLines().count
        AppState.shared.config.legacyShell = true
        pump(until: { AppState.shared.requestedTab == "home" })
        XCTAssertEqual(AppState.shared.requestedTab, "home", "the classic shell shows Home while requestedTab keeps the pane's key")
        pump(until: { false }, seconds: 0.2)
        XCTAssertEqual(try openLines().count, opensBefore, "the flip counted an open")
        window.contentView = nil
    }

    func test_closingAPaneResetsTheRequestSoTheSameTabCanReopen() {
        let m = model()
        AppState.shared.requestedTab = "chat"
        m.applyRequested("chat")
        XCTAssertEqual(m.pane, .chat)
        m.closePane()
        XCTAssertNil(m.pane)
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none,
                       "requestedTab is a String and onChange fires only on change; a close must reset it")
        m.applyRequested("chat")
        XCTAssertEqual(m.pane, .chat, "chat, close, chat must reopen")
    }

    // MARK: The title bar toggle

    func test_theTitleBarToggleClosesAnOpenPane() {
        let m = model()
        m.open(.chat, via: .trigger)
        m.togglePane()
        XCTAssertNil(m.pane)
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none)
    }

    func test_theTitleBarToggleReopensTheLastPane() {
        let m = model()
        m.openKey("calendar", via: .trigger)
        let calendar = m.pane
        XCTAssertNotNil(calendar)
        m.closePane()
        m.togglePane()
        XCTAssertEqual(m.pane, calendar, "closed, then the toggle: the pane that was open comes back")
    }

    /// Settings is its own window, so it is never the pane the toggle brings
    /// back; with nothing else recent the toggle opens Chat.
    func test_theTitleBarToggleSkipsSettingsAndFallsBackToChat() {
        SidebarStateStore.shared.replaceRecents(["settings"])
        let m = model()
        m.togglePane()
        XCTAssertEqual(m.pane, .chat)
    }

    /// R5.7: every open writes the key it opened, so a later request for the
    /// same key from any source is a change the root sees; and a request for
    /// the pane already open does nothing at all.
    func test_everyOpenWritesItsKeyAndTheOpenKeyIsNotReapplied() throws {
        let m = model()
        AppState.shared.requestedTab = PanelKeys.none
        m.perform(.open(tabKey: "calendar"))
        XCTAssertEqual(AppState.shared.requestedTab, "calendar", "a Now row did not write the key it opened")
        m.openKey("notes", via: .recent)
        XCTAssertEqual(AppState.shared.requestedTab, "notes", "a Recent chip did not write the key it opened")
        m.open(.chat, via: .input)
        XCTAssertEqual(AppState.shared.requestedTab, "chat", "the input did not write the key it opened")

        let before = try openLines().count
        m.applyRequested("chat")
        XCTAssertEqual(try openLines().count, before, "re-requesting the open pane recorded another open")
        XCTAssertEqual(m.pane, .chat)
    }

    /// R5.6: a request that arrives while onboarding presents is held, in the
    /// model and in a rendered root, and honored once onboarding is done.
    func test_aTabRequestedDuringOnboardingOpensAfterIt() {
        let m = model()
        m.onboardingPresenting = true
        m.applyRequested("calendar")
        XCTAssertNil(m.pane, "nothing opens over onboarding")
        m.onboardingPresenting = false
        XCTAssertEqual(m.pane, .calendar, "the request is honored once onboarding is done")

        OnboardingModel.shared.reset()
        XCTAssertTrue(OnboardingModel.shared.isPresenting, "the suite could not put onboarding on screen")
        let rendered = model()
        AppState.shared.requestedTab = PanelKeys.none
        let host = NSHostingView(rootView: CommandPanelRoot(model: rendered).environmentObject(AppState.shared)
            .frame(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        pump(until: { rendered.onboardingPresenting })
        XCTAssertTrue(rendered.onboardingPresenting, "the root did not tell the model onboarding is up")
        AppState.shared.requestedTab = "calendar"
        pump(until: { false }, seconds: 0.2)
        XCTAssertNil(rendered.pane, "a pane opened over onboarding")
        OnboardingModel.shared.finish(skippedFirstLook: true)
        pump(until: { rendered.pane == .calendar })
        XCTAssertEqual(rendered.pane, .calendar, "the request made during onboarding was lost")
        window.contentView = nil
    }

    /// R10.4: starting onboarding over from a pane (Settings, "Start over")
    /// must not leave that pane's key behind to reopen once the flow is done.
    func test_aLeftoverKeyIsClearedWhenOnboardingStarts() {
        if OnboardingModel.shared.isPresenting { OnboardingModel.shared.finish(skippedFirstLook: true) }
        let rendered = model()
        AppState.shared.requestedTab = PanelKeys.none
        let host = NSHostingView(rootView: CommandPanelRoot(model: rendered).environmentObject(AppState.shared)
            .frame(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        pump(until: { false }, seconds: 0.2)
        AppState.shared.requestedTab = "settings"
        pump(until: { rendered.pane == .settings })
        XCTAssertEqual(rendered.pane, .settings, "the suite could not open the settings pane")

        OnboardingModel.shared.reset()
        pump(until: { rendered.onboardingPresenting && AppState.shared.requestedTab == PanelKeys.none })
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none, "the leftover key survived onboarding starting")
        OnboardingModel.shared.finish(skippedFirstLook: true)
        pump(until: { rendered.pane == nil })
        XCTAssertNil(rendered.pane, "the pane open before onboarding came back after it")
        window.contentView = nil
    }

    // MARK: What an open records

    func test_openingRecordsARecentAndAnOpen() throws {
        OpensLog.shared.flush()
        try? FileManager.default.removeItem(at: OpensLog.shared.fileURL)
        let m = model()
        m.open(.notes, via: .palette)
        XCTAssertEqual(SidebarStateStore.shared.recents.first, "notes")
        let lines = try openLines()
        XCTAssertEqual(lines.count, 1, "one open, one line: \(lines)")
        XCTAssertEqual(lines.last?["key"], "notes")
        XCTAssertEqual(lines.last?["via"], "palette")
    }

    /// R3.4: a caller that opens through requestedTab names its door first,
    /// and the panel spends that name once.
    func test_aRequestCarriesTheDoorItCameThrough() throws {
        let m = model()
        OpensLog.shared.nextVia = .palette
        m.applyRequested("contacts")
        XCTAssertNil(OpensLog.shared.nextVia, "the door was not consumed")
        XCTAssertEqual(try openLines().last?["via"], "palette")
        m.applyRequested("calendar")
        XCTAssertEqual(try openLines().last?["via"], "trigger", "a request with no named door is a trigger")
    }

    /// Sending from the input while Chat is up opens Chat again: that is no
    /// open, and no recent, or every message would write a line.
    func test_openingThePaneAlreadyOpenCountsNothing() throws {
        OpensLog.shared.flush()
        try? FileManager.default.removeItem(at: OpensLog.shared.fileURL)
        let m = model()
        m.open(.chat, via: .input)
        SidebarStateStore.shared.recordRecent("notes")
        m.open(.chat, via: .input)
        m.openKey("chat", via: .recent)
        XCTAssertEqual(try openLines().count, 1, "opening the pane already open counted an open")
        XCTAssertEqual(SidebarStateStore.shared.recents.first, "notes", "opening the pane already open moved its recent")
        XCTAssertEqual(m.pane, .chat)
    }

    /// A door named for a request that never came (the request was no
    /// change) is spent by the next open, whatever door that one came
    /// through, so a later unrelated open cannot inherit it.
    func test_aDoorNamedButNeverRequestedIsSpentByTheNextOpen() throws {
        let m = model()
        OpensLog.shared.nextVia = .palette
        m.open(.notes, via: .now)
        XCTAssertNil(OpensLog.shared.nextVia, "an open left a named door pending")
        m.applyRequested("calendar")
        XCTAssertEqual(try openLines().last?["via"], "trigger", "a later request inherited a stale door")

        OpensLog.shared.nextVia = .hub
        m.open(.calendar, via: .now)
        XCTAssertNil(OpensLog.shared.nextVia, "opening the pane already open left a named door pending")
    }

    /// R5.12: one call site records an open, so no door is counted twice.
    func test_onlyThePanelModelRecordsOpens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "the scan found too few sources to trust")
        var sites: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = text.components(separatedBy: "OpensLog.shared.record(").count - 1
            if n > 0 { sites.append("\(url.lastPathComponent) x\(n)") }
        }
        XCTAssertEqual(sites, ["CommandPanelRoot.swift x1"])
    }

    // MARK: Actions

    func test_actionsRoute() {
        let m = model()
        m.perform(.open(tabKey: "calendar"))
        XCTAssertEqual(m.pane, .calendar)
        m.perform(.openApprovals)
        XCTAssertTrue(ApprovalsTrayState.shared.isOpen)
        m.perform(.openWorkOrder(id: "wo-x"))
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
        XCTAssertEqual(OptimizeHubState.shared.highlightedOrder, "wo-x")
        OptimizeHubState.shared.isExpanded = false
        m.perform(.openOptimize)
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
        m.perform(.setup(featureId: "mailbox"))
        XCTAssertEqual(m.pane, .mailbox, "a setup gap opens the surface, whose gate shows the card")
        m.perform(.setup(featureId: "integrations.webhooks"))
        XCTAssertEqual(m.pane, .integrations, "a row with no tab of its own opens the surface that holds it")
    }

    /// R2.6: a job row opens that job's window, and a job the service no
    /// longer knows opens the agents list instead of nothing.
    func test_aJobRowOpensItsWindowOrFallsBackToAgents() {
        let known = PanelModel(stateProvider: { RelevanceState() }, jobExists: { $0 == "job-1" })
        var posted: String?
        let token = NotificationCenter.default.addObserver(forName: .gruxOpenAgentJobWindow, object: nil, queue: nil) {
            posted = $0.userInfo?["jobId"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        known.perform(.openJob(id: "job-1"))
        XCTAssertEqual(posted, "job-1", "the job window was not asked for")
        XCTAssertNil(known.pane)

        posted = nil
        known.perform(.openJob(id: "gone"))
        XCTAssertNil(posted)
        XCTAssertEqual(known.pane, .agents, "an unknown job did not fall back to the agents list")
    }

    // MARK: Now

    /// R5.16: Now is what the injected state says, whatever the live queue holds.
    func test_nowComesFromTheInjectedState() {
        let empty = model()
        empty.refreshNow(force: true)
        XCTAssertEqual(empty.now, [], "an empty state produced rows")

        var s = RelevanceState()
        s.approvalsPending = 2
        let two = model(s)
        two.refreshNow(force: true)
        XCTAssertEqual(two.now.map(\.id), ["approvals"])
        XCTAssertEqual(two.now.first?.title, "2 approvals waiting")
    }

    /// R5.10, R5.22: inside the window a change is not dropped: one trailing
    /// refresh is scheduled for the window's end, and only one. Driven by an
    /// injected clock and scheduler, so no wall-clock timing is involved.
    func test_aRefreshInsideTheWindowTrailsInsteadOfDropping() {
        var calls = 0
        var pending = 1
        var t = Date(timeIntervalSinceReferenceDate: 1000)
        var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        let m = PanelModel(stateProvider: {
            calls += 1
            var s = RelevanceState()
            s.approvalsPending = pending
            return s
        }, refreshInterval: 1, clock: { t }, schedule: { scheduled.append(($0, $1)) })
        m.refreshNow()
        XCTAssertEqual(calls, 1, "the first refresh did not run at once")
        pending = 3
        t = t.addingTimeInterval(0.25)
        m.refreshNow()
        m.refreshNow()
        XCTAssertEqual(calls, 1, "a refresh inside the window ran at once")
        XCTAssertEqual(scheduled.count, 1, "the change inside the window was dropped, or scheduled twice")
        XCTAssertEqual(scheduled.first?.delay ?? -1, 0.75, accuracy: 0.0001, "the trailing refresh is not at the window's end")
        t = t.addingTimeInterval(0.75)
        scheduled[0].work()
        XCTAssertEqual(calls, 2, "the trailing refresh did not run")
        XCTAssertEqual(m.now.first?.title, "3 approvals waiting")

        // A trailing refresh overtaken by a forced one does nothing.
        t = t.addingTimeInterval(0.1)
        m.refreshNow()
        XCTAssertEqual(scheduled.count, 2)
        m.refreshNow(force: true)
        XCTAssertEqual(calls, 3)
        scheduled[1].work()
        XCTAssertEqual(calls, 3, "an overtaken trailing refresh ran anyway")
    }

    /// R5.10: the calendar (a synchronous EventKit fetch) and the setup gaps
    /// (capability and keychain probes) are read on appear and on the 60 s
    /// timer, not on every throttled refresh a store change causes. Driven by
    /// the injected clock, over this Mac's fast stores.
    func test_calendarAndSetupGapsAreReadOnAppearAndOnTheTimerOnly() throws {
        var slowReads = 0
        var t = Date(timeIntervalSinceReferenceDate: 1000)
        let gap = SetupGap(featureId: "mailbox", label: "Mail", missing: "an IMAP account")
        let m = PanelModel(slowInputs: { _ in
            slowReads += 1
            return RelevanceState.SlowInputs(agenda: [], setupGaps: [gap])
        }, refreshInterval: 1, clock: { t }, schedule: { _, _ in })
        m.refreshNow(force: true, includingSlow: true)          // on appear
        XCTAssertEqual(slowReads, 1)
        XCTAssertTrue(m.now.contains { $0.action == .setup(featureId: "mailbox") }, "the slow inputs did not reach Now")
        for _ in 0..<5 {                                        // a burst of store changes
            t = t.addingTimeInterval(1.5)
            m.refreshNow()
        }
        m.refreshNow(force: true)                               // a trailing refresh
        XCTAssertEqual(slowReads, 1, "a store change re-read the calendar and the setup gaps")
        XCTAssertTrue(m.now.contains { $0.action == .setup(featureId: "mailbox") }, "a fast refresh dropped the cached gaps")
        t = t.addingTimeInterval(60)
        m.refreshNow(force: true, includingSlow: true)          // the timer
        XCTAssertEqual(slowReads, 2, "the timer did not re-read them")

        let root = try sources("Sources/Grux/Shell/CommandPanelRoot.swift")
        XCTAssertEqual(root.components(separatedBy: "refreshNow(force: true, includingSlow: true)").count - 1, 3,
                       "appear, the 60 s timer and the end of onboarding each re-read the slow inputs")
    }

    // MARK: Window sizing

    /// The shell asks for panelWidth with no pane and panelWidth + paneWidth
    /// with one, with the matching minimum, and only when the state flips.
    func test_theShellAsksForThePaneWidths() {
        var asked: [[CGFloat]] = []
        let m = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { asked.append([$0, $1]) })
        let rest = [GruxLayout.panelWidth, GruxLayout.panelWidth]
        let open = [GruxLayout.panelWidth + GruxLayout.paneWidth, GruxLayout.panelWidth + GruxLayout.detailContentMin]
        m.sizeForPane()
        XCTAssertEqual(asked, [rest], "the first pass did not size the panel")
        m.open(.notes, via: .now)
        m.sizeForPane()
        XCTAssertEqual(asked.last, open)
        m.open(.calendar, via: .now)
        m.sizeForPane()
        XCTAssertEqual(asked.count, 2, "swapping panes resized the window")
        m.closePane()
        m.sizeForPane()
        XCTAssertEqual(asked.last, rest)
    }

    /// A pane with a real minimum asks the window for it when it opens, and a
    /// swap moves only the floor: into a pane that needs more the window grows
    /// to it, back into an ordinary one the floor drops and the width stays.
    func test_aPaneWithARealMinimumRaisesTheWindowFloor() {
        var asked: [[CGFloat]] = []
        var floors: [CGFloat] = []
        let wide = GruxLayout.paneWidth - GruxSpacing.xl
        let m = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { asked.append([$0, $1]) },
                           floorWidth: { floors.append($0) },
                           paneMinimum: { $0 == .cognitionMap ? wide : GruxLayout.detailContentMin })
        m.sizeForPane()
        m.open(.cognitionMap, via: .now)
        m.sizeForPane()
        XCTAssertEqual(asked.last, [GruxLayout.panelWidth + GruxLayout.paneWidth, GruxLayout.panelWidth + wide],
                       "opening a pane with a minimum did not ask for it")
        m.open(.notes, via: .now)
        m.sizeForPane()
        XCTAssertEqual(floors, [GruxLayout.panelWidth + GruxLayout.detailContentMin], "the floor did not drop on the swap")
        m.open(.calendar, via: .now)
        m.sizeForPane()
        XCTAssertEqual(floors.count, 1, "a swap between two ordinary panes asked the window for something")
        m.open(.cognitionMap, via: .now)
        m.sizeForPane()
        XCTAssertEqual(floors.last, GruxLayout.panelWidth + wide, "swapping into the wider pane did not raise the floor")
        XCTAssertEqual(asked.count, 2, "a swap resized the window instead of moving its floor")
    }

    /// The width floor grows a narrower window to it and leaves a wider one.
    func test_theWidthFloorGrowsANarrowWindowAndLeavesAWideOne() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let floor = GruxLayout.panelWidth + GruxLayout.paneWidth
        LaunchWindowSizer(window: win).setMinimumWidth(floor)
        XCTAssertEqual(win.contentMinSize.width, floor)
        XCTAssertEqual(win.contentLayoutRect.width, floor, accuracy: 0.5, "a narrower window did not grow to the floor")
        let wider = floor + GruxLayout.detailContentMin
        AppDelegate.setContentWidth(of: win, to: wider, minWidth: floor, animated: false)
        LaunchWindowSizer(window: win).setMinimumWidth(GruxLayout.panelWidth + GruxLayout.detailContentMin)
        XCTAssertEqual(win.contentLayoutRect.width, wider, accuracy: 0.5, "a lower floor shrank the window")
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth + GruxLayout.detailContentMin)
    }

    /// R5.17: onboarding asks for its own width on a rendered root, and the
    /// shell gives the panel width back when it ends.
    func test_onboardingAsksForItsWidthAndTheShellGivesItBack() throws {
        XCTAssertTrue(try sources("Sources/Grux/Onboarding/OnboardingView.swift")
            .contains("minWidth: GruxLayout.onboardingMinWidth"), "OnboardingView does not read the token")
        var asked: [[CGFloat]] = []
        let m = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { asked.append([$0, $1]) })
        OnboardingModel.shared.reset()
        XCTAssertTrue(OnboardingModel.shared.isPresenting, "the suite could not put onboarding on screen")
        let host = NSHostingView(rootView: CommandPanelRoot(model: m).environmentObject(AppState.shared)
            .frame(width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelIdealHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        pump(until: { !asked.isEmpty })
        XCTAssertGreaterThanOrEqual(asked.first?.first ?? 0, GruxLayout.onboardingMinWidth,
                                    "onboarding did not ask for its width: \(asked)")
        XCTAssertGreaterThanOrEqual(asked.first?.last ?? 0, GruxLayout.onboardingMinWidth,
                                    "onboarding did not raise the minimum: \(asked)")
        OnboardingModel.shared.finish(skippedFirstLook: true)
        pump(until: { asked.last == [GruxLayout.panelWidth, GruxLayout.panelWidth] })
        XCTAssertEqual(asked.last, [GruxLayout.panelWidth, GruxLayout.panelWidth],
                       "the panel width did not come back after onboarding: \(asked)")
        window.contentView = nil
    }

    // MARK: Scrolling

    /// R9.6: the Now list and the Optimize card scroll between a fixed head
    /// and input above and a fixed foot below, so an expanded card never
    /// pushes the foot off a short window. Pinned on the source with runs of
    /// whitespace collapsed (R4.1 style).
    func test_theMiddleScrollsAndTheFootStaysOutsideIt() throws {
        let text = try sources("Sources/Grux/Shell/CommandPanelRoot.swift")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let panelStart = try XCTUnwrap(text.range(of: "private var panel: some View {"), "no panel view").upperBound
        let panelEnd = try XCTUnwrap(text.range(of: "private func paneColumn", range: panelStart..<text.endIndex)).lowerBound
        let panel = String(text[panelStart..<panelEnd])
        let scroll = try XCTUnwrap(panel.range(of: "ScrollView"), "the panel's middle does not scroll")
        let open = try XCTUnwrap(panel[scroll.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var close = open
        for i in panel[open...].indices {
            if panel[i] == "{" { depth += 1 }
            if panel[i] == "}" { depth -= 1; if depth == 0 { close = i; break } }
        }
        XCTAssertGreaterThan(close, open, "the ScrollView block never closes")
        let inside = String(panel[open...close])
        XCTAssertTrue(inside.contains("PanelNowList("), "Now is outside the scroll")
        XCTAssertTrue(inside.contains("OptimizeHubCard()"), "the card is outside the scroll")
        for fixed in ["PanelHead(", "PanelInput(", "PanelFoot("] {
            XCTAssertFalse(inside.contains(fixed), "\(fixed) scrolls away with the middle")
        }
        let input = try XCTUnwrap(panel.range(of: "PanelInput("))
        let foot = try XCTUnwrap(panel.range(of: "PanelFoot("))
        XCTAssertLessThan(input.lowerBound, scroll.lowerBound, "the scroll is not after the input")
        XCTAssertGreaterThan(foot.lowerBound, close, "the foot is not after the scroll")
    }

    /// A theme commit must not remount the input: its `onAppear` takes focus,
    /// so a remount pulls focus out of an open pane, and it drops the draft.
    /// The theme key sits on the head, the middle and the foot; the input
    /// follows a theme by observing it. Pinned on the source with runs of
    /// whitespace collapsed (R4.1 style): focus and a draft are not reachable
    /// from a test without a key window.
    func test_aThemeCommitDoesNotRemountTheInput() throws {
        let text = try sources("Sources/Grux/Shell/CommandPanelRoot.swift")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let panelStart = try XCTUnwrap(text.range(of: "private var panel: some View {"), "no panel view").upperBound
        let panelEnd = try XCTUnwrap(text.range(of: "private func paneColumn", range: panelStart..<text.endIndex)).lowerBound
        let panel = String(text[panelStart..<panelEnd])
        let open = try XCTUnwrap(panel.firstIndex(of: "{"), "the panel has no stack")
        var depth = 0
        var close = open
        for i in panel[open...].indices {
            if panel[i] == "{" { depth += 1 }
            if panel[i] == "}" { depth -= 1; if depth == 0 { close = i; break } }
        }
        XCTAssertGreaterThan(close, open, "the panel's stack never closes")
        XCTAssertFalse(panel[close...].contains(".id("), "the whole panel, input included, is keyed on the theme")
        let input = try XCTUnwrap(panel.range(of: "PanelInput("))
        let scroll = try XCTUnwrap(panel.range(of: "ScrollView("))
        XCTAssertFalse(panel[input.lowerBound..<scroll.lowerBound].contains(".id("), "the input is keyed on the theme")
        XCTAssertEqual(panel.components(separatedBy: ".id(theme.revision)").count - 1, 3,
                       "the head, the middle and the foot no longer repaint on a theme commit")
        XCTAssertTrue(try sources("Sources/Grux/Shell/CommandPanel/PanelInput.swift").contains("ThemeConfig.shared"),
                      "the input no longer follows a theme commit")
    }

    // MARK: Settings

    /// R5.20: in the panel shell the menu bar's Settings opens the Grux
    /// Settings window, once, and does not touch the pane.
    func test_settingsOpensItsOwnWindowInThePanelShell() throws {
        let delegate = AppDelegate()
        AppState.shared.requestedTab = PanelKeys.none
        WindowOpener.openSettings(legacy: false, delegate: delegate)
        let win = try XCTUnwrap(delegate.settingsWindow, "no Settings window opened")
        XCTAssertEqual(win.title, "Grux Settings")
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none, "Settings went to a pane")
        WindowOpener.openSettings(legacy: false, delegate: delegate)
        XCTAssertTrue(delegate.settingsWindow === win, "a second Settings window opened")
        win.close()
    }

    /// One Settings window: the AppKit one the gear and the menu bar open.
    /// A SwiftUI `Window` scene for it has no caller left and still shows in
    /// the Window menu, where it opens a second Settings beside the first.
    func test_thereIsOneSettingsWindowAndNoOrphanScene() throws {
        let app = try sources("Sources/Grux/GruxApp.swift")
        XCTAssertFalse(app.contains(#"id: "settings""#), "GruxApp still declares a SwiftUI Settings scene")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "the scan found too few sources to trust")
        let callers = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains(#"openWindow(id: "settings")"#)
        }.map(\.lastPathComponent)
        XCTAssertEqual(callers, [], "something still opens the SwiftUI Settings scene")
        XCTAssertTrue(app.contains("func openSettingsWindow()"), "the one Settings window is gone")
    }

    /// R5.19: one listening toggle beside the input. The foot shows the tell
    /// and toggles nothing.
    func test_theFootShowsListeningWithoutAToggle() throws {
        let foot = try sources("Sources/Grux/Shell/CommandPanel/PanelFoot.swift")
        XCTAssertFalse(foot.contains("MicController."), "the foot toggles the microphone")
        XCTAssertTrue(foot.contains("tell.label"), "the foot does not show the tell")
        XCTAssertTrue(try sources("Sources/Grux/Shell/CommandPanel/PanelInput.swift").contains("MicController.toggle("),
                      "the input lost its mic")
    }

    /// With listening OFF (mode off, or always on without consent) the mic is
    /// not muted, so the field must not say "unmute", and the press opens
    /// Tuning instead of muting a listener that is already silent.
    func test_withListeningOffTheInputOffersTuningNotUnmute() {
        var config = AppState.shared.config
        config.listeningMode = .alwaysOn
        config.ambientConsentAcknowledged = false
        let tell = ListeningTell.resolve(mode: config.listeningModeInEffect, micMuted: false,
                                         isSpeaking: false, isThinking: false)
        XCTAssertEqual(tell, .off, "always on without consent is not listening")
        XCTAssertEqual(PanelInput.placeholder(for: .off), PanelCopy.placeholderOff)
        XCTAssertFalse(PanelInput.placeholder(for: .off).lowercased().contains("unmute"),
                       "the field offers unmute to a mic that is not muted")
        XCTAssertTrue(PanelInput.micOpensTuning(.off), "the mic press mutes a listener that is already off")
        XCTAssertEqual(PanelInput.placeholder(for: .muted), PanelCopy.placeholderMuted)
        XCTAssertFalse(PanelInput.micOpensTuning(.muted), "a muted mic must still unmute")
        XCTAssertEqual(PanelInput.placeholder(for: .armed), PanelCopy.placeholder)
        XCTAssertFalse(PanelInput.micOpensTuning(.armed))
    }

    // MARK: The root

    /// R5.13: 420 wide with no pane, wider with one.
    func test_theRootIs420WideWithNoPaneAndWiderWithOne() {
        OnboardingModel.shared.finish(skippedFirstLook: true)
        let rest = NSHostingView(rootView: CommandPanelRoot(model: model()).environmentObject(AppState.shared))
        rest.layoutSubtreeIfNeeded()
        XCTAssertEqual(rest.fittingSize.width, GruxLayout.panelWidth, "the resting panel is not panelWidth")

        let open = model()
        open.open(.notes, via: .now)
        let withPane = NSHostingView(rootView: CommandPanelRoot(defaultTab: "notes", model: open)
            .environmentObject(AppState.shared))
        withPane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(withPane.fittingSize.width, GruxLayout.panelWidth + GruxLayout.detailContentMin,
                             "a pane did not widen the root")
    }

    /// With no pane the panel reports `panel`, so a sweep can tell a closed
    /// pane from one that never opened.
    func test_closingThePaneReportsPanel() {
        OnboardingModel.shared.finish(skippedFirstLook: true)
        XCTAssertTrue(RenderedTab.fileURL.path.hasPrefix(Persistence.gruxDir.path))
        let m = model()
        m.open(.reactor, via: .now)
        let host = NSHostingView(rootView: CommandPanelRoot(defaultTab: "reactor", model: m)
            .environmentObject(AppState.shared)
            .frame(width: GruxLayout.panelWidth + GruxLayout.paneWidth, height: GruxLayout.panelIdealHeight))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth + GruxLayout.paneWidth, height: GruxLayout.panelIdealHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let read = { try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8) }
        pump(until: { read() == "reactor" })
        XCTAssertEqual(read(), "reactor")
        m.closePane()
        pump(until: { read() == PanelKeys.none })
        XCTAssertEqual(read(), PanelKeys.none, "a closed pane did not report the panel")
        window.contentView = nil
    }

    // MARK: Foot and labels

    func test_recentChipsArePinnedFirstUniqueWithoutSettingsAndCapped() {
        XCTAssertEqual(PanelFoot.chips(pinned: ["notes"],
                                       recents: ["chat", "notes", "settings", "mailbox", "calendar", "tasks", "home"]),
                       ["notes", "chat", "mailbox", "calendar", "tasks"])
        XCTAssertEqual(PanelFoot.chips(pinned: [], recents: []), [])
    }

    /// RV18: a pin saved before Terminal Focus was removed drew a dead chip forever.
    func test_aRetiredOrUnknownKeyNeverBecomesAChip() {
        XCTAssertEqual(PanelFoot.chips(pinned: ["terminalFocus", "notes"], recents: ["noSuchTab", "chat"]),
                       ["notes", "chat"])
    }

    /// RV18: the store drops unknown keys at load and writes them back as they were.
    func test_theSidebarStoreSetsAsideRetiredKeysAndKeepsThemOnDisk() {
        let saved = SidebarStateStore.FilePayload(collapsedGroups: ["door.labs"],
                                                  pinned: ["terminalFocus", "notes"],
                                                  recents: ["chat", "terminalFocus"])
        let (live, aside) = SidebarStateStore.split(saved)
        XCTAssertEqual(live.pinned, ["notes"])
        XCTAssertEqual(live.recents, ["chat"])
        XCTAssertEqual(live.collapsedGroups, ["door.labs"])
        XCTAssertEqual(aside.pinned, ["terminalFocus"])
        XCTAssertEqual(aside.recents, ["terminalFocus"])
        let written = SidebarStateStore.merged(live, aside)
        XCTAssertEqual(written.pinned, ["notes", "terminalFocus"], "kept on disk")
        XCTAssertEqual(written.recents, ["chat", "terminalFocus"])
    }

    func test_railLabelReadsTheRail() {
        XCTAssertEqual(SidebarIA.railLabel(forKey: "mailbox"), "Mail")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "designStudio"), "Studio")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "metaAds"), "Meta Ads")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "settings"), "Settings")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "workflows"), "Workflows", "a key off the rail uses the legacy label")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "tuning"), TuningCopy.title)
        XCTAssertEqual(SidebarIA.railLabel(forKey: "labs"), "Labs")
    }

    // MARK: Window

    /// The sizer moves the minimum with the pane and never leaves the content
    /// narrower than it: panelWidth alone, panelWidth + detailContentMin with a pane.
    func test_theWindowWidthAndMinimumFollowThePane() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let wide = GruxLayout.panelWidth + GruxLayout.paneWidth
        let floor = GruxLayout.panelWidth + GruxLayout.detailContentMin
        AppDelegate.setContentWidth(of: win, to: wide, minWidth: floor, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, wide, accuracy: 0.5)
        XCTAssertEqual(win.contentMinSize.width, floor)
        AppDelegate.setContentWidth(of: win, to: GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth, accuracy: 0.5)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth)
    }

    // MARK: Source guards on the new files

    private static let panelFiles = ["Sources/Grux/Shell/CommandPanelRoot.swift",
                                     "Sources/Grux/Shell/ShellRootView.swift",
                                     "Sources/Grux/Shell/CommandPanel/PanelHead.swift",
                                     "Sources/Grux/Shell/CommandPanel/PanelInput.swift",
                                     "Sources/Grux/Shell/CommandPanel/PanelNowList.swift",
                                     "Sources/Grux/Shell/CommandPanel/PanelFoot.swift"]

    /// Every string the panel shows comes from PanelCopy, and the two
    /// first-run lines are actually drawn (R5.9).
    func test_everyPanelStringLivesInPanelCopy() throws {
        let literal = try NSRegularExpression(
            pattern: #"(Text|Button|Label)\(\s*"|\.(help|accessibilityLabel)\(\s*""#)
        for file in Self.panelFiles {
            let text = try sources(file)
            let hits = literal.matches(in: text, range: NSRange(text.startIndex..., in: text)).count
            XCTAssertEqual(hits, 0, "\(file) draws a string that is not in PanelCopy")
        }
        XCTAssertTrue(try sources("Sources/Grux/Shell/CommandPanel/PanelNowList.swift").contains("PanelCopy.paletteHint"),
                      "the empty Now state does not name the palette")
        XCTAssertTrue(try sources("Sources/Grux/Shell/CommandPanel/PanelInput.swift").contains("PanelCopy.firstRunUnderInput"),
                      "the first-run line under the input is not drawn")
    }

    /// The new shell files use the design tokens only: the ratchet's four
    /// patterns, plus numeric frames, count zero in them.
    func test_theNewPanelFilesUseOnlyTokens() throws {
        let patterns = try [
            #"\.font\(\.system\(size:|\.font\(\.(largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?)\b"#,
            #"Color\.(white|black)\.opacity\(|Color\(red:|\.foregroundStyle\(\.(secondary|tertiary|primary)\)|Color\.(green|red|blue|orange|yellow|gray|purple|pink|secondary)\b"#,
            #"\.padding\((\.[a-zA-Z]+, *)?\d"#,
            #"\.cornerRadius\(\d|RoundedRectangle\(cornerRadius: *\d"#,
            #"\.frame\((width|height|minWidth|minHeight|maxWidth|maxHeight): *\d"#,
            #"\.kerning\(\d"#,
        ].map { try NSRegularExpression(pattern: $0) }
        for file in Self.panelFiles {
            let text = try sources(file)
            for p in patterns {
                let n = p.matches(in: text, range: NSRange(text.startIndex..., in: text)).count
                XCTAssertEqual(n, 0, "\(file) has \(n) literal(s) matching \(p.pattern)")
            }
        }
    }
}
