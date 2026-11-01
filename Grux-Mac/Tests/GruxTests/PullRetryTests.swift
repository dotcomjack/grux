import XCTest
@testable import Grux

/// release/3.2: a stalled pull tries again. Measured 2026-10-31 on a MacBook,
/// the first-run press of Grux Local 9B ended after 3m50s with Ollama's
/// "context canceled" during a registry stall, and the one click was spent.
@MainActor
final class PullRetryTests: XCTestCase {
    func test_aCancelledPullTriesAgainAndSucceeds() async {
        var tries: [Int] = [], waits: [TimeInterval] = [], retried: [(Int, String)] = []
        let outcomes: [PullRetry.Outcome] = [.failed("context canceled", attempts: 1),
                                             .failed("context canceled", attempts: 1), .installed]
        let ended = await PullRetry.run(
            attempt: { n in tries.append(n); return outcomes[n - 1] },
            sleep: { waits.append($0) },
            onRetry: { n, _, why in retried.append((n, why)) })
        XCTAssertEqual(ended, .installed)
        XCTAssertEqual(tries, [1, 2, 3])
        XCTAssertEqual(waits, [2, 4], "backoff")
        XCTAssertEqual(retried.map(\.0), [1, 2])
        XCTAssertEqual(retried.map(\.1), ["context canceled", "context canceled"])
    }

    func test_retriesRunOutAfterFiveTriesWithAPlainLine() async {
        var tries = 0, waits: [TimeInterval] = []
        let ended = await PullRetry.run(
            attempt: { _ in tries += 1; return .failed("context canceled", attempts: 1) },
            sleep: { waits.append($0) }, onRetry: { _, _, _ in })
        XCTAssertEqual(ended, .failed("context canceled", attempts: 5))
        XCTAssertEqual(tries, PullRetry.maxAttempts)
        XCTAssertEqual(waits, [2, 4, 8, 16])
        XCTAssertEqual(PullRetry.giveUpLine(attempts: 5, why: "context canceled"), "context canceled, after 5 tries")
    }

    func test_anErrorAnotherTryCannotChangeEndsAtOnce() async {
        var tries = 0
        let ended = await PullRetry.run(
            attempt: { _ in tries += 1; return .failed("pull model manifest: file does not exist", attempts: 1) },
            sleep: { _ in XCTFail("waited for a retry that cannot help") }, onRetry: { _, _, _ in })
        XCTAssertEqual(ended, .failed("pull model manifest: file does not exist", attempts: 1))
        XCTAssertEqual(tries, 1)
        XCTAssertTrue(PullRetry.isRetryable("context canceled"), "control")
    }

    func test_aCancelledPullStopsWithoutRetrying() async {
        var tries = 0
        let ended = await PullRetry.run(attempt: { _ in tries += 1; return .cancelled },
                                        sleep: { _ in }, onRetry: { _, _, _ in })
        XCTAssertEqual(ended, .cancelled)
        XCTAssertEqual(tries, 1)
    }

    func test_theLogSaysWhereThePullStopped() {
        var p = OllamaManager.PullProgress(status: "pulling", fraction: 0.45)
        p.completedBytes = 3.24e9
        p.totalBytes = 7.2e9
        XCTAssertEqual(PullRetry.whereItStopped(p), "45% (3.2 of 7.2 GB)")
        XCTAssertEqual(PullRetry.whereItStopped(nil), "0%")
    }

    func test_aClientErrorIsNotRetried() {
        for code in [400, 401, 403, 404] {
            XCTAssertFalse(PullRetry.isRetryable("HTTP \(code)"), "HTTP \(code)")
        }
        XCTAssertTrue(PullRetry.isRetryable("HTTP 500"), "control: a server error may pass")
        XCTAssertTrue(PullRetry.isRetryable("no progress for 45 s"), "a stall is retried")
    }

    /// The watchdog ends a try whose download moves no byte for the limit,
    /// so the next try starts long before Ollama would give up on its own.
    func test_aStalledDownloadEndsTheTry() async {
        let clock = PullRetry.ProgressClock()
        clock.note(downloading: true, completed: 100)
        let started = Date()
        let outcome = await PullRetry.withWatchdog(limit: 0.3, poll: 0.05, clock: clock) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .installed
        }
        guard case .failed(let why, _) = outcome else { return XCTFail("a stall was not ended: \(outcome)") }
        XCTAssertTrue(why.hasPrefix("no progress for"), why)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the watchdog waited for the body")
    }

    func test_aDownloadThatKeepsMovingIsLeftAlone() async {
        let clock = PullRetry.ProgressClock()
        let outcome = await PullRetry.withWatchdog(limit: 0.3, poll: 0.05, clock: clock) {
            for i in 0..<12 {
                clock.note(downloading: true, completed: Double(i + 1) * 1_000)
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            return .installed
        }
        XCTAssertEqual(outcome, .installed, "a moving download was ended as a stall")
    }

    func test_verifyingIsNotAStall() {
        let clock = PullRetry.ProgressClock()
        let long = Date().addingTimeInterval(-600)
        clock.note(downloading: true, completed: 5, at: long)
        XCTAssertGreaterThan(clock.idle(), 500, "control: a silent download is idle")
        clock.note(downloading: false, completed: nil)
        XCTAssertEqual(clock.idle(), 0, "verifying or writing counted as a stall")
    }

    /// Try again shows only under the line a stopped download left.
    func test_tryAgainShowsOnlyUnderAStoppedDownload() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("if err == downloadStoppedLine {\n                        Button(ModelGate.tryAgain)"))
        XCTAssertEqual(src.components(separatedBy: "downloadStoppedLine = localError").count - 1, 1)
        let failed = try XCTUnwrap(src.range(of: "localError = ConnectModelCopy.downloadFailed(pick, ended)\n"))
        XCTAssertTrue(src[failed.upperBound...].hasPrefix("                    downloadStoppedLine = localError"))
        XCTAssertEqual(ModelGate.tryAgain, "Try again")
    }
}
