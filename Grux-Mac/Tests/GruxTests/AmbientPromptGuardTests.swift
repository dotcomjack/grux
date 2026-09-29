import XCTest
@testable import Grux

/// An ambient watcher starts by itself on every launch. If it asks macOS to
/// raise the Accessibility dialog, the person sees that dialog on every launch
/// until they say yes, and on a rebuilt app (a new signature) even after they
/// did. Measured 2026-09-27 on the test Mac: Accessibility listed Grux as on,
/// and the dialog still came up half a second after each launch.
///
/// The explicit paths stay: the Set up card (`CapabilityRequest`) opens the
/// right pane, and the Screen control switch (`ScreenControlEngine.
/// promptAccessibility`) may prompt because a person just asked for it.
/// Nothing under `Sources/Grux/Ambient` may call the prompting variant.
///
/// Same shape as `LaunchConsentGateTests`: walk the real source from a path
/// derived off `#filePath`, match code and not comments.
final class AmbientPromptGuardTests: XCTestCase {

    static let promptingCall = "AXIsProcessTrustedWithOptions"

    func testAmbientWatchersNeverRaiseTheAccessibilityPrompt() throws {
        let dir = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources/Grux/Ambient")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no ambient sources at \(dir.path); the scan is not wired up")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            let hits = Self.codeLines(containing: Self.promptingCall, in: lines)
            XCTAssertTrue(hits.isEmpty,
                          "\(file.lastPathComponent) raises the Accessibility prompt at line(s) \(hits); ambient watchers use AXIsProcessTrusted() and leave prompting to an explicit action")
        }
    }

    /// Calendar is the same class. Launch used to call
    /// `CalendarCorrelator.ensurePermission()` two seconds in, which asks
    /// EventKit for full access whenever nobody has answered yet: a fresh
    /// install got a Calendar dialog over onboarding, and every rebuild with a
    /// new signature got it again (measured 2026-09-27 on the test Mac:
    /// `requestFullAccessToEvents` at 10:15, 10:23 and 10:30, one per launch).
    /// The Calendar pane and the `fire-calendar` trigger still ask, because a
    /// person just opened them.
    static let launchFile = "Sources/Grux/GruxApp.swift"
    static let calendarPromptCalls = ["ensurePermission()", "requestFullAccessToEvents", "requestAccess(to: .event"]

    func testLaunchNeverRaisesTheCalendarPrompt() throws {
        let file = LaunchConsentGateTests.repoRoot().appendingPathComponent(Self.launchFile)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertFalse(lines.isEmpty, "no source at \(file.path); the scan is not wired up")
        for call in Self.calendarPromptCalls {
            let hits = Self.codeLines(containing: call, in: lines)
            XCTAssertTrue(hits.isEmpty,
                          "GruxApp.swift asks for Calendar access at line(s) \(hits) (\(call)); launch reads the state and leaves asking to the Calendar pane")
        }
    }

    /// The scanner must be able to go red, or a guard that never failed is a
    /// guard nobody confirmed is wired up.
    func testScannerSeesACallAndIgnoresAComment() {
        let planted = [
            "// AXIsProcessTrustedWithOptions is banned here",
            "    return AXIsProcessTrustedWithOptions(opts as CFDictionary)",
        ]
        XCTAssertEqual(Self.codeLines(containing: Self.promptingCall, in: planted), [2])
    }

    /// 1-based line numbers whose code (not a `//` comment) contains `needle`.
    static func codeLines(containing needle: String, in lines: [String]) -> [Int] {
        lines.enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), line.contains(needle) else { return nil }
            return index + 1
        }
    }
}
