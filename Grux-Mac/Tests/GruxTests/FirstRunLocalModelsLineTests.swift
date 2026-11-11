import XCTest
@testable import Grux

/// D134: first run's last screen ended "The Local Models tab has the full list",
/// but Local Models sits behind the Developer door, which is off on a new
/// install, so a stranger looked for a tab the rail does not show. The line now
/// names a way in that exists on their Mac.
@MainActor
final class FirstRunLocalModelsLineTests: XCTestCase {

    func test_behindAClosedDeveloperDoor_namesThePalette() {
        let line = HowItWorksCopy.localModelsLine(door: .developer, developerUnlocked: false)
        XCTAssertFalse(line.contains("tab"), line)
        XCTAssertEqual(line, "Local Models has the full list and can download any of them. "
                       + "Open it from the command palette, \(PaletteHotkeyConfig.spokenShortcut).")
    }

    func test_behindAnOpenDeveloperDoor_namesTheSidebarRow() {
        XCTAssertEqual(HowItWorksCopy.localModelsLine(door: .developer, developerUnlocked: true),
                       "Local Models, under Developer in the sidebar, has the full list and can download any of them.")
    }

    func test_onTheRail_isATab() {
        XCTAssertEqual(HowItWorksCopy.localModelsLine(door: .rail, developerUnlocked: false),
                       "The Local Models tab has the full list and can download any of them.")
    }

    /// Every other door is reached from the palette too, so the line never names a tab it cannot see.
    func test_everyOtherDoor_namesThePalette() {
        for door: FeatureRow.Disposition in [.studio, .labs, .brandScoped, .folds(into: "settings")] {
            XCTAssertTrue(HowItWorksCopy.localModelsLine(door: door, developerUnlocked: true)
                .contains("command palette"), "\(door)")
        }
    }

    /// A fresh install: Local Models is a Developer row and the door starts locked.
    func test_aFreshInstall_readsThePaletteLine() throws {
        XCTAssertEqual(FeatureRegistry.disposition(for: "cookbook"), .developer)
        XCTAssertFalse(GruxConfig.default.developerSurfacesUnlocked)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"))
        XCTAssertTrue(src.contains("HowItWorksCopy.localModelsLine(door: FeatureRegistry.disposition(for: \"cookbook\"),"))
    }
}
