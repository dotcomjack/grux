import XCTest
@testable import Grux

/// The one usage counter the reskin adds. Local, append-only, one JSON object
/// per line, so a later version can rank Recent on real use. Nothing reads it
/// in 3.0.
final class OpensLogTests: XCTestCase {
    /// A fresh file under the suite's support folder, never under the home folder.
    private func temp() -> URL {
        let dir = Persistence.supportDir
            .appendingPathComponent("opens-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("opens.jsonl")
    }

    private func lines(_ file: URL) throws -> [Substring] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    }

    func test_eachOpenIsOneJSONLine() throws {
        let file = temp()
        let log = OpensLog(fileURL: file)
        log.record(key: "mailbox", via: .now)
        log.record(key: "chat", via: .input)
        log.flush()
        let lines = try lines(file)
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["key"] as? String, "mailbox")
        XCTAssertEqual(first["via"] as? String, "now")
        XCTAssertNotNil(first["ts"] as? String)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["key"] as? String, "chat")
        XCTAssertEqual(second["via"] as? String, "input")
    }

    func test_theSharedLogLivesInSupportUnderTest() {
        XCTAssertTrue(OpensLog.shared.fileURL.path.hasPrefix(Persistence.supportDir.path),
                      "the suite must never write the operator's opens.jsonl")
        XCTAssertEqual(OpensLog.shared.fileURL.lastPathComponent, "opens.jsonl")
    }

    func test_anUnwritableFileIsIgnored() throws {
        let impossible = URL(fileURLWithPath: "/dev/null/impossible/opens.jsonl")
        let log = OpensLog(fileURL: impossible)
        log.record(key: "chat", via: .cli)   // must not throw or crash
        log.flush()                          // must return
        XCTAssertFalse(FileManager.default.fileExists(atPath: impossible.path))

        // The failure is contained: the next record to a writable log lands.
        let file = temp()
        let good = OpensLog(fileURL: file)
        good.record(key: "chat", via: .cli)
        good.flush()
        XCTAssertEqual(try lines(file).count, 1)
    }
}
