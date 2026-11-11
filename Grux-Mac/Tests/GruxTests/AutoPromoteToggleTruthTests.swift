import XCTest
@testable import Grux

/// D187 item 1 (sense pass 24): Settings, General read "Auto-promote detected
/// task to NOW" on under "Enable screen analysis" off and "Needs Screen
/// Recording first". Auto-promote acts only on what screen analysis sees
/// (`FocusWatcher`), so it can do nothing while analysis is off.
@MainActor
final class AutoPromoteToggleTruthTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every combination: on only when chosen and analysis is on and allowed.
    func test_autoPromoteReadsOnOnlyWhileScreenAnalysisRuns() {
        for choice in [true, false] {
            for analysis in [true, false] {
                for granted in [true, false] {
                    let runs = analysis && granted
                    XCTAssertEqual(AutoPromoteToggleTruth.shown(choice: choice, analysisOn: analysis, granted: granted),
                                   choice && runs, "choice \(choice) analysis \(analysis) granted \(granted)")
                    XCTAssertEqual(AutoPromoteToggleTruth.usable(analysisOn: analysis, granted: granted), runs)
                    let line = AutoPromoteToggleTruth.line(analysisOn: analysis, granted: granted)
                    if runs {
                        XCTAssertNil(line)
                    } else {
                        XCTAssertTrue(line?.contains("screen analysis") == true, line ?? "nil")
                    }
                }
            }
        }
    }

    /// The toggle on screen goes through the rule and is greyed while it cannot act.
    func test_theGeneralPaneTogglesThroughTheRule() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Toggle(\"Auto-promote detected task to NOW\"") else {
            return XCTFail("the auto-promote toggle moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(700))
        XCTAssertTrue(around.contains("AutoPromoteToggleTruth.shown("), "the toggle reads the config value alone")
        XCTAssertTrue(around.contains("AutoPromoteToggleTruth.usable("), "the toggle stays live while it cannot act")
        XCTAssertTrue(around.contains("AutoPromoteToggleTruth.line("), "no line says why it is off")
    }
}
