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
                arguments: [Self.sleepSeconds],
                cwd: "/tmp",
                env: [:],
                timeoutSec: 1
            ))
            XCTFail("expected CommandTimeout")
        } catch is CommandTimeout {
        }
        let listed = try Self.pgrepOwnSleep()
        XCTAssertEqual(listed, "", "the timed-out sleep must not survive the timeout")
    }

    /// About 30 seconds, written so no other program's sleep matches it. The
    /// check looked for any "sleep 30" on the Mac and failed on an unrelated
    /// script that waits in `sleep 30` (2026-10-31).
    private static let sleepSeconds = "30.4718"

    /// Every process on the Mac still running this test's own sleep.
    private static func pgrepOwnSleep() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "^/bin/sleep 30\\.4718$"]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
