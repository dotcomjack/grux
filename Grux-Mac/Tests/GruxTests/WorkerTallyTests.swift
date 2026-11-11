import XCTest
@testable import Grux
@testable import GruxAgentCore

/// D135 item 10 (sense pass 14): Agents read "0/2 done · 1 failed" for a
/// self-upgrade job whose second worker never started (it waited on the one
/// that failed), so one worker went unaccounted for. Every place that counts
/// workers now reads one tally that names every worker exactly once.
final class WorkerTallyTests: XCTestCase {

    private func job(_ status: AgentJob.Status, _ workers: [SwarmWorkerSpec.Status]) -> AgentJob {
        AgentJob(title: "t", goal: "g", status: status,
                 workers: workers.enumerated().map { i, s in
                     SwarmWorkerSpec(role: .implementor, label: "w\(i)", goal: "g", cwd: "/tmp", status: s)
                 },
                 rootDir: "/tmp")
    }

    /// The case the sense pass saw: architect failed, implementor queued, job failed.
    func testAFailedJobNamesTheWorkerThatNeverStarted() {
        XCTAssertEqual(WorkerTally(job(.failed, [.failed, .queued])).line, "0/2 done · 1 failed · 1 not run")
        // While the job still runs, a queued worker is waiting its turn, not abandoned.
        XCTAssertEqual(WorkerTally(job(.running, [.done, .running, .queued])).line,
                       "1/3 done · 1 running · 1 waiting to start")
        XCTAssertEqual(WorkerTally(job(.done, [.done, .done])).line, "2/2 done")
        XCTAssertEqual(WorkerTally(job(.cancelled, [.done, .cancelled, .skipped])).line,
                       "1/3 done · 1 stopped · 1 skipped")
        XCTAssertEqual(WorkerTally(job(.waiting, [.pausedForAuth, .queued])).line,
                       "0/2 done · 1 paused · 1 waiting to start")
    }

    /// The class guard: for every worker status in every job status, the
    /// numbers in the line add up to the number of workers.
    func testEveryWorkerIsCountedExactlyOnce() {
        let workerStates: [SwarmWorkerSpec.Status] = [.queued, .running, .done, .failed, .cancelled, .skipped, .pausedForAuth]
        let jobStates: [AgentJob.Status] = [.queued, .running, .waiting, .paused, .done, .failed, .cancelled]
        for js in jobStates {
            for a in workerStates {
                for b in workerStates {
                    let t = WorkerTally(job(js, [a, b, .done]))
                    XCTAssertEqual(t.parts.reduce(0) { $0 + $1.count }, 3, "\(js) \(a) \(b): \(t.line)")
                    XCTAssertTrue(t.line.hasPrefix("\(t.parts.first { $0.kind == .done }?.count ?? -1)/3 done"),
                                  "\(js) \(a) \(b): \(t.line)")
                }
            }
        }
        XCTAssertEqual(WorkerTally(job(.queued, [])).line, "0/0 done")
    }

    /// Every surface that showed a worker count reads the tally: the Agents
    /// row, the chat context, the copied cost summary and the agent_list tool.
    func testNoSurfaceCountsWorkersByHand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Grux")
        for file in ["AgentsView.swift", "AgentTools.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(src.contains("workers.count) done"), "\(file) builds a worker count by hand")
            XCTAssertTrue(src.contains("WorkerTally("), "\(file) no longer reads the tally")
        }
    }
}
