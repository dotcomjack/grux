import XCTest
@testable import Grux

/// A window title obeys the same exclusion list a screenshot does.
///
/// `CapturePrivacy` exists to keep a password manager out of what Grux looks at. Its only
/// two readers were both in `ScreenCapture`, so `WorkspaceObserver` read the focused window
/// TITLE and never consulted it, and `ChatService` splices that title into the system prompt
/// of EVERY chat turn as ACTIVE_APP_RIGHT_NOW / LAST_APP_USER_WAS_ON.
///
/// The result: Grux composited 1Password out of a screenshot and sent
/// `1Password - Personal vault` verbatim to the model in the same session. Every default
/// pattern in that list describes a TITLE rather than a frame: "password", "api key",
/// "recovery phrase", "bank", "credit card".
final class WindowTitlePrivacyTests: XCTestCase {

    private let bundles = CapturePrivacy.defaultExcludedBundleIds
    private let patterns = CapturePrivacy.defaultExcludedTitlePatterns

    /// The rule itself, on the cases that matter.
    func testTheExclusionListCatchesWhatAWindowTitleLeaks() {
        // An excluded app, whatever its title says.
        XCTAssertNotNil(CapturePrivacy.frontmostBlockReason(
            bundleId: "com.1password.1password", windowTitle: "Personal vault",
            bundleIds: bundles, titlePatterns: patterns),
            "a password manager is not blocked by bundle id")

        // An ordinary app whose TITLE is the leak. This is the case a bundle list alone
        // never catches: a browser tab is Chrome, and the tab is the bank.
        for title in ["Chase - Bank of America", "Reset your password",
                      "AWS console - api key", "Recovery phrase backup"] {
            XCTAssertNotNil(CapturePrivacy.frontmostBlockReason(
                bundleId: "com.google.Chrome", windowTitle: title,
                bundleIds: bundles, titlePatterns: patterns),
                "\(title) reached the model")
        }

        // THE CONTROL. Without this the assertions above pass on a rule that blocks
        // everything, which would be a different bug wearing the same green tick.
        XCTAssertNil(CapturePrivacy.frontmostBlockReason(
            bundleId: "com.apple.dt.Xcode", windowTitle: "GruxApp.swift",
            bundleIds: bundles, titlePatterns: patterns),
            "an ordinary window is being withheld, so the context is useless")
    }

    /// THE ANSWER, not merely the call. The first version of this test asserted only that
    /// `WorkspaceObserver` mentioned `CapturePrivacy`, and it stayed green against a gate
    /// whose body had been reduced to `return title`. Proven by planting exactly that.
    func testTheGateActuallyWithholds() {
        let blocked = WorkspaceObserver.allowedTitle(
            bundleId: "com.1password.1password", title: "Personal vault",
            bundleIds: bundles, titlePatterns: patterns)
        XCTAssertEqual(blocked, "",
            "an excluded app's window title came back intact, so it reaches the model")

        let byTitle = WorkspaceObserver.allowedTitle(
            bundleId: "com.google.Chrome", title: "Chase - Bank of America",
            bundleIds: bundles, titlePatterns: patterns)
        XCTAssertEqual(byTitle, "", "a banking tab title came back intact")

        // THE CONTROL, again: a gate that returns "" for everything is a different bug.
        let kept = WorkspaceObserver.allowedTitle(
            bundleId: "com.apple.dt.Xcode", title: "GruxApp.swift",
            bundleIds: bundles, titlePatterns: patterns)
        XCTAssertEqual(kept, "GruxApp.swift",
            "an ordinary title is being withheld, so the context is useless")
    }

    /// And the observer actually consults it, which is the half that was missing.
    func testTheObserverRunsTitlesThroughTheList() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/WorkspaceObserver.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("CapturePrivacy.frontmostBlockReason"),
            "WorkspaceObserver never consults the capture exclusion list, so window titles "
            + "reach the model while the same window is composited out of screenshots")

        // EVERY site that stores a title, not just the first. There are three: activation,
        // the live refresh on snapshot (a browser tab switch changes the title without
        // changing the app), and the frontmost read.
        let guarded = source.components(separatedBy: "Self.allowedTitle(").count - 1
        XCTAssertGreaterThanOrEqual(guarded, 3,
            "only \(guarded) of the title reads go through the gate. A tab switch under an "
            + "already-approved bundle id is exactly how a banking page gets through.")

        // No raw assignment survives beside them.
        XCTAssertFalse(
            source.contains("lastNonGruxWindowTitle = Self.focusedWindowTitle(pid: app.processIdentifier) ?? \"\""),
            "the activation path still stores the raw title")
    }
}
