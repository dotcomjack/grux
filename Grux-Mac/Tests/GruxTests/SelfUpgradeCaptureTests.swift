import XCTest
import SwiftUI
@testable import Grux

/// The Self-Upgrade card rendered from fixtures in the states a person can
/// meet: signed in (Build it, powered by the subscription), signed out (Sign
/// in to build it), and a build in flight. Fixtures rather than the live app
/// because the installed app shows whoever is signed in, and because the
/// signed-out state cannot be driven without signing the owner out.
///
/// Set GRUX_SELF_UPGRADE_CAPTURE_DIR to a folder to write the PNGs.
@MainActor
final class SelfUpgradeCaptureTests: XCTestCase {

    /// The card from the screenshot that started this, with every evidence
    /// line the real one carried folded behind "+7 more".
    static let fixture = FoundryProposalCardModel(
        id: "capture-1",
        title: "Sidebar IA: four collapsible groups plus pinned favorites",
        lane: "UX Polish",
        domain: "Mac",
        evidence: [
            "manual: the rail lists 31 rows with no grouping",
            "transcript: asked where Mailbox went, twice in one week",
            "swarm: worker scrolled the rail 14 times in one job",
            "manual: Settings fell off the bottom at the 560pt floor",
            "transcript: asked to pin Notes to the top",
            "swarm: two workers opened the wrong Schedules surface",
            "manual: the Labs door reads as a ninth surface",
            "transcript: asked which rows are new since last week",
            "manual: no way to hide surfaces that are never used",
        ],
        expectedGain: "Expected gain score 86 of 100",
        estimatedCostUSD: 8,
        risk: "Medium",
        tierRequired: 0,
        score: 0.86,
        readyPrompt: "Group the sidebar into four collapsible sections and add a pinned favorites row.",
        touchedPaths: ["Sources/Grux/DesignSystem/SidebarModel.swift"]
    )

    /// The pane's content width: the pane less its padding on both sides.
    private var width: CGFloat { GruxLayout.paneWidth - GruxSpacing.l * 2 }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Hosts one card on the app's base colour, sized to fit, and returns the
    /// bitmap and PNG, written to the capture folder when that is set.
    private func capture(_ card: FoundryProposalCard, name: String) throws -> (NSBitmapImageRep, Data) {
        let root = card
            .padding(GruxSpacing.l)
            .frame(width: width)
            .background(GruxTheme.base)
            .environmentObject(AppState.shared)
        let host = NSHostingView(rootView: root)
        let fitting = host.fittingSize
        let size = NSSize(width: width, height: max(fitting.height, 120))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(seconds: 0.6)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let dir = ProcessInfo.processInfo.environment["GRUX_SELF_UPGRADE_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("2026-09-27-self-upgrade-\(name).png")
            try png.write(to: url)
        }
        window.contentView = nil
        return (rep, png)
    }

    func test_signedInCardOffersBuildItPoweredByTheSubscription() throws {
        let action = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedIn, subscriptionType: "max", cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .proposed, buildInFlight: false, escalatedJobId: nil, approvalPending: false))
        XCTAssertEqual(action, .build(power: "powered by your Claude Max subscription"))
        let (rep, png) = try capture(
            FoundryProposalCard(card: Self.fixture, action: action, copied: false,
                                onPrimary: {}, onCopyHandoff: {}, onNotNow: {}),
            name: "card-signed-in")
        XCTAssertEqual(rep.size.width, width, "the card is not the pane's content width")
        XCTAssertGreaterThan(rep.size.height, 120, "the card rendered with no height")
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }

    func test_signedOutCardOffersSignInInstead() throws {
        let action = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedOut, subscriptionType: nil, cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .proposed, buildInFlight: false, escalatedJobId: nil, approvalPending: false))
        XCTAssertEqual(action, .signIn)
        let (rep, png) = try capture(
            FoundryProposalCard(card: Self.fixture, action: action, copied: false,
                                onPrimary: {}, onCopyHandoff: {}, onNotNow: {}),
            name: "card-signed-out")
        XCTAssertEqual(rep.size.width, width)
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }

    /// The text "Copy handoff for your agent" puts on the clipboard for the
    /// same fixture, written beside the captures so the sample in the PR is
    /// the generated document and not a retyped one.
    func test_handoffSampleForTheFixtureIsComplete() throws {
        let context = WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "1",
                                       installed: .release(olderSource: nil), supportDir: "~/Library/Application Support/Grux",
                                       orderDir: "~/.grux/work-orders/wo-sample")
        let text = WorkOrderPrompt.build(id: "wo-sample", request: ProposalHandoff.request(for: Self.fixture),
                                         detail: ProposalHandoff.detail(for: Self.fixture), context: context)
        for line in Self.fixture.evidence {
            XCTAssertTrue(text.contains(FoundryFormat.evidenceLabel(line)), "evidence dropped: \(line)")
        }
        XCTAssertTrue(text.contains("Sources/Grux/DesignSystem/SidebarModel.swift"))
        if let dir = ProcessInfo.processInfo.environment["GRUX_SELF_UPGRADE_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("2026-09-27-self-upgrade-handoff-sample.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func test_buildingCardShowsProgressAndNoSecondBuildIt() throws {
        var building = Self.fixture
        building.status = .accepted
        building.stage = .building
        let action = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedIn, subscriptionType: "max", cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .building, buildInFlight: true, escalatedJobId: nil, approvalPending: false))
        XCTAssertEqual(action, .inFlight(stage: .building, jobId: nil))
        XCTAssertFalse(action.isActionable)
        let (rep, png) = try capture(
            FoundryProposalCard(card: building, action: action, copied: true,
                                onPrimary: {}, onCopyHandoff: {}, onNotNow: nil),
            name: "card-building")
        XCTAssertEqual(rep.size.width, width)
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }
}
