import XCTest
@testable import Grux

/// Files that name themselves is checked and undone without a click (operator
/// rule 0r.4). The status file is what a hands-free check reads, so it carries
/// counts, the route and the watched folders, and never a file name: the name
/// of a person's file is their content.
@MainActor
final class FileNamingTriggersTests: XCTestCase {

    /// Every key the status file may carry. Pinned, so a new key is a decision
    /// somebody makes here, and a key that would carry a file name (a list of
    /// recent renames, a last name) cannot arrive by way of a new property.
    private static let documentedStatusKeys: Set<String> = [
        "enabled", "armed", "route", "model", "folders", "named", "undone", "skipped",
        "lastNamedAt", "settingsLine", "writtenAt",
    ]

    private var savedRefresh: (() async -> Void)!
    private var savedService: (() -> FileNamingService)!
    private var roots: [URL] = []
    private var seeded: [FileNamingService] = []

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        savedRefresh = FileNamingTriggers.refreshRoute
        savedService = FileNamingTriggers.service
        // The real refresh asks the Ollama address in config for its models.
        // These tests are about the file the trigger writes, not the route.
        FileNamingTriggers.refreshRoute = {}
    }

    override func tearDown() async throws {
        for service in seeded { service.apply(enabled: false) }
        seeded = []
        FileNamingTriggers.refreshRoute = savedRefresh
        FileNamingTriggers.service = savedService
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        try await super.tearDown()
    }

    private let oldName = "document (3).pdf"
    private let newBase = "Northwind Studio Invoice Oct 2026"

    /// A service on a folder and a ledger of the test's own, holding one real
    /// rename: the file is on disk under its new name and the ledger says so.
    /// The triggers are pointed at it, so they act on a rename that happened
    /// rather than on the suite's empty shared ledger.
    private func seededService(batch: UUID? = nil) throws -> (service: FileNamingService, folder: URL, entry: FileRename) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("file-naming-trigger-service-\(UUID().uuidString)")
        roots.append(root)
        let folder = root.appendingPathComponent("watched")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent(oldName)
        try Data("%PDF-fixture bytes".utf8).write(to: original)
        let stamp = try XCTUnwrap(FileFingerprint.of(original, fileManager: fm))
        let renamed = try FileRenamer(fileManager: fm).rename(original, to: newBase, expecting: stamp)
        let ledgerURL = root.appendingPathComponent("ledger/ledger.json")
        let entry = FileRename(id: UUID(), folder: folder.path, oldName: oldName, newName: renamed.lastPathComponent,
                               at: Date(), undoneAt: nil, fileID: stamp.fileNumber, batch: batch)
        FileRenameLedger(url: ledgerURL, fileManager: fm).append(entry)
        let service = FileNamingService(folders: [FileNamingFolder(url: folder, screenshots: false, downloads: true)],
                                        fileManager: fm, ledgerURL: ledgerURL)
        seeded.append(service)
        FileNamingTriggers.service = { service }
        XCTAssertEqual(service.recent.map(\.id), [entry.id], "control: the seeded rename is not in the service's ledger")
        return (service, folder, entry)
    }

    /// Drops `name` in a folder of the test's own, runs the app's registration
    /// on it, and returns the JSON file it writes.
    private func fire(_ name: String, _ contents: String = "",
                      expecting output: String = FileNamingTriggers.statusFile) throws -> [String: Any] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-naming-triggers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = TriggerWatcher(directory: dir)
        FileNamingTriggers.register(in: dir, on: watcher)
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        watcher.sweepNow()
        let url = dir.appendingPathComponent(output)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                       "the trigger file was not taken")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func test_theStatusTriggerWritesTheDocumentedKeys() throws {
        let status = try fire(FileNamingTriggers.status)
        XCTAssertEqual(Set(status.keys), Self.documentedStatusKeys,
                       "the status file's keys changed; a new key must be a decision, and never a file name")
        XCTAssertNotNil(status["enabled"] as? Bool, "enabled is not a Bool")
        XCTAssertNotNil(status["armed"] as? Bool, "armed is not a Bool")
        XCTAssertTrue(["ok", "noLocalModel", "notLoopback", "unknown"].contains(status["route"] as? String ?? ""),
                      "route is not one of the documented words: \(String(describing: status["route"]))")
        XCTAssertNotNil(status["named"] as? Int)
        XCTAssertNotNil(status["undone"] as? Int)
        XCTAssertNotNil(status["folders"] as? [String])
        XCTAssertNotNil(status["skipped"] as? [String: Int])
        XCTAssertFalse((status["settingsLine"] as? String ?? "").isEmpty, "the Settings status line is empty")
        XCTAssertNotNil(status["writtenAt"] as? String)
        XCTAssertNil(status["undo"], "a plain status reports an undo nobody asked for")
    }

    /// The pure half, on a status built by hand, so the values are known and the
    /// "never a file name" claim is checked against names that really exist.
    func test_theStatusObjectCarriesCountsAndFoldersButNoFileName() throws {
        var s = FileNamingStatus.idle
        s.enabled = true
        s.armed = true
        s.route = "ok"
        s.model = "grux-local:4b"
        s.folders = ["/tmp/Northwind Studio/Downloads"]
        s.named = 3
        s.undone = 1
        s.skipped = ["humanName": 2, "noText": 1]
        s.lastNamedAt = Date(timeIntervalSince1970: 0)

        let object = FileNamingTriggers.statusObject(s, now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(Set(object.keys), Self.documentedStatusKeys)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), "the status cannot be written as JSON")
        XCTAssertEqual(object["named"] as? Int, 3)
        XCTAssertEqual(object["undone"] as? Int, 1)
        XCTAssertEqual(object["route"] as? String, "ok")
        XCTAssertEqual(object["model"] as? String, "grux-local:4b")
        XCTAssertEqual(object["folders"] as? [String], ["/tmp/Northwind Studio/Downloads"])
        XCTAssertEqual(object["skipped"] as? [String: Int], ["humanName": 2, "noText": 1])
        XCTAssertEqual(object["lastNamedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(object["writtenAt"] as? String, "1970-01-01T00:01:00Z")

        let text = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8))
        XCTAssertTrue(text.contains("Northwind Studio"), "control: the serialized text is not the status")

        // Absent values are written as null, not dropped, so a reader sees the key.
        let idle = FileNamingTriggers.statusObject(.idle)
        XCTAssertTrue(idle["model"] is NSNull, "a missing model is not written as null")
        XCTAssertTrue(idle["lastNamedAt"] is NSNull, "a missing last time is not written as null")
    }

    /// THE STATUS FILE NEVER CARRIES A FILE NAME, checked against a status
    /// built by a real rename. A name can only reach the file through a status
    /// field set while the service names a file, so the rename goes through
    /// the pipeline itself (a dropped download, a model reply, the rename)
    /// rather than a ledger written by hand: with that, a status line that
    /// started quoting the last name would be caught here (review 2026-10-28,
    /// twice).
    func test_theStatusFileHoldsNoNameTheServiceKnows() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("file-naming-trigger-pipeline-\(UUID().uuidString)")
        roots.append(root)
        let folder = root.appendingPathComponent("watched")
        let staging = root.appendingPathComponent("staging")
        let out = root.appendingPathComponent("out")
        for made in [folder, staging, out] { try fm.createDirectory(at: made, withIntermediateDirectories: true) }
        let service = FileNamingService(
            folders: [FileNamingFolder(url: folder, screenshots: false, downloads: true)],
            backend: FixedNameBackend(reply: newBase),
            model: "grux-local-test",
            fileManager: fm,
            ledgerURL: root.appendingPathComponent("ledger/ledger.json"),
            textReader: { _, _ in "Northwind Studio\nInvoice 2041\nOctober 2026" },
            settleInterval: 0.05,
            pendingInterval: 0.05,
            retryInterval: 0.2,
            quietInterval: 0,
            completeness: { _, _ in true })
        seeded.append(service)
        FileNamingTriggers.service = { service }
        service.apply(enabled: true)
        await service.rescanNow()

        let temp = staging.appendingPathComponent("download")
        try Data("%PDF-fixture bytes".utf8).write(to: temp)
        try fm.moveItem(at: temp, to: folder.appendingPathComponent(oldName))
        service.rescan()
        let deadline = Date().addingTimeInterval(5)
        while service.status.named < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(service.status.named, 1, "control: the pipeline renamed nothing, so this proves nothing")
        let given = try XCTUnwrap(service.recent.first?.newName, "control: the rename is not in the service's list")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(given).path), "control: the file was not renamed on disk")

        await FileNamingTriggers.fire(FileNamingTriggers.status, contents: "", dir: out)
        let data = try Data(contentsOf: out.appendingPathComponent(FileNamingTriggers.statusFile))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(status["named"] as? Int, 1, "control: this is not the renaming service's status")
        XCTAssertEqual(status["folders"] as? [String], [folder.path], "control: this is not the renaming service's status")
        for name in [oldName, given, (oldName as NSString).deletingPathExtension, newBase] {
            XCTAssertFalse(text.contains(name), "the status file carries the file name \(name)")
        }
        XCTAssertEqual(Set(status.keys), Self.documentedStatusKeys)
    }

    /// THE HANDS-FREE UNDO UNDOES. Fired against a ledger this test wrote, it
    /// must put the old name back on disk and say "restored"; the old test
    /// accepted any outcome word from an empty ledger (review 2026-10-28).
    func test_undoLastUndoesTheNewestRenameOnDisk() throws {
        let (_, folder, entry) = try seededService()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(entry.newName).path), "control: nothing was renamed")

        let status = try fire(FileNamingTriggers.undoLast)
        XCTAssertEqual(status["undo"] as? String, "restored", "the undo trigger did not undo the rename")
        XCTAssertEqual(status["undone"] as? Int, 1)
        XCTAssertEqual(Set(status.keys), Self.documentedStatusKeys.union(["undo"]))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(oldName).path), "the old name is not back")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(entry.newName).path))

        let again = try fire(FileNamingTriggers.undoLast)
        XCTAssertEqual(again["undo"] as? String, "nothingToUndo", "the same rename was undone twice")
    }

    /// A failed undo's error text can quote a path, so only the word is written.
    func test_theUndoWordNeverCarriesTheErrorText() {
        XCTAssertEqual(FileNamingTriggers.word(.failed("/tmp/Acme Corp/Invoice.pdf")), "failed")
        XCTAssertEqual(FileNamingTriggers.word(.restored), "restored")
        XCTAssertEqual(FileNamingTriggers.word(.nothingToUndo), "nothingToUndo")
        XCTAssertEqual(FileNamingTriggers.word(.newNameGone), "newNameGone")
        XCTAssertEqual(FileNamingTriggers.word(.oldNameTaken), "oldNameTaken")
        XCTAssertEqual(FileNamingTriggers.word(.fileChanged), "fileChanged")
    }

    /// The preview takes an absolute path and nothing else, and says so in the
    /// file rather than writing nothing a script could wait on.
    func test_previewRefusesAPathThatIsNotAbsolute() throws {
        let preview = try fire(FileNamingTriggers.preview, "relative/Acme Corp invoice.png",
                               expecting: FileNamingTriggers.previewFile)
        XCTAssertEqual(preview["decision"] as? String, "leave")
        XCTAssertEqual(preview["reason"] as? String, "notAbsolutePath")
        XCTAssertTrue(preview["proposedName"] is NSNull, "a refused preview proposed a name")
    }

    /// The documented preview keys, with proposedName written as null when the
    /// pipeline leaves a file alone (the eval reads null, not a missing key).
    func test_thePreviewObjectWritesEveryDocumentedKey() throws {
        let json = #"{"path":"/tmp/photo.png","decision":"leave","reason":"noText","readMs":40,"modelMs":0}"#
        let preview = try JSONDecoder().decode(FileNamingPreview.self, from: Data(json.utf8))
        let object = FileNamingTriggers.previewObject(preview, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Set(object.keys),
                       ["path", "decision", "reason", "proposedName", "readMs", "modelMs", "model", "writtenAt"])
        XCTAssertTrue(object["proposedName"] is NSNull)
        XCTAssertTrue(object["model"] is NSNull)
        XCTAssertEqual(object["readMs"] as? Int, 40)
        XCTAssertEqual(object["reason"] as? String, "noText")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
    }

    /// The app registers these with the rest (the tests above run the same
    /// registration on a folder of their own), under names that are locked.
    func test_theAppRegistersTheFileNamingTriggers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let triggers = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Triggers/AppTriggers.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(triggers.contains("WorkflowTriggers.register(in: dir)"),
                      "control: this is not the trigger table")
        XCTAssertTrue(triggers.contains("FileNamingTriggers.register(in: dir)"),
                      "the file naming triggers are never registered")
        XCTAssertEqual(FileNamingTriggers.names,
                       ["fire-file-naming-status", "fire-file-naming-undo-last", "fire-file-naming-preview",
                        "fire-file-naming-backlog", "fire-file-naming-undo-batch"],
                       "a trigger file name changed")
        XCTAssertEqual(FileNamingTriggers.statusFile, "file-naming-status.json")
        XCTAssertEqual(FileNamingTriggers.previewFile, "file-naming-preview.json")
        XCTAssertEqual(FileNamingTriggers.backlogFile, "file-naming-backlog.json")
        XCTAssertEqual(FileNamingTriggers.backlogRefusedFile, "file-naming-backlog-refused.json")
    }

    /// THE RUN'S UNDO UNDOES, by its batch id and, with no id, the newest run.
    func test_undoBatchPutsTheRunBack() throws {
        let batch = UUID()
        let (service, folder, entry) = try seededService(batch: batch)
        XCTAssertEqual(service.lastBatch, batch, "control: the seeded rename is not part of a run")
        let fm = FileManager.default
        let result = try fire(FileNamingTriggers.undoBatch, "", expecting: FileNamingTriggers.backlogFile)
        XCTAssertEqual(result["restored"] as? Int, 1, "the run was not undone")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(oldName).path), "the old name is not back")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(entry.newName).path))
        let again = try fire(FileNamingTriggers.undoBatch, batch.uuidString, expecting: FileNamingTriggers.backlogFile)
        XCTAssertEqual(again["restored"] as? Int, 0, "a run was undone twice")
    }

    /// THE RUN TRIGGER RUNS: the file it writes at the end holds the counts of
    /// a run that renamed a real file, and a second run while one is going is
    /// refused in its own file, leaving the running one's file as it was.
    func test_theRunTriggerNamesAndRefusesASecondRun() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("file-naming-trigger-run-\(UUID().uuidString)")
        roots.append(root)
        let folder = root.appendingPathComponent("watched")
        let out = root.appendingPathComponent("out")
        for made in [folder, out] { try fm.createDirectory(at: made, withIntermediateDirectories: true) }
        let gate = RunGate()
        let service = FileNamingService(
            folders: [FileNamingFolder(url: folder, screenshots: false, downloads: true)],
            backend: FixedNameBackend(reply: newBase),
            model: "grux-local-test",
            fileManager: fm,
            ledgerURL: root.appendingPathComponent("ledger/ledger.json"),
            textReader: { [gate] _, _ in
                while !gate.open { try? await Task.sleep(for: .milliseconds(10)) }
                return "Northwind Studio\nInvoice 2041\nOctober 2026"
            },
            quietInterval: 0,
            completeness: { _, _ in true })
        seeded.append(service)
        FileNamingTriggers.service = { service }
        let file = folder.appendingPathComponent(oldName)
        try Data("%PDF-fixture bytes".utf8).write(to: file)

        let first = Task { await FileNamingTriggers.fire(FileNamingTriggers.backlog, contents: file.path, dir: out) }
        let started = out.appendingPathComponent(FileNamingTriggers.backlogFile)
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let begun = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: started)) as? [String: Any])
        XCTAssertEqual(begun["running"] as? Bool, true)
        XCTAssertEqual(begun["total"] as? Int, 1, "the start was written before the run counted its files")

        await FileNamingTriggers.fire(FileNamingTriggers.backlog, contents: file.path, dir: out)
        let refused = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: out.appendingPathComponent(FileNamingTriggers.backlogRefusedFile))) as? [String: Any])
        XCTAssertEqual(refused["refused"] as? String, "alreadyRunning")
        let still = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: started)) as? [String: Any])
        XCTAssertEqual(still["running"] as? Bool, true, "the refusal overwrote the running run's file")

        gate.open = true
        await first.value
        let done = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: started)) as? [String: Any])
        XCTAssertEqual(done["running"] as? Bool, false)
        XCTAssertEqual(done["named"] as? Int, 1)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("\(newBase).pdf").path))
        let text = try String(contentsOf: started, encoding: .utf8)
        XCTAssertFalse(text.contains(newBase) || text.contains(oldName), "the run file carries a file name")
    }

    /// A run takes absolute paths and nothing else, and names nothing when a
    /// line is not one.
    func test_aRunRefusesARelativePath() throws {
        _ = try seededService()
        let result = try fire(FileNamingTriggers.backlog, "/tmp/a.png\nrelative/Acme Corp invoice.png",
                              expecting: FileNamingTriggers.backlogRefusedFile)
        XCTAssertEqual(result["refused"] as? String, "notAbsolutePath")
        XCTAssertNil(result["named"], "control: this is the refusal, not a run")
    }

    /// The run's file carries counts, never a file name.
    func test_theRunFileHoldsCountsOnly() {
        let run = FileNamingBacklog(batch: UUID(), total: 3, done: 3, named: 2, running: false)
        XCTAssertEqual(Set(FileNamingTriggers.backlogObject(run).keys),
                       ["batch", "total", "done", "named", "undone", "running", "stopped", "settingsLine", "writtenAt"])
        XCTAssertFalse(run.settingsLine.contains("\u{2014}") || run.settingsLine.contains("\u{2013}"))
    }
}

// MARK: - A backend that answers one name

private struct FixedNameBackendNotExercised: Error {}

/// Replies with one name to every call; the rest of `ModelBackend` is never
/// used here and throws. `completeShortAnswer` is the protocol's default, which
/// calls `complete`, so the naming call reaches the reply.
private actor FixedNameBackend: ModelBackend {
    private let reply: String

    init(reply: String) { self.reply = reply }

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String {
        reply
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String {
        throw FixedNameBackendNotExercised()
    }

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream<ClaudeStreamEvent, Error> { $0.finish(throwing: FixedNameBackendNotExercised()) }
    }

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse {
        throw FixedNameBackendNotExercised()
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (0, 0, 0, 0)
    }
}

/// A switch the text reader reads from any thread.
private final class RunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var open: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
