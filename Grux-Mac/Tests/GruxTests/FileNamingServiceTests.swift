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

/// A switch a seam reads from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

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
    /// The fixture files are not real PDFs or images, so content is taken as
    /// whole unless a test says otherwise, and nothing waits for a quiet
    /// period unless a test asks for one.
    private func make(reply: String, error: Error? = nil, text: String? = nil,
                      reader: FileNamingService.TextReader? = nil,
                      screenshots: Bool = false,
                      folderSource: (@Sendable () -> [FileNamingFolder])? = nil,
                      lister: FileNamingService.Lister? = nil,
                      settleTimeout: TimeInterval = 5,
                      quiet: TimeInterval = 0,
                      complete: @escaping FileNamingService.Completeness = { _, _ in true },
                      recheck: TimeInterval = 0.05,
                      unloader: FileNamingService.Unloader? = nil,
                      previewDelay: TimeInterval = 60,
                      idleDelay: TimeInterval = 0)
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
            textReader: reader ?? { _, _ in fixed },
            settleInterval: 0.05,
            settleTimeout: settleTimeout,
            pendingInterval: 0.05,
            retryInterval: 0.2,
            quietInterval: quiet,
            completeness: complete,
            incompleteRecheck: recheck,
            unloader: unloader,
            previewUnloadDelay: previewDelay,
            idleUnloadDelay: idleDelay)
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

    /// A FILE THAT NEVER SETTLES DOES NOT HOLD UP THE ONES BEHIND IT. A
    /// download that never becomes whole never settles; settling inside the
    /// worker held every file behind it (review 2026-10-28). The stuck file's
    /// name sorts first ("I" before "d"), so it reaches the queue ahead of the
    /// good one: with settling back inside the worker, the good file would
    /// wait out the whole timeout and this goes red. It is held by the content
    /// seam, never by thread timing: a writer thread racing the settling
    /// checks could settle it on a busy runner (review 2026-10-28).
    func testAFileThatNeverSettlesDoesNotHoldUpTheQueue() async throws {
        let (service, backend) = make(reply: invoiceName, settleTimeout: 4,
                                      complete: { url, _ in url.lastPathComponent != "IMG_0001.pdf" })
        await arm(service)
        try drop("IMG_0001.pdf", "%PDF-never whole")
        try drop("document (3).pdf")
        XCTAssertLessThan("IMG_0001.pdf", "document (3).pdf", "control: the stuck file no longer sorts first")
        service.rescan()
        let named = await eventually(3.5) { service.status.named == 1 }
        XCTAssertTrue(named, "a file that settled waited behind one that never did: \(service.status)")
        XCTAssertTrue(exists("IMG_0001.pdf"))
        XCTAssertNil(service.status.skipped["unsupported"], "the stuck file was dropped before its time")

        let dropped = await eventually { service.status.skipped["unsupported"] == 1 }
        XCTAssertTrue(dropped, "a file that never settled was never dropped: \(service.status)")
        XCTAssertTrue(exists("IMG_0001.pdf"), "the stuck file was renamed")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the stuck file was read")
    }

    /// A SETTLING FILE IS READ ALONE. The check that runs while a file settles
    /// reads that file and never lists a folder again: it used to list every
    /// watched folder once a second, for up to 10 minutes (review
    /// 2026-10-28). The file here really is settling: its content never reads
    /// as whole, and the counting content check proves the settling checks
    /// ran in the window where the lister must stay still.
    func testASettlingFileIsReadWithoutListingTheFolders() async throws {
        let gate = ListGate(open: true)
        let checks = CallCount()
        let (service, _) = make(reply: invoiceName, lister: gate.lister,
                                complete: { _, _ in checks.bump(); return false })
        await arm(service)
        try drop("IMG_0001.pdf")
        await service.rescanNow()
        let pending = await eventually { checks.value >= 1 }
        XCTAssertTrue(pending, "control: the file never reached a settling check, so nothing was settling")
        let listsBefore = gate.calls.value
        let checksBefore = checks.value
        // About 12 settling checks at the test's 0.05 s.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(checks.value, checksBefore, "control: no settling check ran in the window")
        XCTAssertEqual(gate.calls.value, listsBefore, "a settling check listed the folders")
        XCTAssertEqual(service.status.named, 0)
        // Control: a folder event does list.
        service.rescan()
        let listed = await eventually { gate.calls.value > listsBefore }
        XCTAssertTrue(listed, "control: the counting lister is not the one in use")
    }

    /// A FILE THAT READ AS NOT WHOLE IS CHECKED AGAIN ONLY AFTER A PAUSE. The
    /// check can parse a whole PDF, and a stalled download was parsed every
    /// second for 10 minutes (review 2026-10-28).
    func testAnIncompleteFileIsCheckedAgainOnlyAfterAPause() async throws {
        let checks = CallCount()
        let (service, _) = make(reply: invoiceName, complete: { _, _ in checks.bump(); return false }, recheck: 2)
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let first = await eventually { checks.value >= 1 }
        XCTAssertTrue(first, "control: the content was never checked")
        // About 12 settling checks at the test's 0.05 s, none of them due.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(checks.value, 1, "a file that read as not whole was checked again within the pause")
        XCTAssertEqual(service.status.named, 0)
    }

    /// Firefox makes an empty placeholder under the final name and, when the
    /// download finishes, moves the `.part` file over it: a new number under a
    /// name the folder already showed. The placeholder is not an arrival, so
    /// the finished file is (review 2026-10-28: the first fix left every
    /// Firefox download unnamed).
    func testAFirefoxDownloadIsNamedWhenItsPartFileLands() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        try drop("IMG_0005.pdf", "")
        try drop("IMG_0005.pdf.part", "")
        service.rescan()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.status.named, 0, "an empty placeholder was named")
        try Data("%PDF-finished bytes".utf8).write(to: dir.appendingPathComponent("IMG_0005.pdf.part"))
        // rename(2) replaces the destination, the way the browser finishes.
        XCTAssertEqual(Darwin.rename(dir.appendingPathComponent("IMG_0005.pdf.part").path,
                                     dir.appendingPathComponent("IMG_0005.pdf").path), 0)
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the finished download was not named: \(service.status)")
        XCTAssertFalse(exists("IMG_0005.pdf"), "the finished download kept its machine-made name")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "the download was read more than once")
    }

    /// The same for a file from before arming that a tool rewrites by moving
    /// a temporary file over it (`exiftool -overwrite_original`): a new number
    /// and a new creation date, under a name the folder held at its baseline
    /// (review 2026-10-28).
    func testAFileFromBeforeArmingRewrittenInPlaceIsLeftAlone() async throws {
        try drop("IMG_1234.jpg", "the original")
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        let before = try XCTUnwrap(FileFingerprint.of(dir.appendingPathComponent("IMG_1234.jpg"), fileManager: fm))
        let temp = staging.appendingPathComponent("rewrite.tmp")
        try Data("the same picture, metadata stripped".utf8).write(to: temp)
        XCTAssertEqual(Darwin.rename(temp.path, dir.appendingPathComponent("IMG_1234.jpg").path), 0)
        let after = try XCTUnwrap(FileFingerprint.of(dir.appendingPathComponent("IMG_1234.jpg"), fileManager: fm))
        XCTAssertNotEqual(after.fileNumber, before.fileNumber, "control: the rewrite kept the file number")

        try drop("IMG_1235.jpg")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: a new file was not named: \(service.status)")
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("IMG_1234.jpg"), "a file from before arming, rewritten in place, was renamed")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1)
    }

    /// A NAME THAT WENT AWAY AND CAME BACK IS A NEW FILE. The rewrite rule
    /// read every name a folder ever held as taken, so a new download reusing
    /// a deleted file's generic name was never named (review 2026-10-28).
    /// Only a name the last listing held counts.
    func testANewDownloadUnderADeletedFilesNameIsNamed() async throws {
        try drop("document.pdf", "last week's download")
        let (service, _) = make(reply: invoiceName)
        await arm(service)
        try fm.removeItem(at: dir.appendingPathComponent("document.pdf"))
        await service.rescanNow()
        try drop("document.pdf", "%PDF-a new invoice")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "a new download under a name the folder once held was never named: \(service.status)")
        XCTAssertFalse(exists("document.pdf"))
    }

    /// A FILE GRUX PUT BACK IS NOT NEW IN ANOTHER WATCHED FOLDER. The numbers
    /// Grux has renamed or restored are known across folders, so a capture
    /// the person reverted with Undo and dragged into Downloads is left alone
    /// (review 2026-10-28).
    func testAFileMovedBetweenWatchedFoldersAfterUndoIsLeftAlone() async throws {
        let other = dir.deletingLastPathComponent().appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let watched = [FileNamingFolder(url: dir, screenshots: false, downloads: true),
                       FileNamingFolder(url: other, screenshots: false, downloads: true)]
        let (service, backend) = make(reply: invoiceName, folderSource: { watched })
        await arm(service)
        XCTAssertEqual(service.status.folders, [dir.path, other.path], "control: both folders are not watched")
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: nothing was named: \(service.status)")
        let id = try XCTUnwrap(service.recent.first?.id)
        let undone = await service.undoInBackground(id: id)
        XCTAssertEqual(undone, .restored)
        try fm.moveItem(at: dir.appendingPathComponent("document (3).pdf"), to: other.appendingPathComponent("document (3).pdf"))
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(400))
        await service.rescanNow()
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("document (3).pdf").path),
                      "a file the person put back with Undo was renamed again in another watched folder")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1)
    }

    /// A WATCHED FOLDER MISSING AT ARM IS WAITED FOR. It is kept, its listing
    /// fails, and the retry arms it once it exists (review 2026-10-28: it was
    /// dropped for the whole arm).
    func testAFolderMissingWhenArmedIsWatchedOnceItAppears() async throws {
        try fm.removeItem(at: dir)
        let (service, _) = make(reply: invoiceName)
        await arm(service)
        XCTAssertEqual(service.status.folders, [dir.path], "a missing folder was dropped")
        XCTAssertEqual(service.status.unwatched, [dir.path])
        XCTAssertFalse(service.status.armed)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let watched = await eventually { service.status.armed && service.watchedPaths.contains(self.dir.path) }
        XCTAssertTrue(watched, "the folder appeared and was never watched: \(service.status)")
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "\(service.status)")
    }

    /// A MISSING SCREENSHOT FOLDER, THROUGH THE REAL FOLDER LIST. The folders
    /// come from `FileNamingRules.watchedFolders(defaults:home:downloads:)`,
    /// the function the app's own list is built by, under a home where
    /// neither folder exists yet. Both stay in the list, both are retried, the
    /// status says the screenshot folder does not exist rather than asking
    /// for a permission (review 2026-10-28), and each is watched once it
    /// appears. An existence filter put back in the folder list fails here.
    func testAMissingScreenshotFolderIsWaitedForAndSaysSo() async throws {
        let home = dir.deletingLastPathComponent().appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let shots = home.appendingPathComponent("Shots")
        let downloads = home.appendingPathComponent("Downloads")
        let (service, _) = make(reply: invoiceName, folderSource: {
            FileNamingRules.watchedFolders(defaults: ["location": "~/Shots"], home: home, downloads: downloads)
        })
        await arm(service)
        XCTAssertEqual(service.status.folders, [shots.path, downloads.path], "a folder missing at arm was dropped")
        XCTAssertEqual(service.status.unwatched, [shots.path, downloads.path])
        XCTAssertEqual(service.status.missing, [shots.path, downloads.path])
        XCTAssertTrue(service.status.settingsLine.contains("Waiting for the screenshot folder Shots to exist."),
                      service.status.settingsLine)
        XCTAssertFalse(service.status.settingsLine.contains("Files and Folders"),
                       "a folder that does not exist was sent to the permission pane: \(service.status.settingsLine)")

        try fm.createDirectory(at: shots, withIntermediateDirectories: true)
        let shotsWatched = await eventually { service.watchedPaths.contains(shots.path) }
        XCTAssertTrue(shotsWatched, "the screenshot folder appeared and was never watched: \(service.status)")
        XCTAssertEqual(service.status.unwatched, [downloads.path], "the folder still missing is no longer retried")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let both = await eventually { service.status.unwatched.isEmpty && service.watchedPaths.contains(downloads.path) }
        XCTAssertTrue(both, "\(service.status)")
        XCTAssertEqual(service.status.missing, [])
    }

    // MARK: - Whole and quiet

    /// A FILE IS NAMED ONLY WHEN ITS CONTENT IS WHOLE. A download written
    /// straight to its final name held its size through a network stall and
    /// was named from its first half (review 2026-10-28).
    func testAnIncompleteFileWaitsUntilItIsWhole() async throws {
        let whole = Flag()
        let (service, backend) = make(reply: invoiceName, complete: { _, _ in whole.value })
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(service.status.named, 0, "a file that is not whole was named")
        let during = await backend.shortAnswers
        XCTAssertEqual(during, 0, "a file that is not whole was read")
        whole.value = true
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the file was not named once whole: \(service.status)")
    }

    /// And checked again just before the rename: here the content reads as
    /// whole when it settles and not when the rename comes.
    func testAFileNoLongerWholeAtRenameIsLeftAlone() async throws {
        let calls = CallCount()
        let (service, backend) = make(reply: invoiceName, complete: { _, _ in calls.bump(); return calls.value == 1 })
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let skipped = await eventually { service.status.skipped["changedMeanwhile"] == 1 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("document (3).pdf"), "a file that was not whole at rename time was renamed")
        XCTAssertEqual(service.status.named, 0)
        XCTAssertEqual(calls.value, 2, "the content was not checked both when it settled and before the rename")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "control: the model was asked, so the rename was what the check stopped")
    }

    /// A file written within the quiet period waits for it.
    func testAFileWrittenRecentlyWaitsUntilItIsQuiet() async throws {
        let (service, _) = make(reply: invoiceName, quiet: 1.5)
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(service.status.named, 0, "a file written under a second ago was named")
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "the file was never named once quiet: \(service.status)")
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
        // The partner first, so every listing that holds the HEIC holds it too.
        try drop("IMG_4471.MOV")
        try drop("IMG_4471.HEIC")
        service.rescan()
        // One for the MOV (not an image), one for the HEIC (it has a pair).
        let skipped = await eventually { service.status.skipped["unsupported"] == 2 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("IMG_4471.HEIC"), "half of a pair was renamed")
        XCTAssertEqual(service.status.named, 0)
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
    }

    /// The partner still downloading counts, and so does a sidecar named
    /// after the whole file name (review 2026-10-28).
    func testAPartnerStillDownloadingOrASidecarKeepsAFileAlone() async throws {
        let (service, backend) = make(reply: invoiceName)
        await arm(service)
        // Partners first, so every listing that holds a file holds its partner.
        try drop("IMG_4471.MOV.crdownload")
        try drop("IMG_0012.jpg.xmp")
        try drop("IMG_4471.HEIC")
        try drop("IMG_0012.jpg")
        service.rescan()
        // The HEIC and the JPEG for their partners, the xmp for its kind; the
        // .crdownload is not a finished file and is not counted.
        let skipped = await eventually { service.status.skipped["unsupported"] == 3 }
        XCTAssertTrue(skipped, "\(service.status)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists("IMG_4471.HEIC"), "a Live Photo's still was renamed while its movie downloaded")
        XCTAssertTrue(exists("IMG_0012.jpg"), "a photo was renamed away from its sidecar")
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 0)
    }

    /// A partner that lands while the model is naming the file is caught by
    /// the check just before the rename.
    func testAPartnerThatLandsDuringTheModelCallStopsTheRename() async throws {
        let dir = self.dir!
        let partner = staging.appendingPathComponent("partner")
        let text = invoiceText
        let (service, backend) = make(reply: invoiceName, reader: { _, _ in
            try? Data("movie".utf8).write(to: partner)
            try? FileManager.default.moveItem(at: partner, to: dir.appendingPathComponent("IMG_4471.MOV"))
            return text
        })
        await arm(service)
        try drop("IMG_4471.HEIC")
        service.rescan()
        let stopped = await eventually { (service.status.skipped["unsupported"] ?? 0) >= 1 }
        XCTAssertTrue(stopped, "\(service.status)")
        // One for the HEIC (its partner landed), one for the MOV once listed.
        await service.rescanNow()
        let skipped = await eventually { service.status.skipped["unsupported"] == 2 }
        XCTAssertTrue(skipped, "\(service.status)")
        XCTAssertTrue(exists("IMG_4471.HEIC"), "a file whose partner landed during naming was renamed")
        XCTAssertEqual(service.status.named, 0)
        let shorts = await backend.shortAnswers
        XCTAssertEqual(shorts, 1, "control: the model was asked, so the rename was what the check stopped")
    }

    // MARK: - The naming model

    /// A NAMING MODEL THAT IS NOT THE CHAT MODEL IS LET GO. Otherwise one
    /// screenshot holds a second model beside chat for 30 minutes (review
    /// 2026-10-28).
    /// Unloading after every rename made each screenshot reload the model
    /// (2,052 and 4,406 ms against about 700 warm, measured 2026-10-28). It
    /// stays loaded for the idle delay after the last file and goes after it.
    func testTheNamingModelStaysLoadedUntilTheIdleDelayPasses() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "chat-model-test:4b"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) }, idleDelay: 1.5)
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: nothing was named: \(service.status)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unloaded, [], "the naming model was let go right after the rename")
        let gone = await eventually { unloaded == ["grux-local-test"] }
        XCTAssertTrue(gone, "the naming model was never let go after the idle delay: \(unloaded)")
    }

    func testANamingModelThatIsNotTheChatModelIsUnloadedWhenIdle() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "chat-model-test:4b"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) })
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: nothing was named: \(service.status)")
        let gone = await eventually { unloaded == ["grux-local-test"] }
        XCTAssertTrue(gone, "the naming model was not unloaded once idle: \(unloaded)")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(unloaded, ["grux-local-test"], "the naming model was unloaded more than once")
    }

    /// The chat model is never unloaded, by either of its names.
    func testTheChatModelIsNeverUnloaded() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "grux-local-test:latest"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) })
        await arm(service)
        try drop("document (3).pdf")
        service.rescan()
        let named = await eventually { service.status.named == 1 }
        XCTAssertTrue(named, "control: nothing was named: \(service.status)")
        try await Task.sleep(for: .milliseconds(400))
        service.apply(enabled: false)
        XCTAssertEqual(unloaded, [], "the chat model was unloaded")
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

    // MARK: - The preview's model

    /// A PREVIEW'S MODEL IS LET GO AFTER A PAUSE. The eval runs previews with
    /// the feature off, where nothing else ever unloaded the naming model
    /// (review 2026-10-28).
    func testAPreviewLetsItsModelGoAfterAPause() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "chat-model-test:4b"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) }, previewDelay: 0.4)
        try drop("document (3).pdf")
        let preview = await service.preview(path: dir.appendingPathComponent("document (3).pdf").path)
        XCTAssertEqual(preview.decision, "rename", "control: the preview never called the model")
        XCTAssertEqual(unloaded, [], "the model was let go at once, so the next preview pays a cold load")
        let gone = await eventually { unloaded == ["grux-local-test"] }
        XCTAssertTrue(gone, "the preview's model was never let go: \(unloaded)")
    }

    /// A preview before the pause is over keeps the model, so the eval's items
    /// all run warm.
    func testAPreviewSoonAfterAnotherKeepsTheModel() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "chat-model-test:4b"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) }, previewDelay: 0.6)
        try drop("document (3).pdf")
        let path = dir.appendingPathComponent("document (3).pdf").path
        _ = await service.preview(path: path)
        try await Task.sleep(for: .milliseconds(350))
        _ = await service.preview(path: path)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(unloaded, [], "the model was let go between two previews")
        let gone = await eventually { unloaded == ["grux-local-test"] }
        XCTAssertTrue(gone, "\(unloaded)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unloaded, ["grux-local-test"], "the model was let go once per preview")
    }

    /// A PASS AFTER A PREVIEW DOES NOT UNLOAD ITS MODEL. With the feature on
    /// during the eval, a pass over a folder unloaded the preview's model
    /// between items and the eval paid cold loads (review 2026-10-28).
    func testAPassAfterAPreviewDoesNotUnloadItsModel() async throws {
        let savedModel = AppState.shared.config.offlineLLMModel
        let savedSuspended = Persistence.writesSuspended
        Persistence.writesSuspended = true
        AppState.shared.config.offlineLLMModel = "chat-model-test:4b"
        defer {
            AppState.shared.config.offlineLLMModel = savedModel
            Persistence.writesSuspended = savedSuspended
        }
        var unloaded: [String] = []
        let (service, _) = make(reply: invoiceName, unloader: { unloaded.append($0.model) }, previewDelay: 5)
        await arm(service)
        let item = staging.appendingPathComponent("item.pdf")
        try Data("%PDF-an eval item".utf8).write(to: item)
        // An eval item outside the watched folder, the way the harness copies them.
        let renamedItem = staging.appendingPathComponent("document (9).pdf")
        try fm.moveItem(at: item, to: renamedItem)
        let preview = await service.preview(path: renamedItem.path)
        XCTAssertEqual(preview.decision, "rename", "control: the preview never called the model")
        await service.rescanNow()
        try await Task.sleep(for: .milliseconds(200))
        await service.rescanNow()
        XCTAssertEqual(unloaded, [], "a pass after a preview unloaded the preview's model")
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
