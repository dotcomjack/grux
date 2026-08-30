import XCTest
@testable import GruxShellCore

/// The shell undo safety net, driven against a real shadow repository on disk.
///
/// Everything here uses a temp support directory. `NSHomeDirectory()` ignores `$HOME`, so
/// without that seam these tests would create repositories inside the operator's real
/// Application Support and leave them there.
final class ShellSnapshotDurabilityTests: XCTestCase {

    private var tmp: URL!
    private var work: URL!
    private var support: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grux-snap-" + UUID().uuidString)
        work = tmp.appendingPathComponent("work")
        support = tmp.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func store(_ id: String = "test-session") -> ShellSnapshotStore {
        ShellSnapshotStore(sessionId: id, rootDir: work.path, supportDir: support.path)
    }

    private func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--git-dir", dir] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Signing

    /// A SNAPSHOT IS NEVER SIGNED.
    ///
    /// The shadow repo inherits the user's global git config, and `commit.gpgsign = true` is
    /// common. Measured on the machine this was written on: every existing snapshot commit
    /// had been SSH-signed with the operator's personal key. That attaches a personal
    /// identity to internal state for no reason, and worse, it makes the safety net depend
    /// on a signing key being available. A passphrase-protected key turns `git commit` into
    /// a prompt, and the snapshot that fails is the one taken immediately before a
    /// destructive command.
    func testSnapshotsAreNeverSigned() async throws {
        let s = store()
        try await s.ensureInitialized()
        let dir = s.shadowPath

        XCTAssertEqual(try git(["config", "--get", "commit.gpgsign"], in: dir), "false",
            "the shadow repo does not disable commit signing, so it inherits the global one")

        try "hello".write(to: work.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        _ = try await s.snapshot(label: "first", trigger: "manual", commandIndex: 1)

        let sig = try git(["log", "-1", "--format=%G?"], in: dir)
        XCTAssertEqual(sig, "N", "a snapshot commit came out signed, state \(sig)")
        XCTAssertEqual(try git(["log", "-1", "--format=%an"], in: dir), "Grux ShellTool",
            "a snapshot was authored by somebody other than the tool")
    }

    // MARK: - Durability

    /// AN UNDO MUST SURVIVE A RESTART.
    ///
    /// The record list is in memory and nothing ever persisted it, so `restore` on a fresh
    /// store threw "no snapshots exist" while the commits sat on disk the whole time. A
    /// safety net that evaporates when the app restarts is not one.
    func testAFreshStoreRecoversSnapshotsFromDisk() async throws {
        let first = store()
        try await first.ensureInitialized()
        try "one".write(to: work.appendingPathComponent("a.txt"),
                        atomically: true, encoding: .utf8)
        _ = try await first.snapshot(label: "session start", trigger: "manual", commandIndex: 0)
        try "two".write(to: work.appendingPathComponent("a.txt"),
                        atomically: true, encoding: .utf8)
        _ = try await first.snapshot(label: "before destructive cmd #1",
                                     trigger: "destructive-detect", commandIndex: 1)

        // A COMPLETELY NEW STORE, as though the app had been quit and reopened.
        let reopened = store()
        let emptyAtFirst = await reopened.list().isEmpty
        XCTAssertTrue(emptyAtFirst, "a fresh store starts empty")
        try await reopened.hydrate()
        let recovered = await reopened.list()

        // GUARD, NOT ASSERT, BEFORE INDEXING. XCTAssertEqual does not stop execution, so
        // `recovered[1]` on an empty array crashed the whole xctest process with "Index out
        // of range" rather than failing. That takes down every other test in the run and
        // prints no assertion message at all, which is exactly what happened the first time
        // this test was checked against a planted defect.
        guard recovered.count == 2 else {
            return XCTFail("recovered \(recovered.count) snapshots from a repo holding 2")
        }
        XCTAssertEqual(recovered.map(\.label), ["session start", "before destructive cmd #1"],
            "recovered in the wrong order, so `undo` with no argument targets the wrong one")
        XCTAssertEqual(recovered[1].trigger, "destructive-detect",
            "the trigger did not survive, so nothing can tell a routine baseline from a guard")
        XCTAssertEqual(recovered[1].commandIndex, 1)
    }

    /// And the recovered snapshot actually restores.
    func testARecoveredSnapshotRestoresTheWorkTree() async throws {
        let first = store()
        try await first.ensureInitialized()
        let file = work.appendingPathComponent("a.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        _ = try await first.snapshot(label: "before", trigger: "manual", commandIndex: 0)

        try "destroyed".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "destroyed")

        let reopened = store()
        try await reopened.hydrate()
        _ = try await reopened.restore(to: nil)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original",
            "a snapshot recovered from disk did not restore the file")
    }

    /// The shadow repo knows where its own work tree is.
    ///
    /// Without this the commits are unusable after a restart: the path lives only in memory,
    /// so a relaunch leaves a directory of commits nothing knows how to apply.
    func testTheShadowRepoRecordsItsWorkTree() async throws {
        let s = store()
        try await s.ensureInitialized()
        let recorded = await s.recordedRootDir()
        XCTAssertEqual(recorded, work.path,
            "the shadow repo does not know its work tree, so a dead session cannot be undone")
    }

    /// READING A REPOSITORY MUST NOT REQUIRE KNOWING ITS WORK TREE.
    ///
    /// Discovery has to answer "which folder does this belong to" for a repository it knows
    /// nothing about, so it constructs a store with an empty `rootDir`. The git wrapper adds
    /// `--work-tree=<rootDir>` to every call, and `git --work-tree=` on an empty string is a
    /// hard error: "The empty string is not a valid path". So the probe failed, and every
    /// recovered session reported that it did not know its own folder and could not be
    /// restored.
    ///
    /// The existing test for this passed the whole time, because it supplied a real
    /// `rootDir`, which is the one thing the caller that matters cannot do. Only driving the
    /// shipped binary against a real shadow repository showed it.
    func testAStoreWithNoWorkTreeCanStillReadTheRepository() async throws {
        let seeded = store()
        try await seeded.ensureInitialized()
        try "one".write(to: work.appendingPathComponent("a.txt"),
                        atomically: true, encoding: .utf8)
        _ = try await seeded.snapshot(label: "session start", trigger: "manual", commandIndex: 0)

        // Exactly what discovery does: it has the session id and nothing else.
        let blind = ShellSnapshotStore(sessionId: "test-session", rootDir: "",
                                       supportDir: support.path)
        let root = await blind.recordedRootDir()
        XCTAssertEqual(root, work.path,
            "a store with no work tree could not read the recorded one, so discovery reports "
            + "every session as unrestorable")

        try await blind.hydrate()
        let records = await blind.list()
        XCTAssertEqual(records.count, 1,
            "hydrating without a work tree recovered \(records.count) snapshots, expected 1")
    }

    /// Discovery finds a finished session and calls it restorable.
    func testDiscoveryFindsAFinishedSessionAndCanRestoreIt() async throws {
        let seeded = store("discoverable")
        try await seeded.ensureInitialized()
        let file = work.appendingPathComponent("a.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        _ = try await seeded.snapshot(label: "session start", trigger: "manual", commandIndex: 0)
        try "destroyed".write(to: file, atomically: true, encoding: .utf8)

        let sessions = await ShellSnapshotIndex.sessions(supportDir: support.path)
        guard let found = sessions.first(where: { $0.sessionId == "discoverable" }) else {
            return XCTFail("discovery did not find the session, saw "
                           + "\(sessions.map(\.sessionId))")
        }
        XCTAssertEqual(found.rootDir, work.path)
        XCTAssertTrue(found.isRestorable, "a session with a live folder and one snapshot "
                      + "was reported as not restorable")
        XCTAssertEqual(found.snapshots.count, 1)

        guard let (_, record) = await ShellSnapshotIndex
            .locate(snapshotId: found.snapshots[0].snapshotId, supportDir: support.path) else {
            return XCTFail("locate could not find a snapshot discovery had just listed")
        }
        let restorer = ShellSnapshotStore(sessionId: found.sessionId, rootDir: work.path,
                                          supportDir: support.path)
        try await restorer.hydrate()
        _ = try await restorer.restore(to: record.snapshotId)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    /// A RESTORE MUST REPORT WHAT IT DELETED, not only what it put back.
    ///
    /// `git diff --name-only <sha>` reports TRACKED differences only, so a file created
    /// after the snapshot is invisible to it, and the `git clean -fdq` that follows deletes
    /// it anyway. The list handed back was missing exactly the files the restore DESTROYED.
    ///
    /// In the worst case the whole list came back empty and `grux undo` printed "Nothing had
    /// changed since then, so nothing needed putting back" over a deletion that had just
    /// happened. A safety net that reports the opposite of what it did is worse than one
    /// that does nothing, because it stops somebody looking.
    func testRestoreReportsFilesItDeletesNotOnlyOnesItRestores() async throws {
        let s = store()
        try await s.ensureInitialized()
        try "tracked".write(to: work.appendingPathComponent("tracked.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await s.snapshot(label: "before", trigger: "manual", commandIndex: 0)

        // The ONLY change is a brand new file. Nothing tracked differs at all, which is the
        // case that reported an empty list.
        let created = work.appendingPathComponent("newfile.txt")
        try "made after the snapshot".write(to: created, atomically: true, encoding: .utf8)

        let changed = try await s.restore(to: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path),
            "clean did not remove the untracked file, so this test is not exercising the bug")
        XCTAssertTrue(changed.contains("newfile.txt"),
            "restore deleted newfile.txt and reported \(changed), so the caller is told "
            + "nothing about a file that no longer exists")
    }

    /// And a restore that genuinely changes nothing still reports nothing, or the fix above
    /// would just make every restore claim to have done something.
    func testARestoreThatChangesNothingReportsNothing() async throws {
        let s = store()
        try await s.ensureInitialized()
        try "same".write(to: work.appendingPathComponent("a.txt"),
                         atomically: true, encoding: .utf8)
        _ = try await s.snapshot(label: "before", trigger: "manual", commandIndex: 0)

        let changed = try await s.restore(to: nil)
        XCTAssertTrue(changed.isEmpty,
            "a restore with nothing to undo reported \(changed)")
    }

    // MARK: - The rule that matters most

    /// THE REAL `.git` IS NEVER TOUCHED. Acceptance criterion 11.
    ///
    /// The work tree is somebody's actual project. If undo reached their real repository it
    /// could destroy uncommitted work or corrupt an in-progress rebase, which is far worse
    /// than the command it was undoing.
    func testRestoringNeverTouchesTheRealGitRepository() async throws {
        // A real repository in the work tree, with real history and a real dirty file.
        func realGit(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", work.path] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try realGit(["init", "-q"])
        try realGit(["config", "user.email", "t@t.local"])
        try realGit(["config", "user.name", "T"])
        try realGit(["config", "commit.gpgsign", "false"])
        try "v1".write(to: work.appendingPathComponent("tracked.txt"),
                       atomically: true, encoding: .utf8)
        try realGit(["add", "-A"])
        try realGit(["commit", "-q", "-m", "real commit"])

        let realDir = work.appendingPathComponent(".git").path
        let headBefore = try git(["rev-parse", "HEAD"], in: realDir)
        let reflogBefore = try git(["reflog", "--format=%H %gs"], in: realDir)
        let branchBefore = try git(["symbolic-ref", "HEAD"], in: realDir)
        XCTAssertFalse(headBefore.isEmpty, "the real repo has no HEAD, so this proves nothing")

        let s = store()
        try await s.ensureInitialized()
        _ = try await s.snapshot(label: "before", trigger: "manual", commandIndex: 0)
        try "v2-destroyed".write(to: work.appendingPathComponent("tracked.txt"),
                                 atomically: true, encoding: .utf8)
        _ = try await s.restore(to: nil)

        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: realDir), headBefore,
            "the real repository's HEAD moved")
        XCTAssertEqual(try git(["reflog", "--format=%H %gs"], in: realDir), reflogBefore,
            "the real repository's reflog gained an entry, so something wrote to it")
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], in: realDir), branchBefore,
            "the real repository changed branch")

        // And the restore did do its job, or the three assertions above are vacuous.
        let content = try String(contentsOf: work.appendingPathComponent("tracked.txt"),
                                 encoding: .utf8)
        XCTAssertEqual(content, "v1", "the work tree was not restored, so nothing was tested")
    }
}
