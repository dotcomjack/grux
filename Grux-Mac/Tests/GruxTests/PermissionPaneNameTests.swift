import XCTest
@testable import Grux

/// D170 item 4: Focus log's setup step said "Privacy & Security ... tick Grux AI" while
/// Meetings' sibling step said "Privacy and Security ... enable Grux". System Settings
/// names the pane "Privacy & Security" and lists this app as "Grux AI" (its
/// CFBundleDisplayName), so a person following the second line looks for a pane and a
/// row that are not there under those words. Every line that points into System
/// Settings names both exactly as the Mac shows them.
final class PermissionPaneNameTests: XCTestCase {

    /// "Grux" named as the row to switch on: after a verb that turns it on, or as a step
    /// in a settings path. "Grux AI" is the name in the list.
    static let appAsRow = try! NSRegularExpression(
        pattern: #"(?:\b(?:enable|Enable|tick|Tick|grant|Grant|set|Set|Turn|turn on|Toggle|toggle|it for)|→|>|\|| Notifications,) Grux\b(?! AI)"#)

    static func pointsIntoSettings(_ line: String) -> Bool {
        line.contains("System Settings") || line.contains("Privacy & Security") || line.contains("Privacy and Security")
    }

    /// `previous` is the line before, for a step list that names System Settings
    /// on one line and the row on the next (W57-FIX P3 2).
    static func problems(in line: String, previous: String = "") -> [String] {
        guard pointsIntoSettings(line) || pointsIntoSettings(previous) else { return [] }
        var found: [String] = []
        if line.contains("Privacy and Security") { found.append("names the pane \"Privacy and Security\"; the Mac calls it \"Privacy & Security\"") }
        let range = NSRange(line.startIndex..., in: line)
        if appAsRow.firstMatch(in: line, range: range) != nil { found.append("names the row \"Grux\"; System Settings lists it as \"Grux AI\"") }
        if line.contains("tick Grux") { found.append("says tick; each app in a Privacy & Security list has a switch, so the line says turn on") }
        return found
    }

    func testTheRuleReadsBothShapes() {
        XCTAssertFalse(Self.problems(in: "Open System Settings, Privacy and Security, Microphone, and enable Grux.").isEmpty)
        XCTAssertFalse(Self.problems(in: "Open System Settings, Privacy & Security, Microphone and enable Grux.").isEmpty)
        XCTAssertFalse(Self.problems(in: "System Settings → Privacy & Security → Automation → Grux → Music.").isEmpty)
        XCTAssertFalse(Self.problems(in: "Open System Settings, Notifications, Grux, and turn them on.").isEmpty)
        XCTAssertFalse(Self.problems(in: "Open System Settings, Privacy & Security, Screen & System Audio Recording, and tick Grux AI.").isEmpty)
        XCTAssertTrue(Self.problems(in: "Open System Settings, Privacy & Security, Microphone, and turn on Grux AI.").isEmpty)
        XCTAssertTrue(Self.problems(in: "System Settings → Privacy & Security → Automation → Grux AI → Music.").isEmpty)
        XCTAssertTrue(Self.problems(in: "Grux needs the microphone to hear you. Open System Settings.").isEmpty)
        XCTAssertTrue(Self.problems(in: "let x = 1").isEmpty)
        XCTAssertFalse(Self.problems(in: "Contacts access is denied. Enable it for Grux in System Settings.").isEmpty)
        XCTAssertFalse(Self.problems(in: "  2. Toggle Grux on", previous: "  1. System Settings > Privacy & Security > Full Disk Access").isEmpty)
        XCTAssertTrue(Self.problems(in: "  3. Relaunch Grux", previous: "  2. Turn on Grux AI").isEmpty)
    }

    func testEveryPointerIntoSystemSettingsNamesThePaneAndTheRowAsTheMacDoes() throws {
        let files = try AccessibilityTrustGuardTests.swiftFiles(under: "Sources")
        XCTAssertGreaterThan(files.count, 100, "the scan found almost no sources; it is not wired up")
        var bad: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for problem in Self.problems(in: line, previous: index > 0 ? lines[index - 1] : "") {
                    bad.append("\(AccessibilityTrustGuardTests.relativePath(file)):\(index + 1) \(problem)")
                }
            }
        }
        XCTAssertTrue(bad.isEmpty, bad.joined(separator: "\n"))
    }

    func testTheSetupStepsReadTheSameWay() {
        for need in [SetupRequirement.permMicrophone, .permAccessibility, .permCalendar, .permContacts, .permFullDiskAccess,
                     .permScreenRecording, .permSystemAudio] {
            let line = need.remediation
            XCTAssertTrue(line.contains("Privacy & Security"), line)
            XCTAssertTrue(line.contains("Grux AI"), line)
        }
    }
}
