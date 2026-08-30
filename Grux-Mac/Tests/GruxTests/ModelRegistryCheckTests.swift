import XCTest
@testable import Grux

/// The check that stops the cookbook going stale, and the ways it could lie.
///
/// A staleness checker has one failure mode that matters more than the rest:
/// reporting "up to date" when it actually failed. That answer looks like success,
/// nobody investigates it, and the catalog rots exactly as it did before the check
/// existed. So the network path throws on every ambiguity rather than returning an
/// empty result, and the tests below exist mostly to prove it cannot go quiet.
final class ModelRegistryCheckTests: XCTestCase {

    // MARK: - Parsing

    func testParsesFamiliesFromLibraryHrefs() {
        let html = """
        <a href="/library/gemma4">Gemma 4</a>
        <a href="/library/qwen3.5">Qwen</a>
        <a href="/library/gemma4">Gemma 4 again</a>
        <a href="/other/thing">not a model</a>
        <a href="/library/gpt-oss">GPT OSS</a>
        """
        XCTAssertEqual(ModelRegistryCheck.parseLibrary(html),
                       ["gemma4", "qwen3.5", "gpt-oss"],
                       "first seen order, deduplicated, and nothing outside /library/")
    }

    func testParsingEmptyPageYieldsNothingRatherThanCrashing() {
        XCTAssertTrue(ModelRegistryCheck.parseLibrary("").isEmpty)
        XCTAssertTrue(ModelRegistryCheck.parseLibrary("<html><body>nope</body></html>").isEmpty)
    }

    // MARK: - Family extraction

    func testFamilyStripsTheTag() {
        XCTAssertEqual(ModelRegistryCheck.family(of: "qwen3.5:27b"), "qwen3.5")
        XCTAssertEqual(ModelRegistryCheck.family(of: "gpt-oss:120b"), "gpt-oss")
        XCTAssertEqual(ModelRegistryCheck.family(of: "mistral"), "mistral",
                       "a bare id with no colon is already the family")
    }

    // MARK: - Comparison

    private func model(_ id: String) -> CookbookModel {
        CookbookModel(id: id, displayName: "x", parameterLabel: "0B",
                      diskGB: 1, estimatedMemoryGB: 1, contextTokens: 1,
                      strengths: "x", supportsTools: true)
    }

    func testVersionSplitting() {
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("qwen3.5")?.base, "qwen")
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("qwen3.5")?.version, [3, 5])
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("gemma4")?.version, [4])
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("llama3.3")?.version, [3, 3])
        // The suffix rejoins the base so a coder model is never called an upgrade
        // of a chat model of the same generation.
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("qwen3-coder")?.base, "qwen-coder")
        XCTAssertEqual(ModelRegistryCheck.baseAndVersion("qwen3-vl")?.base, "qwen-vl")
        // Unversioned names are simply out of scope for this check.
        XCTAssertNil(ModelRegistryCheck.baseAndVersion("gpt-oss"))
        XCTAssertNil(ModelRegistryCheck.baseAndVersion("mistral"))
    }

    func testVersionOrdering() {
        XCTAssertTrue(ModelRegistryCheck.isNewer([3, 6], than: [3, 5]))
        XCTAssertTrue(ModelRegistryCheck.isNewer([4], than: [3, 9]))
        XCTAssertTrue(ModelRegistryCheck.isNewer([3, 5], than: [3]), "3.5 beats a bare 3")
        XCTAssertFalse(ModelRegistryCheck.isNewer([3], than: [3, 5]))
        XCTAssertFalse(ModelRegistryCheck.isNewer([3, 5], than: [3, 5]), "equal is not newer")
    }

    /// The exact situation that started this: the catalog on gemma3 and qwen3 while
    /// the registry had moved on.
    func testFindsTheUpgradeThatWasActuallyMissed() {
        let r = ModelRegistryCheck.compare(
            registry: ["gemma2", "gemma3", "gemma4", "qwen3", "qwen3.5", "qwen3.6"],
            catalog: [model("gemma3:12b"), model("qwen3:14b")])
        XCTAssertTrue(r.isStale)
        XCTAssertEqual(r.upgrades, [
            ModelRegistryCheck.Upgrade(have: "gemma3", newer: ["gemma4"]),
            ModelRegistryCheck.Upgrade(have: "qwen3", newer: ["qwen3.5", "qwen3.6"]),
        ])
    }

    /// THE FAILURE THAT SHIPPED FIRST. Asking "what is in the registry that we do
    /// not list" returned 211 families, nearly all of them OLDER models the catalog
    /// omits on purpose. An older release must never be reported as an upgrade.
    func testOlderFamiliesAreNeverReported() {
        let r = ModelRegistryCheck.compare(
            registry: ["llama2", "llama3", "llama3.1", "llama3.2", "llama3.3",
                       "gemma", "gemma2", "gemma3", "qwen", "qwen2", "qwen2.5", "qwen3"],
            catalog: [model("llama3.3:70b"), model("qwen3.6:27b"), model("gemma4:12b")])
        XCTAssertFalse(r.isStale,
            "reported \(r.upgrades) as upgrades, but every one of them is older")
    }

    /// A coder or vision variant is a different product, not a newer generation.
    func testAVariantIsNotAnUpgradeOfTheBaseModel() {
        let r = ModelRegistryCheck.compare(
            registry: ["qwen4", "qwen4-coder"],
            catalog: [model("qwen3-coder:30b")])
        XCTAssertEqual(r.upgrades, [ModelRegistryCheck.Upgrade(have: "qwen3-coder",
                                                              newer: ["qwen4-coder"])],
                       "plain qwen4 is not an upgrade of qwen3-coder")
    }

    func testUnversionedCatalogEntriesAreSilentlySkipped() {
        let r = ModelRegistryCheck.compare(registry: ["mistral", "gpt-oss"],
                                           catalog: [model("gpt-oss:20b")])
        XCTAssertFalse(r.isStale)
        XCTAssertEqual(r.registryCount, 2)
    }

    // MARK: - The shipping catalog

    /// Not a staleness assertion. The catalog WILL fall behind, that is the whole
    /// premise. This asserts the two are comparable at all: every catalog id must
    /// yield a family, or the check silently compares nothing and reports clean.
    func testEveryCatalogIDYieldsAUsableFamily() {
        XCTAssertFalse(Cookbook.catalog.isEmpty)
        for m in Cookbook.catalog {
            let f = ModelRegistryCheck.family(of: m.id)
            XCTAssertFalse(f.isEmpty, "\(m.id) produced an empty family")
            XCTAssertFalse(f.contains(":"), "\(m.id) family still carries a tag: \(f)")
        }
    }

    // MARK: - The live page

    /// Runs against the REAL library page, because a parser proved only against a
    /// fixture I wrote myself proves that I can write a fixture. The page shape is
    /// the thing that will change, and this is the only test that can notice.
    ///
    /// Skipped rather than failed without a network, since a checker that fails the
    /// suite on an aeroplane teaches people to ignore it.
    func testParserWorksAgainstTheRealLibraryPage() async throws {
        let url = ModelRegistryCheck.libraryURL
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw XCTSkip("no network: \(error.localizedDescription)")
        }
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        let families = ModelRegistryCheck.parseLibrary(html)
        XCTAssertGreaterThan(families.count, 50,
            "parsed only \(families.count) families from the live page. Ollama lists "
            + "hundreds, so the page shape has changed and the parser is reading nothing.")
        // A model everybody has heard of, as a canary that we parsed names and not
        // some other href that happens to sit under /library/.
        XCTAssertTrue(families.contains("llama3.1") || families.contains("mistral"),
                      "parsed \(families.count) names and not one recognisable model")
    }
}
