import Foundation
import GruxAgentCore

/// How many of a job's workers are in each state, as one line. Every place
/// that shows a worker count reads this, so none of them can leave a worker
/// out (D135 item 10: "0/2 done · 1 failed" hid the worker that never ran).
struct WorkerTally {
    enum Kind: Equatable { case done, failed, running, paused, waitingToStart, notRun, stopped, skipped }
    struct Part: Equatable { let kind: Kind; let count: Int }

    let total: Int
    let parts: [Part]

    init(_ job: AgentJob) {
        total = job.workers.count
        func n(_ s: SwarmWorkerSpec.Status) -> Int { job.workers.filter { $0.status == s }.count }
        // A queued worker in a job that has settled never got its turn (its
        // dependency failed, or the job stopped); in a live job it is next.
        let settled = [.done, .failed, .cancelled].contains(job.status)
        parts = [Part(kind: .done, count: n(.done)), Part(kind: .failed, count: n(.failed)),
                 Part(kind: .running, count: n(.running)), Part(kind: .paused, count: n(.pausedForAuth)),
                 Part(kind: settled ? .notRun : .waitingToStart, count: n(.queued)),
                 Part(kind: .stopped, count: n(.cancelled)), Part(kind: .skipped, count: n(.skipped))]
    }

    /// The pieces in order: "n/total done" first, then every other state
    /// that has a worker in it. The Agents row colours them one by one.
    var lineParts: [(kind: Kind, text: String)] {
        let done = parts.first { $0.kind == .done }?.count ?? 0
        return [(.done, "\(done)/\(total) done")]
            + parts.filter { $0.kind != .done && $0.count > 0 }.map { ($0.kind, "\($0.count) \(Self.word($0.kind))") }
    }

    var line: String { lineParts.map(\.text).joined(separator: " · ") }

    static func word(_ kind: Kind) -> String {
        switch kind {
        case .done: return "done"
        case .failed: return "failed"
        case .running: return "running"
        case .paused: return "paused"
        case .waitingToStart: return "waiting to start"
        case .notRun: return "not run"
        case .stopped: return "stopped"
        case .skipped: return "skipped"
        }
    }
}
