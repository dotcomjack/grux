import XCTest
@testable import Grux

/// THE WHOLE LOOP, IN A FOLDER OF THE TEST'S OWN.
///
/// A file lands, settles, is read, a model names it, it is renamed and
/// ledgered, and it can be undone. The service is built through its test
/// seams: a temporary folder instead of Desktop, Documents or Downloads, a
/// recording backend instead of a server, and a text reader that returns a
/// fixed string, so no folder of the machine's is listed and nothing goes on
/// the network. `FileNamingService.shared` is never touched here.

// MARK: - A backend that records instead of sending

private struct NamingBackendNotExercised: Error {}

/// Copied from ChatRoutingTests' RecordingBackend, which is file-private.
/// Conforms to `ModelBackend` in full, so the service is proven to take the
/// real protocol rather than one method of it.
private actor NamingRecordingBackend: ModelBackend {

    struct Call: Equatable {
        let apiKey: String
        let model: String
        let system: String?
        let maxTokens: Int
    }

    private(set) var calls: [Call] = []
    private(set) var shortAnswers = 0
    private(set) var temperatures: [Double] = []
    private let reply: String
    private let error: Error?

    init(reply: String, error: Error? = nil) { self.reply = reply; self.error = error }

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String {
        calls.append(Call(apiKey: apiKey, model: model, system: system, maxTokens: maxTokens))
        temperatures.append(temperature)
        if let error { throw error }
        return reply
    }

    func completeShortAnswer(apiKey: String, model: String, system: String?,
                             messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                             spanName: String, feature: String) async throws -> String {
        shortAnswers += 1
        return try await complete(apiKey: apiKey, model: model, system: system, messages: messages,
                                  maxTokens: maxTokens, temperature: temperature,
                                  spanName: spanName, feature: feature)
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String {
        throw NamingBackendNotExercised()
    }

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream<ClaudeStreamEvent, Error> { $0.finish(throwing: NamingBackendNotExercised()) }
    }

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse {
        throw NamingBackendNotExercised()
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (0, 0, 0, 0)
    }
}

// MARK: - Seams that record

/// Counts how often a seam was called, from any thread.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func bump() { lock.lock(); stored += 1; lock.unlock() }
}

/// A folder listing that can be refused, the way macOS refuses one before
/// folder access is granted, and counts every listing it was asked for.
private final class ListGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    let calls = CallCount()
    init(open: Bool) { isOpen = open }
    var open: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isOpen }
        set { lock.lock(); isOpen = newValue; lock.unlock() }
    }
    var lister: FileNamingService.Lister {
        { [self] url in
            self.calls.bump()
            return self.open ? FileNamingEntry.list(url) : nil
        }
    }
}

// MARK: - The service

@MainActor
final class FileNamingServiceTests: XCTestCase {

    private var dir: URL!
    private var staging: URL!
    private var services: [FileNamingService] = []
    private let fm = FileManager.default

    private let invoiceText = "Northwind Studio\nInvoice 2041\nOctober 2026\nDesign retainer for Acme Corp"
    private let invoiceName = "Northwind Studio Invoice Oct 2026"

    override func setUp() async throws {
        try await super.setUp()
        let root = fm.temporaryDirectory.appendingPathComponent("file-naming-service-\(UUID().uuidString)")
        dir = root.appendingPathComponent("watched")
        staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for service in services { service.apply(enabled: false) }
        services = []
        try? fm.removeItem(at: dir.deletingLastPathComponent())
        try await super.tearDown()
    }

    /// A service watching only the test's folder, as Downloads unless
    /// `screenshots` says otherwise.
    private func make(reply: String, error: Error? = nil, text: String? = nil,
                      screenshots: Bool = false,
                      folderSource: (() -> [FileNamingFolder])? = nil,
                      lister: FileNamingService.Lister? = nil,
                      settleTimeout: TimeInterval = 5)
        -> (FileNamingService, NamingRecordingBackend) {
        let backend = NamingRecordingBackend(reply: reply, error: error)
        let fixed = text ?? invoiceText
        let service = FileNamingService(
            folders: [FileNamingFolder(url: dir, screenshots: screenshots, downloads: !screenshots)],
            folderSource: folderSource,
            lister: lister,
            backend: backend,
            model: "grux-local-test",
            fileManager: fm,
            ledgerURL: staging.deletingLastPathComponent().appendingPathComponent("ledger/ledger.json"),
            textReader: { _, _ in fixed },
            settleInterval: 0.05,
            settleTimeout: settleTimeout,
            pendingInterval: 0.05,
            retryInterval: 0.2)
        services.append(service)
        return (service, backend)
    }

    /// Turns the service on and waits for its first pass, the one that takes
    /// each folder's baseline, so a file dropped after this is new.
    private func arm(_ service: FileNamingService) async {
        service.apply(enabled: true)
        await service.rescanNow()
    }

    /// Puts a file into the watched folder in one step, the way a finished
    /// download or a capture's final rename lands.
    private func drop(_ name: String, _ bytes: String = "%PDF-fixture bytes", capture: Bool = false) throws {
        let temp = staging.appendingPathComponent(UUID().uuidString)
        try Data(bytes.utf8).write(to: temp)
        if capture { try markAsCapture(temp) }
        try fm.moveItem(at: temp, to: dir.appendingPathComponent(name))
    }

    /// The xattr macOS puts on a keyboard capture, as FileNamingRulesTests sets it.
    private func markAsCapture(_ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let rc = data.withUnsafeBytes {
            setxattr(url.path, FileNamingRules.screenCaptureAttribute, $0.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(rc, 0, "could not set the capture xattr")
        XCTAssertTrue(FileNamingRules.isScreenCapture(url), "control: the capture mark did not take")
    }

    private func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    // MARK: - Renamed

    func testANewCandidateIsRenamedAndLedgered() async throws {
        let (service, backend) = make(reply: invoiceName)
        var announced: [FileRename] = []
        service.onRenamed = { announced.append($0) }
        await arm(service)
        XCTAssertTrue(service.status.armed)
        XCTAssertEqual(service.status.folders, [dir.path])
        XCTAssertEqual(service.status.unwatched, [])

        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the new download was not named: \(service.status)")

        XCTAssertTrue(exists("\(invoiceName).pdf"))
        XCTAssertFalse(exists("document (3).pdf"))
        XCTAssertEqual(service.recent.first?.oldName, "document (3).pdf")
        XCTAssertEqual(service.recent.first?.newName, "\(invoiceName).pdf")
        XCTAssertEqual(service.recent.first?.folder, dir.path)
        let renamedNumber = FileFingerprint.of(dir.appendingPathComponent("\(invoiceName).pdf"), fileManager: fm)?.fileNumber
        XCTAssertNotNil(renamedNumber)
        XCTAssertEqual(service.recent.first?.fileID, renamedNumber, "the ledger does not hold the file's number")
        XCTAssertEqual(announced.map(\.newName), ["\(invoiceName).pdf"])
        XCTAssertNotNil(service.status.lastNamedAt)

        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the name was not asked for as a short answer")
        let calls = await backend.calls
        XCTAssertEqual(calls.first?.maxTokens, 24)
        XCTAssertEqual(calls.first?.model, "grux-local-test")
        XCTAssertEqual(calls.first?.system, FileNamePrompt.system)
        let temperatures = await backend.temperatures
        XCTAssertEqual(temperatures, [0])

        // Its own rename fires the folder again; the file it renamed is not
        // new. Not even judged: the name Grux gave reads as a person's, so a
        // service that re-read its own rename would count it as humanName.
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        await service.rescanNow()
        let again = await backend.shortAnswers
        XCTAssertEqual(again, 1, "Grux read the name it had just given as a new file")
        XCTAssertNil(service.status.skipped["humanName"], "Grux judged its own rename as a new file: \(service.status)")
        XCTAssertEqual(service.status.named, 1)
    }

    func testUndoPutsTheOldNameBackAndDoesNotRenameItAgain() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named)
        let id = try XCTUnwrap(service.recent.first?.id)

        XCTAssertEqual(service.undo(id: id), .restored)
        XCTAssertTrue(exists("document (3).pdf"))
        XCTAssertFalse(exists("\(invoiceName).pdf"))
        XCTAssertEqual(service.status.undone, 1)
        XCTAssertNotNil(service.recent.first?.undoneAt)
        XCTAssertEqual(service.undoLast(), .nothingToUndo)

        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        await service.rescanNow()
        XCTAssertTrue(exists("document (3).pdf"), "the undone file was renamed straight back")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1)
    }

    // MARK: - What counts as new: the file, not its name

    /// THE CAPTURE A PERSON RENAMES IS NOT A NEW FILE. The capture mark
    /// survives a rename and the old diff was by name, so a renamed capture
    /// was renamed again (review 2026-10-28). The strictest case: the person
    /// gives it a name that still reads as a capture stamp, so only its
    /// identity says it is not new.
    func testACaptureAPersonRenamesIsNeverRenamed() async throws {
        try drop("Screenshot 2026-10-01 at 9.41.03 AM.png", capture: true)
        let (service, backend) = make(reply: invoiceName, screenshots: true)
        await arm(service)
        try fm.moveItem(at: dir.appendingPathComponent("Screenshot 2026-10-01 at 9.41.03 AM.png"),
                        to: dir.appendingPathComponent("Screenshot 2026-10-02 at 8.00.00 AM.png"))
        try drop("Screenshot 2026-10-28 at 10.00.00 AM.png", capture: true)
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: a new capture was not named, so this proves nothing: \(service.status)")
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("Screenshot 2026-10-02 at 8.00.00 AM.png"), "a capture the person renamed was renamed again")
        XCTAssertFalse(exists("Screenshot 2026-10-28 at 10.00.00 AM.png"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the renamed capture was read")
    }

    /// The same in Downloads: a file from before arming, renamed by the person
    /// to a name that looks machine-made, keeps its number and is left alone.
    func testADownloadAPersonRenamesIsNeverRenamed() async throws {
        try drop("Lease notes.pdf")
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try fm.moveItem(at: dir.appendingPathComponent("Lease notes.pdf"), to: dir.appendingPathComponent("document (4).pdf"))
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: the new download was not named: \(service.status)")
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("document (4).pdf"), "a file the person renamed was renamed")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1)
    }

    /// A file moved in from elsewhere keeps its creation date, so an old file
    /// dragged into Downloads is not a new download.
    func testAnOldFileMovedInIsNotNew() async throws {
        let old = staging.appendingPathComponent("moved-in")
        try Data("%PDF-old".utf8).write(to: old)
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let created = try XCTUnwrap(fm.attributesOfItem(atPath: old.path)[.creationDate] as? Date)
        XCTAssertLessThan(created, Date(timeIntervalSinceNow: -60), "control: the creation date could not be set")

        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try fm.moveItem(at: old, to: dir.appendingPathComponent("IMG_0042.png"))
        try drop("IMG_0043.png")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: the new file was not named: \(service.status)")
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("IMG_0042.png"), "an old file moved in was renamed")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1)
    }

    /// A FOLDER THAT CANNOT BE LISTED HAS NO BASELINE, NOT AN EMPTY ONE. An
    /// empty one made every file already there new the moment access was
    /// granted (review 2026-10-28). Here the listing is refused at arm, then
    /// allowed, then refused and allowed again; the file from before arming
    /// is never touched, and a file that lands once it is watched is named.
    func testAFolderThatCannotBeListedIsNotWatchedUntilItCan() async throws {
        try drop("IMG_0001.png")
        let gate = ListGate(open: false)
        let (service, backend) = make(reply: invoiceName, lister: gate.lister)
        await arm(service)
        XCTAssertGreaterThan(gate.calls.value, 0, "control: the folder was never asked for")
        XCTAssertFalse(service.status.armed, "a folder that could not be listed reads as watched")
        XCTAssertEqual(service.status.unwatched, [dir.path])
        XCTAssertTrue(service.status.settingsLine.contains("Waiting to open"), service.status.settingsLine)
        XCTAssertFalse(service.watchedPaths.contains(dir.path), "a folder that could not be listed was opened")

        gate.open = true
        let watched = await eventually { service.status.armed }
        XCTAssertTrue(watched, "the fallback never retried the folder: \(service.status)")
        XCTAssertEqual(service.status.unwatched, [])
        XCTAssertTrue(service.watchedPaths.contains(dir.path))

        // A later failure drops the baseline; the next listing is a new one.
        gate.open = false
        await service.rescanNow()
        XCTAssertEqual(service.status.unwatched, [dir.path])
        gate.open = true
        let back = await eventually { service.status.armed }
        XCTAssertTrue(back)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("IMG_0001.png"), "a file from before arming was renamed once the folder could be listed")
        let before = await backend.shortAnswers
        XCTAssertEqual(before, 0, "a file from before arming was read")

        try drop("IMG_0002.png")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: a new file in the folder once watched was not named: \(service.status)")
        XCTAssertTrue(exists("IMG_0001.png"))
    }

    /// A WATCHED FOLDER THAT GOES AWAY AND COMES BACK IS WATCHED AGAIN. The old
    /// descriptor is dead once the folder is deleted, and nothing reopened it
    /// (review 2026-10-28).
    func testAFolderDeletedAndMadeAgainIsWatchedAgain() async throws {
        let (service, _) = make(reply: invoiceName)
        await arm(service)
        XCTAssertTrue(service.watchedPaths.contains(dir.path), "control: the folder was never watched")

        try fm.removeItem(at: dir)
        service.rescan()
        let lost = await eventually { service.status.unwatched == [self.dir.path] }
        XCTAssertTrue(lost, "a deleted folder still reads as watched: \(service.status)")

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let back = await eventually { service.status.unwatched.isEmpty && service.watchedPaths.contains(self.dir.path) }
        XCTAssertTrue(back, "the folder came back and was never watched again: \(service.status)")

        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "a file in the folder made again was not named: \(service.status)")
    }

    // MARK: - Settling

    /// A FILE THAT NEVER SETTLES DOES NOT HOLD UP THE ONES BEHIND IT. Firefox
    /// leaves a 0 byte file under the final name while it downloads; settling
    /// inside the worker held every file behind it (review 2026-10-28).
    func testAFileThatNeverSettlesDoesNotHoldUpTheQueue() async throws {
        let (service, backend) = make(reply: invoiceName, settleTimeout: 4)
        await arm(service)
        try drop("scan_0001.pdf", "")
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually(3.5) { service.status.named == 1 }
        XCTAssertTrue(named, "a file that settled waited behind one that never did: \(service.status)")
        XCTAssertTrue(exists("scan_0001.pdf"))
        XCTAssertNil(service.status.skipped["unsupported"], "the empty file was dropped before its time")

        let dropped = await eventually { service.status.skipped["unsupported"] == 1 }
        XCTAssertTrue(dropped, "a file that never settled was never dropped: \(service.status)")
        XCTAssertTrue(exists("scan_0001.pdf"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the empty file was read")
    }

    /// The finished download moved over that placeholder is a new file with
    /// its own number, and is named.
    func testAFileReplacedUnderItsNameIsNamedWhenItSettles() async throws {
        let (service, _) = make(reply: invoiceName)
        await arm(service)
        try drop("scan_0001.pdf", "")
        service.rescan()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.status.named, 0, "an empty file was named")
        try drop("scan_0001.pdf.part", "%PDF-finished bytes")
        // rename(2) replaces the destination, the way the browser finishes.
        XCTAssertEqual(Darwin.rename(dir.appendingPathComponent("scan_0001.pdf.part").path,
                                     dir.appendingPathComponent("scan_0001.pdf").path), 0)
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the finished download was never named: \(service.status)")
        XCTAssertTrue(exists("\(invoiceName).pdf"))
    }

    // MARK: - Left alone

    func testAHumanNamedPDFIsLeftAlone() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try drop("Lease renewal 2027.pdf")
        service.rescan()
        let skipped = await eventually { service.status.skipped["humanName"] == 1 }
        XCTAssertTrue(skipped, "the file was not judged: \(service.status)")
        XCTAssertTrue(exists("Lease renewal 2027.pdf"))
        XCTAssertEqual(service.status.named, 0)
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0, "a file a person named was sent to the model")
    }

    func testAFilePresentBeforeArmingIsNeverTouched() async throws {
        try drop("IMG_0001.png")
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try drop("IMG_0002.png")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: the new file was not named, so this proves nothing")
        XCTAssertTrue(exists("IMG_0001.png"), "a file from before arming was renamed")
        XCTAssertFalse(exists("IMG_0002.png"))
        XCTAssertTrue(exists("\(invoiceName).png"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the backlog was read")
    }

    /// A Live Photo lands as a HEIC and a MOV with one stem; renaming the
    /// HEIC alone splits the pair (review 2026-10-28).
    func testAPairOfFilesWithOneStemIsLeftAlone() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try drop("IMG_4471.HEIC")
        try drop("IMG_4471.MOV")
        service.rescan()
        // One for the MOV (not an image), one for the HEIC (it has a pair).
        let skipped = await eventually { service.status.skipped["unsupported"] == 2 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("IMG_4471.HEIC"), "half of a pair was renamed")
        XCTAssertEqual(service.status.named, 0)
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
    }

    func testTheModelDecliningLeavesTheFileAlone() async throws {
        let (service, _) = make(reply: "")
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let skipped = await eventually { service.status.skipped["modelDeclined"] == 1 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("document (3).pdf"))
        XCTAssertEqual(service.status.named, 0)
    }

    func testAModelThatThoughtThroughItsBudgetDeclinedRatherThanFailed() async throws {
        let (service, _) = make(reply: "", error: ClaudeError.http(200, OpenAICompatBackend.thinkingBudgetMessage))
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let skipped = await eventually { service.status.skipped["modelDeclined"] == 1 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("document (3).pdf"))
    }

    func testANameWithNoWordFromTheFileIsNotUsed() async throws {
        let (service, _) = make(reply: "Quarterly Tax Return")
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let skipped = await eventually { service.status.skipped["modelDeclined"] == 1 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("document (3).pdf"))
    }

    func testAFileWithNoTextIsNotSentToTheModel() async throws {
        let (service, backend) = make(reply: invoiceName, text: "")
        await arm(service)
        try drop("IMG_4471.png")
        service.rescan()
        let skipped = await eventually { service.status.skipped["noText"] == 1 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("IMG_4471.png"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
    }

    // MARK: - A chat turn goes first

    func testTheNamingCallWaitsForAChatTurn() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        AppState.shared.beginChatTurn()
        var ended = false
        defer { if !ended { AppState.shared.endChatTurn() } }
        try drop("document (3).pdf")
        service.rescan()
        try await Task.sleep(for: .milliseconds(600))
        let during = await backend.shortAnswers
        XCTAssertEqual(during, 0, "the naming call ran during a chat turn")
        AppState.shared.endChatTurn()
        ended = true
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the file was not named once the turn ended")
    }

    // MARK: - Off

    /// WHILE OFF, NO FOLDER IS EVEN ASKED FOR. The folder list and every
    /// listing go through seams that count, so a regression that reads a
    /// folder at init, on a rescan or on turning off fails here (review
    /// 2026-10-28: the old test passed explicit folders and could not see it).
    func testWhileOffNoFolderIsListed() async throws {
        let sources = CallCount()
        let gate = ListGate(open: true)
        let folder = FileNamingFolder(url: dir, screenshots: false, downloads: true)
        let (service, backend) = make(reply: invoiceName,
                                      folderSource: { sources.bump(); return [folder] },
                                      lister: gate.lister)
        XCTAssertFalse(service.status.enabled)
        try drop("document (3).pdf")
        service.rescan()
        await service.rescanNow()
        service.apply(enabled: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sources.value, 0, "the folders were looked up while off")
        XCTAssertEqual(gate.calls.value, 0, "a folder was listed while off")
        XCTAssertTrue(exists("document (3).pdf"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
        XCTAssertEqual(service.status.settingsLine, "Off. New screenshots and downloads keep the names they arrive with.")

        // Control: the same seams do see the folder once it is on.
        await arm(service)
        XCTAssertEqual(sources.value, 1, "turning on did not look the folders up exactly once")
        XCTAssertGreaterThan(gate.calls.value, 0, "control: the counting lister is not the one in use")
    }

    func testTurningOffStopsWatching() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        service.apply(enabled: true)
        service.apply(enabled: false)
        XCTAssertFalse(service.status.armed)
        XCTAssertEqual(service.status.folders, [])
        XCTAssertTrue(service.watchedPaths.isEmpty, "turning off left a folder open")
        try drop("document (3).pdf")
        service.rescan()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("document (3).pdf"))
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
    }

    // MARK: - Preview

    func testPreviewNamesWithoutRenamingAndWorksWhileOff() async throws {
        let (service, _) = make(reply: invoiceName)
        try drop("document (3).pdf")
        let path = dir.appendingPathComponent("document (3).pdf").path
        let preview = await service.preview(path: path)
        XCTAssertEqual(preview.decision, "rename")
        XCTAssertEqual(preview.proposedName, invoiceName)
        XCTAssertEqual(preview.model, "grux-local-test")
        XCTAssertEqual(preview.path, path)
        XCTAssertTrue(exists("document (3).pdf"), "a preview renamed the file")
        XCTAssertEqual(service.status.named, 0)

        try drop("Lease renewal 2027.pdf")
        let human = await service.preview(path: dir.appendingPathComponent("Lease renewal 2027.pdf").path)
        XCTAssertEqual(human.decision, "leave")
        XCTAssertEqual(human.reason, "humanName")
        XCTAssertNil(human.proposedName)
    }

    // MARK: - Status line

    func testTheStatusLineIsOneSentenceWithNoTypographicDash() {
        var status = FileNamingStatus.idle
        status.enabled = true
        status.armed = true
        status.route = "ok"
        status.model = "grux-local-test"
        status.folders = ["/tmp/a/Documents", "/tmp/a/Downloads"]
        status.named = 3
        let line = status.settingsLine
        XCTAssertTrue(line.hasPrefix("Watching Documents and Downloads"), line)
        XCTAssertTrue(line.contains("3 files named"), line)
        XCTAssertTrue(line.hasSuffix("."), line)

        var waiting = status
        waiting.unwatched = ["/tmp/a/Documents"]
        XCTAssertTrue(waiting.settingsLine.hasPrefix("Watching Downloads"), waiting.settingsLine)
        XCTAssertTrue(waiting.settingsLine.contains("Waiting to open Documents"), waiting.settingsLine)
        waiting.armed = false
        waiting.unwatched = status.folders
        XCTAssertTrue(waiting.settingsLine.hasPrefix("Paused"), waiting.settingsLine)

        for state in ["noLocalModel", "notLoopback"] {
            status.route = state
            XCTAssertTrue(status.settingsLine.hasPrefix("Paused"), status.settingsLine)
        }
        for s in [line, waiting.settingsLine, FileNamingStatus.idle.settingsLine] {
            XCTAssertFalse(s.contains("\u{2014}") || s.contains("\u{2013}"), s)
        }
    }
}
