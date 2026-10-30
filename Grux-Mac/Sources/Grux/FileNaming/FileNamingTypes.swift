import Foundation

// The shapes "Files that name themselves" shares with the app: Settings, the
// notification, and the three ~/.grux triggers read these and nothing else.
// Design: docs/superpowers/specs/2026-10-27-files-name-themselves-design.md.
//
// None of them carries the text read from a file. A name a person can see in
// Finder is the most any of them holds, and only the ledger and the preview
// trigger hold even that.

/// One rename Grux made, as the ledger keeps it. `folder` is the folder's
/// path, `oldName` and `newName` are whole file names with their extension.
struct FileRename: Codable, Equatable, Identifiable {
    let id: UUID
    let folder: String
    let oldName: String
    let newName: String
    let at: Date
    var undoneAt: Date?
    /// The file's number on its volume (`st_ino`) when Grux renamed it. Undo
    /// moves the file at `newName` only when it still has this number: a name
    /// alone cannot tell Grux's file from one a person saved under the same
    /// name later (review 2026-10-28). nil in entries written before this
    /// field existed, which decode as before and undo by name.
    var fileID: UInt64? = nil
    /// The "Name the files already here" run this rename was part of, so
    /// the whole run can be undone together. nil for a file named as it
    /// arrived, and in entries written before runs existed.
    var batch: UUID? = nil
}

/// What an undo did. Anything but `.restored` changed nothing on disk.
enum FileUndoOutcome: Equatable {
    case restored
    case nothingToUndo
    /// The renamed file is no longer there (moved, deleted or renamed again).
    case newNameGone
    /// Something else now holds the old name, and an undo never overwrites.
    case oldNameTaken
    /// The file under the new name is not the one Grux renamed: it was
    /// changed after the rename (saved over, or replaced), so Grux leaves it.
    case fileChanged
    case failed(String)
}

/// The kind of file the namer reads. Everything else is left alone.
enum FileNamingKind: String, Codable, Equatable {
    case image
    case pdf
}

/// Why a file was left alone. The raw values are the `skipped` keys in the
/// status, which the status trigger writes and the Settings row reads.
enum FileNamingSkip: String, CaseIterable {
    case humanName
    case noText
    case modelDeclined
    case changedMeanwhile
    case unsupported
    case error
}

/// What the feature is doing, with no file content in it.
struct FileNamingStatus: Codable, Equatable {
    var enabled: Bool
    var armed: Bool
    var route: String            // "ok" | "noLocalModel" | "notLoopback" | "unknown"
    var model: String?
    var folders: [String]
    var named: Int
    var undone: Int
    var skipped: [String: Int]   // keys: FileNamingSkip raw values
    var lastNamedAt: Date?
    /// Folders in `folders` that are not watched yet: their listing failed
    /// (macOS has not granted access, or the folder is gone), so there is no
    /// baseline to tell a new file from an old one. Retried every 30 s.
    var unwatched: [String] = []
    /// The folders in `unwatched` that do not exist at all, as against ones
    /// macOS will not let Grux list. Each needs a different sentence: a
    /// missing screenshot folder was told to grant a permission that was
    /// never the problem (review 2026-10-28).
    var missing: [String] = []
    /// The screenshot folder's path, when one is watched.
    var screenshotFolder: String? = nil

    static let idle = FileNamingStatus(enabled: false, armed: false, route: "unknown", model: nil,
                                       folders: [], named: 0, undone: 0, skipped: [:], lastNamedAt: nil)

    /// One plain sentence for the Settings status row. No time in it: the
    /// row has no room for a second clock format, and the list below it
    /// already says what was renamed.
    var settingsLine: String {
        guard enabled else {
            return "Off. New screenshots and downloads keep the names they arrive with."
        }
        switch route {
        case "notLoopback":
            return "Paused: the model server in Settings is not on this Mac, and file text never leaves this Mac."
        case "noLocalModel":
            return "Paused: no model is running on this Mac yet. Start Grux Local or another Ollama model to begin."
        default:
            break
        }
        let refused = unwatched.filter { !missing.contains($0) }
        let waitingNames = refused.map { URL(fileURLWithPath: $0).lastPathComponent }
        var waiting = waitingNames.isEmpty ? "" :
            " Waiting to open \(Self.list(waitingNames)): allow Grux in System Settings, Privacy and Security, Files and Folders."
        for path in unwatched where missing.contains(path) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            waiting += path == screenshotFolder
                ? " Waiting for the screenshot folder \(name) to exist."
                : " Waiting for the folder \(name) to exist."
        }
        guard armed else {
            if !waiting.isEmpty { return "Paused." + waiting }
            return "Paused: none of the folders to watch could be found."
        }
        let names = folders.filter { !unwatched.contains($0) }.map { URL(fileURLWithPath: $0).lastPathComponent }
        let watching = names.isEmpty ? "Watching for new files" : "Watching " + Self.list(names)
        let using = model.map { " with \($0)" } ?? ""
        let count = named == 1 ? "1 file named" : "\(named) files named"
        let undoneText = undone > 0 ? ", \(undone) undone" : ""
        return "\(watching)\(using). \(count)\(undoneText).\(waiting)"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

/// What the pipeline would do with one file, without doing it. Written by the
/// preview trigger, which is the eval harness's entry point.
struct FileNamingPreview: Codable, Equatable {
    let path: String
    let decision: String /* "rename" | "leave" */
    let reason: String
    let proposedName: String?
    let readMs: Int
    let modelMs: Int
    let model: String?
}

/// A run over files that were already in the folders ("Name the files
/// already here"), as it stands. Counts only, never a file name.
struct FileNamingBacklog: Codable, Equatable {
    let batch: UUID
    var total: Int
    var done: Int = 0
    var named: Int = 0
    var running: Bool = true
    /// Renames of this run undone since.
    var undone: Int = 0
    /// Stopped before it reached the last file.
    var stopped: Bool = false

    /// One plain sentence for the Settings row.
    var settingsLine: String {
        let files = total == 1 ? "1 file" : "\(total) files"
        if running { return "Naming the files already here: \(done) of \(files) read, \(named) named." }
        let namedText = named == 1 ? "1 file named" : "\(named) files named"
        let undoneText = undone > 0 ? ", \(undone) undone" : ""
        if stopped { return "Stopped after \(done) of \(files): \(namedText)\(undoneText)." }
        return "Done: \(files) read, \(namedText)\(undoneText). Files with names a person typed, and files with no text, kept theirs."
    }
}
