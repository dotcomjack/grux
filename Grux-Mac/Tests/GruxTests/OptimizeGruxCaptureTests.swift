import XCTest
import SwiftUI
@testable import Grux

/// Optimize Grux, in pixels, from the app's own views on the suite's scratch
/// state: the sidebar header with its button, and the panel over three sample
/// orders at different stations. Writes PNGs only when
/// `GRUX_OPTIMIZE_CAPTURE_DIR` names a folder, so a normal run renders and
/// checks without leaving files behind.
@MainActor
final class OptimizeGruxCaptureTests: XCTestCase {

    private func render<V: View>(_ view: V, size: NSSize) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Orders sort by their `created` second. Dated explicitly rather than slept
    /// apart, so the order never depends on how fast the host is.
    private func backdate(_ order: WorkOrderStore.Order?, seconds: TimeInterval) throws {
        let o = try XCTUnwrap(order)
        let url = o.dir.appendingPathComponent("order.json")
        var meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        meta["created"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
        try JSONSerialization.data(withJSONObject: meta).write(to: url)
    }

    private func write(_ png: Data, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["GRUX_OPTIMIZE_CAPTURE_DIR"] else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func test_theSidebarHeaderCarriesTheButton_andThePanelShowsTheLine() throws {
        OnboardingModel.shared.finish(skippedFirstLook: true)
        let window = try render(LaunchRootView().environmentObject(AppState.shared), size: NSSize(width: 1040, height: 900))
        XCTAssertGreaterThan(window.count, 10_000, "the window render came out empty")
        try write(window, "optimize-window.png")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("optimize-capture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let store = WorkOrderStore(root: root)
        func ctx(_ dir: URL) -> WorkOrderContext {
            WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8",
                             installed: .release(olderSource: nil), supportDir: "/support", orderDir: dir.path)
        }
        func report(_ order: WorkOrderStore.Order?, _ lines: String) throws {
            let o = try XCTUnwrap(order)
            let h = try FileHandle(forWritingTo: o.progressFile)
            h.seekToEndOfFile(); h.write(lines.data(using: .utf8)!); try h.close()
        }
        let done = store.create(request: "Hide Meetings from the sidebar", context: ctx)
        try report(done, "requirements | hide Meetings\nanalysis | a sidebar pin setting\nreview-1 | ok\ninstall | wrote the setting\nverify | Meetings is gone\nmonitor | log clean\ndone | Meetings hidden; undo in Settings\n")
        try backdate(done, seconds: 120)
        let review = store.create(request: "change grux color accent to red", context: ctx)
        try report(review, "requirements | make the accent red everywhere\nanalysis | theme.json accentHue, no code\nreview-1 | set accentHue to 0 and restart Grux?\n")
        try backdate(review, seconds: 60)
        _ = store.create(request: "Add a pomodoro timer to Today", context: ctx)
        store.reload()
        XCTAssertEqual(store.orders.map(\.progress.stage), [.written, .reviewPlan, .done])

        let panel = try render(OptimizeGruxPanel(store: store, state: OptimizeState()).background(GruxTheme.base),
                               size: NSSize(width: 440, height: 620))
        XCTAssertGreaterThan(panel.count, 10_000, "the panel render came out empty")
        try write(panel, "optimize-panel.png")
        try? FileManager.default.removeItem(at: root)
    }

    /// The hub card as it opens with nothing proposed (every shipped proposal
    /// has retired itself), over three orders: one moving, one quiet for an
    /// hour, one done. Written as optimize-hub-card.png.
    func test_theCardWithNoProposalAndLiveOrdersRenders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hub-capture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkOrderStore(root: root)
        func ctx(_ dir: URL) -> WorkOrderContext {
            WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8",
                             installed: .release(olderSource: nil), supportDir: "/support", orderDir: dir.path)
        }
        func report(_ order: WorkOrderStore.Order?, _ lines: String) throws {
            let o = try XCTUnwrap(order)
            let h = try FileHandle(forWritingTo: o.progressFile)
            h.seekToEndOfFile(); h.write(Data(lines.utf8)); try h.close()
        }
        let done = store.create(request: "Keep Grux on top", context: ctx)
        try report(done, "requirements | keep the panel above other windows\ninstall | built and relaunched\nverify | it stays on top\nmonitor | log clean\ncleanup | worktree and branch removed\ndone | the panel stays on top\n")
        try backdate(done, seconds: 120)
        let quiet = try XCTUnwrap(store.create(request: "make the accent baby blue", context: ctx))
        // Written an hour ago, and not a line since.
        let hourAgo = Date().addingTimeInterval(-3600)
        let metaURL = quiet.dir.appendingPathComponent("order.json")
        var meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        meta["created"] = ISO8601DateFormatter().string(from: hourAgo)
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
        try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: quiet.progressFile.path)
        let moving = store.create(request: "Hide Meetings from the sidebar", context: ctx)
        try report(moving, "requirements | hide Meetings\nanalysis | a sidebar pin setting\nreview-1 | ok\nbuild | adding the setting\n")
        store.reload()
        XCTAssertEqual(store.orders.first { $0.id == quiet.id }?.isWaiting(), true, "the quiet order does not read as waiting")

        let hub = OptimizeHubState(proposals: [], store: store)
        hub.isExpanded = true
        XCTAssertFalse(hub.showsProposal)
        let png = try render(OptimizeHubCard(store: store, hub: hub).environmentObject(AppState.shared)
                                .padding(GruxSpacing.l).background(GruxTheme.base),
                             size: NSSize(width: 420, height: 1000))
        XCTAssertGreaterThan(png.count, 10_000, "the card render came out empty")
        try write(png, "optimize-hub-card.png")

        // The Success card in the Proposed card's place: Keep Grux on top
        // exists in this build, so the card opens on it until Got it.
        store.markSeen(proposal: OptimizeProposal.keepOnTop.id)
        let success = OptimizeHubState(proposals: [.keepOnTop], store: store)
        success.isExpanded = true
        XCTAssertTrue(success.showsSuccess, "the shipped change did not open on its Success card")
        let successPNG = try render(OptimizeHubCard(store: store, hub: success).environmentObject(AppState.shared)
                                .padding(GruxSpacing.l).background(GruxTheme.base),
                              size: NSSize(width: 420, height: 1100))
        XCTAssertGreaterThan(successPNG.count, 10_000, "the Success render came out empty")
        try write(successPNG, "optimize-hub-success.png")
    }

    /// P-E-2's Tuning beside the accepted render (tuning-c.png): three cards
    /// open in turn, the link at the top of Settings, and the one on Today.
    func test_tuningRenders() throws {
        for (card, name) in [(TuningCopy.Card.acts, "tuning-acts.png"), (.alone, "tuning-alone.png"), (.spends, "tuning-spends.png")] {
            let png = try render(TuningView(open: card).background(GruxTheme.base), size: NSSize(width: 900, height: 900))
            XCTAssertGreaterThan(png.count, 10_000, "\(name) came out empty")
            try write(png, name)
        }
        let settings = try render(SettingsView().environmentObject(AppState.shared).background(GruxTheme.base),
                                  size: NSSize(width: 900, height: 700))
        XCTAssertGreaterThan(settings.count, 10_000, "the Settings render came out empty")
        try write(settings, "tuning-settings-link.png")
        // Today, with its "Tune how Grux works" link under the say-it line.
        OnboardingModel.shared.finish(skippedFirstLook: true)
        let today = try render(LaunchRootView().environmentObject(AppState.shared), size: NSSize(width: 1040, height: 900))
        try write(today, "tuning-today-link.png")
    }

    /// P-F-1's three new first-run screens beside the accepted render
    /// (first-run-a.png). The selection is put back afterwards, so a render
    /// does not decide what the next test thinks was chosen.
    func test_theFirstRunScreensRender() throws {
        let saved = FeatureSelection.stored()
        defer { if let saved { FeatureSelection.choose(saved) } else { FeatureSelection.clear() } }

        let question = try render(FirstPromptStep().background(GruxTheme.base), size: NSSize(width: 760, height: 520))
        XCTAssertGreaterThan(question.count, 10_000, "the question render came out empty")
        try write(question, "first-run-question.png")

        FeatureSelection.choose(IntentToFeatures.keyless(answer: "run my inbox and transcribe my meetings"))
        let yours = try render(YourGruxStep().background(GruxTheme.base), size: NSSize(width: 560, height: 760))
        XCTAssertGreaterThan(yours.count, 10_000, "the Here's your Grux render came out empty")
        try write(yours, "first-run-your-grux.png")

        let setup = try render(SetupStep().background(GruxTheme.base), size: NSSize(width: 560, height: 520))
        XCTAssertGreaterThan(setup.count, 10_000, "the setup render came out empty")
        try write(setup, "first-run-setup.png")
    }

    /// P-E-3's shelf beside the accepted render (labs-a.png).
    func test_theLabsShelfRenders() throws {
        let png = try render(LabsShelfView(open: { _ in }).background(GruxTheme.base), size: NSSize(width: 800, height: 560))
        XCTAssertGreaterThan(png.count, 10_000, "the shelf render came out empty")
        try write(png, "labs-shelf.png")
    }
}
