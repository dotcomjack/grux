import Foundation

/// A workflow run waiting at a gate, as the app saved it.
public struct WaitingWorkflow: Equatable, Sendable {
    public var id: String
    public var workflow: String
    public var name: String
    public var question: String
    /// When the gate phase began.
    public var since: Date?
    public var dryRun: Bool
}

/// Workflow runs waiting at a gate, read off disk so `grux approvals` can
/// name them with Grux closed. They are not in the Jax queue: a gate is
/// answered with its own words, in Chat or on the run's Workflows card.
public enum WaitingWorkflows {

    public static var runsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/v2-runs", isDirectory: true)
    }

    // Every field optional: one run saved by an older build must not hide the rest.
    private struct Saved: Decodable {
        struct Phase: Decodable { var startedAt: String? }
        var id: String?
        var definitionId: String?
        var displayName: String?
        var status: String?
        var blockingReason: String?
        var gateQuestion: String?
        var dryRun: Bool?
        var phaseHistory: [Phase]?
    }

    public static func read(runsDir: URL = runsDir) -> [WaitingWorkflow] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: nil)) ?? []
        let stamp = ISO8601DateFormatter()
        let rows = files.filter { $0.pathExtension == "json" }.compactMap { url -> WaitingWorkflow? in
            guard let data = try? Data(contentsOf: url),
                  let run = try? JSONDecoder().decode(Saved.self, from: data),
                  run.status == "waitingForApproval", let id = run.id else { return nil }
            let name = run.displayName ?? run.definitionId ?? "A workflow"
            let question = run.gateQuestion
                ?? "\(name): \(run.blockingReason ?? "waiting for an answer")"
            return WaitingWorkflow(
                id: id, workflow: run.definitionId ?? "", name: name, question: question,
                since: run.phaseHistory?.last?.startedAt.flatMap { stamp.date(from: $0) },
                dryRun: run.dryRun ?? false)
        }
        return rows.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}
