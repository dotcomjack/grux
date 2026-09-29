import XCTest
@testable import Grux

/// Every tab that HAS a registry row must consult it.
///
/// The audit that produced this found 16 of 36 tabs ungated, and the assumption
/// that they simply needed nothing was wrong: 15 of the 16 already had registry
/// rows, and FOUR of those had BLOCKING capabilities.
///
///   jaxCommand    step.agent_cli_installed, step.corpus_sources_confirmed
///   designStudio  key.anthropic
///   agents        step.agent_cli_installed
///   compare       key.anthropic, endpoint.ollama
///
/// So the registry counted them, the sidebar drew a dot on them, and opening the
/// tab explained nothing. A dot that points at a surface which then says nothing
/// is worse than no dot: it reports a problem and withholds the fix.
///
/// This test is a source scan because the failure mode is somebody adding tab 37
/// with a row and forgetting the one line, which no behavioural test would catch.
@MainActor
final class TabAdoptionTests: XCTestCase {

    /// Tabs deliberately NOT gated, each with the reason. The list is short on
    /// purpose: an exception that is not argued for is just an omission.
    ///
    /// `settings` is a hard rule rather than a judgment call. It is where every
    /// capability is fixed, so gating it would deadlock: the card would send
    /// somebody to the Settings they cannot reach.
    ///
    /// `home` is a composite of independent tiles, so one tab-level gate would
    /// hide a dozen working sections because a single registrar credential is
    /// absent. It gates per SECTION instead, which is why the domain monitor
    /// renders its own card.
    private let deliberatelyUngated: Set<String> = ["settings", "home"]

    private var launchRootSource: String {
        (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift"),
            encoding: .utf8)) ?? ""
    }

    /// The one switch that renders every tab, hosted by both shells. The gates
    /// live here; the `Tab` enum stays in `LaunchRootView`.
    private var surfacePaneSource: String {
        (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Shell/SurfacePane.swift"),
            encoding: .utf8)) ?? ""
    }

    /// A folded tab's gate moves WITH the surface, into the parent that now
    /// renders it. Skills renders inside the Chat composer (Phase C), so its
    /// gate is in ChatView, and looking for it only in SurfacePane would
    /// either fail a correct fold or push the gate back to where the surface
    /// no longer is.
    private let gateMovedWithAFold: [String: String] = [
        "skills": "Sources/Grux/ChatView.swift",
    ]

    /// The source a tab's gate has to appear in.
    private func gateSource(for tab: String) -> String {
        guard let file = gateMovedWithAFold[tab] else { return surfacePaneSource }
        return (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(file),
            encoding: .utf8)) ?? ""
    }

    /// The tab keys declared in `LaunchRootView.Tab`, read from source so the
    /// test cannot drift from the enum.
    private func declaredTabs() -> [String] {
        guard let line = launchRootSource.components(separatedBy: .newlines)
            .first(where: { $0.contains("enum Tab: Hashable") }) else { return [] }
        return line.components(separatedBy: "case ").dropFirst().joined()
            .components(separatedBy: ",")
            .map { $0.replacingOccurrences(of: "}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testTheScanFindsTheTabEnum() {
        let tabs = declaredTabs()
        // 36 since P-E-3 (2026-09-22): `labs` is the Labs door's shelf. It is
        // the door's own page, not a feature, so it has no registry row and
        // nothing to gate, the same as Roadmap.
        // 37 since P-E-2: `tuning`, a surface of dials over config, with no
        // registry row either.
        // 36 since 2026-09-27: `terminalFocus` left with the overlay it opened.
        XCTAssertEqual(tabs.count, 36, "expected 36 tabs, parsed \(tabs.count): \(tabs)")
        XCTAssertNil(FeatureRegistry.row(forTab: "labs"), "the Labs shelf grew a registry row; it would need a gate")
        XCTAssertNil(FeatureRegistry.row(forTab: "tuning"), "Tuning grew a registry row; it would need a gate")
    }

    /// The invariant: a tab with a registry row is gated, unless it is one of the
    /// two documented exceptions.
    func testEveryTabWithARegistryRowIsGated() {
        var unadopted: [String] = []

        for tab in declaredTabs() where !deliberatelyUngated.contains(tab) {
            guard FeatureRegistry.row(forTab: tab) != nil else { continue }
            if !gateSource(for: tab).contains("capabilityGated(\"\(tab)\")") {
                let blocking = FeatureRegistry.missing(forTab: tab).map(\.rawValue)
                unadopted.append("\(tab) has a registry row but no gate"
                                 + (blocking.isEmpty ? "" : ", and is currently missing \(blocking)"))
            }
        }

        XCTAssertTrue(unadopted.isEmpty,
                      "the registry knows about these tabs and the UI never asks it, so the "
                      + "sidebar can draw a needs-setup dot on a tab that then explains "
                      + "nothing:\n" + unadopted.joined(separator: "\n"))
    }

    /// A tab with BLOCKING capabilities and no gate is the severe form of the
    /// same bug, so it gets its own assertion with a sharper message.
    func testNoTabWithBlockingCapabilitiesIsUngated() {
        var bad: [String] = []
        for tab in declaredTabs() where !deliberatelyUngated.contains(tab) {
            guard let row = FeatureRegistry.row(forTab: tab), !row.blocking.isEmpty else { continue }
            if !gateSource(for: tab).contains("capabilityGated(\"\(tab)\")") {
                bad.append("\(tab) blocks on \(row.blocking.map(\.rawValue))")
            }
        }
        XCTAssertTrue(bad.isEmpty,
                      "these tabs can be unusable and say nothing about why:\n"
                      + bad.joined(separator: "\n"))
    }

    /// `settings` must never gain a gate. Stated as a test because the invariant
    /// above would happily be "satisfied" by adding one.
    func testSettingsIsNeverGated() {
        XCTAssertFalse(surfacePaneSource.contains("capabilityGated(\"settings\")"),
                       "gating Settings deadlocks setup: the card sends the user to the very "
                       + "screen it is covering")
    }

    /// Roadmap is the one tab with no registry row, and that is correct rather
    /// than an omission: it reads a local plan file, needs no credential, no
    /// permission and no endpoint, and has nothing that could be unset. A row
    /// with empty requirements would add a name to the registry that can never
    /// change state.
    func testRoadmapNeedsNoRow() {
        XCTAssertNil(FeatureRegistry.row(forTab: "roadmap"))
        XCTAssertEqual(FeatureRegistry.state(forTab: "roadmap"), .ready,
                       "a tab with no row must read as ready, never as needs-setup")
    }
}
