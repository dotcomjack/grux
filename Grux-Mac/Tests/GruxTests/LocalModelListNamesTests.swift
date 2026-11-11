import XCTest
@testable import Grux

/// D130: Settings, Models read "found 7 local models" over a list naming
/// grux-local:2b twice, once as the raw pull tag gruxai.com/grux/grux-local:2b.
/// Ollama lists every name a model was pulled or copied under, and Grux printed
/// the names. A person reads one entry per model, by the name the Cookbook uses.
final class LocalModelListNamesTests: XCTestCase {

    // This Mini's /api/tags on 2026-11-02, names and digests in Ollama's order.
    private let mini: [(String, String)] = [
        ("gruxai.com/grux/grux-local:2b", "601cd23c66ef"),
        ("grux-local:9b", "357e4bd45ff0"),
        ("grux-local:latest", "1de6472396f2"),
        ("grux-local:4b", "1de6472396f2"),
        ("grux-local:2b", "601cd23c66ef"),
        ("qwen3.5:4b", "7f3251fa6878"),
        ("llama3.2:3b", "a80c4f17acd5"),
    ]
    private var tags: [String] { mini.map(\.0) }
    private var digests: [String: String] { Dictionary(uniqueKeysWithValues: mini) }

    func test_oneNamePerModelPreferringTheCatalogName() {
        XCTAssertEqual(Cookbook.shownLocalModels(tags, digests: digests, configured: "qwen3.5:4b"),
                       ["gruxai.com/grux/grux-local:2b", "grux-local:9b", "grux-local:4b",
                        "qwen3.5:4b", "llama3.2:3b"])
    }

    /// The configured name wins its group, so the picker's selection is one of
    /// its own rows and never added a second time.
    func test_theConfiguredNameStandsForItsModel() {
        XCTAssertEqual(Cookbook.shownLocalModels(tags, digests: digests, configured: "grux-local:2b").first,
                       "grux-local:2b")
        XCTAssertEqual(Cookbook.shownLocalModels(tags, digests: digests, configured: "GRUX-LOCAL:LATEST").dropFirst(2).first,
                       "grux-local:latest")
    }

    /// A server that lists no digests (an OpenAI-compatible one) keeps every name once.
    func test_noDigestsKeepsEveryNameOnce() {
        XCTAssertEqual(Cookbook.shownLocalModels(["a", "b", "a"], digests: [:], configured: ""), ["a", "b"])
        XCTAssertEqual(Cookbook.shownLocalModels([], digests: [:], configured: "x"), [])
    }

    func test_theFoundLineCountsModelsNotNames() {
        XCTAssertEqual(ModelRegistry.ollamaStatus(tags: tags, digests: digests), "found 5 local models")
        XCTAssertEqual(ModelRegistry.ollamaStatus(tags: ["grux-local:latest", "grux-local:4b"],
                                                  digests: ["grux-local:latest": "d", "grux-local:4b": "d"]),
                       "found 1 local model")
        XCTAssertEqual(ModelRegistry.ollamaStatus(tags: [], digests: [:]),
                       "local server reachable, no models installed")
    }

    func test_theListReadsByThePersonName() {
        let shown = Cookbook.shownLocalModels(tags, digests: digests, configured: "qwen3.5:4b")
        XCTAssertEqual(shown.map(Cookbook.personName(for:)).first, "Grux Local 2B")
    }

    /// The class guard: nothing outside the registry reads `localTags` beyond
    /// asking whether it is empty; a list a person sees comes from
    /// `shownLocalModels`, read through `personName`. Wave 37: Compare built its
    /// chips in a plain `for` loop over `localTags` (seven chips on this Mini,
    /// grux-local:2b twice, all selected), which a guard on `Text(`/`ForEach(`
    /// lines missed. CostMeter's read is a price lookup nobody sees (the chat
    /// footer's "cheaper:" nudge is gone, ChatView "WAS:" note).
    func test_noViewRendersRawLocalTags() throws {
        let allowed: Set<String> = ["Backend/ModelRegistry.swift", "Pricing/CostMeter.swift"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let src = try String(contentsOf: url, encoding: .utf8)
            guard !allowed.contains(rel) else { continue }
            for line in src.components(separatedBy: "\n")
            where line.contains("localTags")
                && line.replacingOccurrences(of: "localTags.isEmpty", with: "").contains("localTags") {
                offenders.append("\(rel): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "show Cookbook.shownLocalModels through Cookbook.personName")
    }
}
