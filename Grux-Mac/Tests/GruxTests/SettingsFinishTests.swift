import XCTest
@testable import Grux

/// Audit 2026-10-13, item 6: Settings broke names mid-word at the 361pt pane
/// floor, said "Foundry" where the rest of the app says "Self-Upgrade", named a
/// model ("Haiku") in its copy, and drew its forms in a different grey.
final class SettingsFinishTests: XCTestCase {

    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        try String(contentsOf: macRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_theNotificationCategoryIsSelfUpgrade() {
        XCTAssertEqual(TriageCategory.foundry.label, "Self-Upgrade")
        for c in TriageCategory.allCases {
            XCTAssertFalse(c.label.contains("Foundry"), c.label)
        }
    }

    func test_noModelNameInTheCopyPeopleReadWhenChoosingHowOftenGruxLooks() {
        for tier in GruxTier.allCases {
            for text in [tier.label, tier.architecture] {
                XCTAssertNil(text.range(of: "Haiku|Sonnet|Opus", options: .regularExpression), text)
            }
        }
    }

    func test_noModelNameInTheSettingsStrings() throws {
        for rel in ["Sources/Grux/SettingsView.swift", "Sources/Grux/Notifications/TriageMatrixView.swift"] {
            let lines = try source(rel).components(separatedBy: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && t.contains("\"")
            }
            let hits = lines.filter { $0.contains("Haiku") }
            XCTAssertEqual(hits, [], "\(rel) names a model in a string")
        }
    }

    /// Names never wrap: the grid goes compact instead, and only when it must.
    func test_theNotificationGridNeverBreaksAName() throws {
        let grid = try source("Sources/Grux/Notifications/TriageMatrixView.swift")
        XCTAssertTrue(grid.contains("ViewThatFits(in: .horizontal) {\n            wideGrid\n            compactGrid"),
                      "the grid lost its compact form")
        let label = try XCTUnwrap(grid.components(separatedBy: "private func categoryLabel(").dropFirst().first).prefix(400)
        XCTAssertTrue(label.contains(".lineLimit(1)") && label.contains(".fixedSize()"),
                      "a category name can wrap mid-word again")
    }

    func test_everySettingsFormWearsTheSharedBackground() throws {
        let files = ["Sources/Grux/SettingsView.swift", "Sources/Grux/Settings/TerminalSessionsSettingsView.swift",
                     "Sources/Grux/DesignSystem/AppearanceSettingsView.swift",
                     "Sources/Grux/Security/SecuritySettingsView.swift", "Sources/Grux/Backup/BackupView.swift"]
        for rel in files {
            let text = try source(rel)
            let grouped = text.components(separatedBy: ".formStyle(.grouped)\n").count - 1
            let shared = text.components(separatedBy: ".formStyle(.grouped)\n").dropFirst()
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".settingsPaneBackground()") }.count
            XCTAssertGreaterThan(grouped, 0, "\(rel) has no grouped form; the scan is reading the wrong file")
            XCTAssertEqual(shared, grouped, "\(rel) has a grouped form in its own grey")
        }
    }
}

/// Audit 2026-10-13, item 7: Notes, Documents, Labs and Tuning printed their
/// name twice in a pane, once in the pane bar and again 40pt below it.
final class PaneHeadingTests: XCTestCase {
    func test_aHeadingThatRepeatsThePaneBarIsHidden() {
        XCTAssertTrue(PaneHeading.repeats("Notes", paneTitles: ["Notes"]))
        XCTAssertTrue(PaneHeading.repeats("Tuning", paneTitles: ["tuning"]))
    }

    func test_aHeadingThatSaysSomethingElseStays() {
        XCTAssertFalse(PaneHeading.repeats("October 2026", paneTitles: PaneHeading.names(forKey: "calendar")))
        XCTAssertFalse(PaneHeading.repeats("Notes", paneTitles: []), "outside a pane the heading is the only title")
    }

    /// PR 35 review: the bar says "Mail" over a "Mailbox" header and "Studio"
    /// over "Design Studio", so those printed twice as well.
    func test_aBarsShortNameAndTheSurfacesFullNameAreTheSameTitle() {
        XCTAssertEqual(PaneHeading.names(forKey: "mailbox"), ["Mail", "Mailbox"])
        XCTAssertEqual(PaneHeading.names(forKey: "designStudio"), ["Studio", "Design Studio"])
        XCTAssertTrue(PaneHeading.repeats("Mailbox", paneTitles: PaneHeading.names(forKey: "mailbox")))
        XCTAssertTrue(PaneHeading.repeats("Design Studio", paneTitles: PaneHeading.names(forKey: "designStudio")))
        XCTAssertFalse(PaneHeading.repeats("Launch site", paneTitles: PaneHeading.names(forKey: "designStudio")),
                       "a project's own name must still show")
    }

    func test_theFourSurfacesAskBeforeDrawingTheirHeading() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        XCTAssertTrue(try src("Sources/Grux/DesignSystem/GruxToolbar.swift").contains("PaneHeading.repeats(title, paneTitles: paneTitles)"),
                      "Notes and Documents draw their toolbar title under the pane bar's")
        XCTAssertTrue(try src("Sources/Grux/Labs/LabsShelfView.swift").contains(#"PaneHeading.repeats("Labs", paneTitles: paneTitles)"#))
        XCTAssertTrue(try src("Sources/Grux/Tuning/TuningView.swift").contains("PaneHeading.repeats(TuningCopy.title, paneTitles: paneTitles)"))
        XCTAssertTrue(try src("Sources/Grux/Shell/CommandPanelRoot.swift").contains(".environment(\\.paneTitles, PaneHeading.names(forKey: key))"),
                      "the pane never tells its surface what its bar says")
    }
}

/// Audit 2026-10-13, item 8: the panel led with "Optimize Grux" in the
/// largest type it draws, above the things that need you.
final class PanelOptimizeRowTests: XCTestCase {
    func test_collapsedOptimizeIsARowAtTheNowRowsWeight() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Optimize/OptimizeHubCard.swift"), encoding: .utf8)
        let header = try XCTUnwrap(card.components(separatedBy: "Text(OptimizeCopy.title)").dropFirst().first).prefix(80)
        XCTAssertTrue(header.contains(".font(GruxType.body)"), "the Optimize row is back in title type")
        XCTAssertTrue(card.contains(".padding(.vertical, hub.isExpanded ? GruxSpacing.l : GruxSpacing.s)"),
                      "the collapsed row lost the Now row's padding")
        let now = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Shell/CommandPanel/PanelNowList.swift"), encoding: .utf8)
        XCTAssertTrue(now.contains("Text(item.title)\n                                .font(GruxType.body)"),
                      "the Now rows changed weight; the Optimize row must match them")
    }
}
