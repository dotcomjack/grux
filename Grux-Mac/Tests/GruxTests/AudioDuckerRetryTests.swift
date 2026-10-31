import XCTest
@testable import Grux

/// Wave 9 review (P2): the duck and the restore share the script gate, which can be busy
/// behind an Automation prompt. A restore that failed cancelled the 120 s backstop and
/// gave up, so Music stayed lowered for the rest of the session. It now tries again.
/// Music is never reached: `setVolumeUnderTest` plays it.
@MainActor
final class AudioDuckerRetryTests: XCTestCase {

    override func tearDown() {
        AudioDucker().stageDuckUnderTest(saved: nil)
        super.tearDown()
    }

    func testAFailedRestoreTriesAgainInsteadOfGivingUp() {
        let ducker = AudioDucker()
        var calls: [Int] = []
        ducker.setVolumeUnderTest = { calls.append($0); return false }
        ducker.stageDuckUnderTest(saved: 70)
        ducker.restore()
        XCTAssertEqual(calls, [70])
        XCTAssertTrue(ducker.restoreIsPending, "a failed restore left Music lowered with nothing scheduled")
    }

    func testARestoreThatWorksSchedulesNothingMore() {
        let ducker = AudioDucker()
        ducker.setVolumeUnderTest = { _ in true }
        ducker.stageDuckUnderTest(saved: 70)
        ducker.restore()
        XCTAssertFalse(ducker.restoreIsPending)
    }

    func testRetriesStopAtTheLimit() {
        let ducker = AudioDucker()
        ducker.setVolumeUnderTest = { _ in false }
        ducker.stageDuckUnderTest(saved: 70)
        for _ in 0..<AudioDucker.maxRestoreRetries { ducker.restore() }
        XCTAssertTrue(ducker.restoreIsPending, "the last allowed retry was not scheduled")
        ducker.restore()
        XCTAssertFalse(ducker.restoreIsPending, "retries went past the limit")
    }
}
