import XCTest
@testable import Grux
@testable import GruxAgentCore

/// Wave 13 review round 2 (c705568b...ad3004c6), each finding red first.
@MainActor
final class Wave13Round2Tests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func src(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // P2: the card read "Waiting to build" after a failed build until something
    // unrelated redrew it, because the engine published nothing; a disk hold
    // never cleared on screen. The pane observes the engine, and the hold is
    // computed once per redraw inside a once-a-minute timeline.
    func test_theCardsRedrawWhenTheRailOrTheDiskChanges() throws {
        let engine = try src("Sources/Grux/Foundry/FoundryEngine.swift")
        XCTAssertTrue(engine.contains("@Published private var building: Set<UUID>"))
        XCTAssertTrue(engine.contains("@Published private(set) var escalatedJobs: [String: UUID]"))
        let view = try src("Sources/Grux/Foundry/SelfUpgradeView.swift")
        XCTAssertTrue(view.contains("@ObservedObject private var engine = FoundryEngine.shared"))
        let pane = try XCTUnwrap(view.range(of: "private var proposalsPane: some View {"))
        let body = String(view[pane.upperBound...].prefix(1800))
        XCTAssertTrue(body.contains("TimelineView(.periodic(from: .now, by: 60))"))
        XCTAssertTrue(body.contains("let hold = engine.currentBuildHold()"))
        XCTAssertTrue(body.contains("readiness(for: card, hold: hold)"))
        XCTAssertFalse(view.contains("buildHold: FoundryEngine.shared.currentBuildHold()"), "a disk read per card per redraw")
    }

    // P3: the door said "'X' is Building, with no build left to run" of a
    // proposal whose swarm job is running.
    func test_anEscalatedProposalCountsAsInFlight() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(FoundryEngine.inFlightProposals(building: [a], escalated: ["job": b]), [a, b])
    }

    // P3: an ended escalation holds the rail only while an activated engine
    // will route it; with Foundry off it never would.
    func test_anEndedEscalationHoldsOnlyWhileTheEngineRoutes() {
        let p = UUID()
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: ["j": .done], routing: true), ["j": p])
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: ["j": .done], routing: false), [:])
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: ["j": .running], routing: false), ["j": p])
    }

    // P3: the title rule covers only jobs stored before `startedBy` existed.
    func test_aPersonsNewJobNamedFoundryStillReportsToChat() {
        let old = AgentJob(title: "foundry: x", goal: "g", createdAt: AgentService.startedByIntroduced.addingTimeInterval(-60), rootDir: "/tmp")
        XCTAssertFalse(AgentService.reportsEndToChat(old))
        let new = AgentJob(title: "foundry: tidy notes", goal: "g", createdAt: AgentService.startedByIntroduced.addingTimeInterval(60), rootDir: "/tmp")
        XCTAssertTrue(AgentService.reportsEndToChat(new))
    }

    // P3: a Settings that was already open when the link was spent is not a
    // replacement: closing the window that took it does not move it.
    func test_onlyASettingsThatAppearedAfterTheSpendGetsItBack() {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
        let t0 = Date(), pane = UUID(), window = UUID()
        state.settingsViewAppeared(now: t0)                       // the pane, open already
        state.requestedSettingsTab = "voice"
        state.settingsViewAppeared(now: t0.addingTimeInterval(1)) // the window opens
        XCTAssertEqual(state.takeSettingsRequest(now: t0.addingTimeInterval(1), appearing: true, viewID: window), "voice")
        state.settingsViewDisappeared(viewID: window, now: t0.addingTimeInterval(2))
        XCTAssertNil(state.requestedSettingsTab, "the pane jumped to the window's link")
        state.settingsViewDisappeared(viewID: pane, now: t0.addingTimeInterval(3))
    }

    // P3: a handed-back link nobody took is gone after the window, so the
    // gear never opens at it later.
    func test_aHandedBackLinkExpires() {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
        let t0 = Date(), a = UUID()
        state.requestedSettingsTab = "presets"
        state.settingsViewAppeared(now: t0)
        _ = state.takeSettingsRequest(now: t0, appearing: true, viewID: a)
        state.settingsViewAppeared(now: t0.addingTimeInterval(0.1))
        state.settingsViewDisappeared(viewID: a, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(state.requestedSettingsTab, "presets")
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(0.5 + AppState.settingsRequestWindow), appearing: true),
                     "a handback nobody took opened Settings at it later")
        while state.liveSettingsViews > 0 { state.settingsViewDisappeared(viewID: UUID()) }
    }
}
