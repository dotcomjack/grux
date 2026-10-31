import XCTest
@testable import Grux

/// T1, 2026-10-29: the live runner looked at a child every 0.2 s, so a git call
/// that took 13 ms cost 200 ms. Foundry's gates run dozens of them per build, and
/// FoundryBuiltChangeTests spent 121 s of the suite waiting on that sleep. The
/// runner now returns when the child exits; the time limit and the signal code
/// it already had still hold.
final class RDLiveProcessRunnerTests: XCTestCase {

    func testAQuickChildReturnsWhenItExits() async {
        let runner = RDLiveProcessRunner()
        let start = Date()
        for _ in 0..<10 {
            let out = await runner.run(executable: "/usr/bin/true", arguments: [], currentDirectory: nil,
                                       stdin: nil, timeoutSeconds: 30)
            XCTAssertEqual(out.exitCode, 0)
        }
        // Polling every 0.2 s made ten of these take at least 2 s.
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 1.0, "ten quick children took \(took) s")
    }

    func testAChildPastItsLimitIsStoppedAndSaysSo() async {
        let start = Date()
        let out = await RDLiveProcessRunner().run(executable: "/bin/sleep", arguments: ["20"], currentDirectory: nil,
                                                  stdin: nil, timeoutSeconds: 0.5)
        XCTAssertEqual(out.exitCode, -2, out.stderr)
        XCTAssertTrue(out.stderr.contains("timed out"), out.stderr)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the limit did not stop the child")
    }

    func testAChildKilledByASignalIsNotAnOrdinaryExit() async {
        let out = await RDLiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"],
                                                  currentDirectory: nil, stdin: nil, timeoutSeconds: 30)
        XCTAssertEqual(out.exitCode, -3, out.stderr)
        XCTAssertTrue(out.stderr.contains("killed by signal 9"), out.stderr)
    }

    func testOutputAndExitCodeStillArrive() async {
        let out = await RDLiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 4"],
                                                  currentDirectory: nil, stdin: nil, timeoutSeconds: 30)
        XCTAssertEqual(out.exitCode, 4)
        XCTAssertEqual(out.stdout, "out\n")
        XCTAssertTrue(out.stderr.hasPrefix("err\n"), out.stderr)
    }
}
