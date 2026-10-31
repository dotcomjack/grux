import XCTest
@testable import Grux

/// D16 (P2): `ShellRunner` waited for the shell to exit, then read its pipe to the end
/// with no deadline. Anything still holding the pipe (a background job the command
/// started) kept the caller waiting until it ended; measured 2026-10-22, one full suite
/// run sat 25 minutes in that read. And output past the pipe's 64 KB buffer stalled the
/// command until the timeout killed it. The whole wait is now bounded and the pipe is
/// read while the command runs.
final class ShellRunnerBoundTests: XCTestCase {

    /// Unique, so cleanup kills only what this test started.
    private let marker = "23.\(Int.random(in: 100_000...999_999))"

    override func tearDown() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "sleep \(marker)"]
        try? kill.run()
        kill.waitUntilExit()
        super.tearDown()
    }

    func testABackgroundJobHoldingTheOutputDoesNotHoldTheCaller() async {
        let started = Date()
        let r = await ShellRunner.runRaw(command: "echo started; /bin/sleep \(marker) &", timeoutSeconds: 10)
        let waited = Date().timeIntervalSince(started)
        XCTAssertLessThan(waited, 8, "the caller waited for a background job that held the pipe")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "started")
    }

    func testOutputPastThePipeBufferArrivesWhole() async {
        let started = Date()
        let r = await ShellRunner.runRaw(command: "/usr/bin/yes x | /usr/bin/head -c 200000", timeoutSeconds: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "a big output stalled the command until the timeout")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout.utf8.count, 200_000)
    }

    func testACommandThatRunsPastItsLimitIsStoppedAndTheCallerAnswered() async {
        let started = Date()
        let r = await ShellRunner.runRaw(command: "/bin/sleep \(marker)", timeoutSeconds: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "the limit did not bound the wait")
        XCTAssertNotEqual(r.status, 0)
    }

    func testTheArgvDoorIsBoundedTheSameWay() async {
        let started = Date()
        let r = await ShellRunner.runArgs("/bin/sh", ["-c", "echo started; /bin/sleep \(marker) &"], timeoutSeconds: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the caller waited for a background job that held the pipe")
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "started")
    }

    /// Wave 9 review: closing the pipe when the step returned killed a background job
    /// the moment it next wrote (SIGPIPE), so `start-server &` died on its first log line.
    func testABackgroundJobThatWritesAfterTheStepReturnsKeepsRunning() async throws {
        let done = FileManager.default.temporaryDirectory.appendingPathComponent("bg-survived-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: done) }
        let r = await ShellRunner.runRaw(command: "echo started; (/bin/sleep 1.5; echo late; /usr/bin/touch '\(done.path)') &",
                                         timeoutSeconds: 10)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "started")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the background job died when it wrote after the step returned")
    }

    /// Wave 9 review round 2 (P2): with the pipe read as it fills, `yes` for 30 s would
    /// fill memory. Output past the cap is read and dropped, and the step says so.
    func testOutputPastTheCapIsDroppedAndSaysSo() async {
        let r = await ShellRunner.runRaw(command: "/usr/bin/yes x | /usr/bin/head -c 6000000", timeoutSeconds: 20)
        XCTAssertEqual(r.status, 0)
        XCTAssertLessThan(r.stdout.utf8.count, BoundedProcess.maxOutputBytes + 200)
        XCTAssertTrue(r.stdout.hasSuffix("…(output past 4 MB dropped: \(6_000_000 - BoundedProcess.maxOutputBytes) bytes)"),
                      String(r.stdout.suffix(120)))
    }
}
