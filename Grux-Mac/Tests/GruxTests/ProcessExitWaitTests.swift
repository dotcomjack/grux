import XCTest
@testable import GruxAgentCore

/// D64: a SwarmWorker hung 32 minutes in `Process.waitUntilExit()` with its
/// child gone (`logs/d64-hang-sample.txt`): the run-loop wait missed the exit.
final class ProcessExitWaitTests: XCTestCase {

    private func spawn(_ script: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    func test_theAsyncWaitReturnsWithTheExitStatus() async throws {
        let p = try spawn("sleep 0.2; exit 3")
        await p.waitForExit()
        XCTAssertFalse(p.isRunning)
        XCTAssertEqual(p.terminationStatus, 3)
    }

    func test_theAsyncWaitReturnsForAChildThatAlreadyExited() async throws {
        let p = try spawn("exit 0")
        while p.isRunning { usleep(5_000) }
        await p.waitForExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func test_aCancelledTaskStillWaitsForTheExit() async throws {
        let p = try spawn("sleep 0.3; exit 5")
        let t = Task { () -> Int32 in
            await p.waitForExit()
            return p.terminationStatus
        }
        t.cancel()
        let status = await t.value
        XCTAssertEqual(status, 5)
    }

    func test_theBlockingWaitReturnsWithTheExitStatus() throws {
        let p = try spawn("sleep 0.1; exit 7")
        p.waitForExitBlocking()
        XCTAssertEqual(p.terminationStatus, 7)
    }

    /// The class guard: no code in GruxAgentCore (the workers, the bridge,
    /// the CLI probes, the command executor) waits in a run loop.
    func test_noAgentCoreCodeWaitsInARunLoop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/GruxAgentCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in src.components(separatedBy: "\n").enumerated()
            where line.contains("waitUntilExit()") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "these wait for a child in a run loop, which can miss its exit")
    }
}
