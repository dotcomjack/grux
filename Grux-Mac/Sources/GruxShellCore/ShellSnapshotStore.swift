import Foundation

// MARK: - ShellSnapshotStore
//
// The "reversibility" half of Grux's shell tool. Before any command that could
// write, we snapshot the session's rootDir. On undo, we restore.
//
// Mechanism: shadow git.
//   - We never touch the user's real `.git` in rootDir (would corrupt their
//     working tree and fight any in-progress rebase/merge).
//   - We keep a PARALLEL git directory per session at:
//         ~/Library/Application Support/Grux/shell-snapshots/<sessionId>.git
//   - That repo uses rootDir as its work-tree via `--git-dir` + `--work-tree`.
//   - Each snapshot = one commit. Each undo = reset --hard to that sha (within
//     the shadow repo - the rootDir files change, but the real .git is untouched).
//
// Why not APFS snapshots? `tmutil localsnapshot` is volume-wide - can't target
// a folder; restoring touches the whole disk. Shadow git works on any folder,
// is fast enough (~100ms for Projecto 2.0, seconds for larger trees), shows
// clear per-file diffs, and handles the "undo this one command" case cleanly.
//
// Excluded from snapshots (via shadow-excludes file): node_modules, .git/,
// build/, dist/, .next/, target/, .venv/, __pycache__. These regenerate from
// source; snapshotting them inflates disk + slows commits with no benefit.

public actor ShellSnapshotStore {

    private let sessionId: String
    private let rootDir: String
    private let shadowGitDir: String
    private var records: [ShellSnapshotRecord] = []

    /// `supportDir` is a TEST SEAM and nothing else passes it.
    ///
    /// `NSHomeDirectory()` ignores `$HOME`, so a test cannot redirect this by setting an
    /// environment variable: it would create shadow repositories inside the operator's real
    /// Application Support directory and leave them there. That has already happened once in
    /// this codebase, when the suite wrote 16 KB into the operator's own `~/.grux`.
    public init(sessionId: String, rootDir: String, supportDir: String? = nil) {
        self.sessionId = sessionId
        self.rootDir = rootDir
        let base = supportDir
            ?? (NSHomeDirectory() + "/Library/Application Support/Grux/shell-snapshots")
        self.shadowGitDir = base + "/" + sessionId + ".git"
    }

    /// Where the shadow repo lives, so a test can look at it without recomputing the path.
    public nonisolated var shadowPath: String { shadowGitDir }

    // MARK: - Public API

    public func ensureInitialized() async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (shadowGitDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let headFile = shadowGitDir + "/HEAD"
        if fm.fileExists(atPath: headFile) { return }
        // `git init --bare <path>` creates the bare repo layout at <path>. We must
        // NOT pass --git-dir / --work-tree here - those only make sense once the
        // repo exists. Use runGitRaw to bypass the wrapper that adds those flags.
        let initResult = try await runGitRaw(["init", "--bare", "-q", shadowGitDir])
        if initResult.exitCode != 0 {
            throw ShellToolError.snapshotFailed("git init failed: \(initResult.stderr)")
        }
        // Write a gitignore-equivalent via excludesfile so node_modules etc. never
        // land in the shadow repo. Kept inside the shadow dir - does NOT create a
        // .gitignore in rootDir.
        let excludes = """
        node_modules/
        .git/
        .DS_Store
        build/
        dist/
        .next/
        target/
        .venv/
        __pycache__/
        .gruxshell.log
        """
        let excludesPath = shadowGitDir + "/info/exclude"
        try fm.createDirectory(atPath: (excludesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try excludes.write(toFile: excludesPath, atomically: true, encoding: .utf8)
        // Configure commit identity for the shadow repo - won't pollute global config.
        try await runGit(["config", "user.email", "shell@grux.local"])
        try await runGit(["config", "user.name", "Grux ShellTool"])

        // NEVER SIGN A SNAPSHOT. A bare repo inherits the user's global git config, and
        // `commit.gpgsign = true` is common. Measured on this machine: every snapshot commit
        // in the shadow repo was SSH-signed with the operator's personal key.
        //
        // Two reasons that is wrong, and the second is the serious one. It attaches a
        // personal identity to internal machine state for no reason. And it makes the safety
        // net depend on a signing key being available: a passphrase-protected key or one on
        // a hardware token turns `git commit` into a prompt, and the snapshot taken
        // immediately BEFORE a destructive command is the one that fails. The net would be
        // missing at the exact moment it exists for.
        try await runGit(["config", "commit.gpgsign", "false"])

        // The shadow repo describes itself. Without this a snapshot cannot be restored once
        // the session that made it is gone: the work tree path lives only in memory, so a
        // relaunch leaves a directory full of commits nothing knows how to apply.
        try await runGit(["config", "grux.rootdir", rootDir])
        try await runGit(["config", "grux.sessionid", sessionId])
    }

    /// Rebuild the record list from the shadow repo's own history.
    ///
    /// `records` is in memory and nothing ever persisted it, so an undo was only possible
    /// inside the session that created it. A safety net that disappears when the app restarts
    /// is not a safety net, and the commits were on disk the whole time with usable labels.
    ///
    /// Trailers give the trigger and command index back. A repo written before those existed
    /// hydrates with what the message carries and says `unknown` rather than guessing, which
    /// is why `trigger` is a string here and not an enum.
    public func hydrate() async throws {
        guard records.isEmpty else { return }
        // RAW, with no --work-tree. Reading history does not need one, and requiring one
        // means a caller that only wants to inspect a repository has to invent a path.
        // `git --work-tree=` on an empty string is a hard error, "The empty string is not a
        // valid path", so the probe used during discovery failed and every recovered session
        // reported that it did not know its own folder.
        let log = try await runGitRaw(["--git-dir=\(shadowGitDir)",
                                       "log", "--reverse",
                                       "--format=%H%x00%at%x00%s%x00%b%x1E"])
        guard log.exitCode == 0 else { return }

        var rebuilt: [ShellSnapshotRecord] = []
        for entry in log.stdout.split(separator: "\u{1E}") {
            let parts = entry.split(separator: "\u{0}", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 3, !parts[0].isEmpty else { continue }
            let sha = parts[0]
            let when = Double(parts[1]).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let label = parts[2]
            let body = parts.count > 3 ? parts[3] : ""

            func trailer(_ key: String) -> String? {
                for line in body.split(separator: "\n") where line.hasPrefix(key + ":") {
                    return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }

            rebuilt.append(ShellSnapshotRecord(
                snapshotId: "s\(rebuilt.count + 1)-\(sha.prefix(7))",
                commitSha: sha,
                trigger: trailer("Grux-Trigger") ?? "unknown",
                createdAt: when,
                commandIndex: trailer("Grux-Command-Index").flatMap(Int.init) ?? 0,
                label: label))
        }
        records = rebuilt
    }

    /// Where this shadow repo's work tree is, according to the repo itself.
    public func recordedRootDir() async -> String? {
        // Raw, for the same reason: this is the call that ANSWERS "what is the work tree",
        // so it cannot require one to be supplied first.
        let r = try? await runGitRaw(["--git-dir=\(shadowGitDir)",
                                      "config", "--get", "grux.rootdir"])
        let value = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    // Take a snapshot with a label. Returns the created record (also pushed onto the log).
    public func snapshot(label: String, trigger: String, commandIndex: Int) async throws -> ShellSnapshotRecord {
        try await ensureInitialized()
        try await runGit(["add", "-A"])
        // `commit --allow-empty` so a clean-tree snapshot still records a marker
        // we can roll back TO. Needed for the per-turn baseline before the first
        // write happens.
        // TRAILERS, so this commit can be read back as a record after a restart. The label
        // alone cannot say whether a snapshot was a turn baseline or a guard placed in front
        // of something destructive, and that is the difference between the two things
        // somebody undoing wants to find.
        let message = label + "\n\nGrux-Trigger: " + trigger
            + "\nGrux-Command-Index: " + String(commandIndex)
        let result = try await runGit(["commit", "--allow-empty", "-q", "-m", message])
        if result.exitCode != 0 {
            throw ShellToolError.snapshotFailed("git commit failed: \(result.stderr)")
        }
        let shaResult = try await runGit(["rev-parse", "HEAD"])
        let sha = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotId = "s\(records.count + 1)-\(sha.prefix(7))"
        let record = ShellSnapshotRecord(
            snapshotId: snapshotId,
            commitSha: sha,
            trigger: trigger,
            createdAt: Date(),
            commandIndex: commandIndex,
            label: label
        )
        records.append(record)
        return record
    }

    // Restore to a specific snapshot (by snapshotId) or the most recent one if nil.
    // Returns list of files that changed as a result.
    public func restore(to snapshotId: String?) async throws -> [String] {
        guard !records.isEmpty else {
            throw ShellToolError.restoreFailed("no snapshots exist for this session yet")
        }
        let target: ShellSnapshotRecord
        if let id = snapshotId {
            guard let found = records.first(where: { $0.snapshotId == id }) else {
                throw ShellToolError.restoreFailed("snapshot '\(id)' not found")
            }
            target = found
        } else {
            target = records.last!
        }
        // Diff first so the caller can report what changed. `git diff --name-only <sha> HEAD`
        // tells us what files are different NOW from the snapshot target.
        let diff = try await runGit(["diff", "--name-only", target.commitSha])
        var changed = Set(diff.stdout
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty })

        // AND WHAT `clean` IS ABOUT TO DELETE, which the diff above cannot see.
        //
        // `git diff --name-only` reports TRACKED differences only. A file created after the
        // snapshot is untracked in the shadow repo, so it is absent from that list, and the
        // `git clean -fdq` below then deletes it. The report handed back to the caller was
        // therefore missing exactly the files the restore DESTROYED rather than restored.
        //
        // Measured: snapshot, create one new file, restore. `git diff --name-only` returned
        // zero lines, clean removed the file, and `grux undo` printed "Nothing had changed
        // since then, so nothing needed putting back" over a deletion that had just
        // happened. A safety net reporting the opposite of what it did is worse than one
        // that does nothing.
        //
        // `-n` is the dry run, so this enumerates before anything is removed. It has to run
        // BEFORE the reset too, because a reset can itself leave the tree in a state where
        // clean would choose differently.
        let doomed = try await runGit(["clean", "-fdn", "-e", "node_modules", "-e", ".git"])
        for line in doomed.stdout.split(separator: "\n") {
            // git prints `Would remove <path>` for each, one per line.
            guard line.hasPrefix("Would remove ") else { continue }
            let path = String(line.dropFirst("Would remove ".count))
                .trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { changed.insert(path) }
        }
        // Hard reset the work tree to the snapshot commit. This CANNOT touch the
        // user's real .git in rootDir because we use --git-dir pointed at the
        // shadow repo - git writes to the work-tree files only.
        let reset = try await runGit(["reset", "--hard", "-q", target.commitSha])
        if reset.exitCode != 0 {
            throw ShellToolError.restoreFailed("git reset --hard failed: \(reset.stderr)")
        }
        // `git reset --hard` restores tracked files to snapshot state, but doesn't
        // remove UNTRACKED files added after the snapshot. To make "undo" feel
        // right we also `git clean -fd` - but we scope it with the excludes so
        // node_modules etc. isn't blown away.
        _ = try await runGit(["clean", "-fdq", "-e", "node_modules", "-e", ".git"])
        return changed.sorted()
    }

    public func list() -> [ShellSnapshotRecord] { records }

    public func diff(against snapshotId: String) async throws -> String {
        guard let rec = records.first(where: { $0.snapshotId == snapshotId }) else {
            throw ShellToolError.restoreFailed("snapshot '\(snapshotId)' not found")
        }
        let r = try await runGit(["diff", "--stat", rec.commitSha])
        return r.stdout
    }

    // Cleanup: delete the shadow repo. Called on session end.
    public func tearDown() async {
        let fm = FileManager.default
        try? fm.removeItem(atPath: shadowGitDir)
    }

    // MARK: - Internals

    private struct GitResult { let stdout: String; let stderr: String; let exitCode: Int32 }

    private func runGit(_ args: [String]) async throws -> GitResult {
        return try await runGitRaw(["--git-dir=\(shadowGitDir)", "--work-tree=\(rootDir)"] + args)
    }

    private func runGitRaw(_ args: [String]) async throws -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return GitResult(stdout: out, stderr: err, exitCode: proc.terminationStatus)
    }
}
