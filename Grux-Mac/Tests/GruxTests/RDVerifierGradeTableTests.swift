import XCTest
@testable import Grux

// Operator note 9 (2026-10-23), CLASS GUARD: three waves running a reviewer found a P2 in
// how the full-suite gate grades a test run. This table walks every combination of how
// XCTest ended, how swift-testing ended, how the process exited, and whether the suite
// command declares swift-testing, against a baseline of 2 failures, and checks the gate
// against an oracle written here from the rule in plain words, not from the gate's code.
final class RDVerifierGradeTableTests: XCTestCase {

    enum XCTestRun: CustomStringConvertible {
        case absent, startedNotClosed, closed(failures: Int)
        var description: String {
            switch self {
            case .absent: return "XCTest absent"
            case .startedNotClosed: return "XCTest started, not closed"
            case .closed(let f): return "XCTest closed with \(f) failures"
            }
        }
    }

    enum SwiftTestingRun: CustomStringConvertible {
        case absent, startedNotClosed, closed(issues: Int)
        var description: String {
            switch self {
            case .absent: return "swift-testing absent"
            case .startedNotClosed: return "swift-testing started, not closed"
            case .closed(let i): return "swift-testing closed with \(i) issues"
            }
        }
    }

    enum Exit: CustomStringConvertible {
        case zero, one, signal
        var code: Int32 {
            switch self {
            case .zero: return 0
            case .one: return 1
            case .signal: return -3 // RDLiveProcessRunner's code for a signal death
            }
        }
        var description: String { "exit \(code)" }
    }

    static let baselineFailures = 2

    // The rule, in plain words:
    // Accept only when
    //  - XCTest closed (its whole-run line printed) with failures at or under the baseline,
    //  - swift-testing either is declared absent for this suite and printed nothing, or
    //    closed with 0 issues,
    //  - and the exit is 0, or it is 1 and a failure counted in a run that closed explains
    //    it. A signal death is never accepted.
    static func oracle(_ x: XCTestRun, _ s: SwiftTestingRun, _ exit: Exit, declaresSwiftTesting: Bool) -> Bool {
        guard case .closed(let failures) = x, failures <= baselineFailures else { return false }
        switch s {
        case .absent:
            if declaresSwiftTesting { return false }
        case .startedNotClosed:
            return false
        case .closed(let issues):
            if issues != 0 { return false }
        }
        switch exit {
        case .zero: return true
        case .one: return failures > 0
        case .signal: return false
        }
    }

    static func output(_ x: XCTestRun, _ s: SwiftTestingRun) -> String {
        var lines: [String] = []
        switch x {
        case .absent:
            break
        case .startedNotClosed:
            lines += [
                "Test Suite 'All tests' started at 2026-10-23 03:00:00.000.",
                "Test Suite 'GruxPackageTests.xctest' started at 2026-10-23 03:00:00.001.",
                "Test Suite 'AgentTests' started at 2026-10-23 03:00:00.002.",
                "Test Suite 'AgentTests' failed at 2026-10-23 03:00:09.000.",
                "\t Executed 120 tests, with 0 tests skipped and 1 failure (0 unexpected) in 9.0 (9.0) seconds",
            ]
        case .closed(let failures):
            lines += [
                "Test Suite 'All tests' started at 2026-10-23 03:00:00.000.",
                "Test Suite 'All tests' \(failures > 0 ? "failed" : "passed") at 2026-10-23 03:10:00.000.",
                "\t Executed 4039 tests, with 0 tests skipped and \(failures) failure\(failures == 1 ? "" : "s") (0 unexpected) in 600.0 (600.1) seconds",
            ]
        }
        switch s {
        case .absent:
            break
        case .startedNotClosed:
            lines += ["\u{25C7} Test run started.", "\u{21B3} Testing Library Version: 1743"]
        case .closed(let issues):
            lines.append("\u{25C7} Test run started.")
            lines.append(issues > 0
                ? "\u{2718} Test run with 30 tests in 5 suites failed after 1.0 seconds with \(issues) issue\(issues == 1 ? "" : "s")."
                : "\u{2714} Test run with 30 tests in 5 suites passed after 1.0 seconds.")
        }
        return lines.joined(separator: "\n")
    }

    static func proposal() -> UpgradeProposal {
        UpgradeProposal(
            title: "Grade table", lane: .reliability, domain: .mac,
            evidence: [UpgradeEvidence(source: "table", detail: "every combination")],
            expectedGain: 0.5, riskClass: .low, estCostLabel: "$1 estimated",
            tierRequired: .propose, readyPrompt: "none"
        )
    }

    func testEveryCombinationGradesAsTheRuleSays() async {
        let xcRuns: [XCTestRun] = [.absent, .startedNotClosed, .closed(failures: 0), .closed(failures: 1),
                                   .closed(failures: 2), .closed(failures: 3)]
        let stRuns: [SwiftTestingRun] = [.absent, .startedNotClosed, .closed(issues: 0), .closed(issues: 1),
                                         .closed(issues: 2)]
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("grux-rd-table", isDirectory: true)
        let proposal = Self.proposal()
        var checked = 0
        var wrong: [String] = []
        for declares in [true, false] {
            let suite = RDSuiteCommand(full: ["swift", "test"], focused: ["swift", "test", "--filter", "{filter}"],
                                       runsSwiftTesting: declares)
            for x in xcRuns {
                for s in stRuns {
                    for exit in [Exit.zero, .one, .signal] {
                        let runner = RDVerifierTests.FakeRunner(outputs: [
                            "swift test": RDProcessOutput(exitCode: exit.code, stdout: Self.output(x, s), stderr: "")
                        ])
                        let gate = RDBaselineTestGate(runner: runner,
                                                      baseline: RDTestBaseline(failures: Self.baselineFailures, skips: 6),
                                                      suite: suite)
                        let result = await gate.run(RDVerifyContext(worktreeRoot: worktree, proposal: proposal))
                        let expected = Self.oracle(x, s, exit, declaresSwiftTesting: declares)
                        checked += 1
                        if result.passed != expected {
                            wrong.append("\(x), \(s), \(exit), suite \(declares ? "runs" : "declares no") swift-testing: "
                                + "gate \(result.passed ? "ACCEPTED" : "refused"), rule says \(expected ? "accept" : "refuse"). "
                                + result.evidence.prefix(160))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 180)
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) of \(checked) graded against the rule:\n" + wrong.joined(separator: "\n"))
    }

    // P2-W3a exactly: XCTest closed with 1 failure (inside the baseline of 2), exit 1, and
    // swift-testing printed nothing at all, from a suite command that runs swift-testing.
    func testASwiftTestingRunThatPrintedNothingIsUnknownAndRefuses() async {
        let runner = RDVerifierTests.FakeRunner(outputs: [
            "swift test": RDProcessOutput(exitCode: 1, stdout: Self.output(.closed(failures: 1), .absent), stderr: "")
        ])
        let gate = RDBaselineTestGate(runner: runner, baseline: RDTestBaseline(failures: 2, skips: 6))
        let result = await gate.run(RDVerifyContext(
            worktreeRoot: FileManager.default.temporaryDirectory,
            proposal: Self.proposal()))
        XCTAssertFalse(result.passed, result.evidence)
        XCTAssertTrue(result.evidence.contains("swift-testing"), result.evidence)
        XCTAssertTrue(result.evidence.contains("runsSwiftTesting"), "say how to declare an XCTest-only suite: \(result.evidence)")
    }
}
