import Foundation

/// Which run's steps the Workflows view has open. Shared, so a trigger opens a
/// run the way the Drill in button does (SWEEP-13, operator rule 0r.4: the
/// run record could not be opened headless, since the choice lived in the
/// view's own state).
@MainActor
final class WorkflowsSelection: ObservableObject {
    static let shared = WorkflowsSelection()
    @Published private(set) var openRunId: UUID?

    /// What the Drill in and Hide button does.
    func toggle(_ runId: UUID) { openRunId = openRunId == runId ? nil : runId }
    /// Opens one run's steps (closing any other).
    func open(_ runId: UUID?) { openRunId = runId }
}

/// fire-workflow-open-run (contents: a run id) opens that run's steps as a
/// click does; fire-workflows-status only reports. Each then writes
/// workflows-status.json atomically: every workflow card's title and kind as
/// the view draws them and, when a run is open, its step titles and statuses.
@MainActor
enum WorkflowTriggers {
    static let openRun = "fire-workflow-open-run"
    static let status = "fire-workflows-status"
    static let names = [openRun, status]
    static let statusFile = "workflows-status.json"

    /// The engine the view shows. Tests put their own here.
    static var engine: () -> CommandV2Engine = { .shared }

    static func register(in dir: URL, on watcher: TriggerWatcher = .shared) {
        for name in names {
            let file = dir.appendingPathComponent(name)
            watcher.register(file) {
                guard FileManager.default.fileExists(atPath: file.path) else { return }
                let contents = (try? String(contentsOf: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: file)
                // Nothing to wait for: select and report right here, on the
                // main thread the watcher runs its handlers on.
                MainActor.assumeIsolated { fire(name, contents: contents, dir: dir) }
            }
        }
    }

    static func fire(_ name: String, contents: String, dir: URL) {
        if name == openRun {
            let eng = engine()
            let run = UUID(uuidString: contents).flatMap { id in
                eng.run(id: id) ?? eng.recentRuns.first { $0.id == id }
            }
            WorkflowsSelection.shared.open(run?.id)
            WakeLog.shared.log("\(openRun): \(run == nil ? "no run \(contents.prefix(8))" : "opened \(contents.prefix(8))")")
        }
        writeStatus(to: dir.appendingPathComponent(statusFile))
    }

    /// What the Workflows view draws, from the same copy it draws with.
    static func statusObject() -> [String: Any] {
        let eng = engine()
        var out: [String: Any] = [
            "cards": eng.definitions.map { ["title": PhaseLogCopy.cardTitle($0), "kind": PhaseLogCopy.category($0.category)] },
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let id = WorkflowsSelection.shared.openRunId,
           let run = eng.run(id: id) ?? eng.recentRuns.first(where: { $0.id == id }) {
            let def = eng.definition(id: run.definitionId)
            out["openRun"] = [
                "id": run.id.uuidString,
                "name": run.displayName,
                "header": PhaseLogCopy.stepsHeader,
                "steps": run.phaseHistory.map { ["title": PhaseLogCopy.stepTitle($0.phaseId, in: def),
                                                 "status": PhaseLogCopy.status($0.outcome)] },
            ] as [String: Any]
        } else {
            out["openRun"] = NSNull()
        }
        return out
    }

    static func writeStatus(to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: statusObject(), options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
