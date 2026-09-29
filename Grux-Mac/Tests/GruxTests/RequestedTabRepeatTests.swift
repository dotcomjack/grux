import XCTest
import SwiftUI
@testable import Grux

/// `AppState.requestedTab` is a REQUEST, and the shell only hears it on a
/// change. Measured on an installed build, 2026-09-27: "open my calendar" said
/// while first-run setup covered the window left `requestedTab` at "calendar";
/// setup finished, the shell appeared on Home, and every later "open my
/// calendar" (voice, `fire-open-tab`) set the same value again and rendered
/// nothing. The same happens after any sidebar click: ask for a tab, click
/// away, ask for it again, nothing. The pane showing and the request must not
/// disagree.
@MainActor
final class RequestedTabRepeatTests: XCTestCase {
    private func rendered() -> String? {
        try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8)
    }

    func test_askingForTheLastRequestedTab_opensItWhenThePaneShowsAnother() throws {
        OnboardingModel.shared.finish(skippedFirstLook: true, sendFirstExchange: false)
        let state = AppState.shared
        state.requestedTab = "calendar"      // asked for while the shell was not on screen
        try? FileManager.default.removeItem(at: RenderedTab.fileURL)

        let host = NSHostingView(rootView: LaunchRootView(defaultTab: "home").environmentObject(state)
            .frame(width: 1040, height: 800))
        host.frame = NSRect(x: 0, y: 0, width: 1040, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(rendered(), "home", "the shell did not open on its launch tab")

        state.requestedTab = "calendar"      // asked again
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(rendered(), "calendar", "asking for the tab again rendered nothing")
        window.contentView = nil
    }
}
