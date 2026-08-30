import Foundation

/// Every shadow repository on this Mac, and what it can restore.
///
/// The snapshot store is created per live session and knows one repository. Nothing knew the
/// SET of them, so once a session ended its snapshots were unreachable even though the
/// commits were still on disk. Discovery is what turns a directory of orphaned repositories
/// back into an undo history: three of them, from April, were sitting on the machine this was
/// written on, one recording `before destructive cmd #1: rm -rf Jordan2`.
public enum ShellSnapshotIndex {

    public struct Session: Sendable, Equatable {
        public let sessionId: String
        /// Where the work tree is, according to the repository itself. Nil for a repository
        /// written before repositories recorded it, which cannot be restored and is reported
        /// rather than hidden.
        public let rootDir: String?
        public let shadowPath: String
        public let snapshots: [ShellSnapshotRecord]
        public let lastActivity: Date?

        /// A session whose work tree is gone, or was never recorded, can be listed but not
        /// restored. Saying so is the point: an undo that silently does nothing is worse than
        /// one that refuses.
        public var isRestorable: Bool {
            guard let rootDir else { return false }
            return FileManager.default.fileExists(atPath: rootDir) && !snapshots.isEmpty
        }
    }

    public static func defaultSupportDir() -> String {
        NSHomeDirectory() + "/Library/Application Support/Grux/shell-snapshots"
    }

    /// Newest first, because an undo is almost always about what just happened.
    public static func sessions(supportDir: String? = nil) async -> [Session] {
        let base = supportDir ?? defaultSupportDir()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }

        var out: [Session] = []
        for entry in entries where entry.hasSuffix(".git") {
            let sessionId = String(entry.dropLast(".git".count))
            let store = ShellSnapshotStore(sessionId: sessionId, rootDir: "",
                                           supportDir: base)
            let root = await store.recordedRootDir()
            // Hydration needs a work tree for the git wrapper's --work-tree flag. Reading a
            // log does not touch it, but git still wants the path to exist, so a session
            // whose root is gone hydrates against the recorded path and simply finds nothing.
            let hydrated = ShellSnapshotStore(sessionId: sessionId,
                                              rootDir: root ?? base,
                                              supportDir: base)
            try? await hydrated.hydrate()
            let records = await hydrated.list()
            out.append(Session(sessionId: sessionId,
                               rootDir: root,
                               shadowPath: base + "/" + entry,
                               snapshots: records,
                               lastActivity: records.last?.createdAt))
        }
        return out.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// Find one snapshot by its id across every session, so a caller can say
    /// `grux undo s2-1a2b3c4` without also naming the session it belongs to.
    public static func locate(snapshotId: String,
                              supportDir: String? = nil) async -> (Session, ShellSnapshotRecord)? {
        for session in await sessions(supportDir: supportDir) {
            if let hit = session.snapshots.first(where: { $0.snapshotId == snapshotId }) {
                return (session, hit)
            }
        }
        return nil
    }
}
