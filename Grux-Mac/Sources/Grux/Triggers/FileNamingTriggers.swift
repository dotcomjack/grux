import Foundation

/// Hands-free checks for Files that name themselves (operator rule 0r.4): the
/// status, the Undo and the eval harness's entry point, each reachable without
/// a click.
///
/// - `fire-file-naming-status` writes `file-naming-status.json`.
/// - `fire-file-naming-undo-last` undoes the newest rename, then writes the
///   status with the outcome under `undo`.
/// - `fire-file-naming-preview` (contents: an absolute path) runs the whole
///   pipeline on that file without renaming it and writes
///   `file-naming-preview.json`. It runs with the feature off too, which is
///   what lets the eval score a model before anyone turns naming on.
/// - `fire-file-naming-backlog` (contents: absolute paths, one per line, or
///   nothing for every file already in the watched folders) runs "Name the
///   files already here" and writes `file-naming-backlog.json` once it has
///   counted its files and when it ends. A refusal (a relative path, a run
///   already going, an undo of a run still going) goes to
///   `file-naming-backlog-refused.json`, leaving the run's file be.
/// - `fire-file-naming-undo-batch` (contents: a run's batch id, or nothing
///   for the newest run) undoes that run and writes the same file, with how
///   many were put back under `restored`.
///
/// The status carries counts, the route and the watched folders, NEVER a file
/// name: a file's name is the person's content. The preview is the one place a
/// proposed name is written outside the rename itself, and only because
/// somebody on this Mac asked for exactly that file.
@MainActor
enum FileNamingTriggers {
    static let status = "fire-file-naming-status"
    static let undoLast = "fire-file-naming-undo-last"
    static let preview = "fire-file-naming-preview"
    static let backlog = "fire-file-naming-backlog"
    static let undoBatch = "fire-file-naming-undo-batch"
    static let names = [status, undoLast, preview, backlog, undoBatch]

    nonisolated static let statusFile = "file-naming-status.json"
    static let previewFile = "file-naming-preview.json"
    static let backlogFile = "file-naming-backlog.json"
    static let backlogRefusedFile = "file-naming-backlog-refused.json"

    /// Re-resolves the local route before the status is written, the same
    /// thing Settings does when the section appears, so a model pulled since
    /// launch reads as ready here too. Tests put a no-op here, because the
    /// real one asks the Ollama address in config for its models.
    static var refreshRoute: () async -> Void = { await FileNamingService.shared.refreshStatus() }

    /// The service the triggers act on. Tests put one built on a folder and
    /// ledger of their own here, so an undo is proven against a rename that
    /// really happened rather than an empty ledger (review 2026-10-28).
    static var service: () -> FileNamingService = { FileNamingService.shared }

    static func register(in dir: URL, on watcher: TriggerWatcher = .shared) {
        for name in names {
            let file = dir.appendingPathComponent(name)
            watcher.register(file) {
                guard FileManager.default.fileExists(atPath: file.path) else { return }
                let contents = (try? String(contentsOf: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: file)
                Task { @MainActor in await fire(name, contents: contents, dir: dir) }
            }
        }
    }

    static func fire(_ name: String, contents: String, dir: URL) async {
        let service = Self.service()
        switch name {
        case undoLast:
            let outcome = await service.undoLastInBackground()
            // The outcome word only. `failed` carries an error text that can
            // quote a path, so it stays out of the log and the file.
            WakeLog.shared.log("\(undoLast): \(word(outcome))")
            await refreshRoute()
            writeStatus(service.status, undo: word(outcome), to: dir.appendingPathComponent(statusFile))
        case preview:
            let path = (contents as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                WakeLog.shared.log("\(preview): refused, the contents are not an absolute path")
                write(["path": contents, "decision": "leave", "reason": "notAbsolutePath",
                       "proposedName": NSNull(), "readMs": 0, "modelMs": 0, "model": NSNull()],
                      to: dir.appendingPathComponent(previewFile))
                return
            }
            let result = await service.preview(path: path)
            WakeLog.shared.log("\(preview): \(result.decision) \(result.reason) \(result.readMs + result.modelMs) ms")
            write(previewObject(result), to: dir.appendingPathComponent(previewFile))
        case backlog:
            let paths = contents.split(whereSeparator: \.isNewline)
                .map { (String($0).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
                .filter { !$0.isEmpty }
            let refusedFile = dir.appendingPathComponent(backlogRefusedFile)
            guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
                WakeLog.shared.log("\(backlog): refused, a line is not an absolute path")
                write(["refused": "notAbsolutePath", "writtenAt": ISO8601DateFormatter().string(from: Date())],
                      to: refusedFile)
                return
            }
            let out = dir.appendingPathComponent(backlogFile)
            // Refused before anything starts, so the refusal is the only
            // thing written and a running run's file is left as it is.
            guard service.backlog?.running != true else {
                WakeLog.shared.log("\(backlog): refused, a run is already going")
                write(["refused": "alreadyRunning", "writtenAt": ISO8601DateFormatter().string(from: Date())],
                      to: refusedFile)
                return
            }
            // A refusal from an earlier call is not about this run.
            try? FileManager.default.removeItem(at: refusedFile)
            // The start, once the run has counted its files, so a caller can
            // tell a run that began, and how big it is.
            guard let result = await service.nameExisting(paths: paths.isEmpty ? nil : paths,
                                                          onCounted: { write(backlogObject($0), to: out) }) else {
                return
            }
            WakeLog.shared.log("\(backlog): \(result.named) of \(result.total) named")
            write(backlogObject(result), to: out)
        case undoBatch:
            guard let batch = UUID(uuidString: contents) ?? (contents.isEmpty ? service.lastBatch : nil) else {
                WakeLog.shared.log("\(undoBatch): nothing to undo")
                write(["restored": 0, "writtenAt": ISO8601DateFormatter().string(from: Date())],
                      to: dir.appendingPathComponent(backlogFile))
                return
            }
            if let running = service.backlog, running.running, running.batch == batch {
                WakeLog.shared.log("\(undoBatch): refused, that run is still going")
                write(["refused": "stillRunning", "writtenAt": ISO8601DateFormatter().string(from: Date())],
                      to: dir.appendingPathComponent(backlogRefusedFile))
                return
            }
            let restored = await service.undoBatch(batch)
            WakeLog.shared.log("\(undoBatch): \(restored) restored")
            var object: [String: Any] = service.backlog.flatMap { $0.batch == batch ? backlogObject($0) : nil }
                ?? ["batch": batch.uuidString]
            object["restored"] = restored
            object["writtenAt"] = ISO8601DateFormatter().string(from: Date())
            write(object, to: dir.appendingPathComponent(backlogFile))
        default:
            await refreshRoute()
            writeStatus(service.status, undo: nil, to: dir.appendingPathComponent(statusFile))
        }
    }

    /// A run as JSON keys: counts, never a file name.
    static func backlogObject(_ b: FileNamingBacklog, now: Date = Date()) -> [String: Any] {
        [
            "batch": b.batch.uuidString,
            "total": b.total,
            "done": b.done,
            "named": b.named,
            "undone": b.undone,
            "running": b.running,
            "stopped": b.stopped,
            "settingsLine": b.settingsLine,
            "writtenAt": ISO8601DateFormatter().string(from: now),
        ]
    }

    /// The status as JSON keys. Every key is listed here by hand, so adding one
    /// is a decision and `FileNamingTriggersTests` pins the set: nothing that
    /// holds a file name can arrive by way of a new property.
    static func statusObject(_ s: FileNamingStatus, now: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "enabled": s.enabled,
            "armed": s.armed,
            "route": s.route,
            "model": s.model.map { $0 as Any } ?? NSNull(),
            "folders": s.folders,
            "named": s.named,
            "undone": s.undone,
            "skipped": s.skipped,
            "lastNamedAt": s.lastNamedAt.map { iso.string(from: $0) as Any } ?? NSNull(),
            "settingsLine": s.settingsLine,
            "writtenAt": iso.string(from: now),
        ]
    }

    static func previewObject(_ p: FileNamingPreview, now: Date = Date()) -> [String: Any] {
        [
            "path": p.path,
            "decision": p.decision,
            "reason": p.reason,
            "proposedName": p.proposedName.map { $0 as Any } ?? NSNull(),
            "readMs": p.readMs,
            "modelMs": p.modelMs,
            "model": p.model.map { $0 as Any } ?? NSNull(),
            "writtenAt": ISO8601DateFormatter().string(from: now),
        ]
    }

    /// One word per undo outcome, for the log and the status file.
    static func word(_ outcome: FileUndoOutcome) -> String {
        switch outcome {
        case .restored: return "restored"
        case .nothingToUndo: return "nothingToUndo"
        case .newNameGone: return "newNameGone"
        case .oldNameTaken: return "oldNameTaken"
        case .fileChanged: return "fileChanged"
        case .failed: return "failed"
        }
    }

    static func writeStatus(_ s: FileNamingStatus, undo: String?, to url: URL) {
        var object = statusObject(s)
        if let undo { object["undo"] = undo }
        write(object, to: url)
    }

    private static func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
