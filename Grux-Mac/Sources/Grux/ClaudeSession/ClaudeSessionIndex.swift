import Foundation

// One row in the Settings "Pick a session" dropdown. Also the input shape
// the tailer consumes when the user assigns a session to a corner.
struct ClaudeSessionDescriptor: Identifiable, Equatable, Hashable {
    let sessionId: String
    let fileURL: URL
    let projectSlug: String    // ~/.claude/projects/<slug>/<sessionId>.jsonl
    let title: String          // cwd basename, or first 60 chars of last user text
    let cwd: String?
    let lastActiveAt: Date
    var id: String { sessionId }
}

// Discovers all Claude Code session logs under ~/.claude/projects and
// returns the most recently active N. Meant to populate the Settings
// picker - not called on a tight loop.
enum ClaudeSessionIndex {

    static var projectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func recentSessions(limit: Int = 50) -> [ClaudeSessionDescriptor] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for dir in projectDirs {
            let children = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children where child.pathExtension == "jsonl" {
                let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                files.append((child, mtime))
            }
        }
        files.sort { $0.1 > $1.1 }

        return files.prefix(limit).compactMap { descriptor(for: $0.0, mtime: $0.1) }
    }

    private static func descriptor(for file: URL, mtime: Date) -> ClaudeSessionDescriptor? {
        let sessionId = file.deletingPathExtension().lastPathComponent
        let projectSlug = file.deletingLastPathComponent().lastPathComponent

        // Read the TAIL, not the file.
        //
        // This used to read and split the whole thing, justified by a comment saying most
        // sessions are under 5MB and that a 50-file index read is about 250ms, which is
        // fine for a settings picker. Both halves of that stopped being true. The
        // transcripts on this machine reach 537MB, and the caller is no longer a settings
        // picker: `TerminalFocusState.refreshClaudeSessionIndexIfStale()` drives it from a
        // timer. A `sample` of the shipping build put 8404 of its main-thread samples in
        // here, split over hundreds of megabytes, which made it the single largest cost in
        // the app.
        //
        // A descriptor needs `title`, `cwd` and `lastActiveAt`, and all three come from the
        // LAST entries. Reading the final chunk answers them identically for any session
        // whose tail carries a cwd, which is every ordinary one, and falls back to the same
        // sessionId-prefix title this function already used when the parse yields nothing.
        let lines = readTailLines(file)
        let snap = ClaudeSessionJSONL.snapshot(fromLines: lines, sessionId: sessionId)

        return ClaudeSessionDescriptor(
            sessionId: sessionId,
            fileURL: file,
            projectSlug: projectSlug,
            title: snap?.title ?? String(sessionId.prefix(8)),
            cwd: snap?.cwd,
            lastActiveAt: snap?.lastMessageAt ?? mtime
        )
    }

    /// How much of the end of a transcript to read. Generous enough to hold many entries
    /// even when one carries a large tool result, small enough that the cost no longer
    /// scales with session length.
    private static let tailByteBudget = 256 * 1024

    private static func readTailLines(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailByteBudget) ? size - UInt64(tailByteBudget) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // A tail almost always begins mid-line. Decoding can therefore start on a partial
        // UTF-8 sequence, so decode lossily rather than returning nothing, and drop the
        // first line when the read did not start at the beginning of the file. That line
        // is a fragment and would parse as junk or, worse, as a valid-looking entry.
        var lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" })
            .map(String.init)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
