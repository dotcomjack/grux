import Foundation

// Scans a git repo for commits authored inside a half-open time window
// [windowStart, windowEnd). Returns a minimal `LoggedCommitRaw` per commit
// with file-change stats from `git log --numstat`. Caller maps to domain
// types (`LoggedCommit` in the WorkdayLog subsystem).
//
// Pure; no app state. Safe to call from any thread. Runs /usr/bin/env git
// as a subprocess.

public struct LoggedCommitRaw: Equatable {
    public let sha: String
    public let message: String
    public let timestamp: Date
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int

    public init(sha: String, message: String, timestamp: Date,
                filesChanged: Int, insertions: Int, deletions: Int) {
        self.sha = sha; self.message = message; self.timestamp = timestamp
        self.filesChanged = filesChanged; self.insertions = insertions; self.deletions = deletions
    }
}

public enum GitWindowScanner {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // windowEnd is exclusive. Returns [] if not a git repo, missing git,
    // non-zero exit, or the window has zero commits.
    public static func scan(repoPath: URL, windowStart: Date, windowEnd: Date) -> [LoggedCommitRaw] {
        let gitDir = repoPath.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return [] }

        let sinceStr = iso8601.string(from: windowStart)
        let untilStr = iso8601.string(from: windowEnd)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.currentDirectoryURL = repoPath
        p.arguments = [
            "git", "log",
            "--since=\(sinceStr)",
            "--until=\(untilStr)",
            "--no-merges",
            "--numstat",
            // ASCII RS + US between header fields, then a \n before numstat.
            // Stable + unambiguous even in commit messages containing tabs.
            "--pretty=format:\u{1E}%H\u{1F}%s\u{1F}%aI"
        ]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    // Exposed for unit-testing without a real repo.
    public static func parse(_ text: String) -> [LoggedCommitRaw] {
        // Records start at ASCII RS (0x1E). Split on that, ignore leading empty.
        let records = text.components(separatedBy: "\u{1E}").filter { !$0.isEmpty }
        var out: [LoggedCommitRaw] = []

        for record in records {
            // First line = header "SHA\u{1F}MSG\u{1F}ISO"
            // Remaining lines = numstat until EOF or blank.
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let header = lines.first else { continue }
            let parts = header.components(separatedBy: "\u{1F}")
            guard parts.count == 3 else { continue }
            let sha = parts[0]
            let message = parts[1]
            let tsStr = parts[2]
            guard let ts = iso8601.date(from: tsStr) else { continue }

            var files = 0, ins = 0, dels = 0
            for raw in lines.dropFirst() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                // "<ins>\t<dels>\t<path>" - ins/dels can be "-" for binary.
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3 else { continue }
                files += 1
                ins += Int(cols[0]) ?? 0
                dels += Int(cols[1]) ?? 0
            }

            out.append(LoggedCommitRaw(
                sha: sha, message: message, timestamp: ts,
                filesChanged: files, insertions: ins, deletions: dels
            ))
        }

        return out
    }
}
