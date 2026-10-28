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
        let waitingNames = unwatched.map { URL(fileURLWithPath: $0).lastPathComponent }
        let waiting = waitingNames.isEmpty ? "" :
            " Waiting to open \(Self.list(waitingNames)): allow Grux in System Settings, Privacy and Security, Files and Folders."
        guard armed else {
            if !waitingNames.isEmpty { return "Paused." + waiting }
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
