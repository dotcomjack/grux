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
}
