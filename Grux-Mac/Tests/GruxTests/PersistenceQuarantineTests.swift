import XCTest
@testable import Grux

/// Covers the corrupt-file quarantine in `Persistence`.
///
/// The defect this guards against: `load(_:from:fallback:)` used to answer a
/// MISSING file and a CORRUPT file with the same silent fallback. With 81 load
/// sites, 104 save sites, and stores that debounce a save shortly after they
/// load, that meant one unreadable state file was replaced by an empty default
/// within seconds, permanently, with nothing logged and nothing on screen.
///
/// Every test here runs against a throwaway temp directory, and the quarantine
/// destination is redirected through `Persistence.quarantineDirOverride`, so
/// neither the real Application Support tree nor the real home directory is
/// ever touched.
///
/// Static state (`decodeFailures`, the refusal set, the quarantine override,
/// the restore kill switch) is reset in BOTH setUp and tearDown. This suite is
/// order independent by construction, because this repository has been bitten
/// by order-dependent tests before (see `ModelRegistry.resetLocalForTest`).
final class PersistenceQuarantineTests: XCTestCase {

    private struct Widget: Codable, Equatable {
        var name: String
        var count: Int
    }

    private let fallback = Widget(name: "fallback", count: 0)

    private var sandbox: URL!
    private var stateDir: URL!
    private var quarantineDir: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-persistence-quarantine-\(UUID().uuidString)", isDirectory: true)
        stateDir = sandbox.appendingPathComponent("state", isDirectory: true)
        quarantineDir = sandbox.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        Persistence.quarantineDirOverride = quarantineDir
        Persistence.clearDecodeFailures()
        Persistence.writesSuspended = false
    }

    override func tearDownWithError() throws {
        Persistence.clearDecodeFailures()
        Persistence.quarantineDirOverride = nil
        Persistence.writesSuspended = false
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    // MARK: - Helpers

    private func stateURL(_ name: String = "config.json") -> URL {
        stateDir.appendingPathComponent(name)
    }

    /// Bytes that are definitely not a decodable `Widget`. Deliberately valid
    /// UTF-8 and vaguely JSON-shaped, which is what a truncated or
    /// schema-drifted file actually looks like.
    private func corruptBytes() -> Data {
        Data("{\"name\": \"half a write\", \"cou".utf8)
    }

    private func quarantineContents() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: quarantineDir.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: quarantineDir, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - A missing file is normal

    func test_missingFile_isSilent_andDoesNotArmTheGuard() throws {
        let url = stateURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "precondition: nothing on disk")

        let loaded = Persistence.load(Widget.self, from: url, fallback: fallback)

        XCTAssertEqual(loaded, fallback, "a fresh install gets the fallback")
        XCTAssertTrue(Persistence.decodeFailures.isEmpty, "nothing recorded")
        XCTAssertFalse(Persistence.isWriteRefused(url), "nothing armed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineDir.path),
                       "the quarantine directory is not even created for a missing file")
    }

    func test_missingFile_leavesTheNextSaveWorking() throws {
        // The whole point of staying silent on a missing file: first launch has
        // to be able to write its first state.
        let url = stateURL()
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        Persistence.save(Widget(name: "first", count: 1), to: url)

        XCTAssertEqual(Persistence.load(Widget.self, from: url, fallback: fallback),
                       Widget(name: "first", count: 1))
    }

    // MARK: - A corrupt file is a defect

    func test_corruptFile_returnsFallback_andLeavesTheOriginalUntouched() throws {
        let url = stateURL()
        let planted = corruptBytes()
        try planted.write(to: url)

        let loaded = Persistence.load(Widget.self, from: url, fallback: fallback)

        XCTAssertEqual(loaded, fallback, "callers still see the fallback, so no call site changes behaviour")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "quarantine COPIES, it never moves the user's file")
        XCTAssertEqual(try Data(contentsOf: url), planted,
                       "the original bytes on disk are byte-for-byte unchanged")
    }

    func test_corruptFile_isRecordedForTheUI() throws {
        let url = stateURL()
        try corruptBytes().write(to: url)

        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        let failures = Persistence.decodeFailures
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.path, url.path)
        XCTAssertFalse(failures.first?.quarantined.isEmpty ?? true,
                       "the record names where the preserved copy went")
        XCTAssertFalse(failures.first?.error.isEmpty ?? true,
                       "the record carries the decode error, not just the fact of one")
    }

    // MARK: - The guard proves it fires

    func test_quarantineCopyIsByteForByteIdenticalToThePlantedFile() throws {
        // A guard that cannot demonstrate it fires is not a guard. Plant known
        // bytes, then assert the surviving copy is exactly those bytes: this is
        // the assertion that makes the whole feature worth having, because the
        // copy is the only thing standing between a corrupt file and a
        // permanent loss.
        let url = stateURL()
        let planted = corruptBytes()
        try planted.write(to: url)

        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        let copies = try quarantineContents()
        XCTAssertEqual(copies.count, 1, "exactly one copy for one broken file")
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(try Data(contentsOf: copy), planted,
                       "the quarantined copy is the planted bytes, unmodified")

        // Follow the recorded path itself rather than comparing path strings.
        // A temp directory reaches the recorder as /var/... and comes back out
        // of contentsOfDirectory as /private/var/..., because /var is a symlink
        // on macOS, so string equality here fails on a difference that is not
        // the thing under test. Opening the recorded path is the stronger claim
        // anyway: the UI will follow that string, so it has to lead to bytes.
        let recorded = try XCTUnwrap(Persistence.decodeFailures.first?.quarantined)
        XCTAssertFalse(recorded.isEmpty, "the copy succeeded, so the record names it")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recorded)), planted,
                       "the recorded path opens onto the planted bytes")

        // The name has to be findable a week later: original basename first,
        // timestamp in the middle.
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("config.json."),
                      "kept the original basename, got \(copy.lastPathComponent)")
        XCTAssertTrue(copy.lastPathComponent.hasSuffix(".json"),
                      "still readable as JSON, got \(copy.lastPathComponent)")
        XCTAssertGreaterThan(copy.lastPathComponent.count, "config.json.json".count,
                             "a timestamp sits between the basename and the suffix")
    }

    func test_repeatedLoadOfTheSameCorruptFileQuarantinesOnce() throws {
        // Several stores read the same file. Without the already-armed check,
        // one broken file would fill quarantine with a copy per reader.
        let url = stateURL()
        try corruptBytes().write(to: url)

        for _ in 0..<4 {
            _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        }

        XCTAssertEqual(try quarantineContents().count, 1)
        XCTAssertEqual(Persistence.decodeFailures.count, 1)
    }

    // MARK: - One copy per distinct content, across launches

    // The in-process guard above is `refusedPathStorage`, a plain static that
    // dies with the process. `clearDecodeFailures()` leaves exactly what a
    // fresh launch has: no records and no refusals. So calling it between loads
    // is what a relaunch looks like to this code, and it is the only way to
    // reach the across-launch behaviour from inside one test process.
    private func simulateRelaunch() {
        Persistence.clearDecodeFailures()
    }

    /// Same length as `corruptBytes()`, different bytes. Same length on purpose:
    /// it forces the comparison to actually read the two files instead of
    /// settling the question on size, which is also what a schema drift looks
    /// like in practice.
    private func differentCorruptBytes() -> Data {
        Data("{\"name\": \"half a WRITE\", \"cou".utf8)
    }

    func test_relaunchingWithTheSameCorruptFileDoesNotAddASecondCopy() throws {
        // The defect: the copy was taken again on every launch of a file the
        // write refusal guarantees cannot have changed, so a hidden directory
        // grew by one full duplicate per app start, forever, for a user who
        // never noticed the banner.
        let url = stateURL()
        let planted = corruptBytes()
        try planted.write(to: url)

        _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        let firstCopy = try XCTUnwrap(try quarantineContents().first)

        for _ in 0..<5 {
            simulateRelaunch()
            _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        }

        let copies = try quarantineContents()
        XCTAssertEqual(copies.count, 1, "six launches of one unchanged corrupt file, one copy")
        XCTAssertEqual(copies.first?.lastPathComponent, firstCopy.lastPathComponent,
                       "and it is the copy the FIRST failure took, not a replacement")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copies.first)), planted,
                       "the surviving copy is still the planted bytes")

        // The banner on the sixth launch has to point at something real, not at
        // a copy this launch decided not to take.
        let recorded = try XCTUnwrap(Persistence.decodeFailures.first?.quarantined)
        XCTAssertFalse(recorded.isEmpty, "the record still names a copy")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recorded)), planted,
                       "and the recorded path opens onto the planted bytes")
    }

    func test_aDifferentCorruptVersionOfTheSamePathIsPreservedSeparately() throws {
        // The rule is one copy per distinct CONTENT, not one copy per path. A
        // second, genuinely different broken version is a second corruption
        // event, and losing it would be the exact failure quarantine exists to
        // prevent.
        let url = stateURL()
        let first = corruptBytes()
        let second = differentCorruptBytes()
        XCTAssertEqual(first.count, second.count, "precondition: only the bytes differ, not the size")

        try first.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        simulateRelaunch()
        // Written directly rather than through Persistence.save, because the
        // refusal is what stops that door, and the file changing underneath the
        // app is the case being tested.
        try second.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        let copies = try quarantineContents()
        XCTAssertEqual(copies.count, 2, "two distinct broken versions, two copies")
        let preserved = try copies.map { try Data(contentsOf: $0) }
        XCTAssertTrue(preserved.contains(first), "the original broken version survived")
        XCTAssertTrue(preserved.contains(second), "so did the new one")
    }

    func test_whenContentRepeatsTheEarliestCopyIsTheOneKept() throws {
        // Two copies of the same bytes can already be sitting in quarantine
        // from before this rule existed. Planted by hand with stamps ten years
        // apart so the answer cannot depend on which order the filesystem
        // happens to hand them back.
        let url = stateURL()
        let planted = corruptBytes()
        try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let oldest = quarantineDir.appendingPathComponent("config.json.2020-01-01T000000Z.json")
        let newest = quarantineDir.appendingPathComponent("config.json.2030-01-01T000000Z.json")
        try planted.write(to: oldest)
        try planted.write(to: newest)

        try planted.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        XCTAssertEqual(try quarantineContents().count, 2, "no third copy of bytes already preserved twice")
        // Compared by basename, not by the whole string: a temp directory
        // reaches the recorder as /var/... and comes back out of
        // contentsOfDirectory as /private/var/..., because /var is a symlink on
        // this platform, and that difference is not the thing under test.
        let recorded = try XCTUnwrap(Persistence.decodeFailures.first?.quarantined)
        XCTAssertEqual(URL(fileURLWithPath: recorded).lastPathComponent, oldest.lastPathComponent,
                       "the record names the EARLIEST copy, the one nearest the original failure")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recorded)), planted,
                       "and it opens onto the planted bytes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path),
                      "nothing was pruned to get there")
    }

    // MARK: - The overwrite guard

    func test_saveToAPathWhoseLoadFailedIsRefused() throws {
        let url = stateURL()
        let planted = corruptBytes()
        try planted.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        XCTAssertTrue(Persistence.isWriteRefused(url), "the failed load armed the path")

        // This is the debounced save that used to make the loss permanent.
        Persistence.save(Widget(name: "empty default", count: 0), to: url)

        XCTAssertEqual(try Data(contentsOf: url), planted,
                       "the corrupt file is still the corrupt file, not an empty default")
    }

    func test_rawWriteToAPathWhoseLoadFailedIsRefused() throws {
        // save(_:to:) is not the only way data reaches disk: the NDJSON and
        // markdown stores go through write(_:to:options:), and the guard has to
        // cover that door too.
        let url = stateURL("events.json")
        let planted = corruptBytes()
        try planted.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        let wrote = Persistence.write(Data("replacement".utf8), to: url)

        XCTAssertFalse(wrote, "the raw write reports that it did not happen")
        XCTAssertEqual(try Data(contentsOf: url), planted)
    }

    func test_otherPathsKeepWritingWhileOneIsRefused() throws {
        // The refusal is per path. One broken file must not freeze the app.
        let broken = stateURL("config.json")
        let healthy = stateURL("tasks.json")
        try corruptBytes().write(to: broken)
        _ = Persistence.load(Widget.self, from: broken, fallback: fallback)

        Persistence.save(Widget(name: "unaffected", count: 7), to: healthy)

        XCTAssertEqual(Persistence.load(Widget.self, from: healthy, fallback: fallback),
                       Widget(name: "unaffected", count: 7))
        XCTAssertTrue(Persistence.isWriteRefused(broken))
        XCTAssertFalse(Persistence.isWriteRefused(healthy))
    }

    // MARK: - Acknowledgement

    func test_acknowledgeDecodeFailureReEnablesTheSave() throws {
        let url = stateURL()
        try corruptBytes().write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        Persistence.acknowledgeDecodeFailure(url)

        XCTAssertFalse(Persistence.isWriteRefused(url), "the refusal is lifted")
        XCTAssertTrue(Persistence.decodeFailures.isEmpty,
                      "and the record goes with it, so no banner outlives the state it describes")

        Persistence.save(Widget(name: "repaired", count: 3), to: url)
        XCTAssertEqual(Persistence.load(Widget.self, from: url, fallback: fallback),
                       Widget(name: "repaired", count: 3))
    }

    func test_acknowledgeLeavesTheQuarantinedCopyInPlace() throws {
        let url = stateURL()
        let planted = corruptBytes()
        try planted.write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)

        Persistence.acknowledgeDecodeFailure(url)
        Persistence.save(Widget(name: "repaired", count: 3), to: url)

        let copies = try quarantineContents()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copies.first)), planted,
                       "acknowledging is not deleting: the preserved bytes survive the overwrite")
    }

    func test_acknowledgeIsScopedToOnePath() throws {
        let first = stateURL("config.json")
        let second = stateURL("chat.json")
        try corruptBytes().write(to: first)
        try corruptBytes().write(to: second)
        _ = Persistence.load(Widget.self, from: first, fallback: fallback)
        _ = Persistence.load(Widget.self, from: second, fallback: fallback)
        XCTAssertEqual(Persistence.decodeFailures.count, 2)

        Persistence.acknowledgeDecodeFailure(first)

        XCTAssertFalse(Persistence.isWriteRefused(first))
        XCTAssertTrue(Persistence.isWriteRefused(second), "the other broken file stays protected")
        XCTAssertEqual(Persistence.decodeFailures.map(\.path), [second.path])
    }

    // MARK: - Files with nothing to preserve

    func test_emptyFileDoesNotArmTheGuard() throws {
        // A zero-byte file fails to decode, but there is nothing in it worth
        // preserving, and arming the refusal would leave the store with no
        // recoverable data AND no way to write new data. It gets a log line and
        // the fallback, nothing more.
        let url = stateURL()
        try Data().write(to: url)

        let loaded = Persistence.load(Widget.self, from: url, fallback: fallback)

        XCTAssertEqual(loaded, fallback)
        XCTAssertTrue(Persistence.decodeFailures.isEmpty)
        XCTAssertFalse(Persistence.isWriteRefused(url))
        XCTAssertEqual(try quarantineContents().count, 0)

        Persistence.save(Widget(name: "recovered", count: 2), to: url)
        XCTAssertEqual(Persistence.load(Widget.self, from: url, fallback: fallback),
                       Widget(name: "recovered", count: 2))
    }

    // MARK: - The healthy path is unchanged

    func test_validFileStillRoundTrips() throws {
        let url = stateURL()
        let value = Widget(name: "intact", count: 42)
        Persistence.save(value, to: url)

        XCTAssertEqual(Persistence.load(Widget.self, from: url, fallback: fallback), value)
        XCTAssertTrue(Persistence.decodeFailures.isEmpty)
        XCTAssertFalse(Persistence.isWriteRefused(url))
    }

    func test_clearDecodeFailuresResetsBothTheRecordAndTheRefusal() throws {
        // Asserted directly because every other test in this file depends on
        // setUp doing exactly this. If the reset is partial, the suite becomes
        // order dependent and stops meaning anything.
        let url = stateURL()
        try corruptBytes().write(to: url)
        _ = Persistence.load(Widget.self, from: url, fallback: fallback)
        XCTAssertFalse(Persistence.decodeFailures.isEmpty)
        XCTAssertTrue(Persistence.isWriteRefused(url))

        Persistence.clearDecodeFailures()

        XCTAssertTrue(Persistence.decodeFailures.isEmpty)
        XCTAssertFalse(Persistence.isWriteRefused(url))
    }
}
