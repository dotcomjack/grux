import XCTest
@testable import Grux
@testable import GruxAgentCore

// D26, live 2026-10-28 1:12 PM on this Mini: Build it escalated to swarm job 2B81F330,
// the architect stopped in one second on "Failed to authenticate: OAuth session expired
// and could not be refreshed", and every place a person could read about it said less:
// the job's error was "workers failed: architect", Self-Upgrade's timeline said "ended
// failed; nothing to verify.", and chat offered "retry with a smaller scope". The
// worker's own words were on disk the whole time.
final class FoundryFailureReasonTests: XCTestCase {

    private let expired = "Failed to authenticate: OAuth session expired and could not be refreshed"

    private func worker(_ label: String, _ status: SwarmWorkerSpec.Status, error: String? = nil,
                        interruption: WorkerInterruption? = nil) -> SwarmWorkerSpec {
        SwarmWorkerSpec(role: .generic, label: label, goal: "g", cwd: "/tmp", status: status,
                        errorMessage: error, interruption: interruption)
    }

    // MARK: - The job's error keeps each failed worker's words

    func testTheJobErrorCarriesTheWorkersOwnWords() {
        let summary = SwarmOrchestrator.failureSummary(workers: [
            worker("architect", .failed, error: expired, interruption: WorkerInterruption(kind: .signInExpired)),
            worker("implementor", .queued),
        ])
        XCTAssertEqual(summary, "workers failed: architect (\(expired))")
    }

    func testEveryFailedWorkerIsNamedAndALongReasonIsCut() {
        let long = String(repeating: "x", count: 500)
        let summary = SwarmOrchestrator.failureSummary(workers: [
            worker("a", .failed, error: "line one\nline two"),
            worker("b", .done),
            worker("c", .failed, error: long),
            worker("d", .failed),
        ])
        XCTAssertTrue(summary.hasPrefix("workers failed: a (line one line two), c ("), summary)
        XCTAssertTrue(summary.hasSuffix(", d"), "a worker with no words is still named: \(summary)")
        XCTAssertLessThan(summary.count, 260, "one long reason cannot bury the rest")
        // The cut keeps a reason at or under 160 characters, the ellipsis included.
        for n in [159, 160, 161] {
            let words = String(repeating: "y", count: n)
            let one = SwarmOrchestrator.failureSummary(workers: [worker("w", .failed, error: words)])
            let reason = one.dropFirst("workers failed: w (".count).dropLast()
            XCTAssertLessThanOrEqual(reason.count, 160, "\(n)")
            XCTAssertEqual(reason.count == n, n <= 160, "\(n): kept whole only up to 160")
        }
        XCTAssertFalse(summary.contains("\n"))
    }

    // MARK: - Self-Upgrade's reason says what stopped the build

    func testAnExpiredSignInSaysToSignInAgain() {
        let job = AgentJob(id: "2B81F330-49AD-4019-AC4F-8F8C52872018", title: "foundry: t", goal: "g",
                           status: .failed,
                           workers: [worker("architect", .failed, error: expired,
                                            interruption: WorkerInterruption(kind: .signInExpired))],
                           rootDir: "/tmp", errorMessage: "workers failed: architect (\(expired))")
        let reason = FoundryEngine.escalationFailureReason(job: job, jobId: job.id, statusRaw: "failed")
        XCTAssertEqual(reason, "The build could not start: Claude's sign-in on this Mac has expired. Sign in (Claude sign-in, at the top of Now), then build it again.")
    }

    func testAnyOtherFailureKeepsTheJobsWords() {
        let job = AgentJob(id: "BB340D13", title: "foundry: t", goal: "g", status: .failed,
                           workers: [worker("implementor", .failed, error: "TTL exceeded (1800s) - terminating")],
                           rootDir: "/tmp", errorMessage: "workers failed: implementor (TTL exceeded (1800s) - terminating)")
        XCTAssertEqual(FoundryEngine.escalationFailureReason(job: job, jobId: "BB340D13", statusRaw: "failed"),
                       "Escalated swarm job BB340D13 ended failed: workers failed: implementor (TTL exceeded (1800s) - terminating). Nothing to verify.")
    }

    func testAReasonEndingInAPeriodIsNotDoubled() {
        let job = AgentJob(id: "J3", title: "t", goal: "g", status: .failed, rootDir: "/tmp",
                           errorMessage: "workers failed: a (It stopped.)")
        XCTAssertFalse(FoundryEngine.escalationFailureReason(job: job, jobId: "J3", statusRaw: "failed").contains(".."))
        let dotted = AgentJob(id: "J4", title: "t", goal: "g", status: .failed, rootDir: "/tmp",
                              errorMessage: "it stopped.")
        XCTAssertEqual(FoundryEngine.escalationFailureReason(job: dotted, jobId: "J4", statusRaw: "failed"),
                       "Escalated swarm job J4 ended failed: it stopped. Nothing to verify.")
    }

    func testAJobThatIsGoneOrSaysNothingKeepsTheOldLine() {
        XCTAssertEqual(FoundryEngine.escalationFailureReason(job: nil, jobId: "J1", statusRaw: "cancelled"),
                       "Escalated swarm job J1 ended cancelled; nothing to verify.")
        let silent = AgentJob(id: "J2", title: "t", goal: "g", status: .failed, rootDir: "/tmp")
        XCTAssertEqual(FoundryEngine.escalationFailureReason(job: silent, jobId: "J2", statusRaw: "failed"),
                       "Escalated swarm job J2 ended failed; nothing to verify.")
    }
}
