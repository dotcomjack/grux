import XCTest
@testable import Grux

// F4 part 1: the test baseline an upgrade is graded against is measured on this Mac,
// from a full run of the configured suite on the unmodified checkout, through the same
// trust checks the full-suite gate uses. Before this, nothing in the app could move
// the baseline off its default (2 failures, 6 skips), so a suite that skips 12 here
// refused every upgrade, and the only way past it was editing baseline.json by hand.
@MainActor
final class RDBaselineMeasureTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-baseline-measure-\(UUID().uuidString).json")
    }

    private let checkout = URL(fileURLWithPath: "/tmp/grux-measure-checkout", isDirectory: true)

    private let wrapper = RDSuiteCommand(
        full: ["zsh", "~/grux-loop/xctest.sh"],
        focused: ["zsh", "~/grux-loop/xctest.sh", "GruxTests.{filter}"],
        runsSwiftTesting: false
    )

    private static func xctest(executed: Int, skips: Int, failures: Int, closed: Bool = true) -> String {
        let verb = failures == 0 ? "passed" : "failed"
        return (closed ? "Test Suite 'All tests' \(verb) at 2026-10-23 05:10:00.000.\n" : "Test Suite 'GruxTests.xctest' started at 2026-10-23 05:00:00.000.\n")
            + "\t Executed \(executed) tests, with \(skips) tests skipped and \(failures) failures (0 unexpected) in 620.0 (620.3) seconds\n"
    }

    private func store() -> RDBaselineStore { RDBaselineStore(storageURL: tempURL()) }

    func testAGreenRunOnTheCheckoutBecomesTheBaseline() async throws {
        let runner = RDVerifierTests.RecordingRunner(output: RDProcessOutput(
            exitCode: 0, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0) + "XCTEST: PASS\n", stderr: ""))
        let store = store()
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let line = await store.measure(repoRoot: checkout, suite: wrapper, runner: runner, now: { at })
        XCTAssertEqual(store.baseline.failures, 0)
        XCTAssertEqual(store.baseline.skips, 12)
        XCTAssertEqual(store.baseline.measuredExecuted, 4139)
        XCTAssertEqual(store.baseline.measuredAt, at)
        XCTAssertFalse(store.measuring)
        XCTAssertTrue(line.contains("4,139 tests"), line)

        // It ran the suite on the checkout itself, not a worktree.
        let call = try XCTUnwrap(runner.recorded.first)
        XCTAssertEqual(call.arguments.first, "GRUX_REPO=\(checkout.path)")
        XCTAssertEqual(call.cwd, checkout.appendingPathComponent("Grux-Mac"))

        // Saved, and an upgrade at 12 skips now grades AT BASELINE where the default refused it.
        let reloaded = RDBaselineStore(storageURL: store.storageURLForTests)
        XCTAssertEqual(reloaded.baseline, store.baseline)
        let ctx = RDVerifyContext(worktreeRoot: checkout, proposal: UpgradeProposal(
            title: "t", lane: .reliability, domain: .mac, evidence: [], expectedGain: 0.1,
            riskClass: .low, estCostLabel: "$1", tierRequired: .propose, readyPrompt: "p"))
        let before = await RDBaselineTestGate(runner: runner, baseline: .default, suite: wrapper).run(ctx)
        XCTAssertFalse(before.passed, before.evidence)
        let after = await RDBaselineTestGate(runner: runner, baseline: reloaded.baseline, suite: wrapper).run(ctx)
        XCTAssertTrue(after.passed, after.evidence)
    }

    func testKnownFailuresInAFinishedRunAreRecordedAsTheAllowance() async {
        let runner = RDVerifierTests.RecordingRunner(output: RDProcessOutput(
            exitCode: 1, stdout: Self.xctest(executed: 4139, skips: 12, failures: 1) + "XCTEST: FAIL (1 failures)\n", stderr: ""))
        let store = store()
        _ = await store.measure(repoRoot: checkout, suite: wrapper, runner: runner)
        XCTAssertEqual(store.baseline.failures, 1)
        XCTAssertEqual(store.baseline.skips, 12)
    }

    // A run that could not grade an upgrade cannot set the bar either: each of these is
    // refused with its reason, and the baseline stays where it was.
    func testARunTheGateWouldNotTrustLeavesTheBaselineAlone() async {
        let cases: [(String, RDProcessOutput, RDSuiteCommand)] = [
            ("did not finish", RDProcessOutput(exitCode: 1, stdout: Self.xctest(executed: 900, skips: 2, failures: 0, closed: false), stderr: ""), wrapper),
            ("below its own floor", RDProcessOutput(exitCode: 1, stdout: Self.xctest(executed: 4000, skips: 12, failures: 0) + "XCTEST: FAIL (executed 4000 is below floor 4139)\n", stderr: ""), wrapper),
            ("zero tests", RDProcessOutput(exitCode: 0, stdout: Self.xctest(executed: 0, skips: 0, failures: 0), stderr: ""), wrapper),
            ("timed out", RDProcessOutput(exitCode: -2, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0), stderr: ""), wrapper),
            ("swift-testing silent", RDProcessOutput(exitCode: 0, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0), stderr: ""), .swiftTest),
            ("swift-testing issue", RDProcessOutput(exitCode: 1, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0)
                + "Test run started.\n\u{2718} Test run with 30 tests in 5 suites failed after 1.0 seconds with 1 issue.\n", stderr: ""), .swiftTest),
        ]
        for (label, out, suite) in cases {
            let store = store()
            let line = await store.measure(repoRoot: checkout, suite: suite,
                                           runner: RDVerifierTests.RecordingRunner(output: out))
            XCTAssertEqual(store.baseline, .default, label)
            XCTAssertTrue(line.hasPrefix("Not measured:"), "\(label): \(line)")
            XCTAssertEqual(store.lastMeasurement, line, label)
            XCTAssertFalse(store.measuring, label)
        }
    }

    func testOneMeasurementAtATime() async {
        let gate = HeldRunner(output: RDProcessOutput(
            exitCode: 0, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0), stderr: ""))
        let store = store()
        let first = Task { await store.measure(repoRoot: checkout, suite: wrapper, runner: gate) }
        var spins = 0
        while !store.measuring && spins < 10_000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(store.measuring, "the first measurement never showed as in flight")
        let second = await store.measure(repoRoot: checkout, suite: wrapper, runner: gate)
        XCTAssertTrue(second.contains("already"), second)
        gate.release()
        _ = await first.value
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(store.baseline.skips, 12)
    }

    func testAnUpgradeOnTheBuildRailRefusesTheMeasurementWithoutRunningIt() async {
        let runner = RDVerifierTests.RecordingRunner(output: RDProcessOutput(
            exitCode: 0, stdout: Self.xctest(executed: 4139, skips: 12, failures: 0), stderr: ""))
        let store = store()
        let line = await store.measure(repoRoot: checkout, suite: wrapper, runner: runner, canMeasure: { false })
        XCTAssertEqual(line, "Not measured: an upgrade is building; measure again when it settles.")
        XCTAssertTrue(runner.recorded.isEmpty)
        XCTAssertEqual(store.baseline, .default)
        XCTAssertEqual(store.lastMeasurement, line)
    }

    func testThePaneSaysWhereTheBarCameFrom() {
        XCTAssertEqual(RDBaselineStore.line(.default, measuring: false),
                       "Upgrades must pass the full test suite with at most 2 known failures and 6 skips, Grux's default and not this Mac's. Measure this Mac's own numbers before building one.")
        var measured = RDTestBaseline(failures: 1, skips: 12)
        measured.measuredExecuted = 4139
        measured.measuredAt = Date(timeIntervalSince1970: 0)
        let line = RDBaselineStore.line(measured, measuring: false)
        XCTAssertTrue(line.hasPrefix("Upgrades must pass the full test suite with at most 1 known failure and 12 skips, measured on this Mac from 4,139 tests on "), line)
        XCTAssertEqual(RDBaselineStore.line(.default, measuring: true),
                       "Measuring: running the full test suite on your checkout. This can take a while.")
    }

    // A runner that holds its one call until released, to observe the in-flight state.
    final class HeldRunner: RDProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        let output: RDProcessOutput
        init(output: RDProcessOutput) { self.output = output }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func release() {
            lock.lock(); released = true; let c = continuation; continuation = nil; lock.unlock()
            c?.resume()
        }
        func run(executable: String, arguments: [String], currentDirectory: URL?,
                 stdin: String?, timeoutSeconds: TimeInterval) async -> RDProcessOutput {
            lock.lock(); count += 1; lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
            }
            return output
        }
    }
}
