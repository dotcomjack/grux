import XCTest
@testable import Grux

// Items 32 + 33: BackupManager.
//
// Every test runs against an injected temp-dir sandbox (supportRoot /
// documentsRoot / safetyRoot) so the REAL Application Support and Documents
// trees are never touched. Zip/unzip go through the same /usr/bin binaries
// the app uses, so the round-trip is exercised for real.
final class BackupManagerTests: XCTestCase {

    private var sandbox: URL!
    private var supportRoot: URL!
    private var documentsRoot: URL!
    private var safetyRoot: URL!
    private var backupsDir: URL!
    private var manager: BackupManager!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-backup-tests-\(UUID().uuidString)", isDirectory: true)
        supportRoot = sandbox.appendingPathComponent("support-root", isDirectory: true)
        documentsRoot = sandbox.appendingPathComponent("documents-root", isDirectory: true)
        safetyRoot = sandbox.appendingPathComponent("safety-root", isDirectory: true)
        backupsDir = sandbox.appendingPathComponent("backups", isDirectory: true)
        for dir in [supportRoot!, documentsRoot!, backupsDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        manager = BackupManager(supportRoot: supportRoot, documentsRoot: documentsRoot, safetyRoot: safetyRoot)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ text: String, to relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ relative: String, under root: URL) -> String? {
        let url = root.appendingPathComponent(relative)
        return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func seedTypicalTree() throws {
        try write("{\"threads\":[]}", to: "chat-threads/index.json", under: supportRoot)
        try write("{\"id\":\"t1\"}", to: "chat-threads/t1.json", under: supportRoot)
        try write("{\"job\":\"j1\"}", to: "agents/j1/job.json", under: supportRoot)
        try write("day one", to: "workday-logs/2026-06-08.ndjson", under: supportRoot)
        try write("not durable", to: "audio-wal/m1/chunk0.pcm", under: supportRoot)
        try write("a doc", to: "exports/grux-memory-x.json", under: documentsRoot)
    }

    // MARK: - Manifest round-trip

    func test_manifest_jsonRoundTrip() throws {
        let manifest = BackupManifest(
            schemaVersion: BackupManifest.currentSchemaVersion,
            appVersion: "1.2",
            appBuild: "42",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            hostName: "test-mac",
            componentSchemaVersions: BackupManifest.snapshotComponentVersions(),
            entries: [
                .init(root: "support", relativePath: "chat-threads/index.json", byteCount: 14)
            ],
            totalFiles: 1,
            totalBytes: 14
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(BackupManifest.self, from: enc.encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.componentSchemaVersions["manifest"], BackupManifest.currentSchemaVersion)
        XCTAssertEqual(decoded.componentSchemaVersions["memory-export"], GruxMemoryExport.currentSchemaVersion)
    }

    // MARK: - Backup

    func test_createBackup_producesArchiveWithReadableManifest() async throws {
        try seedTypicalTree()
        let archive = try await manager.createBackup(to: backupsDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(archive.lastPathComponent.hasPrefix("grux-backup-"))
        XCTAssertEqual(archive.pathExtension, "zip")

        let manifest = try await manager.readManifest(fromArchive: archive)
        XCTAssertEqual(manifest.schemaVersion, BackupManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.totalFiles, manifest.entries.count)

        let paths = Set(manifest.entries.map { "\($0.root)/\($0.relativePath)" })
        XCTAssertTrue(paths.contains("support/chat-threads/index.json"))
        XCTAssertTrue(paths.contains("support/chat-threads/t1.json"))
        XCTAssertTrue(paths.contains("support/agents/j1/job.json"))
        XCTAssertTrue(paths.contains("support/workday-logs/2026-06-08.ndjson"))
        XCTAssertTrue(paths.contains("documents/exports/grux-memory-x.json"))
        // Transient WAL data must be excluded.
        XCTAssertFalse(paths.contains { $0.contains("audio-wal") })
    }

    func test_createBackup_excludesPreviousBackupArchives() async throws {
        // The DEFAULT destination (~/Documents/Grux/backups) lives inside
        // documentsRoot. Without the exclusion every archive embeds all
        // earlier ones and backup size compounds run over run.
        try seedTypicalTree()
        let insideDocs = documentsRoot.appendingPathComponent("backups", isDirectory: true)
        _ = try await manager.createBackup(to: insideDocs)
        try write("stray archive", to: "grux-backup-2026-01-01-000000.zip", under: documentsRoot)

        let second = try await manager.createBackup(to: insideDocs)
        let manifest = try await manager.readManifest(fromArchive: second)
        let paths = Set(manifest.entries.map { "\($0.root)/\($0.relativePath)" })
        XCTAssertFalse(paths.contains { $0.contains("backups/") }, "backups dir must not be re-archived")
        XCTAssertFalse(paths.contains { $0.contains("grux-backup-") }, "previous archives must not be re-archived")
        XCTAssertTrue(paths.contains("documents/exports/grux-memory-x.json"), "real documents still included")
    }

    func test_createBackup_emptyTreesThrows() async throws {
        do {
            _ = try await manager.createBackup(to: backupsDir)
            XCTFail("expected nothingToBackUp")
        } catch let e as BackupError {
            guard case .nothingToBackUp = e else { return XCTFail("wrong error: \(e)") }
        }
    }

    func test_readManifest_rejectsNonBackupZip() async throws {
        // A zip with no manifest.json must be rejected at preview time.
        try write("hello", to: "random.txt", under: sandbox)
        let zipURL = sandbox.appendingPathComponent("not-a-backup.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-q", zipURL.path, "random.txt"]
        proc.currentDirectoryURL = sandbox
        try proc.run()
        proc.waitUntilExit()

        do {
            _ = try await manager.readManifest(fromArchive: zipURL)
            XCTFail("expected manifestMissing")
        } catch let e as BackupError {
            guard case .manifestMissing = e else { return XCTFail("wrong error: \(e)") }
        }
    }

    // MARK: - Restore

    func test_restore_swapsArchiveIn_andKeepsSafetyCopyOfCurrentState() async throws {
        // 1. Seed and back up.
        try seedTypicalTree()
        let archive = try await manager.createBackup(to: backupsDir)

        // 2. Mutate the live state AFTER the backup.
        try write("{\"id\":\"t1\",\"mutated\":true}", to: "chat-threads/t1.json", under: supportRoot)
        try write("brand new", to: "chat-threads/t2.json", under: supportRoot)

        // 3. Restore the archive.
        let result = try await manager.restore(fromArchive: archive)
        XCTAssertTrue(result.restoredSupport)
        XCTAssertTrue(result.restoredDocuments)

        // Live tree matches the backup again.
        XCTAssertEqual(read("chat-threads/t1.json", under: supportRoot), "{\"id\":\"t1\"}")
        XCTAssertNil(read("chat-threads/t2.json", under: supportRoot), "post-backup file must not survive the swap into the live tree")
        XCTAssertEqual(read("exports/grux-memory-x.json", under: documentsRoot), "a doc")

        // Safety copy holds the pre-restore (mutated) state, nothing lost.
        let safety = URL(fileURLWithPath: result.safetyCopyPath, isDirectory: true)
        let safetySupport = safety.appendingPathComponent("support", isDirectory: true)
        XCTAssertEqual(read("chat-threads/t1.json", under: safetySupport), "{\"id\":\"t1\",\"mutated\":true}")
        XCTAssertEqual(read("chat-threads/t2.json", under: safetySupport), "brand new")
    }

    func test_restore_rejectsNewerSchema() async throws {
        try seedTypicalTree()
        let archive = try await manager.createBackup(to: backupsDir)

        // Rewrite the manifest inside a copy of the archive with a future schema.
        let work = sandbox.appendingPathComponent("tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", work.path]
        try unzip.run()
        unzip.waitUntilExit()

        let manifestURL = work.appendingPathComponent("manifest.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\"schemaVersion\" : \(BackupManifest.currentSchemaVersion)",
            with: "\"schemaVersion\" : \(BackupManifest.currentSchemaVersion + 99)"
        )
        try text.data(using: .utf8)!.write(to: manifestURL)

        let tampered = sandbox.appendingPathComponent("tampered.zip")
        let rezip = Process()
        rezip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        rezip.arguments = ["-r", "-q", tampered.path, "."]
        rezip.currentDirectoryURL = work
        try rezip.run()
        rezip.waitUntilExit()

        // Live state must be untouched after the rejected restore.
        try write("still here", to: "chat-threads/sentinel.json", under: supportRoot)
        do {
            _ = try await manager.restore(fromArchive: tampered)
            XCTFail("expected unsupportedSchema")
        } catch let e as BackupError {
            guard case .unsupportedSchema = e else { return XCTFail("wrong error: \(e)") }
        }
        XCTAssertEqual(read("chat-threads/sentinel.json", under: supportRoot), "still here")
    }

    func test_restore_intoEmptyLiveTree_freshInstallScenario() async throws {
        try seedTypicalTree()
        let archive = try await manager.createBackup(to: backupsDir)

        // Simulate a fresh install: blank roots in a NEW sandbox location.
        let freshSupport = sandbox.appendingPathComponent("fresh-support", isDirectory: true)
        let freshDocs = sandbox.appendingPathComponent("fresh-docs", isDirectory: true)
        let freshSafety = sandbox.appendingPathComponent("fresh-safety", isDirectory: true)
        let fresh = BackupManager(supportRoot: freshSupport, documentsRoot: freshDocs, safetyRoot: freshSafety)

        let result = try await fresh.restore(fromArchive: archive)
        XCTAssertTrue(result.restoredSupport)
        XCTAssertEqual(read("chat-threads/t1.json", under: freshSupport), "{\"id\":\"t1\"}")
        XCTAssertEqual(read("exports/grux-memory-x.json", under: freshDocs), "a doc")
    }
}
