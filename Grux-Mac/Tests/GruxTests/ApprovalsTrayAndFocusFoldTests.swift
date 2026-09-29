import XCTest
@testable import Grux

/// C10 and C11, the last two folds. Approvals become a tray at the foot of the
/// rail on every tab; the Focus log leaves the rail for Today.
@MainActor
final class ApprovalsTrayAndFocusFoldTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/" + rel), encoding: .utf8)
    }

    func test_theTrayBadgeSaysHowManyAreWaiting() {
        XCTAssertEqual(ApprovalsTray.badge(38), "38 waiting")
        XCTAssertFalse(ApprovalsTray.help.contains("\u{2014}") || ApprovalsTray.help.contains("\u{2013}"))
    }

    /// Reachable from anywhere: the badge sits in the rail foot, which every
    /// tab shows, and it is not a rail row.
    func test_theTrayLivesInTheRailFootOnEveryTab_notAsARow() throws {
        let root = try source("LaunchRootView.swift")
        let foot = try XCTUnwrap(root.components(separatedBy: "private var listeningFoot: some View {").dropFirst().first)
        XCTAssertTrue(foot.prefix(1_600).contains("ApprovalsTrayButton()"), "the tray left the rail foot")
        XCTAssertFalse(SidebarIA.rail(developerUnlocked: true, brands: []).contains { $0.id == "approvals" },
                       "approvals grew a rail row")
    }

    /// The root must not redraw for an approval; the badge observes the queue
    /// itself (P-R-8's load work depends on the root observing little).
    func test_theRootDoesNotObserveTheQueue() throws {
        let root = try source("LaunchRootView.swift")
        XCTAssertFalse(root.contains("@ObservedObject private var approvals")
                       || root.contains("= ApprovalQueue.shared"), "the root observes the approval queue")
        let tray = try source("Jax/ApprovalsTray.swift")
        XCTAssertTrue(tray.contains("@ObservedObject private var queue = ApprovalQueue.shared"))
    }

    /// The tray acts exactly as Jax HQ does: approve runs the sanctioned
    /// action through the queue, skip marks it, and nothing else.
    func test_theTrayApprovesAndSkipsThroughTheQueue() throws {
        let tray = try source("Jax/ApprovalsTray.swift")
        XCTAssertTrue(tray.contains("onApprove: { id in Task { await queue.approveAndExecute(id) } }"))
        XCTAssertTrue(tray.contains("onSkip: { queue.skip($0) }"))
    }

    /// The tray is reachable by key too, so a script or a sweep can open it,
    /// and the key never falls through to Chat the way an unknown one does.
    func test_theApprovalsKeyOpensTheTray() throws {
        let triggers = try source("Triggers/AppTriggers.swift")
        let branch = try XCTUnwrap(triggers.components(separatedBy: "if tab == ApprovalsTray.openKey {").dropFirst().first)
        XCTAssertTrue(branch.prefix(700).contains("ApprovalsTrayState.shared.isOpen = true"))
        XCTAssertTrue(branch.prefix(700).contains("return"), "the approvals key falls through to the tab switch")
        XCTAssertNil(LaunchRootView.tab(forKey: ApprovalsTray.openKey), "approvals grew a tab; the tray is the home")
        let after = try XCTUnwrap(branch.components(separatedBy: "return\n                }").dropFirst().first)
        XCTAssertTrue(after.prefix(400).contains("ApprovalsTrayState.shared.isOpen = false"),
                      "another key leaves the tray open over the tab it opened")
    }

    /// C11: the Focus log's key still opens it, with Today's row lit, and it
    /// is no longer a row of its own.
    func test_theFocusLogFoldsIntoToday() {
        XCTAssertEqual(LaunchRootView.tab(forKey: "focus"), .focus, "the locked key stopped resolving")
        XCTAssertEqual(LaunchRootView.host(of: .focus), .home)
        XCTAssertFalse(SidebarIA.rail(developerUnlocked: true, brands: []).contains { $0.id == "focus" },
                       "the Focus log is still a rail row")
        XCTAssertEqual(FeatureRegistry.rows.first { $0.id == "focus" }?.disposition, .folds(into: "today.card"))
    }

    /// C5's child opens its parent at the child: `integrations:webhooks`
    /// scrolls Integrations to Outbound Webhooks, so a sweep can capture the
    /// fold without anybody scrolling a live window by hand.
    func test_theWebhooksKeyOpensIntegrationsAtWebhooks() throws {
        let view = try source("Integrations/IntegrationsView.swift")
        XCTAssertTrue(view.contains("WebhooksView()\n                        .id(Self.webhooksSection)"), "the webhooks section lost its anchor")
        XCTAssertTrue(view.contains("proxy.scrollTo(Self.webhooksSection, anchor: .top)"))
        let triggers = try source("Triggers/AppTriggers.swift")
        XCTAssertTrue(triggers.contains("else { AppState.shared.requestedSection = parts[1] }"),
                      "a section key outside Settings is dropped")
        XCTAssertEqual(IntegrationsView.webhooksSection, "webhooks")
    }
}
