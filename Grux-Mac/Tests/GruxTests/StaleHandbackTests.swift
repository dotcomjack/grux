import XCTest
@testable import Grux

/// D55 (wave 13 round 3 P3s).
@MainActor
final class StaleHandbackTests: XCTestCase {

    /// The pane closed in the same transaction as the double build: A hands the
    /// link back, B goes before its onChange runs. Ten minutes later a fresh
    /// "connect" link was dropped as if it were the stale handback, and a gear
    /// open inside 2 s landed on the handed-back pane.
    func test_aFreshLinkAfterAnUntakenHandbackStillLands() {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
        let t0 = Date(), a = UUID(), b = UUID()
        state.requestedSettingsTab = "models"
        state.settingsViewAppeared(now: t0)
        _ = state.takeSettingsRequest(now: t0, appearing: true, viewID: a)
        state.settingsViewAppeared(now: t0.addingTimeInterval(0.1))
        state.settingsViewDisappeared(viewID: a, now: t0.addingTimeInterval(0.5))
        state.settingsViewDisappeared(viewID: b, now: t0.addingTimeInterval(0.5))
        XCTAssertNil(state.requestedSettingsTab, "the last Settings closed and the handback still waits for the gear")
        state.requestedSettingsTab = "connect"
        state.settingsViewAppeared(now: t0.addingTimeInterval(600))
        XCTAssertEqual(state.takeSettingsRequest(now: t0.addingTimeInterval(600), appearing: true, viewID: UUID()), "connect")
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
    }

    /// The door counts only escalations whose job the store still has.
    func test_theDoorCountsOnlyEscalationsThatHold() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/Foundry/FoundryEngine.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("inFlight: Self.inFlightProposals(building: building, escalated: escalatedJobs)"))
        XCTAssertTrue(src.contains("Self.inFlightProposals(building: building, escalated: Self.holdingEscalations("))
    }
}
