import XCTest
import GruxAgentCore
@testable import Grux

/// `RelevanceState.live()` reads the stores. Under the suite's clean state it
/// must produce an empty struct apart from setup gaps, and never touch the
/// operator's data.
@MainActor
final class RelevanceLiveTests: XCTestCase {
    /// The feature selection is process-wide UserDefaults; leave it as found.
    private var savedSelection: Any?

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.object(forKey: FeatureSelection.defaultsKey)
    }

    override func tearDown() {
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: FeatureSelection.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        }
        super.tearDown()
    }

    func test_aCleanInstallHasNoNeedsYouAndNoRunning() {
        let s = RelevanceState.live()
        // Approvals are the one store an earlier class writes: the design-route
        // gate tests queue two items into the suite's scratch queue and leave
        // them. So the count must be exactly the scratch queue's, never the
        // operator's and never an invented number.
        XCTAssertTrue(ApprovalQueue.shared.storeFileURL.path.hasPrefix(Persistence.supportDir.path),
                      "the approvals read must be the suite's scratch queue")
        XCTAssertEqual(s.approvalsPending, ApprovalQueue.shared.pending.count)
        XCTAssertEqual(s.reviewsWaiting, [])
        XCTAssertEqual(s.mail, [])
        XCTAssertEqual(s.jobsRunning, [])
        XCTAssertEqual(s.jobsWaitingOnYou, [])
        XCTAssertNil(s.workflowRunning)
    }

    /// Now, the Improve door and the head badge count proposals from one
    /// source: the dashboard's pending count, which spec 5.4 binds the door
    /// and the badge to. Two sources could show two numbers on one panel.
    func test_proposalsAreCountedWhereTheDoorAndTheBadgeCountThem() {
        let dashboard = FoundryDashboardModel.shared
        let saved = dashboard.proposals
        defer { dashboard.proposals = saved }
        func card(_ id: String, _ status: FoundryProposalCardStatus) -> FoundryProposalCardModel {
            FoundryProposalCardModel(id: id, title: id, lane: "ux polish", domain: "panel", status: status)
        }
        dashboard.proposals = [card("p1", .pending), card("p2", .pending), card("p3", .accepted)]
        XCTAssertEqual(dashboard.pendingCount, 2)
        XCTAssertEqual(RelevanceState.live().proposals, dashboard.pendingCount,
                       "Now counts proposals from a different source than the Improve door and the badge")
    }

    func test_setupGapsNameOnlyPickedFeatures() throws {
        // Picked nothing: no gap may be suggested.
        FeatureSelection.choose([])
        XCTAssertEqual(RelevanceState.live().setupGaps, [])

        // Picked exactly one row that is missing something here: that row alone.
        let row = try XCTUnwrap(FeatureRegistry.rows.first {
            FeatureRegistry.capabilityState(of: $0) == .needsSetup && $0.disposition == .rail
        }, "the suite machine has no keys, so some rail row must need setup")
        FeatureSelection.choose([row.id])
        XCTAssertEqual(RelevanceState.live().setupGaps.map(\.featureId), [row.id])
    }

    func test_aGapCarriesTheFirstMissingThingAndItsBrandScope() throws {
        let meta = try XCTUnwrap(FeatureRegistry.row(forTab: "metaAds"))
        let gap = try XCTUnwrap(RelevanceState.setupGap(for: meta, missing: [.keyTelegram, .keyAnthropic]))
        XCTAssertEqual(gap, SetupGap(featureId: "meta.ads", label: "Meta Ads",
                                     missing: "Telegram bot token", brandScoped: true))

        let chat = try XCTUnwrap(FeatureRegistry.row(forTab: "chat"))
        XCTAssertEqual(RelevanceState.setupGap(for: chat, missing: [.keyAnthropic])?.brandScoped, false)
        XCTAssertNil(RelevanceState.setupGap(for: chat, missing: []), "nothing missing is no gap")
    }

    /// Spec 4.1 and 4.2: only rows reachable without a door suggest setup:
    /// rail, Studio (under a rail row, R3.8), fold and brand scoped. The
    /// Developer and Labs doors contribute nothing.
    func test_onlyRailFoldAndBrandRowsBecomeGaps() throws {
        func gap(_ id: String) throws -> SetupGap? {
            let row = try XCTUnwrap(FeatureRegistry.row(id: id), id)
            return RelevanceState.setupGap(for: row, missing: [.keyAnthropic])
        }
        XCTAssertEqual(FeatureRegistry.disposition(for: "agents"), .developer)
        XCTAssertNil(try gap("agents"), "a Developer door row is never a Now suggestion")
        XCTAssertEqual(FeatureRegistry.disposition(for: "reactor"), .labs)
        XCTAssertNil(try gap("reactor"), "a Labs door row is never a Now suggestion")
        XCTAssertEqual(FeatureRegistry.disposition(for: "creative"), .studio)
        XCTAssertEqual(try gap("creative")?.brandScoped, false, "a Studio row sits under a rail row, so it is a gap")

        XCTAssertEqual(try gap("meetings")?.brandScoped, false, "a rail row is a gap")
        XCTAssertEqual(try gap("mailbox.compose")?.brandScoped, false, "a folded row is a gap")
        XCTAssertEqual(try gap("social")?.brandScoped, true, "a brand-scoped row is a gap, marked brand scoped")
    }

    func test_jobsSplitIntoRunningAndWaitingInStartOrder() {
        let now = Date()
        func job(_ id: String, _ status: AgentJob.Status, startedMinutesAgo: Double?,
                 createdMinutesAgo: Double = 60) -> AgentJob {
            AgentJob(id: id, title: "Job \(id)", goal: "", status: status,
                     createdAt: now.addingTimeInterval(-createdMinutesAgo * 60),
                     startedAt: startedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                     rootDir: "")
        }
        let rows = RelevanceState.jobRows([
            job("late", .running, startedMinutesAgo: 1),
            job("done", .done, startedMinutesAgo: 30),
            job("paused", .paused, startedMinutesAgo: 5),
            job("early", .running, startedMinutesAgo: 20),
            job("queued", .queued, startedMinutesAgo: nil, createdMinutesAgo: 10),
            job("gated", .waiting, startedMinutesAgo: 40),
            job("failed", .failed, startedMinutesAgo: 2),
        ])
        XCTAssertEqual(rows.running.map(\.id), ["early", "queued", "late"],
                       "running ones by start time; a queued job has not started, so its created time counts")
        XCTAssertEqual(rows.waiting.map(\.id), ["gated", "paused"])
        XCTAssertEqual(rows.running.first?.title, "Job early")
    }
}
