import XCTest
@testable import Grux

/// Ambient memories are filed under the person's existing projects, the last
/// of Phase R's fourteen decision points to reach the engine. P-R-6 recorded
/// them as "not attributed" only because `Ambient/*` was outside that lane.
/// They share `ProjectAttribution.fill` with the decision log, so the two
/// cannot drift apart.
@MainActor
final class MemoryAttributionTests: XCTestCase {

    private let projects = [
        ProjectAttribution.Option(name: "Harbor Bakery Site", description: "tasks already in it: Draft the catering page copy"),
        ProjectAttribution.Option(name: "Trailhead iOS", description: "local project at ~/Projects/trailhead-ios"),
    ]

    private func engine(key: String = "k", _ provider: WorkJudgmentTests.Scripted, ledger: DecisionLedger? = nil) -> DecisionEngine {
        DecisionEngine(keyLookup: { key }, ledger: ledger ?? DecisionLedger(storeURL: nil), remote: { _ in provider })
    }

    func test_keylessMemoriesComeBackUntouched() async {
        let provider = WorkJudgmentTests.Scripted { _ in .choice("Trailhead iOS", confidence: 1, probabilities: [:]) }
        let ledger = DecisionLedger(storeURL: nil)
        let memories = [AmbientMemory(kind: .commitment, text: "ship the offline maps build today")]
        let out = await AmbientMemoryExtractor.attributeProjects(memories, options: projects,
                                                                 engine: engine(key: "", provider, ledger: ledger), threshold: 0.70)
        XCTAssertEqual(out, memories)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0, "a keyless install recorded a decision it never made")
    }

    func test_oneCallFillsOnlyTheBlanks_andNeverInventsAProject() async throws {
        let picks: [String: DecisionAnswer] = [
            "d0": .choice("Trailhead iOS", confidence: 0.94, probabilities: [:]),
            "d2": .choice("Made Up Co", confidence: 0.99, probabilities: [:]),
            "d3": .choice("Harbor Bakery Site", confidence: 0.40, probabilities: [:]),
        ]
        let provider = WorkJudgmentTests.Scripted { picks[$0] }
        let memories = [
            AmbientMemory(kind: .commitment, text: "ship the offline maps build today"),
            AmbientMemory(kind: .intent, text: "rework the menu layout", project: "Bakery"),
            AmbientMemory(kind: .fact, text: "the stand-up moved to ten"),
            AmbientMemory(kind: .intent, text: "maybe redo the catering page"),
        ]
        let out = await AmbientMemoryExtractor.attributeProjects(memories, options: projects, engine: engine(provider), threshold: 0.70)
        XCTAssertEqual(provider.calls.count, 1, "one call per extraction pass")
        XCTAssertEqual(provider.calls.first?.questions.keys.sorted(), ["d0", "d2", "d3"], "a tagged memory was put up for judgment")
        XCTAssertEqual(out.map(\.project), ["Trailhead iOS", "Bakery", nil, nil],
                       "an invented project or a pick under the threshold was filed")
        XCTAssertEqual(out.map(\.text), memories.map(\.text))
        guard case .choice(let instructions, _)? = provider.calls.first?.questions["d0"] else { return XCTFail("no d0") }
        XCTAssertTrue(instructions.hasPrefix("The commitment: ship the offline maps build today."), instructions)
        XCTAssertEqual(provider.calls.first?.state, AmbientMemoryExtractor.memoryAttributionState)
    }

    /// The extractor stores memories only after the pass, so nothing is
    /// written twice and nothing reaches disk untagged when a tag was coming.
    func test_theExtractorStoresMemoriesOnlyAfterTheyAreFiled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Ambient/AmbientMemoryExtractor.swift"), encoding: .utf8)
        let parse = try XCTUnwrap(src.components(separatedBy: "private func parseAndApply(_ raw: String) -> [AmbientMemory] {").dropFirst().first)
        XCTAssertFalse(parse.prefix(3_000).contains("addMemory("), "memories are stored before they are filed")
        XCTAssertTrue(src.contains("for m in filed { ambient.addMemory(m) }"))
    }
}
