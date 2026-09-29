import XCTest
import AppKit
import SwiftUI
@testable import Grux

/// One umbrella, four doors. The copy is the contract: a stranger reads the
/// four titles and knows which door is theirs.
@MainActor
final class OptimizeHubTests: XCTestCase {
    private var savedRequest = ""

    override func setUp() async throws {
        savedRequest = AppState.shared.requestedTab
        AppState.shared.requestedTab = PanelKeys.none
        OpensLog.shared.nextVia = nil
    }

    override func tearDown() async throws {
        AppState.shared.requestedTab = savedRequest
        OpensLog.shared.nextVia = nil
    }

    /// A scratch work-order store under the suite's scratch root, never the
    /// live one, which other classes may have left orders in.
    private func scratchStore() -> WorkOrderStore {
        let root = Persistence.gruxDir.appendingPathComponent("hub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WorkOrderStore(root: root)
    }

    private func context(_ dir: URL) -> WorkOrderContext {
        WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8",
                         installed: .release(olderSource: nil), supportDir: "/support/Grux", orderDir: dir.path)
    }

    private func sourcesFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The doors

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
        XCTAssertEqual(OpensLog.shared.nextVia, .hub, "an open through a door is counted as the hub's")
        OpensLog.shared.nextVia = nil
        s.enter(.improve)
        XCTAssertEqual(AppState.shared.requestedTab, "selfUpgrade")
        XCTAssertEqual(OpensLog.shared.nextVia, .hub)
    }

    // MARK: - Rulings R8.2 to R8.7

    /// R8.2: an order already waiting at a review when the app launches opens
    /// the card on first render, not only when the count later changes.
    func test_anOrderAlreadyWaitingAtAReviewExpandsTheCardOnAppear() throws {
        let store = scratchStore()
        let order = try XCTUnwrap(store.create(request: "make the accent red", context: context))
        let handle = try FileHandle(forWritingTo: order.progressFile)
        handle.seekToEndOfFile()
        handle.write(Data("review-1 | set accentHue to 0?\n".utf8))
        try handle.close()
        store.reload()
        XCTAssertEqual(store.waitingOnYou, 1)

        let hub = OptimizeHubState()
        XCTAssertFalse(hub.isExpanded)
        let host = NSHostingView(rootView: OptimizeHubCard(store: store, hub: hub).environmentObject(AppState.shared))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while !hub.isExpanded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(hub.isExpanded, "an order waiting at launch left the card collapsed")
        store.remove(order.id)
    }

    /// R8.3: the Change door on an open card is never a no-op; each press asks
    /// the card to focus its request field, once.
    func test_theChangeDoorFocusesTheFieldEvenWhenTheCardIsOpen() {
        let s = OptimizeHubState()
        s.isExpanded = true
        XCTAssertFalse(s.focusPending)
        s.enter(.change)
        XCTAssertTrue(s.isExpanded)
        XCTAssertTrue(s.focusPending, "Change on an open card did nothing")
        s.consumeFocus()
        XCTAssertFalse(s.focusPending, "the field took focus and the request is still pending")
        s.enter(.change)
        XCTAssertTrue(s.focusPending, "a second press did nothing")
    }

    /// Fix round 1: a focus request is spent once. A later expand (a review
    /// popping the card on the poll, fire-optimize, a theme remount) must not
    /// pull typing into the work-order field, where Enter would write an order
    /// and overwrite the clipboard.
    func test_aSpentFocusIsNotReplayedWhenTheCardExpandsAgain() {
        let s = OptimizeHubState()
        s.enter(.change)
        s.consumeFocus()
        s.isExpanded = false
        s.noteReviewsWaiting(1)
        XCTAssertTrue(s.isExpanded)
        XCTAssertFalse(s.focusPending, "a review pop-open would steal keyboard focus")
        s.isExpanded = false
        s.isExpanded = true
        XCTAssertFalse(s.focusPending, "re-expanding would steal keyboard focus")
    }

    /// Fix round 1: the card spends a pending request when the field appears.
    func test_theCardSpendsAPendingFocusWhenTheFieldAppears() {
        let hub = OptimizeHubState()
        hub.enter(.change)
        XCTAssertTrue(hub.focusPending)
        let host = NSHostingView(rootView: OptimizeHubCard(store: scratchStore(), hub: hub)
            .environmentObject(AppState.shared))
        host.frame = NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while hub.focusPending, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(hub.focusPending, "the field appeared and left the request pending")
    }

    /// Fix round 1: the note belongs to the last door press. It clears on the
    /// next press and when the card collapses.
    func test_theNoteClearsOnTheNextDoorAndOnCollapse() {
        let url = Persistence.gruxDir.appendingPathComponent("handoff/x", isDirectory: true)
        let s = OptimizeHubState(handOff: { .success(url) })
        s.enter(.handOver)
        XCTAssertEqual(s.note, .handedOver(url))
        s.enter(.change)
        XCTAssertNil(s.note, "the next door press kept an old note")
        s.enter(.handOver)
        XCTAssertNotNil(s.note)
        s.isExpanded = false
        XCTAssertNil(s.note, "collapsing kept an old note")
    }

    /// R8.4: one "Copy work order" for the legacy panel and the card, and one
    /// poll. It writes the order and hands the exact file text to the copier.
    func test_copyingAWorkOrderIsOneSharedPath() throws {
        let store = scratchStore()
        var copied: [String] = []
        XCTAssertNil(store.createAndCopy("   ", copy: { copied.append($0) }), "an empty request wrote an order")
        XCTAssertTrue(copied.isEmpty)
        let order = try XCTUnwrap(store.createAndCopy("hide Meetings", copy: { copied.append($0) }))
        XCTAssertEqual(copied, [try XCTUnwrap(store.workOrderText(order))])
        store.remove(order.id)

        let card = try sourcesFile("Sources/Grux/Optimize/OptimizeHubCard.swift")
        let legacy = try sourcesFile("Sources/Grux/Optimize/OptimizeGruxView.swift")
        for (name, text) in [("card", card), ("legacy", legacy)] {
            XCTAssertTrue(text.contains("createAndCopy("), "\(name) does not use the shared copy")
            XCTAssertFalse(text.contains("create(request:"), "\(name) writes orders on its own")
            XCTAssertTrue(text.contains("pollWhileActive()"), "\(name) does not use the shared poll")
            XCTAssertFalse(text.contains(".seconds(5)"), "\(name) runs its own 5 s poll")
        }
    }

    /// R8.5: handing over shows the bundle path or the error, with no work
    /// order in the store at all.
    func test_handingOverShowsThePathOrTheError_withNoWorkOrders() {
        let bundle = Persistence.gruxDir.appendingPathComponent("handoff/20260926-101500", isDirectory: true)
        let ok = OptimizeHubState(handOff: { .success(bundle) })
        ok.enter(.handOver)
        XCTAssertTrue(ok.isExpanded)
        XCTAssertEqual(ok.note, .handedOver(bundle))

        let failing = OptimizeHubState(handOff: { .failure(HandoffBundle.Error.noConfig) })
        failing.enter(.handOver)
        guard case .failed(let message)? = failing.note else {
            return XCTFail("a failed hand over showed nothing: \(String(describing: failing.note))")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// R9.7: the note shows the bundle path with the home folder as ~, so
    /// the username never sits in the card or a screenshot of it.
    func test_theNotePathAbbreviatesTheHomeFolder() throws {
        // Built under the real home on purpose: nothing is written there, and a tilde needs a home path to abbreviate.
        let bundle = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux/handoff/20260926-101500", isDirectory: true)
        XCTAssertEqual(OptimizeCopy.displayPath(bundle), "~/.grux/handoff/20260926-101500")
        let outside = URL(fileURLWithPath: "/private/tmp/handoff/x")
        XCTAssertEqual(OptimizeCopy.displayPath(outside), "/private/tmp/handoff/x")
        let card = try sourcesFile("Sources/Grux/Optimize/OptimizeHubCard.swift")
        XCTAssertTrue(card.contains("Text(OptimizeCopy.displayPath(url))"), "the note does not use the abbreviated path")
        XCTAssertFalse(card.contains("Text(url.path)"), "the note still prints the raw path")
    }

    /// R8.6: the Improve door and the head's Foundry badge read one source,
    /// so they cannot disagree about what is waiting.
    func test_theImproveDoorShowsWhatTheFoundryBadgeShows() throws {
        XCTAssertNil(OptimizeDoor.improve.status(pendingProposals: 0), "the badge draws nothing at zero")
        XCTAssertEqual(OptimizeDoor.improve.status(pendingProposals: 1), "1 proposal waiting")
        XCTAssertEqual(OptimizeDoor.improve.status(pendingProposals: 3), "3 proposals waiting")
        for door in OptimizeDoor.allCases where door != .improve {
            XCTAssertNil(door.status(pendingProposals: 3), door.rawValue)
        }
        let badge = try sourcesFile("Sources/Grux/Foundry/SelfUpgradeView.swift")
        let card = try sourcesFile("Sources/Grux/Optimize/OptimizeHubCard.swift")
        XCTAssertTrue(badge.contains("FoundryDashboardModel.shared"))
        XCTAssertTrue(card.contains("FoundryDashboardModel.shared"), "the door reads a different source than the badge")
    }

    /// R8.7: a work order fired from outside opens the hub it will show in.
    func test_fireOptimizeExpandsTheHub() throws {
        let triggers = try sourcesFile("Sources/Grux/Triggers/AppTriggers.swift")
        let start = try XCTUnwrap(triggers.range(of: "let fireOptimize = "))
        let end = try XCTUnwrap(triggers.range(of: "fire-first-run-reset", range: start.upperBound..<triggers.endIndex))
        XCTAssertTrue(triggers[start.upperBound..<end.lowerBound].contains("if order != nil { OptimizeHubState.shared.isExpanded = true }"),
                      "fire-optimize does not open the hub, or opens it for a refused request")
    }

    func test_thePanelShowsTheCard() throws {
        let root = try sourcesFile("Sources/Grux/Shell/CommandPanelRoot.swift")
        XCTAssertTrue(root.contains("OptimizeHubCard()"), "the hub is not in the panel")
        XCTAssertFalse(root.contains("OptimizeGruxButton()"), "the legacy pill is still in the panel")
    }

    // MARK: - The proposed action

    private func words(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    private func assertNoDashes(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("\u{2014}"), "\(name) has an em dash", file: file, line: line)
        XCTAssertFalse(text.contains("\u{2013}"), "\(name) has an en dash", file: file, line: line)
    }

    /// The first proposal shipped with the app, and copy a stranger reads in
    /// one glance: a headline of five words at most, one sentence of fifteen
    /// at most, no jargon, no exclamation.
    func test_theFirstShippedProposalIsKeepGruxOnTop_andItsCopyIsShort() throws {
        let p = OptimizeProposal.keepOnTop
        XCTAssertEqual(OptimizeProposals.shipped.first, p, "the proposal left the shipped list")
        XCTAssertEqual(p.id, "keep-on-top")
        XCTAssertEqual(p.headline, "Keep Grux on top")
        XCTAssertLessThanOrEqual(words(p.headline), 5)
        XCTAssertLessThanOrEqual(words(p.line), 15, p.line)
        XCTAssertTrue(p.line.hasSuffix("."), "the line is not a sentence")
        XCTAssertEqual(p.line.filter { $0 == "." }.count, 1, "more than one sentence: \(p.line)")
        for text in [p.headline, p.line] {
            XCTAssertFalse(text.contains("!"), text)
            for jargon in ["z-index", "tier", "floating", "NSWindow"] {
                XCTAssertFalse(text.lowercased().contains(jargon.lowercased()), "jargon on the card: \(text)")
            }
            assertNoDashes(text, "card copy")
        }
        XCTAssertEqual(p.detail, OptimizeProposal.keepOnTopDetail, "the card carries a different detail than the generator")
        XCTAssertLessThanOrEqual(p.request.count, WorkOrderPrompt.maxRequest)
    }

    /// The detail is complete enough for an agent with no knowledge of this
    /// repo: the toggle, the config home, the window, the two levels, the
    /// classic shell carve-out, the acceptance checks and the red-first
    /// tests. The house rules, the build and the install come from the one
    /// template around it. And it carries nothing about this Mac.
    func test_theHandoffIsCompleteAndCarriesNothingPersonal() {
        let h = OptimizeProposal.keepOnTopDetail
        for needed in ["Keep Grux on top", "default off", "GruxConfig", "Sources/Grux/Models.swift",
                       "SettingsView.swift", "Classic sidebar", "GruxApp.swift", "openLaunchWindow",
                       "LaunchWindowSizer", "ShellRootView", "CommandPanelRoot", ".floating", ".normal",
                       "legacyShell", "Acceptance", "stays visible", "drops behind", "relaunch",
                       "red", "XCTest", "GruxType", "GruxTheme"] {
            XCTAssertTrue(h.contains(needed), "the detail never says: \(needed)")
        }
        let order = WorkOrderPrompt.build(id: "wo-x", request: OptimizeProposal.keepOnTop.request, detail: h,
                                          context: context(Persistence.gruxDir))
        for rule in ["U+2014", "U+2013", "Sources/Grux/DesignSystem", "design-ratchet.py --check", "**cleanup**"] {
            XCTAssertTrue(order.contains(rule), "the order around the detail lost: \(rule)")
        }
        assertNoDashes(h, "handoff")
        XCTAssertFalse(h.contains(NSUserName()), "the handoff carries the username")
        XCTAssertFalse(h.contains(NSHomeDirectory()), "the handoff carries the home path")
        XCTAssertFalse(h.contains(Host.current().localizedName ?? "\u{0}"), "the handoff carries the machine name")
        XCTAssertFalse(h.contains("sk-"), "the handoff carries something key shaped")
    }

    /// A proposal whose change does not exist in any build, so it stays
    /// Proposed until its own order says done.
    private let pending = OptimizeProposal(
        id: "test-pending", headline: "Test proposal", line: "A proposal for the tests.",
        request: "do the test thing", detail: "### What to add\n\nThe test thing.",
        successHeadline: "The test thing works now", successLine: "Find it in Settings, General.",
        settingsTag: nil, alreadyDone: .configKey("noSuchSettingEver"))

    private func append(_ text: String, to order: WorkOrderStore.Order) throws {
        let handle = try FileHandle(forWritingTo: order.progressFile)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    /// The proposal sits up front when the card opens. Not now hides it for
    /// this launch, across collapses; nothing is written to disk.
    func test_theProposalShowsOnExpand_andNotNowHidesItForThisLaunch() {
        let store = scratchStore()
        let s = OptimizeHubState(proposals: [self.pending], store: store)
        XCTAssertEqual(s.proposal, pending, "the proposal did not reach the state")
        XCTAssertFalse(s.showsProposal, "a collapsed card shows the proposal")
        s.isExpanded = true
        XCTAssertTrue(s.showsProposal)
        XCTAssertFalse(s.showsSuccess)
        s.dismissProposal()
        XCTAssertFalse(s.showsProposal, "Not now left the proposal up")
        s.isExpanded = false
        s.isExpanded = true
        XCTAssertFalse(s.showsProposal, "the proposal came back after a collapse")
        XCTAssertTrue(store.acknowledgedProposals.isEmpty, "Not now was written to disk")

        let none = OptimizeHubState(proposals: [], store: store)
        none.isExpanded = true
        XCTAssertFalse(none.showsProposal, "a card with nothing proposed shows a proposal")
        XCTAssertFalse(none.showsSuccess)
    }

    /// One button: it copies the work order, reads as copied for a moment,
    /// then offers again. The spoken label follows the visible one.
    func test_copyingTheFixCopiesTheHandoff_andConfirmsForAMoment() async throws {
        let store = scratchStore()
        let s = OptimizeHubState(proposals: [self.pending], store: store)
        s.isExpanded = true
        var copied: [String] = []
        XCTAssertFalse(s.proposalCopied)
        s.copyProposal(copy: { copied.append($0) }, confirmFor: .milliseconds(60))
        let order = try XCTUnwrap(store.orders.first, "no order was written")
        XCTAssertEqual(copied, [try XCTUnwrap(store.workOrderText(order))])
        XCTAssertEqual(s.note, .copied(orderId: order.id), "the card does not say which order it copied")
        XCTAssertTrue(s.proposalCopied, "the button did not confirm")
        XCTAssertEqual(OptimizeCopy.proposalButton(copied: false), "Copy the fix for your agent")
        XCTAssertEqual(OptimizeCopy.proposalButton(copied: true), "Copied. Paste it to your agent.")
        XCTAssertEqual(OptimizeCopy.proposalNotNow, "Not now")
        let deadline = Date().addingTimeInterval(2)
        while s.proposalCopied, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(s.proposalCopied, "the confirmation never went back to the offer")

        let none = OptimizeHubState(proposals: [], store: store)
        none.copyProposal(copy: { copied.append($0) }, confirmFor: .milliseconds(60))
        XCTAssertEqual(copied.count, 1, "a card with no proposal copied something")
        XCTAssertFalse(none.proposalCopied)
        XCTAssertEqual(store.orders.count, 1, "a card with no proposal wrote an order")
    }

    /// The card draws the proposal, or its Success card, above the doors,
    /// one button carries the copied label for sight and for VoiceOver alike,
    /// and the whole thing stays inside the card's width.
    func test_theCardDrawsTheProposalBeforeTheDoors() throws {
        let card = try sourcesFile("Sources/Grux/Optimize/OptimizeHubCard.swift")
        let proposal = try XCTUnwrap(card.range(of: "if hub.showsProposal"), "the card never shows the proposal")
        let success = try XCTUnwrap(card.range(of: "if hub.showsSuccess"), "the card never shows the Success card")
        let doors = try XCTUnwrap(card.range(of: "ForEach(OptimizeDoor.allCases)"))
        XCTAssertLessThan(proposal.lowerBound, doors.lowerBound, "the proposal sits under the doors")
        XCTAssertLessThan(success.lowerBound, doors.lowerBound, "the Success card sits under the doors")
        XCTAssertTrue(card.contains(".accessibilityLabel(OptimizeCopy.proposalButton(copied: hub.proposalCopied))"),
                      "the spoken label does not follow the visible one")
        XCTAssertTrue(card.contains("hub.copyProposal()"))
        XCTAssertTrue(card.contains("hub.dismissProposal()"))
        XCTAssertTrue(card.contains("hub.acknowledgeSuccess()"))
        XCTAssertTrue(card.contains("GruxTheme.successMint"), "the Success eyebrow is not the success colour")
        assertNoDashes(card, "card source")
        assertNoDashes(try sourcesFile("Sources/Grux/Optimize/OptimizeProposal.swift"), "proposal source")
    }

    /// A PROPOSAL RETIRES ITSELF. Keep Grux on top shipped as
    /// `GruxConfig.keepOnTop`, so the card must stop offering it with no
    /// dismissal and no relaunch of anything but the new build.
    func test_noProposalShowsWhoseChangeAlreadyExists() {
        XCTAssertNil(OptimizeProposals.current, "the card offers a change that already exists")
        let s = OptimizeHubState(store: scratchStore())
        s.isExpanded = true
        XCTAssertFalse(s.showsProposal, "Keep Grux on top is offered although it exists")
    }

    /// The proposed fix is a real work order: an id, a folder, a progress
    /// log, the text on the clipboard is the order's own file, and the order
    /// knows which proposal it carries out.
    func test_copyingTheFixWritesARealWorkOrder() throws {
        let store = scratchStore()
        let s = OptimizeHubState(proposals: [self.pending], store: store)
        var copied: [String] = []
        s.copyProposal(copy: { copied.append($0) }, confirmFor: .milliseconds(60))
        let text = try XCTUnwrap(copied.first, "nothing was copied")
        XCTAssertTrue(text.hasPrefix("# Grux work order wo-"), "the copied text is not a work order")
        let order = try XCTUnwrap(store.orders.first { text.contains($0.id) }, "no order was written")
        XCTAssertEqual(store.workOrderText(order), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: order.progressFile.path))
        XCTAssertTrue(text.contains("### What to add"), "the proposal's detail did not reach the order")
        XCTAssertTrue(text.contains("\(order.dir.path)/progress.log"))
        XCTAssertEqual(order.request, pending.request)
        XCTAssertEqual(order.proposalId, pending.id, "the order does not know its proposal")
        // A second press while that order is moving copies it again.
        s.copyProposal(copy: { copied.append($0) }, confirmFor: .milliseconds(60))
        XCTAssertEqual(store.orders.count, 1, "a second press started a second order")
        XCTAssertEqual(copied, [text, text])
        // Even with its text gone: the order keeps its id and its log.
        try FileManager.default.removeItem(at: order.workOrderFile)
        s.copyProposal(copy: { copied.append($0) }, confirmFor: .milliseconds(60))
        XCTAssertEqual(store.orders.map(\.id), [order.id], "a missing work-order.md started a second order")
        XCTAssertEqual(copied.count, 3)
        XCTAssertTrue(copied[2].hasPrefix("# Grux work order \(order.id)"), "the rewritten text is not the same order")
        XCTAssertTrue(FileManager.default.fileExists(atPath: order.workOrderFile.path), "the text was not written back")
    }

    /// The mechanism stays for the next proposal: the check reads the
    /// running build, and a proposal whose change is missing is still offered.
    func test_theFirstProposalWhoseChangeIsMissingIsTheOneShown() {
        XCTAssertTrue(OptimizeProposal.Retirement.configKey("keepOnTop").isDone,
                      "the check cannot see a setting this build has")
        XCTAssertFalse(OptimizeProposal.Retirement.configKey("noSuchSettingEver").isDone,
                       "the check calls a missing setting done")
        XCTAssertEqual(OptimizeProposals.current(from: [.keepOnTop, pending]), pending)
        XCTAssertNil(OptimizeProposals.current(from: [.keepOnTop]))
    }

    // MARK: - Proposed, then Success

    /// The state model: pending, running at a station, done by its log,
    /// done by the live check with no order at all, and acknowledged.
    func test_theCardStateFollowsTheOrderAndTheLiveCheck() throws {
        let store = scratchStore()
        func state(_ p: OptimizeProposal) -> ProposalCardState {
            OptimizeProposals.state(for: p, orders: store.orders, acknowledged: store.acknowledgedProposals)
        }
        XCTAssertEqual(state(pending), .proposed(station: nil), "pending")
        // Another order, not this proposal's, finishing changes nothing.
        let stranger = try XCTUnwrap(store.create(request: "hide Meetings", context: context))
        try append("done | hidden\n", to: stranger)
        let order = try XCTUnwrap(store.create(request: pending.request, proposal: pending.id, context: context))
        store.reload()
        XCTAssertEqual(state(pending), .proposed(station: .written))
        try append("build | adding it\n", to: order)
        store.reload()
        XCTAssertEqual(state(pending), .proposed(station: .build), "running")
        // A newer order that stopped does not hide the one still moving.
        let stopped = try XCTUnwrap(store.create(request: pending.request, proposal: pending.id, context: context))
        try append("stopped | out of time\n", to: stopped)
        store.reload()
        XCTAssertEqual(state(pending), .proposed(station: .build), "a stopped order hid the moving one")
        store.remove(stopped.id)
        try append("done | shipped\n", to: order)
        store.reload()
        XCTAssertEqual(state(pending), .success, "done by its log")
        XCTAssertEqual(state(.keepOnTop), .hidden, "done by the live check with no evidence here is mentioned")
        let copied = try XCTUnwrap(store.create(request: OptimizeProposal.keepOnTop.request,
                                                proposal: OptimizeProposal.keepOnTop.id, context: context))
        XCTAssertEqual(state(.keepOnTop), .success, "done by the live check, with an order and no done line")
        store.remove(copied.id)
        store.acknowledge(proposal: pending.id)
        XCTAssertEqual(state(pending), .hidden, "acknowledged")
    }

    /// Got it is kept on disk: a fresh store, as after a relaunch, still
    /// knows, and the file is never read as an order.
    func test_anAcknowledgementSurvivesAReload() {
        let first = scratchStore()
        first.acknowledge(proposal: OptimizeProposal.keepOnTop.id)
        let relaunched = WorkOrderStore(root: first.root)
        XCTAssertEqual(relaunched.acknowledgedProposals, [OptimizeProposal.keepOnTop.id])
        XCTAssertTrue(relaunched.orders.isEmpty, "the acknowledgement file was read as an order")
        let s = OptimizeHubState(proposals: [.keepOnTop], store: relaunched)
        s.isExpanded = true
        XCTAssertFalse(s.showsProposal)
        XCTAssertFalse(s.showsSuccess, "an acknowledged Success card came back after a relaunch")
    }

    /// A FRESH INSTALL SHOWS NOTHING FOR A CHANGE ITS BUILD ALREADY HAS.
    /// Keep Grux on top is in every build from now on, so without evidence
    /// that this install did the work (an order for it, or the Proposed card
    /// shown here) there is no Proposed card and no Success card: it is
    /// simply done and unmentioned.
    func test_aFreshInstallWithTheChangeInItsBuildShowsNoCardForIt() {
        XCTAssertNil(OptimizeProposals.card(from: [.keepOnTop], orders: [], acknowledged: []),
                     "a fresh install opens on Success for work it never saw")
        let store = scratchStore()
        let s = OptimizeHubState(proposals: [.keepOnTop, self.pending], store: store)
        s.isExpanded = true
        XCTAssertFalse(s.showsSuccess, "a fresh install opens on Success for work it never saw")
        XCTAssertEqual(s.proposal, pending, "the next proposal did not take the unmentioned one's place")
    }

    /// Today's real case: the person copied the fix here, the agent shipped
    /// it with no done line, and the build now has the change, so the card
    /// opens on Success. Got it closes it for good, and the next proposal
    /// takes its place; with none left the card shows neither.
    func test_gotItClosesTheSuccessCard_andTheNextProposalShows() throws {
        let store = scratchStore()
        _ = try XCTUnwrap(store.create(request: OptimizeProposal.keepOnTop.request,
                                       proposal: OptimizeProposal.keepOnTop.id, context: context))
        let s = OptimizeHubState(proposals: [.keepOnTop, self.pending], store: store)
        s.isExpanded = true
        XCTAssertTrue(s.showsSuccess, "a proposal whose change exists did not show Success")
        XCTAssertFalse(s.showsProposal)
        XCTAssertEqual(s.proposal, .keepOnTop)
        s.acknowledgeSuccess()
        XCTAssertEqual(store.acknowledgedProposals, [OptimizeProposal.keepOnTop.id])
        XCTAssertEqual(s.proposal, pending, "the next proposal did not take its place")
        XCTAssertTrue(s.showsProposal)

        let alone = OptimizeHubState(proposals: [.keepOnTop], store: store)
        alone.isExpanded = true
        XCTAssertFalse(alone.showsSuccess)
        XCTAssertFalse(alone.showsProposal, "with nothing left the card still shows a proposal")
    }

    /// The other evidence: the Proposed card was shown on this install. It
    /// is kept on disk, so after a relaunch into a build that has the change
    /// the card opens on Success, not on nothing.
    func test_aProposedCardOnceShownHereIsEvidence_acrossARelaunch() {
        let first = scratchStore()
        let shown = OptimizeHubState(proposals: [self.pending], store: first)
        shown.isExpanded = true
        XCTAssertTrue(shown.showsProposal)
        XCTAssertEqual(first.seenProposals, [pending.id], "showing the Proposed card left no evidence")
        // As after a relaunch, with the change now in the build.
        let relaunched = WorkOrderStore(root: first.root)
        XCTAssertEqual(relaunched.seenProposals, [pending.id], "the evidence did not survive a reload")
        XCTAssertEqual(OptimizeProposals.state(for: .keepOnTop, orders: [], acknowledged: [],
                                               seen: [OptimizeProposal.keepOnTop.id]), .success)
        XCTAssertEqual(OptimizeProposals.state(for: .keepOnTop, orders: [], acknowledged: [], seen: []), .hidden,
                       "a change with no evidence on this install is mentioned")
        XCTAssertTrue(relaunched.orders.isEmpty, "the evidence file was read as an order")
    }

    /// LIVE: the Proposed card turns into Success while it is on screen,
    /// the moment its order writes done. No reopen, no reload.
    func test_theProposedCardTurnsIntoSuccessWhileOnScreen() async throws {
        let store = scratchStore()
        let s = OptimizeHubState(proposals: [self.pending], store: store)
        s.isExpanded = true
        s.copyProposal(copy: { _ in }, confirmFor: .milliseconds(60))
        let order = try XCTUnwrap(store.orders.first)
        try append("install | built and relaunched\n", to: order)
        var deadline = Date().addingTimeInterval(3)
        while s.proposalStation != .install, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(s.proposalStation, .install, "the Proposed card did not follow its order's station")
        try append("done | the test thing works\n", to: order)
        deadline = Date().addingTimeInterval(3)
        while !s.showsSuccess, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(s.showsSuccess, "done did not turn the card into Success while it was open")
        XCTAssertFalse(s.showsProposal)
    }

    /// One eyebrow, one headline, one line, one button, and no dashes.
    func test_theSuccessCopyIsShortAndPlain() {
        let p = OptimizeProposal.keepOnTop
        XCTAssertEqual(OptimizeCopy.success, "Done")
        XCTAssertEqual(OptimizeCopy.gotIt, "Got it")
        XCTAssertEqual(OptimizeCopy.openSetting, "Open the setting")
        XCTAssertEqual(p.successHeadline, "Ready: Keep Grux on top", "the headline reads as a fact while the toggle is off")
        XCTAssertEqual(p.successLine, "Turn it on in Settings, General.")
        XCTAssertLessThanOrEqual(words(p.successHeadline), 5)
        XCTAssertLessThanOrEqual(words(p.successLine), 15)
        XCTAssertEqual(p.successLine.filter { $0 == "." }.count, 1, "more than one sentence")
        XCTAssertEqual(SettingsTabAliases.resolve(p.settingsTag ?? "").anchor, "general.shell",
                       "Open the setting does not land on the row with the toggle")
        for text in [OptimizeCopy.success, OptimizeCopy.gotIt, OptimizeCopy.openSetting,
                     p.successHeadline, p.successLine, OptimizeCopy.proposalStation(.build),
                     OptimizeCopy.proposalStation(.written)] {
            XCTAssertFalse(text.contains("!"), text)
            assertNoDashes(text, "success copy")
        }
    }
}
