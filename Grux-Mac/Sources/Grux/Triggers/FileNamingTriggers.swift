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
    static let names = [status, undoLast, preview]

    nonisolated static let statusFile = "file-naming-status.json"
    static let previewFile = "file-naming-preview.json"

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
            let outcome = service.undoLast()
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
        default:
            await refreshRoute()
            writeStatus(service.status, undo: nil, to: dir.appendingPathComponent(statusFile))
        }
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
