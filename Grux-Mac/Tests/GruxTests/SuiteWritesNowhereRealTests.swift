import XCTest
@testable import Grux

/// THE SUITE NEVER WRITES TO THE RUNNING APP'S STATE.
///
/// Measured 2026-09-20 on the operator's own machine, before this guard:
///
/// - The Foundry timeline held 1,000 rows and every one was test noise: 667
///   "Auto-land paused (crash-loop breaker)" and 333 "Demoted". A real
///   self-upgrade event would have been invisible in it.
/// - Worse, Grux's self-install was PAUSED on that machine with the reason
///   recorded as "restored after FoundryGovernorTests". `FoundryGovernorTests`
///   drives `GruxUpdater.shared` and calls `clearAutoLandPause()`, which is
///   the human-only control meaning "it is safe to resume self-install". A
///   test run was toggling a real safety breaker on a real Mac.
///
/// Everything Grux persists hangs off `Persistence.supportDir`, so the guard
/// lives there and this asserts it holds.
final class SuiteWritesNowhereRealTests: XCTestCase {

    func test_theTestProcessIsDetected() {
        XCTAssertTrue(Persistence.isUnderTest,
                      "the test-process check does not fire inside the suite, so every guard resting on it is open")
    }

    func test_appStateDoesNotLandInTheRealApplicationSupportDirectory() {
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grux", isDirectory: true)
        XCTAssertNotEqual(Persistence.supportDir.standardizedFileURL, real.standardizedFileURL,
                          "the suite is writing into the operator's real Grux state")
        XCTAssertFalse(Persistence.supportDir.path.hasPrefix(real.path),
                       "the suite is writing under the operator's real Grux state")
    }

    /// The wake log carries what Grux hears and has no dates on its lines, so
    /// test noise in the real one reads a day later as the app's own doing.
    func test_theWakeLogIsNotTheOperatorsLog() {
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grux", isDirectory: true)
        XCTAssertFalse(WakeLog.shared.fileURL.path.hasPrefix(real.path),
                       "the suite is writing into the operator's real wake.log")
        XCTAssertTrue(WakeLog.shared.fileURL.path.hasPrefix(Persistence.supportDir.path))
    }

    /// The shared approval queue is the one Today and Jax HQ count from. Test
    /// fixtures queued into it read as real approvals waiting on the person.
    @MainActor
    func test_theApprovalQueueIsNotTheOperators() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux", isDirectory: true)
        let url = ApprovalQueue.shared.storeFileURL
        XCTAssertFalse(url.path.hasPrefix(real.path), "the suite is queueing into the operator's real approvals")
        XCTAssertTrue(url.path.hasPrefix(Persistence.supportDir.path))
    }

    /// `~/.grux` is the other half of the app's state (P-H-1). Every store in
    /// it goes through `Persistence.gruxDir`, so this one check covers them.
    func test_theDotGruxFolderIsNotTheOperators() {
        let real = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux", isDirectory: true)
        XCTAssertFalse(Persistence.gruxDir.path.hasPrefix(real.path), "the suite is writing into the operator's real ~/.grux")
        XCTAssertTrue(Persistence.gruxDir.path.hasPrefix(Persistence.supportDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Persistence.gruxDir.path),
                      "stores that write straight into the folder would fail silently")
    }

    /// A scratch directory that is not writable is worse than the real one,
    /// because every store fails silently instead of loudly.
    func test_theScratchDirectoryIsRealAndWritable() throws {
        let dir = Persistence.supportDir
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let probe = dir.appendingPathComponent("write-probe.txt")
        try "ok".write(to: probe, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "ok")
        try? FileManager.default.removeItem(at: probe)
    }

    /// The specific file that was being written, named so the next person
    /// reading this test knows what it cost.
    @MainActor
    func test_theFoundryBreakerCannotBeReachedFromTheSuite() {
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grux/foundry/updater/auto-land-paused.json")
        XCTAssertFalse(Persistence.supportDir.path.hasPrefix(real.deletingLastPathComponent().path))
        // Exercising the real API must not create the real file.
        GruxUpdater.shared.tripAutoLandPause(reason: "guard test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path),
                       "a test just tripped the operator's real crash-loop breaker")
        GruxUpdater.shared.clearAutoLandPause()
    }
}
