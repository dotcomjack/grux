import Foundation

// Flake lane of the Sense pass. Parses a stored `swift test` output log when
// one exists at the seam path (the Foundry's verify stage will tee its runs
// there; CI scripts can drop one in too). No log file means no signals, which
// keeps the kickoff cycle quiet instead of inventing flake data.
//
// Two patterns:
//   - Hard failures: XCTest "Test Case '-[Target.Class testName]' failed".
//   - Flakes proper: the same test seen BOTH passed and failed in the same
//     log (retry loops, repeated suites), the classic flake fingerprint.
struct FlakeSignalSource: FoundrySignalSource {

    let sourceName = "flake"

    // Default seam path: Application Support/Grux/foundry/test-output.log.
    var logURL: URL

    init(logURL: URL? = nil) {
        self.logURL = logURL ?? Persistence.supportDir
            .appendingPathComponent("foundry", isDirectory: true)
            .appendingPathComponent("test-output.log")
    }

    func harvest() async throws -> [FoundrySignal] {
        guard let raw = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Self.signals(fromTestLog: raw)
    }

    struct TestOutcome: Equatable {
        var name: String      // "Target.Class testName"
        var passed: Int
        var failed: Int
        var failureLines: [String]
    }

    // Exposed for tests: pure parse of swift-test/XCTest console output.
    static func signals(fromTestLog raw: String) -> [FoundrySignal] {
        var outcomes: [String: TestOutcome] = [:]
        var lastFailureDetail: [String: [String]] = [:]

        for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(lineSub)
            // XCTest summary lines:
            //   Test Case '-[GruxTests.FooTests testBar]' passed (0.123 seconds).
            //   Test Case '-[GruxTests.FooTests testBar]' failed (0.456 seconds).
            guard let name = testCaseName(in: line) else {
                // Assertion detail lines reference the file/line; keep the most
                // recent few as evidence for whichever test fails next.
                if line.contains("error:") && line.contains("XCTAssert") {
                    lastFailureDetail["__pending__", default: []].append(String(line.prefix(200)))
                }
                continue
            }
            var outcome = outcomes[name] ?? TestOutcome(name: name, passed: 0, failed: 0, failureLines: [])
            if line.contains("' passed") {
                outcome.passed += 1
            } else if line.contains("' failed") {
                outcome.failed += 1
                outcome.failureLines.append(String(line.prefix(200)))
                if let pending = lastFailureDetail["__pending__"], !pending.isEmpty {
                    outcome.failureLines += pending.suffix(2)
                    lastFailureDetail["__pending__"] = []
                }
            }
            outcomes[name] = outcome
        }

        var signals: [FoundrySignal] = []
        for outcome in outcomes.values.sorted(by: { $0.name < $1.name }) {
            guard outcome.failed > 0 else { continue }
            let isFlake = outcome.passed > 0
            signals.append(FoundrySignal(
                source: "flake",
                severity: isFlake ? .medium : .high,
                summary: isFlake
                    ? "Flaky test: \(outcome.name) (passed \(outcome.passed)x, failed \(outcome.failed)x in one log)"
                    : "Failing test: \(outcome.name) (failed \(outcome.failed)x)",
                evidence: outcome.failureLines.suffix(4).joined(separator: "\n"),
                suggestedLane: .codeHealth,
                suggestedDomain: "tests"
            ))
        }
        return signals
    }

    // Pulls "GruxTests.FooTests testBar" out of a Test Case line; nil for any
    // other line shape.
    static func testCaseName(in line: String) -> String? {
        guard line.hasPrefix("Test Case '"),
              let open = line.range(of: "'-["),
              let close = line.range(of: "]'", range: open.upperBound..<line.endIndex)
        else { return nil }
        let inner = String(line[open.upperBound..<close.lowerBound])
        return inner.isEmpty ? nil : inner
    }
}
