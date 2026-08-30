import XCTest
@testable import Grux
@testable import GruxAgentCore

// Activity strip fold logic (blueprint section 03): jobs -> dots, the
// linger window for terminal jobs, the estimated-cost ticker, the compact
// "$N estimated" label, and the wire round-trip for the v2 activitySnapshot
// envelope.
final class ActivityStripModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func job(
        id: String = UUID().uuidString,
        title: String = "job",
        status: AgentJob.Status,
        spentUSD: Double = 0,
        completedAt: Date? = nil
    ) -> AgentJob {
        AgentJob(
            id: id,
            title: title,
            goal: "goal",
            status: status,
            completedAt: completedAt,
            spentUSD: spentUSD,
            rootDir: "/tmp"
        )
    }

    // MARK: - Jobs -> dots

    func testFoldMapsEveryStatusToAPhase() {
        XCTAssertEqual(ActivityStripFold.phase(for: .queued), .queued)
        XCTAssertEqual(ActivityStripFold.phase(for: .running), .running)
        XCTAssertEqual(ActivityStripFold.phase(for: .waiting), .waiting)
        XCTAssertEqual(ActivityStripFold.phase(for: .paused), .waiting)
        XCTAssertEqual(ActivityStripFold.phase(for: .done), .done)
        XCTAssertEqual(ActivityStripFold.phase(for: .failed), .failed)
        XCTAssertEqual(ActivityStripFold.phase(for: .cancelled), .cancelled)
    }

    func testFoldIncludesNonTerminalJobs() {
        let jobs = [
            job(id: "a", title: "alpha", status: .running),
            job(id: "b", title: "beta", status: .queued)
        ]
        let dots = ActivityStripFold.dots(jobs: jobs, now: now)
        XCTAssertEqual(dots.map(\.id), ["a", "b"])
        XCTAssertEqual(dots[0].phase, .running)
        XCTAssertEqual(dots[0].kind, .swarm)
        XCTAssertEqual(dots[0].tooltip, "alpha | running")
        XCTAssertEqual(dots[1].phase, .queued)
    }

    func testFoldKeepsRecentTerminalJobsAndDropsStaleOnes() {
        let fresh = job(id: "fresh", status: .done,
                        completedAt: now.addingTimeInterval(-60))
        let stale = job(id: "stale", status: .failed,
                        completedAt: now.addingTimeInterval(-ActivityStripFold.lingerSeconds - 1))
        let noTimestamp = job(id: "orphan", status: .done, completedAt: nil)
        let dots = ActivityStripFold.dots(jobs: [fresh, stale, noTimestamp], now: now)
        XCTAssertEqual(dots.map(\.id), ["fresh"])
        XCTAssertEqual(dots[0].phase, .done)
    }

    func testFoldCapsDotCount() {
        let jobs = (0..<40).map { job(id: "j\($0)", status: .running) }
        let dots = ActivityStripFold.dots(jobs: jobs, now: now)
        XCTAssertEqual(dots.count, ActivityStripFold.maxDots)
        // Newest-first order from AgentService is preserved.
        XCTAssertEqual(dots.first?.id, "j0")
    }

    func testNextExpiryPicksEarliestLingeringTerminalJob() {
        let early = job(id: "e", status: .done, completedAt: now.addingTimeInterval(-200))
        let late = job(id: "l", status: .failed, completedAt: now.addingTimeInterval(-50))
        let running = job(id: "r", status: .running)
        let expiry = ActivityStripFold.nextExpiry(jobs: [late, early, running], now: now)
        XCTAssertEqual(expiry,
                       now.addingTimeInterval(-200 + ActivityStripFold.lingerSeconds))
        XCTAssertNil(ActivityStripFold.nextExpiry(jobs: [running], now: now))
    }

    // MARK: - Cost ticker

    func testCostSumsOnlyNonTerminalJobs() {
        let jobs = [
            job(status: .running, spentUSD: 1.25),
            job(status: .queued, spentUSD: 0.50),
            job(status: .waiting, spentUSD: 0.25),
            job(status: .done, spentUSD: 9.00, completedAt: now),
            job(status: .failed, spentUSD: 4.00, completedAt: now)
        ]
        XCTAssertEqual(ActivityStripFold.estimatedCostUSD(jobs: jobs), 2.0, accuracy: 0.0001)
    }

    func testCostIncludesFoundryBudgetWhenMidPass() {
        let jobs = [job(status: .running, spentUSD: 1.0)]
        XCTAssertEqual(
            ActivityStripFold.estimatedCostUSD(jobs: jobs, foundryBudgetUSD: 0.40),
            1.4, accuracy: 0.0001
        )
        XCTAssertEqual(
            ActivityStripFold.estimatedCostUSD(jobs: jobs, foundryBudgetUSD: nil),
            1.0, accuracy: 0.0001
        )
    }

    // MARK: - "$N estimated" label

    func testCostLabelFormatting() {
        XCTAssertNil(ActivityStripFold.costLabel(usd: 0))
        XCTAssertNil(ActivityStripFold.costLabel(usd: -3))
        XCTAssertEqual(ActivityStripFold.costLabel(usd: 0.42), "$0.42 estimated")
        XCTAssertEqual(ActivityStripFold.costLabel(usd: 3.0), "$3 estimated")
        XCTAssertEqual(ActivityStripFold.costLabel(usd: 9.99), "$9.99 estimated")
        XCTAssertEqual(ActivityStripFold.costLabel(usd: 12.4), "$12 estimated")
        XCTAssertEqual(ActivityStripFold.costLabel(usd: 12.6), "$13 estimated")
    }

    func testCostLabelAlwaysCarriesTheWordEstimated() {
        for usd in [0.01, 0.42, 1.0, 5.5, 10.0, 999.0] {
            let label = ActivityStripFold.costLabel(usd: usd)
            XCTAssertNotNil(label)
            XCTAssertTrue(label!.contains("estimated"), "label missing estimated: \(label!)")
            XCTAssertTrue(label!.hasPrefix("$"), "label missing $ prefix: \(label!)")
        }
    }

    // MARK: - Wire round-trip (activitySnapshot envelope, wire v2)

    private func sampleActivitySnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> ActivitySnapshotDTO {
        ActivitySnapshotDTO(
            generatedAt: generatedAt,
            jobs: [
                ActivityJobDTO(id: "a", title: "alpha", phase: "running",
                               isFoundry: false, estimatedUSD: 1.25),
                ActivityJobDTO(id: "b", title: "beta", phase: "done",
                               isFoundry: false, estimatedUSD: 0.4)
            ],
            foundryPass: "nightly-light",
            estimatedCostLabel: "$1.65 estimated"
        )
    }

    func testActivityEnvelopeRoundTrip() throws {
        let env = SurfaceEnvelope.activitySnapshot(version: 2, snapshot: sampleActivitySnapshot())
        let data = try env.encode()
        let decoded = try SurfaceEnvelope.decode(data)
        guard case .activitySnapshot(let version, let snapshot) = decoded else {
            return XCTFail("decoded wrong case")
        }
        XCTAssertEqual(version, 2)
        XCTAssertEqual(snapshot, sampleActivitySnapshot())
        XCTAssertEqual(snapshot.jobs.count, 2)
        XCTAssertEqual(snapshot.foundryPass, "nightly-light")
    }

    func testActivityDigestIgnoresGeneratedAt() {
        let a = sampleActivitySnapshot(generatedAt: Date(timeIntervalSince1970: 1))
        let b = sampleActivitySnapshot(generatedAt: Date(timeIntervalSince1970: 999_999))
        XCTAssertEqual(SurfaceSyncEngine.digest(ofActivity: a),
                       SurfaceSyncEngine.digest(ofActivity: b))
        let c = ActivitySnapshotDTO(generatedAt: a.generatedAt, jobs: [],
                                    foundryPass: nil, estimatedCostLabel: "")
        XCTAssertNotEqual(SurfaceSyncEngine.digest(ofActivity: a),
                          SurfaceSyncEngine.digest(ofActivity: c))
    }

    func testWireVersionGatesActivity() {
        // The Mac only ships activity when the negotiated version clears the
        // gate. The negotiation rule is min(mac, max(1, phone)).
        XCTAssertGreaterThanOrEqual(SurfaceWire.version, SurfaceWire.activityMinVersion)
        let v1Phone = min(SurfaceWire.version, max(1, 1))
        XCTAssertLessThan(v1Phone, SurfaceWire.activityMinVersion)
        let v2Phone = min(SurfaceWire.version, max(1, 2))
        XCTAssertGreaterThanOrEqual(v2Phone, SurfaceWire.activityMinVersion)
    }
}
