import XCTest
import AppKit
@testable import Grux

/// The pane must never clip off the right edge: opening one raises both the
/// width and the minimum, closing lowers both. `LaunchWindowSizer` is the one
/// place the launch window's width and minimum are set, so these drive it on
/// a bare window with no AppDelegate.
@MainActor
final class LaunchWindowSizingTests: XCTestCase {
    private func window(width: CGFloat, height: CGFloat = GruxLayout.panelIdealHeight) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    }

    /// Review Focus #5 (R6.4): with a pane the minimum is panelWidth +
    /// detailContentMin; with none it is panelWidth itself.
    func test_openingAPaneRaisesTheMinimumAndTheWidth() {
        let win = window(width: 380, height: 500)
        let sizer = LaunchWindowSizer(window: win)
        sizer.setContentWidth(GruxLayout.panelWidth + GruxLayout.paneWidth,
                              minWidth: GruxLayout.panelWidth + GruxLayout.detailContentMin, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth + GruxLayout.paneWidth, accuracy: 1)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth + GruxLayout.detailContentMin)
        sizer.setContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth, accuracy: 1)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth)
    }

    /// AppKit holds the minimum only for a drag. Anything else that sets the
    /// frame (a window tool, a script) can take the window under it and clip
    /// the pane, so the launch window puts its floor back after a resize.
    func test_aResizeUnderTheFloorIsPutBack() {
        let win = window(width: GruxLayout.panelWidth + GruxLayout.paneWidth)
        let sizer = LaunchWindowSizer(window: win)
        let floor = GruxLayout.panelWidth + GruxLayout.detailContentMin
        sizer.setMinimum(NSSize(width: floor, height: win.contentMinSize.height))
        var f = win.frame
        f.size.width = 629
        win.setFrame(f, display: false)
        XCTAssertLessThan(win.contentLayoutRect.width, floor, "control: setFrame ignores the minimum")
        sizer.restoreFloor()
        XCTAssertEqual(win.contentLayoutRect.width, floor, accuracy: 1)
    }

    func test_aResizeAboveTheFloorIsKept() {
        let win = window(width: GruxLayout.panelWidth + GruxLayout.paneWidth)
        let sizer = LaunchWindowSizer(window: win)
        sizer.setMinimum(NSSize(width: GruxLayout.panelWidth + GruxLayout.detailContentMin,
                                height: win.contentMinSize.height))
        sizer.restoreFloor()
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth + GruxLayout.paneWidth, accuracy: 1)
    }

    /// The frame minimum follows the content minimum, chrome included, so
    /// AppKit's own drag limit agrees with the content floor.
    func test_theFrameMinimumMatchesTheContentMinimum() {
        let win = window(width: GruxLayout.panelWidth)
        let chrome = win.frame.width - win.contentLayoutRect.width
        LaunchWindowSizer(window: win).setContentWidth(GruxLayout.panelWidth + GruxLayout.paneWidth,
                                                       minWidth: GruxLayout.panelWidth + GruxLayout.detailContentMin,
                                                       animated: false)
        XCTAssertEqual(win.minSize.width, GruxLayout.panelWidth + GruxLayout.detailContentMin + chrome)
    }

    func test_aWindowAlreadyAtTheWidthIsLeftAlone() {
        let win = window(width: GruxLayout.panelWidth)
        let before = win.frame
        LaunchWindowSizer(window: win).setContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth,
                                                       animated: false)
        XCTAssertEqual(win.frame, before)
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.panelWidth, "the minimum was not set")
    }

    /// The --win-w decision: a launch width wider than the minimum survives
    /// the panel's first sizing pass, with or without a pane; one under the
    /// minimum is raised to it.
    func test_anExplicitLaunchWidthIsKeptUnlessUnderTheMinimum() {
        let explicit: CGFloat = 900
        let rest = window(width: explicit)
        LaunchWindowSizer(window: rest).setContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth,
                                                        animated: false, keepingExplicitWidth: true)
        XCTAssertEqual(rest.contentLayoutRect.width, explicit, accuracy: 1, "the panel pass shrank --win-w")
        XCTAssertEqual(rest.contentMinSize.width, GruxLayout.panelWidth)

        let withPane = window(width: explicit)
        let paneFloor = GruxLayout.panelWidth + GruxLayout.detailContentMin
        LaunchWindowSizer(window: withPane).setContentWidth(GruxLayout.panelWidth + GruxLayout.paneWidth,
                                                            minWidth: paneFloor,
                                                            animated: false, keepingExplicitWidth: true)
        XCTAssertEqual(withPane.contentLayoutRect.width, explicit, accuracy: 1, "the pane pass grew past --win-w")
        XCTAssertEqual(withPane.contentMinSize.width, paneFloor)

        let narrow = window(width: 380)
        LaunchWindowSizer(window: narrow).setContentWidth(GruxLayout.panelWidth + GruxLayout.paneWidth,
                                                          minWidth: paneFloor,
                                                          animated: false, keepingExplicitWidth: true)
        XCTAssertEqual(narrow.contentLayoutRect.width, paneFloor, accuracy: 1, "a --win-w under the minimum was kept")
    }

    /// Onboarding pins a taller floor than the panel. A window the person
    /// shrank to the panel's floor grows to it, from the top edge, and the
    /// minimum width is left alone.
    func test_aTallerMinimumHeightGrowsAShortWindow() {
        let win = window(width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelMinHeight)
        // Room below the window on any host, so the on-screen clamp stays out of it.
        if let screen = win.screen?.visibleFrame {
            win.setFrameTopLeftPoint(NSPoint(x: screen.minX + 100, y: screen.maxY - 20))
        }
        win.contentMinSize = NSSize(width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelMinHeight)
        let top = win.frame.maxY
        LaunchWindowSizer(window: win).setMinimumHeight(GruxLayout.onboardingMinHeight)
        XCTAssertEqual(win.contentMinSize.height, GruxLayout.onboardingMinHeight, "the minimum height did not rise")
        XCTAssertEqual(win.contentMinSize.width, GruxLayout.onboardingMinWidth, "the minimum width moved")
        XCTAssertEqual(win.contentLayoutRect.height, GruxLayout.onboardingMinHeight, accuracy: 0.5,
                       "the short window was left clipping the flow")
        XCTAssertEqual(win.frame.maxY, top, accuracy: 0.5, "the window grew from its top edge")
    }

    /// A short window at the bottom of the screen grows up instead of off
    /// the screen's bottom edge (the Dock's edge on a host with the Dock there).
    func test_growingNearTheBottomStaysOnTheScreen() throws {
        let win = window(width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelMinHeight)
        let screen = try XCTUnwrap(win.screen?.visibleFrame, "no screen to clamp against")
        win.setFrameOrigin(NSPoint(x: screen.minX + 100, y: screen.minY))
        win.contentMinSize = NSSize(width: GruxLayout.onboardingMinWidth, height: GruxLayout.panelMinHeight)
        LaunchWindowSizer(window: win).setMinimumHeight(GruxLayout.onboardingMinHeight)
        XCTAssertEqual(win.contentLayoutRect.height, GruxLayout.onboardingMinHeight, accuracy: 0.5)
        XCTAssertEqual(win.frame.minY, screen.minY, accuracy: 0.5, "the window grew past the screen's bottom edge")
    }

    /// The model asks for onboarding's height floor with its width, and the
    /// shell's first pass after it gives the panel's floor back.
    func test_onboardingRaisesTheHeightFloorAndThePanelGivesItBack() {
        var heights: [CGFloat] = []
        let m = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { _, _ in },
                           floorHeight: { heights.append($0) })
        m.sizeForOnboarding()
        XCTAssertEqual(heights, [GruxLayout.onboardingMinHeight], "onboarding did not ask for its height floor")
        m.sizeForPane()
        XCTAssertEqual(heights.last, GruxLayout.panelMinHeight, "the panel's floor did not come back after onboarding")
        m.open(.notes, via: .now)
        m.sizeForPane()
        XCTAssertEqual(heights.count, 2, "opening a pane moved the height floor")
    }

    /// The AppDelegate keeps an explicit launch width for the first pass
    /// only; every later pass sizes the window to the pane state.
    func test_theExplicitLaunchWidthLastsOnePass() {
        let delegate = AppDelegate()
        let win = window(width: 900)
        delegate.launchWindow = win
        delegate.explicitLaunchWidthPending = true
        delegate.setLaunchWindowContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, 900, accuracy: 1, "the first pass overrode --win-w")
        XCTAssertFalse(delegate.explicitLaunchWidthPending, "the first pass did not consume the flag")
        delegate.setLaunchWindowContentWidth(GruxLayout.panelWidth, minWidth: GruxLayout.panelWidth, animated: false)
        XCTAssertEqual(win.contentLayoutRect.width, GruxLayout.panelWidth, accuracy: 1,
                       "the explicit width outlived the first pass")
    }
}
