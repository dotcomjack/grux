import XCTest

/// Nothing floats over a stranger's setup flow.
///
/// A brand new install put TWO panels on screen before the owner had answered a
/// single question: the Terminal Focus grid, reading "(unassigned)" because they
/// had no sessions mapped, and the workspace Focus card announcing a seeded
/// starter task they had not written. Reported from a real first launch as "the
/// terminal overlay fires and turns on at boot".
///
/// ## Two separate defects, and the second one hid behind the first fix
///
/// The launch path called `showOverlay()`, which is the USER-INTENT function and
/// carries `if !isEnabled { isEnabled = true }`. That override is right when a
/// person says "overlay on" and wrong when a timer says it: every launch
/// silently re-armed the feature kill-switch, so turning the overlay off did not
/// survive a restart.
///
/// Fixing that alone was NOT enough, and a screenshot proved it. The poll timer
/// computes visibility on its own, and a fresh install satisfies every other
/// condition the moment any Terminal window is open. So the gate lives in
/// `updateVisibility()`, the one place every trigger passes through.
///
/// This test pins both, because both were real and only one was obvious.
final class NoOverlaysDuringOnboardingTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Anti-vacuity. A test that cannot find its files passes forever in silence.
    func testTheFilesUnderTestStillExistAndStillDecideVisibility() throws {
        let tf = try source("Sources/Grux/TerminalFocusState.swift")
        XCTAssertTrue(tf.contains("shouldBeVisible"),
            "TerminalFocusState no longer computes shouldBeVisible; this guard is watching nothing.")
        let app = try source("Sources/Grux/GruxApp.swift")
        XCTAssertTrue(app.contains("FocusOverlayController.shared.show()"),
            "GruxApp no longer shows the focus overlay; re-point or delete this guard.")
    }

    /// The gate that every trigger passes through.
    func testTerminalOverlayVisibilityIsGatedOnOnboarding() throws {
        let tf = try source("Sources/Grux/TerminalFocusState.swift")
        guard let r = tf.range(of: "let shouldBeVisible") else {
            return XCTFail("shouldBeVisible is gone; the gate cannot be verified")
        }
        let window = String(tf[r.lowerBound...].prefix(400))
        XCTAssertTrue(window.contains("onboarded") || window.contains("stage == .done"), """
            Terminal Focus visibility is not gated on onboarding. A fresh install shows the \
            overlay as soon as any Terminal window is open, over the setup flow, reading \
            "(unassigned)" because the user has mapped nothing.
            """)
    }

    /// The launch path must not use the user-intent function.
    func testLaunchDoesNotForceEnableTheKillSwitch() throws {
        let app = try source("Sources/Grux/GruxApp.swift")
        XCTAssertFalse(app.contains("TerminalFocusState.shared.showOverlay()"), """
            GruxApp calls showOverlay() on the launch path. That function force-enables the \
            feature kill-switch, so "off" stops surviving a restart. Use \
            restoreOverlayAtLaunch(), which shows only what was already both enabled and \
            unhidden and mutates neither.
            """)
    }

    /// The second overlay, gated the same way.
    func testWorkspaceFocusOverlayIsGatedOnOnboarding() throws {
        let app = try source("Sources/Grux/GruxApp.swift")
        guard let r = app.range(of: "FocusOverlayState.shared.isVisible") else {
            return XCTFail("the focus overlay launch check is gone; re-point this guard")
        }
        let line = String(app[r.lowerBound...].prefix(160))
        XCTAssertTrue(line.contains("stage == .done"), """
            The workspace Focus card is shown at launch without an onboarding gate. It \
            defaults to visible on a first install, so a new user gets a floating panel over \
            setup announcing a seeded task they did not write.
            """)
    }
}
