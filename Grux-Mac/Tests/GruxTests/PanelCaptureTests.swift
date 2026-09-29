import XCTest
import SwiftUI
@testable import Grux

/// The panel at rest and the panel with the Mail pane, rendered from the
/// suite's scratch state. The committed captures come from here rather than
/// from the installed app, because the installed app shows the person's own
/// mail and names. Set GRUX_PANEL_REST_CAPTURE or GRUX_PANEL_MAIL_CAPTURE to a
/// path to write the PNG.
@MainActor
final class PanelCaptureTests: XCTestCase {
    private var savedRecents: [String] = []
    private var savedPins: [String] = []
    private var savedRequest = ""
    private var onboardingWasPresenting = false

    override func setUp() async throws {
        let store = SidebarStateStore.shared
        savedRecents = store.recents
        savedPins = store.pinned
        store.replaceRecents([])
        store.replacePins([])
        savedRequest = AppState.shared.requestedTab
        onboardingWasPresenting = OnboardingModel.shared.isPresenting
        OnboardingModel.shared.finish(skippedFirstLook: true)
        // At rest the hub is folded; finishing onboarding opens it.
        OptimizeHubState.shared.isExpanded = false
    }

    override func tearDown() async throws {
        let store = SidebarStateStore.shared
        store.replaceRecents(savedRecents)
        store.replacePins(savedPins)
        AppState.shared.requestedTab = savedRequest
        OptimizeHubState.shared.isExpanded = false
        if onboardingWasPresenting, !OnboardingModel.shared.isPresenting { OnboardingModel.shared.reset() }
    }

    /// Now from a fixed, hand-built state (R5.16): the setup gaps a fresh
    /// install shows, typed here so the capture does not depend on what
    /// another test class left in the live stores.
    static let firstRunGaps: [SetupGap] = [
        SetupGap(featureId: "mailbox", label: "Mailbox", missing: "Mail server"),
        SetupGap(featureId: "mailbox.compose", label: "Compose and send", missing: "Email sending API key"),
        SetupGap(featureId: "research", label: "Research", missing: "Web search API key"),
        SetupGap(featureId: "creative", label: "Media Studio", missing: "Replicate API token"),
        SetupGap(featureId: "meetings", label: "Meetings", missing: "Confirm you will tell people"),
        SetupGap(featureId: "focus", label: "Focus log", missing: "Anthropic API key"),
    ]

    private func model() -> PanelModel {
        let state = RelevanceState(setupGaps: Self.firstRunGaps)
        return PanelModel(stateProvider: { state }, sizeWindow: { _, _ in })
    }

    private func pump(until done: () -> Bool, seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func renderedTab() -> String? {
        try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8)
    }

    /// Hosts `root` in a window of `size` points, waits for `ready`, and
    /// returns the bitmap and its PNG, written to `env` when that is set.
    private func capture(_ root: CommandPanelRoot, size: NSSize, env: String,
                         until ready: () -> Bool) throws -> (NSBitmapImageRep, Data, CGFloat) {
        let host = NSHostingView(rootView: root.environmentObject(AppState.shared)
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(until: ready)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment[env] {
            try png.write(to: URL(fileURLWithPath: out))
        }
        let scale = window.backingScaleFactor
        window.contentView = nil
        return (rep, png, scale)
    }

    /// The resting panel: no pane, 420 x 560, reporting `panel`.
    func test_thePanelAtRestIsThePanelAlone() throws {
        let m = model()
        let size = NSSize(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let (rep, png, scale) = try capture(CommandPanelRoot(model: m), size: size,
                                            env: "GRUX_PANEL_REST_CAPTURE",
                                            until: { renderedTab() == PanelKeys.none })
        XCTAssertNil(m.pane, "the resting panel has a pane open")
        XCTAssertEqual(renderedTab(), PanelKeys.none, "the resting panel did not report the panel")
        XCTAssertEqual(rep.size, size, "the capture is not 420 x 560 points")
        XCTAssertEqual(rep.pixelsWide, Int(size.width * scale), "pixel width at scale \(scale)")
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }

    /// The panel with Mail beside it: the pane is the Mail surface, and the
    /// window is the panel plus the pane.
    func test_thePanelWithMailIsThePanelPlusTheMailPane() throws {
        let m = model()
        m.open(.mailbox, via: .now)
        let size = NSSize(width: GruxLayout.panelWidth + GruxLayout.paneWidth, height: GruxLayout.panelIdealHeight)
        let (rep, png, scale) = try capture(CommandPanelRoot(defaultTab: "mailbox", model: m), size: size,
                                            env: "GRUX_PANEL_MAIL_CAPTURE",
                                            until: { renderedTab() == "mailbox" })
        XCTAssertEqual(m.pane, .mailbox)
        XCTAssertEqual(renderedTab(), "mailbox", "the pane did not render the Mail surface")
        XCTAssertEqual(SidebarIA.railLabel(forKey: "mailbox"), "Mail", "Mail's rail label is not Mail")
        XCTAssertEqual(rep.size, size, "the capture is not the panel plus the pane")
        XCTAssertEqual(rep.pixelsWide, Int(size.width * scale), "pixel width at scale \(scale)")
        XCTAssertGreaterThan(png.count, 20_000, "the render came out empty")
    }
}
