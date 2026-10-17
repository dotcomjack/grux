import XCTest
@testable import GruxAgentCore

final class CommandExecutorTests: XCTestCase {

    func testTrueExitsZero() async throws {
        let result = try await LocalExecutor().execute(CommandRequest(
            executable: "/usr/bin/true",
            arguments: [],
            cwd: "/tmp",
            env: [:],
            timeoutSec: 5
        ))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPrintfReturnsHi() async throws {
        let result = try await LocalExecutor().execute(CommandRequest(
            executable: "/usr/bin/printf",
            arguments: ["hi"],
            cwd: "/tmp",
            env: [:],
            timeoutSec: 5
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hi")
    }

    func testSleepTimeoutLeavesNoProcess() async throws {
        do {
            _ = try await LocalExecutor().execute(CommandRequest(
                executable: "/bin/sleep",
                arguments: ["30"],
                cwd: "/tmp",
                env: [:],
                timeoutSec: 1
            ))
            XCTFail("expected CommandTimeout")
        } catch is CommandTimeout {
        }
        let listed = try Self.pgrepSleep30()
        XCTAssertEqual(listed, "", "sleep 30 must not survive the timeout")
    }

    private static func pgrepSleep30() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "sleep 30"]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
