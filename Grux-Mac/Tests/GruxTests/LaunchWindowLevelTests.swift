import XCTest
import AppKit
@testable import Grux

/// Only the Command Panel floats. The classic sidebar shell stays at the
/// normal level whatever the toggle says.
final class LaunchWindowLevelTests: XCTestCase {
    func test_onWithThePanelFloats() {
        XCTAssertEqual(LaunchWindowSizer.level(keepOnTop: true, legacyShell: false), .floating)
    }

    func test_offWithThePanelIsNormal() {
        XCTAssertEqual(LaunchWindowSizer.level(keepOnTop: false, legacyShell: false), .normal)
    }

    func test_onWithTheClassicShellIsNormal() {
        XCTAssertEqual(LaunchWindowSizer.level(keepOnTop: true, legacyShell: true), .normal)
    }

    func test_offWithTheClassicShellIsNormal() {
        XCTAssertEqual(LaunchWindowSizer.level(keepOnTop: false, legacyShell: true), .normal)
    }

    /// RV20: Settings offers the switch only where it does something, and the
    /// caption in the classic shell says why it is off instead of promising.
    func test_theSettingsRowMatchesWhatTheShellDoes() {
        for legacy in [false, true] {
            let floats = LaunchWindowSizer.level(keepOnTop: true, legacyShell: legacy) == .floating
            XCTAssertEqual(KeepOnTopRow.isEnabled(legacyShell: legacy), floats, "legacyShell \(legacy)")
            XCTAssertEqual(KeepOnTopRow.caption(legacyShell: legacy).contains("stays above other windows"), floats,
                           "legacyShell \(legacy)")
        }
    }
}
