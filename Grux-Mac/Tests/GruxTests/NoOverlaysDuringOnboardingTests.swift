import XCTest

/// Nothing floats over a stranger's setup flow.
///
/// A brand new install put the workspace Focus card on screen before the owner had
/// answered a single question, announcing a seeded starter task they had not
/// written. A second floating panel, the terminal overlay, did the same and has
/// since been removed along with its feature, so only the Focus card is pinned here.
final class NoOverlaysDuringOnboardingTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Anti-vacuity. A test that cannot find its files passes forever in silence.
    func testTheFileUnderTestStillShowsTheFocusOverlay() throws {
        let app = try source("Sources/Grux/GruxApp.swift")
        XCTAssertTrue(app.contains("FocusOverlayController.shared.show()"),
            "GruxApp no longer shows the focus overlay; re-point or delete this guard.")
    }

    /// The workspace Focus card is gated on onboarding.
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
