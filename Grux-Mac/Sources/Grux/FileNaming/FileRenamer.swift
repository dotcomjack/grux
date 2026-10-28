import Foundation

/// The size and file number of a file, recorded when it settled. A rename
/// goes ahead only when the file still matches, so a file the person renamed,
/// replaced or rewrote in the meantime is left alone.
struct FileFingerprint: Equatable {
    let size: Int64
    let fileNumber: UInt64

    /// nil when the path is not a regular file (missing, a folder, a package
    /// such as Safari's `.download` bundle, or a link).
    static func of(_ url: URL, fileManager fm: FileManager) -> FileFingerprint? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return FileFingerprint(size: size, fileNumber: number)
    }
}

/// One entry of a watched folder, as a listing reads it off the main actor.
/// `fileID` is the same number as `FileFingerprint.fileNumber` (`st_ino`),
/// which is what tells a file from its name: a rename keeps it, a new file
/// gets a new one.
struct FileNamingEntry: Equatable, Sendable {
    let name: String
    let fileID: UInt64
    let size: Int64
    /// The birth time (`st_birthtime`), what Finder shows as Created.
    let created: Date
    let isRegular: Bool

    /// Every entry of `folder` with one `lstat` each, or nil when the folder
    /// cannot be listed at all. nil is not "empty": a listing macOS refused
    /// (folder access not granted), or a folder that is gone, has no
    /// baseline, and an empty one would make every file already there read as
    /// new the moment access is granted (review 2026-10-28). Never call this on
    /// the main actor: listing a protected folder before access is granted
    /// waits on the permission dialog.
    static func list(_ folder: URL) -> [FileNamingEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.compactMap { name in
            var st = stat()
            guard lstat(folder.appendingPathComponent(name).path, &st) == 0 else { return nil }
            let birth = st.st_birthtimespec
            return FileNamingEntry(
                name: name,
                fileID: UInt64(st.st_ino),
                size: Int64(st.st_size),
                created: Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1_000_000_000),
                isRegular: (st.st_mode & S_IFMT) == S_IFREG)
        }
    }
}

enum FileRenameError: Error, Equatable {
    /// The file is gone, or no longer the file that settled.
    case changedMeanwhile
    /// The name is empty or would leave the folder.
    case badName
}

/// Renames a file inside its own folder and nowhere else.
struct FileRenamer {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// `<base>.<ext>`, then `<base> 2.<ext>`, `<base> 3.<ext>`, until the name
    /// is free. The extension keeps the case it arrived with.
    func uniqueName(base: String, ext: String, in folder: URL) -> String {
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 1
        while fileManager.fileExists(atPath: folder.appendingPathComponent(name(n)).path) && n < 10_000 { n += 1 }
        return name(n)
    }

    /// Renames `url` to `base` plus its own extension, in its own folder.
    /// Never overwrites: the name is made unique first, and `moveItem` refuses
    /// an existing destination anyway. Throws `.changedMeanwhile` when the
    /// file no longer matches `expecting`.
    func rename(_ url: URL, to base: String, expecting: FileFingerprint?) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":")
        else { throw FileRenameError.badName }
        guard let now = FileFingerprint.of(url, fileManager: fileManager) else {
            throw FileRenameError.changedMeanwhile
        }
        if let expecting, expecting != now { throw FileRenameError.changedMeanwhile }
        let folder = url.deletingLastPathComponent()
        let target = folder.appendingPathComponent(uniqueName(base: trimmed, ext: url.pathExtension, in: folder))
        guard target.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
        else { throw FileRenameError.badName }
        try fileManager.moveItem(at: url, to: target)
        return target
    }
}

/// Every rename Grux made, newest last, so each one can be undone. Lives under
/// `Persistence.supportDir`, which is Grux's own storage (and a private folder
/// under test), never a folder a person browses (`NoSurpriseFoldersTests`).
final class FileRenameLedger {

    static let cap = 200

    static var defaultURL: URL {
        Persistence.supportDir
            .appendingPathComponent("FileNaming", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    let url: URL
    private let fileManager: FileManager
    private(set) var entries: [FileRename]

    init(url: URL = FileRenameLedger.defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.entries = Self.load(url)
    }

    /// Newest first, at most `limit`.
    func recent(_ limit: Int = 10) -> [FileRename] {
        Array(entries.suffix(limit).reversed())
    }

    func append(_ rename: FileRename) {
        entries.append(rename)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        save()
    }

    /// Puts the old name back, only when the renamed file is still there and
    /// nothing has taken the old name. Otherwise it says why and changes
    /// nothing. "Still there" is by file number when the entry has one: a file
    /// a person saved later under the same new name is not Grux's file, and
    /// renaming it would destroy a name they chose.
    func undo(id: UUID) -> FileUndoOutcome {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].undoneAt == nil else {
            return .nothingToUndo
        }
        let entry = entries[i]
        let folder = URL(fileURLWithPath: entry.folder, isDirectory: true)
        let renamed = folder.appendingPathComponent(entry.newName)
        let original = folder.appendingPathComponent(entry.oldName)
        guard fileManager.fileExists(atPath: renamed.path) else { return .newNameGone }
        if let want = entry.fileID,
           FileFingerprint.of(renamed, fileManager: fileManager)?.fileNumber != want { return .newNameGone }
        guard !fileManager.fileExists(atPath: original.path) else { return .oldNameTaken }
        do {
            try fileManager.moveItem(at: renamed, to: original)
        } catch {
            return .failed(error.localizedDescription)
        }
        entries[i].undoneAt = Date()
        save()
        return .restored
    }

    /// The newest rename not yet undone.
    func undoLast() -> FileUndoOutcome {
        guard let last = entries.last(where: { $0.undoneAt == nil }) else { return .nothingToUndo }
        return undo(id: last.id)
    }

    func entry(id: UUID) -> FileRename? {
        entries.first { $0.id == id }
    }

    // MARK: - Disk

    private static func load(_ url: URL) -> [FileRename] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([FileRename].self, from: data) else { return [] }
        return Array(entries.suffix(cap))
    }

    /// Creates its folder at the point of writing, never in a getter.
    private func save() {
        // Dates in the default encoding, which reads back to the same Date,
        // so an entry decoded from disk equals the one that was written.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
