import XCTest
@testable import Grux

// F1: every Claude model id Self-Upgrade uses lives in FoundryModelIDs, on
// current models, and the cost line prices them at their own list rates.
@MainActor
final class FoundryModelIDsTests: XCTestCase {

    func test_theIdsAreCurrentModels() {
        XCTAssertEqual(FoundryModelIDs.standard, "claude-sonnet-5-5")
        XCTAssertEqual(FoundryModelIDs.highStakes, "claude-opus-5-5")
        XCTAssertEqual(FoundryModelIDs.vision, "claude-haiku-4-5-20251001")
    }

    func test_theWorkerAndTheCriticDefaultToTheConstant() {
        let config = RDWorker.Config(repoRoot: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(config.model, FoundryModelIDs.standard)
        XCTAssertEqual(ClaudeUXVisionCritic(apiKey: "").model, FoundryModelIDs.vision)
    }

    // A medium or large upgrade escalates to the swarm, which on its own takes
    // the Agents default (claude-opus-4-8, measured as the architect's model on
    // the 2026-10-23 run BB340D13). Foundry names its own: Opus, current.
    func test_anEscalatedUpgradeRunsEveryWorkerOnTheHighStakesModel() {
        let job = RDWorker.escalationJob(title: "t", prompt: "p", rootDir: "/tmp/wt")
        XCTAssertFalse(job.workers.isEmpty)
        for worker in job.workers {
            XCTAssertEqual(worker.model, FoundryModelIDs.highStakes, worker.label)
        }
    }

    // Anthropic's list prices: Sonnet 5.5 $2 in, $10 out, cache read $0.10
    // (main's 329467d7 read the pricing page again on 2026-10-29: $0.10, not $0.20);
    // Opus 5.5 $4 in, $20 out, cache read $0.20; cache write 1.25x input.
    // Without their own ladder rows they fell to a prefix or family rate
    // (Sonnet 5.5 read $3 / $15, Opus 5.5 read $15 / $75).
    func test_theCostLinePricesEachModelAtItsOwnRate() {
        XCTAssertEqual(ModelRates.rates(forModelID: FoundryModelIDs.standard),
                       ModelRates.Rates(input: 2.00, output: 10.00, cacheRead: 0.10, cacheWrite: 2.50))
        XCTAssertEqual(ModelRates.rates(forModelID: FoundryModelIDs.highStakes),
                       ModelRates.Rates(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00))
        XCTAssertEqual(ModelRates.rates(forModelID: FoundryModelIDs.vision).input, 1.00)
    }

    // The class guard: no Foundry source names a Claude model except the
    // constant's own file. A comment naming an old id counts too, because a
    // comment that says "pass claude-opus-4-8" is how a stale id comes back.
    func test_noFoundrySourceNamesAModelOutsideTheConstant() throws {
        let foundry = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Foundry")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: foundry, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "FoundryModelIDs.swift" }
        XCTAssertGreaterThan(files.count, 10, "the scan must actually read the Foundry sources")
        let pattern = try NSRegularExpression(pattern: #"claude-(sonnet|opus|haiku|fable)-[0-9]"#)
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, [], "name the model through FoundryModelIDs")
    }
}
