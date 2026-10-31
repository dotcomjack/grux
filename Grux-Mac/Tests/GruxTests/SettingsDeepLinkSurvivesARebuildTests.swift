import XCTest
@testable import Grux

/// D52: the first pane opened beside the panel builds its Settings twice.
/// Measured on c705568b with wake.log lines in SettingsView (9:45 PM Oct 29):
/// `settings: appearing ..., deep link models` (the first view spends it),
/// 0.7 s later `settings: appearing ..., deep link none, showing general`,
/// then the first view disappears. So `settings:models` from Today with no
/// pane open, or right after the approvals tray, showed General.
/// A Settings that goes away while another is alive hands back the link it
/// spent moments ago; the last Settings closing hands nothing back.
@MainActor
final class SettingsDeepLinkSurvivesARebuildTests: XCTestCase {
    private var state: AppState { AppState.shared }
    private var saved: String?

    override func setUp() async throws {
        saved = state.requestedSettingsTab
        state.requestedSettingsTab = nil
        _ = state.takeSettingsRequest(now: Date.distantFuture, appearing: true)
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
    }
    override func tearDown() async throws { state.requestedSettingsTab = saved }

    func test_aReplacedSettingsHandsTheLinkToItsReplacement() {
        let t0 = Date(), a = UUID(), b = UUID()
        state.requestedSettingsTab = "models"
        state.settingsViewAppeared()
        XCTAssertEqual(state.takeSettingsRequest(now: t0, appearing: true, viewID: a), "models")
        state.settingsViewAppeared()
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(0.1), appearing: true, viewID: b))
        state.settingsViewDisappeared(viewID: a, now: t0.addingTimeInterval(0.7))
        XCTAssertEqual(state.requestedSettingsTab, "models", "the replacement never hears of the link")
        XCTAssertEqual(state.takeSettingsRequest(now: t0.addingTimeInterval(0.7), viewID: b), "models")
        XCTAssertEqual(state.liveSettingsViews, 1)
    }

    /// PR 40: Settings closed and opened again from the gear opens plainly.
    func test_theLastSettingsClosingHandsNothingBack() {
        let t0 = Date(), a = UUID()
        state.requestedSettingsTab = "connect"
        state.settingsViewAppeared()
        XCTAssertEqual(state.takeSettingsRequest(now: t0, appearing: true, viewID: a), "connect")
        state.settingsViewDisappeared(viewID: a, now: t0.addingTimeInterval(0.5))
        XCTAssertNil(state.requestedSettingsTab)
        state.settingsViewAppeared()
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(1), appearing: true, viewID: UUID()))
    }

    /// On, one under and one over the window.
    func test_onlyAReplacementWithinTheWindowGetsIt() {
        for (after, handed) in [(AppState.settingsRequestWindow - 0.01, true),
                                (AppState.settingsRequestWindow, false),
                                (AppState.settingsRequestWindow + 0.01, false)] {
            state.requestedSettingsTab = nil
            let t0 = Date(), a = UUID()
            state.requestedSettingsTab = "presets"
            state.settingsViewAppeared()
            _ = state.takeSettingsRequest(now: t0, appearing: true, viewID: a)
            state.settingsViewAppeared()
            state.settingsViewDisappeared(viewID: a, now: t0.addingTimeInterval(after))
            XCTAssertEqual(state.requestedSettingsTab == "presets", handed, "\(after) s")
            state.requestedSettingsTab = nil
            while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
        }
    }

    /// A Settings that never spent the link (a closed window kept alive)
    /// going away hands nothing back.
    func test_aViewThatDidNotSpendItHandsNothingBack() {
        let t0 = Date(), a = UUID(), other = UUID()
        state.requestedSettingsTab = "voice"
        state.settingsViewAppeared()
        state.settingsViewAppeared()
        _ = state.takeSettingsRequest(now: t0, appearing: true, viewID: a)
        state.settingsViewDisappeared(viewID: other, now: t0.addingTimeInterval(0.3))
        XCTAssertNil(state.requestedSettingsTab)
    }

    func test_settingsViewReportsItsLifeAndItsID() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("state.settingsViewAppeared()"))
        XCTAssertTrue(src.contains("state.settingsViewDisappeared(viewID: viewID)"))
        XCTAssertTrue(src.contains("state.takeSettingsRequest(appearing: appearing, viewID: viewID)"))
    }
}
