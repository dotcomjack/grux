import XCTest
@testable import Grux

/// "All the settings tabs should be consistent padding/margin."
///
/// That was not adjustable when it was asked for, because the panes did not
/// share a number to adjust: nine sub-panes, four container shapes, six
/// hand-written `.padding()` calls. The fix is structural, so the test is too.
/// It does not check that the padding is a particular value, it checks that
/// there is only one place a value could be written.
final class SettingsChromeTests: XCTestCase {

    private func codeLines(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        // Comment lines are dropped WHOLE rather than truncated at "//".
        // Truncating is how a sibling test lost a brace after a URL-shaped
        // literal and started returning nil.
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Every Form in the Settings window wears the same chrome.
    ///
    /// This is the invariant that makes the panes agree. A new sub-pane that
    /// forgets it is the exact regression that produced the reported bug, and it
    /// now costs a red test rather than a screenshot on somebody's Mac Mini.
    func testEveryFormInSettingsRoutesThroughTheSharedChrome() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        let forms = lines.filter { $0.contains("Form {") }.count
        let chromed = lines.filter { $0.contains(".modifier(SettingsFormChrome())") }.count

        // Anti-vacuity: a scan that finds nothing must not read as a pass.
        XCTAssertGreaterThan(forms, 0, "No Form found. The scan is broken, not the file.")
        XCTAssertEqual(chromed, forms,
                       "\(forms) Form blocks, \(chromed) wearing SettingsFormChrome. "
                        + "Every Form in this file routes through the shared chrome.")
    }

    /// The chrome has to actually set the style, or it is a no-op that passes.
    ///
    /// `.formStyle(.grouped)` is the half that fixes the label column rendering
    /// outside the pane. Without it the test above would still pass on six Forms
    /// that all look equally wrong.
    func testTheSharedChromeSetsTheGroupedFormStyle() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        guard let i = lines.firstIndex(where: {
            $0.contains("private struct SettingsFormChrome: ViewModifier")
        }) else {
            return XCTFail("SettingsFormChrome was renamed or removed.")
        }
        let body = lines[i ..< min(i + 12, lines.count)].joined(separator: "\n")
        XCTAssertTrue(body.contains(".formStyle(.grouped)"),
                      "The shared chrome no longer sets a form style, so the columns "
                        + "layout is back and labels render outside the pane.")
    }

    /// The sub-panes that live in their OWN files have to agree too.
    ///
    /// The shared chrome only reaches the Forms declared inside SettingsView.
    /// Four sub-panes delegate to a view in another file, and those were exactly
    /// where the inconsistency survived: measured on the Mini 2026-08-30, Data &
    /// Security rendered its content 73pt left of where General started and 80pt
    /// wider, because BackupView was a bare ScrollView with its own padding and
    /// hand-rolled title-plus-Divider section headers.
    ///
    /// PresetsView is deliberately NOT in this list. It is a master-detail list
    /// and editor, not a settings form, and dressing it as one would be making
    /// two different things look the same rather than making one thing
    /// consistent.
    func testDelegatedSettingsPanesUseTheSameGroupedStyle() throws {
        let panes = [
            "Sources/Grux/Backup/BackupView.swift",
            "Sources/Grux/Security/SecuritySettingsView.swift",
            "Sources/Grux/Settings/TerminalSessionsSettingsView.swift",
            "Sources/Grux/DesignSystem/AppearanceSettingsView.swift",
        ]
        for path in panes {
            let lines = try codeLines(path)
            XCTAssertTrue(lines.contains { $0.contains(".formStyle(.grouped)") },
                          "\(path) does not set .formStyle(.grouped), so its tab will not "
                            + "match the others.")
        }
    }

    /// No pane may go back to hand-rolling its own padding on a Form.
    func testNoFormCarriesItsOwnBarePadding() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        let bare = lines.enumerated().filter {
            $0.element.trimmingCharacters(in: .whitespaces) == ".padding()"
                || $0.element.trimmingCharacters(in: .whitespaces) == "}.padding()"
        }
        XCTAssertTrue(bare.isEmpty,
                      "Bare .padding() is back at line(s) \(bare.map { $0.offset + 1 }). "
                        + "Padding belongs in SettingsFormChrome.")
    }
}
