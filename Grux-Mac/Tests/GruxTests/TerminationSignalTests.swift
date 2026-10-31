import XCTest
@testable import Grux

/// D19 (P2): SIGTERM (`killall Grux`, `kill`, build.sh's fallback) ended Grux at once:
/// no store flush and no clean-shutdown marker, so Self-Upgrade's crash detector read
/// an ordinary quit as a crash (live 2026-10-29 3:22 AM: `killall Grux`, relaunch,
/// `foundry-updater: crash detected at launch`), and two inside 10 minutes restore the
/// previous build. SIGTERM now quits the way Quit does.
final class TerminationSignalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testGruxQuitsOnSIGTERMTheWayQuitDoes() throws {
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)
        let install = try XCTUnwrap(app.range(of: "TerminationSignal.install"), "nothing handles SIGTERM, so it ends Grux at once")
        let handler = String(app[install.lowerBound...].prefix(900))
        let mark = try XCTUnwrap(handler.range(of: "markCleanShutdown()"), "a SIGTERM quit leaves no clean-shutdown marker")
        let quit = try XCTUnwrap(handler.range(of: "NSApp.terminate(nil)"), "a SIGTERM quit skips the store flushes")
        XCTAssertLessThan(mark.lowerBound, quit.lowerBound, "the marker must be written before anything that can stall")
    }

    /// The signal reaches the handler and no longer ends the process.
    func testAHandledSignalRunsTheHandlerInsteadOfEndingTheProcess() {
        let got = expectation(description: "handler ran")
        TerminationSignal.install(SIGUSR2, queue: .global()) { sig in
            XCTAssertEqual(sig, SIGUSR2)
            got.fulfill()
        }
        defer { TerminationSignal.uninstall(SIGUSR2) }
        kill(getpid(), SIGUSR2)
        wait(for: [got], timeout: 5)
    }

    /// Wave 9 review: an ignored signal survives exec, so with SIGTERM ignored every
    /// process Grux started (zsh, MCP servers, agent CLIs) would ignore `terminate()`.
    /// A child must get the default action back.
    func testAChildDoesNotInheritTheHandledSignalAsIgnored() async {
        TerminationSignal.install(SIGUSR2, queue: .global()) { _ in }
        defer { TerminationSignal.uninstall(SIGUSR2) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "kill -USR2 $$; echo survived"]
        let r = await BoundedProcess.run(proc, timeout: 10)
        XCTAssertFalse(r.output.contains("survived"), "the child inherited the signal as ignored")
        XCTAssertEqual(proc.terminationReason, .uncaughtSignal)
    }

    /// Wave 9 review: with the handler on the main queue, a wedged main thread made
    /// Grux ignore `killall` entirely. The fallback exit must not need the main thread.
    func testTheFallbackExitIsArmedOffTheMainThread() throws {
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)
        let install = try XCTUnwrap(app.range(of: "TerminationSignal.install"))
        let handler = String(app[install.lowerBound...].prefix(900))
        XCTAssertTrue(handler.hasPrefix("TerminationSignal.install(queue: .global"), "the handler runs on the main queue")
        let fallback = try XCTUnwrap(handler.range(of: "exit(0)"))
        let main = try XCTUnwrap(handler.range(of: "DispatchQueue.main.async"))
        XCTAssertLessThan(fallback.lowerBound, main.lowerBound, "the fallback is armed only after the main thread answers")
    }
}
