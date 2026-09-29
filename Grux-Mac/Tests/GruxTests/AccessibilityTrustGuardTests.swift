import XCTest
@testable import Grux

/// The test host is never trusted for Accessibility, and on this macOS asking
/// it anything about Accessibility raises the system "would like to control
/// this computer" dialog. Not only the prompting variant: measured 2026-09-27
/// (D-axprompt), `ScreenControlTests/testUnknownActionIsRejected`, whose only
/// Accessibility call is the non-prompting `AXIsProcessTrusted()`, brought up
/// `universalAccessAuthWarn` on every run. A suite that raises a system dialog
/// on someone else's Mac is a defect, so every trust read goes through one door
/// (`AccessibilityTrust`) that answers from `testAnswer` under XCTest, and every
/// AX element read asks that door before it touches another app.
final class AccessibilityTrustGuardTests: XCTestCase {

    static let door = "Sources/Grux/ScreenControl/AccessibilityTrust.swift"
    static let trustCalls = ["AXIsProcessTrusted"]
    static let elementReads = ["AXUIElementCreateApplication", "AXUIElementCreateSystemWide"]
    /// Files that name the calls as text (scanner fixtures), not as calls.
    static let fixtureFiles: Set<String> = ["AccessibilityTrustGuardTests.swift", "AmbientPromptGuardTests.swift"]

    static func swiftFiles(under relative: String) throws -> [URL] {
        let root = LaunchConsentGateTests.repoRoot().appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    static func relativePath(_ url: URL) -> String {
        String(url.path.dropFirst(LaunchConsentGateTests.repoRoot().path.count + 1))
    }

    func testOnlyTheTrustDoorAsksTheSystem() throws {
        let files = try Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Tests")
        XCTAssertGreaterThan(files.count, 100, "the scan found almost no sources; it is not wired up")
        for file in files where !Self.fixtureFiles.contains(file.lastPathComponent) {
            let path = Self.relativePath(file)
            guard path != Self.door else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for call in Self.trustCalls {
                let hits = AmbientPromptGuardTests.codeLines(containing: call, in: lines)
                XCTAssertTrue(hits.isEmpty,
                              "\(path) asks macOS for the Accessibility trust state directly at line(s) \(hits); use AccessibilityTrust, the one door a test run cannot reach the system through")
            }
        }
    }

    /// True when one of the `window` lines before 1-based `line` asks the door.
    static func asksTheDoor(before line: Int, in lines: [String], window: Int = 6) -> Bool {
        let start = max(0, line - 1 - window)
        return lines[start..<(line - 1)].contains { $0.contains("AccessibilityTrust.isGranted()") }
    }

    func testEveryElementReadAsksTheTrustDoorFirst() throws {
        let files = try Self.swiftFiles(under: "Sources")
        var readers = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            let reads = Self.elementReads.flatMap { AmbientPromptGuardTests.codeLines(containing: $0, in: lines) }
            for line in reads.sorted() {
                readers += 1
                XCTAssertTrue(Self.asksTheDoor(before: line, in: lines),
                              "\(Self.relativePath(file)):\(line) reads another app's Accessibility elements without asking AccessibilityTrust.isGranted() in the lines just before; an untrusted read raises the system dialog")
            }
        }
        XCTAssertGreaterThan(readers, 0, "no AX element reader found; the scan is not wired up")
    }
}

/// Under XCTest the door answers from `testAnswer` and a prompt request is only
/// counted, so no test, whatever it drives, can reach the system dialog.
final class AccessibilityTrustTestSeamTests: XCTestCase {

    override func tearDown() {
        AccessibilityTrust.testAnswer = false
        super.tearDown()
    }

    func testTheTestRunAnswersFromTheSeam() {
        AccessibilityTrust.testAnswer = true
        XCTAssertTrue(AccessibilityTrust.isGranted())
        XCTAssertTrue(ScreenControlEngine.hasAccessibility(), "the screen control check bypasses the door")
        AccessibilityTrust.testAnswer = false
        XCTAssertFalse(AccessibilityTrust.isGranted())
        XCTAssertFalse(ScreenControlEngine.hasAccessibility())
    }

    /// RV22: `isGranted()` answers `testAnswer` (false) under XCTest, so a live test
    /// that skips unless it is true never runs anywhere, granted Mac or not. Live
    /// tests go through `LiveAccessibility.require`, which has an opt-in that works.
    func testNoLiveTestSkipsOnTheTestAnswer() throws {
        let deadGates = ["XCTSkipUnless(ScreenControlEngine.hasAccessibility()", "XCTSkipUnless(AccessibilityTrust.isGranted()"]
        var hits: [String] = []
        for file in try AccessibilityTrustGuardTests.swiftFiles(under: "Tests") where file.lastPathComponent != "AccessibilityTrustGuardTests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for gate in deadGates where text.contains(gate) { hits.append("\(file.lastPathComponent): \(gate)") }
        }
        XCTAssertEqual(hits, [], "a live Accessibility test that can never run")
    }

    /// RV22: without the opt-in the gate skips, says how to turn it on, and never asks the system.
    func testTheLiveGateIsOffByDefaultAndSaysHowToRunIt() {
        XCTAssertFalse(AccessibilityTrust.liveTestsOptedIn, "this run has no opt-in")
        XCTAssertFalse(AccessibilityTrust.liveTrustForOptedInTest())
        XCTAssertTrue(LiveAccessibility.offReason.contains("GRUX_LIVE_AX_TESTS=1"))
        XCTAssertThrowsError(try LiveAccessibility.require(self)) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
    }

    func testAPromptRequestIsCountedAndNeverShown() {
        WindowFacade.headlessUnderTest = false
        defer { WindowFacade.headlessUnderTest = nil }
        let before = AccessibilityTrust.testPromptRequests
        AccessibilityTrust.testAnswer = true
        XCTAssertTrue(ScreenControlEngine.promptAccessibility())
        XCTAssertEqual(AccessibilityTrust.testPromptRequests, before + 1,
                       "the prompting path did not go through the door, so it reached the system")
    }

    /// Integrated review, P3: headless, the prompting door answered through
    /// `isGranted()`, which outside a test is `AXIsProcessTrusted()`, and on this
    /// macOS that alone can raise the dialog from an untrusted process. Headless
    /// it answers the last trust state Grux read, or false, and asks nothing.
    func testAHeadlessPromptRequestAsksTheSystemNothing() throws {
        WindowFacade.headlessUnderTest = true
        let savedKnown = AccessibilityTrust.lastKnownAnswer
        defer {
            WindowFacade.headlessUnderTest = nil
            AccessibilityTrust.lastKnownAnswer = savedKnown
        }
        AccessibilityTrust.testAnswer = true
        AccessibilityTrust.lastKnownAnswer = nil
        let before = AccessibilityTrust.testPromptRequests
        XCTAssertFalse(AccessibilityTrust.requestWithPrompt(), "headless with nothing known read a fresh trust state")
        AccessibilityTrust.lastKnownAnswer = true
        XCTAssertTrue(AccessibilityTrust.requestWithPrompt(), "headless did not answer the last known state")
        XCTAssertEqual(AccessibilityTrust.testPromptRequests, before, "headless counted a prompt it must not make")

        // The headless branch names no trust call at all.
        let door = try String(contentsOf: LaunchConsentGateTests.repoRoot()
            .appendingPathComponent(AccessibilityTrustGuardTests.door), encoding: .utf8)
        let branch = try XCTUnwrap(door.range(of: "if WindowFacade.isHeadless {"), "the headless branch moved")
        let body = door[branch.upperBound...].prefix { $0 != "}" }
        XCTAssertFalse(body.contains("isGranted") || body.contains("AXIsProcessTrusted"), String(body))
    }

    func testTheScannerSeesAReadWithNoCheckBeforeIt() {
        let planted = [
            "func title(pid: pid_t) -> String? {",
            "    let app = AXUIElementCreateApplication(pid)",
            "}",
            "func gated(pid: pid_t) -> String? {",
            "    guard AccessibilityTrust.isGranted() else { return nil }",
            "    let app = AXUIElementCreateApplication(pid)",
        ]
        XCTAssertFalse(AccessibilityTrustGuardTests.asksTheDoor(before: 2, in: planted))
        XCTAssertTrue(AccessibilityTrustGuardTests.asksTheDoor(before: 6, in: planted))
    }
}
