import XCTest
@testable import Grux

/// D113: `~/.grux/inject-chat.txt` was read by a 0.8 second repeating timer, so every
/// line written there (a swarm agent's report, a harness turn) waited 0 to 0.8 s before
/// Grux saw it, and the timer woke the main thread 1.25 times a second for the life of
/// the process. Measured on a 16 GB Mac mini (2026-11-01, operator run rel32-final-2b,
/// 36 turns): from Grux reading the line to the reply, median 1.29 s against Ollama's
/// 1.24 s answer, so the app's own share was 0.05 s; the rest of the 1.14 s a turn took
/// end to end was this timer and the harness's own polling.
@MainActor
final class InjectChatWatcherTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("inject-chat.txt") }
    private var got: [String] = []
    private var watcher: InjectChatWatcher?

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inject-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        got = []
    }

    override func tearDown() async throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func startWatcher() {
        let w = InjectChatWatcher(file: file) { [weak self] in self?.got.append($0) }
        w.start()
        watcher = w
    }

    /// Writes into the existing file, the way `printf ... > file` and Python's
    /// `open(path, "w").write(...)` do.
    private func writeInPlace(_ text: String) throws {
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: file.path))
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    /// Spins the main run loop until `count` lines arrived or `seconds` passed, and
    /// returns how long it took.
    @discardableResult
    private func waitFor(_ count: Int, within seconds: TimeInterval) -> TimeInterval {
        let start = Date()
        while got.count < count, Date().timeIntervalSince(start) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return Date().timeIntervalSince(start)
    }

    /// The limit a line must arrive within. Far under the 0.8 s the timer could take,
    /// and far over what a file event takes (a few milliseconds).
    private let prompt: TimeInterval = 0.25

    func testALineWrittenIntoTheFileArrivesAtOnce() throws {
        startWatcher()
        for (i, line) in ["first line", "second line", "third line", "fourth line"].enumerated() {
            try writeInPlace(line + "\n")
            let took = waitFor(i + 1, within: 2)
            XCTAssertEqual(got.last, line)
            XCTAssertLessThan(took, prompt, "line \(i + 1) took \(took) s to arrive")
        }
        XCTAssertEqual(got, ["first line", "second line", "third line", "fourth line"], "each line arrives once")
    }

    func testTheLineIsTakenAndTheDoorStaysPrivate() throws {
        startWatcher()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((before[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try writeInPlace("hello")
        waitFor(1, within: 2)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "", "the line is taken")
        XCTAssertEqual((after[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the fresh door is private")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["inject-chat.txt"],
                       "nothing taken is left behind")
        // Putting the fresh door in place is not read as a line.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(got, ["hello"])
        try writeInPlace("and again")
        waitFor(2, within: 2)
        XCTAssertEqual(got, ["hello", "and again"], "the fresh door is watched")
    }

    /// AgentService writes the file atomically, which puts a new file in its place.
    func testAReplacedFileIsReadAndStillWatched() throws {
        startWatcher()
        try "swarm report".write(to: file, atomically: true, encoding: .utf8)
        let took = waitFor(1, within: 2)
        XCTAssertEqual(got, ["swarm report"])
        XCTAssertLessThan(took, prompt, "the replaced file took \(took) s to be read")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the new file is private too")
        try writeInPlace("after the replace")
        let again = waitFor(2, within: 2)
        XCTAssertEqual(got, ["swarm report", "after the replace"])
        XCTAssertLessThan(again, prompt, "the watch did not follow the new file (\(again) s)")
    }

    func testALineWrittenBeforeStartIsRead() throws {
        try "waiting since before launch".write(to: file, atomically: true, encoding: .utf8)
        startWatcher()
        waitFor(1, within: 2)
        XCTAssertEqual(got, ["waiting since before launch"])
    }

    func testBlankWritesSendNothing() throws {
        startWatcher()
        try writeInPlace("   \n\t ")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(got, [])
    }

    /// Wave 29 review: `{ echo "Swarm job 1 done:"; cat result.txt; } > inject-chat.txt`
    /// writes twice through one open file. Emptying the file in place between the two
    /// writes sent the first half as one turn, and the second landed at its old offset,
    /// so it went out as a second turn led by NUL bytes.
    func testTwoWritesThroughOneOpenFileArriveAsOneLine() throws {
        startWatcher()
        let w = try XCTUnwrap(watcher)
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: file.path))
        try h.truncate(atOffset: 0)
        let before = w.laterCount
        try h.write(contentsOf: Data("Swarm job 1 done:\n".utf8))
        // `cat` writes the rest a few milliseconds later. The second half goes in the
        // moment the watcher has seen the first write and set its read for later, on
        // this thread, so the gap is the scenario's and not the scheduler's: a thread
        // that slept 30 ms woke past the 0.1 s settle under a loaded full suite.
        let seen = Date().addingTimeInterval(2)
        while w.laterCount == before && Date() < seen {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        XCTAssertGreaterThan(w.laterCount, before, "the watcher never saw the first write")
        try h.write(contentsOf: Data("3 tests failed in Foo\n".utf8))
        try h.close()
        waitFor(1, within: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(got, ["Swarm job 1 done:\n3 tests failed in Foo"])
        XCTAssertFalse(got.contains { $0.contains("\0") }, "a line reached chat with NUL bytes in it")
    }

    /// Wave 29 review: with the folder removed, the door was put back nowhere and never
    /// watched again until a relaunch.
    func testARemovedFolderComesBackAndIsWatched() throws {
        startWatcher()
        try FileManager.default.removeItem(at: dir)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the door is put back")
        try writeInPlace("after the folder went")
        waitFor(1, within: 2)
        XCTAssertEqual(got, ["after the folder went"])
    }

    /// Wave 29 review: a door left alone has nothing scheduled. Every delayed step in
    /// the watcher goes through its one `later` (the source guard holds it to that),
    /// which counts what is still waiting to run. A poll of any period keeps something
    /// waiting forever, so it fails here however slow it is (round 4: a backstop every
    /// 5 s first ticked after the old 2.5 s window).
    func testAnIdleDoorHasNothingScheduled() throws {
        startWatcher()
        try writeInPlace("one line")
        waitFor(1, within: 3)
        XCTAssertEqual(got, ["one line"])
        let w = try XCTUnwrap(watcher)
        let start = Date()
        while w.outstanding > 0, Date().timeIntervalSince(start) < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(w.outstanding, 0, "work stays scheduled with nothing written: the door polls")
        let settled = (w.takeCount, w.laterCount)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(w.outstanding, 0)
        XCTAssertEqual(w.takeCount, settled.0, "the file was taken again with nothing written to it")
        XCTAssertEqual(w.laterCount, settled.1, "the idle door put work off for later")
        XCTAssertEqual(got, ["one line"])
    }

    func testAFileOfNULBytesSendsNothing() throws {
        startWatcher()
        try writeInPlace("\0\0\0\0")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(got, [])
    }

    /// Wave 29 review: a line that is not UTF-8 was deleted unread and unlogged.
    func testALineThatIsNotUTF8StillArrives() throws {
        startWatcher()
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: file.path))
        try h.write(contentsOf: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))   // "caf" + Latin-1 e-acute
        try h.close()
        waitFor(1, within: 2)
        XCTAssertEqual(got, ["caf\u{FFFD}"])
    }

    func testADeletedFileComesBackAndIsWatched() throws {
        startWatcher()
        try FileManager.default.removeItem(at: file)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the door is put back")
        try writeInPlace("after a delete")
        let took = waitFor(1, within: 2)
        XCTAssertEqual(got, ["after a delete"])
        XCTAssertLessThan(took, prompt)
    }
}
