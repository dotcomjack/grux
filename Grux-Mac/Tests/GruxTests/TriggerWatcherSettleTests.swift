import XCTest
@testable import Grux

/// A trigger file is read once its writer has written it, not the instant it appears.
///
/// Measured 2026-09-27 on the loop Mini: 3 of 35 `printf '%s' "Open projects." >
/// ~/.grux/fire-ambient-inject` drops never reached the router. The directory event
/// fires when the entry is CREATED, before the shell writes the bytes, so the handler
/// read an empty file, deleted it, and answered "dropped: empty inject". Nothing fires
/// again when the bytes land, so the text was lost. Every trigger that carries a payload
/// shared the race.
@MainActor
final class TriggerWatcherSettleTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trigger-settle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Runs the main run loop until `done` or the deadline.
    private func spin(until done: () -> Bool, seconds: Double = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_payloadWrittenAfterCreationIsReadWhole() throws {
        let watcher = TriggerWatcher(directory: dir)
        let file = dir.appendingPathComponent("fire-probe")
        var seen: [String] = []
        watcher.register(file) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: file)
            seen.append(text)
        }

        // The entry exists and is empty: the moment the directory event fires.
        FileManager.default.createFile(atPath: file.path, contents: Data())
        watcher.sweepNow()
        XCTAssertEqual(seen, [], "a just-created empty file was consumed before its writer wrote it")

        // Then the shell writes the bytes. No directory event follows this.
        try "Open projects.".write(to: file, atomically: false, encoding: .utf8)
        spin(until: { !seen.isEmpty })
        XCTAssertEqual(seen, ["Open projects."])
    }

    func test_emptyTouchTriggerStillFires() {
        let watcher = TriggerWatcher(directory: dir)
        let file = dir.appendingPathComponent("fire-touch")
        var fired = 0
        watcher.register(file) {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            try? FileManager.default.removeItem(at: file)
            fired += 1
        }
        FileManager.default.createFile(atPath: file.path, contents: Data())
        watcher.sweepNow()
        spin(until: { fired > 0 })
        XCTAssertEqual(fired, 1, "a `touch` trigger is empty by design and must still run, once")
    }

    func test_fileWithContentRunsAtOnce() throws {
        let watcher = TriggerWatcher(directory: dir)
        let file = dir.appendingPathComponent("fire-now")
        var seen: [String] = []
        watcher.register(file) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: file)
            seen.append(text)
        }
        try "home".write(to: file, atomically: true, encoding: .utf8)
        watcher.sweepNow()
        XCTAssertEqual(seen, ["home"], "a file already written must not wait for the settle window")
    }
}
