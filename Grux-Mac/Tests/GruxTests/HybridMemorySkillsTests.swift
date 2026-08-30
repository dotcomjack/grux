import XCTest
@testable import Grux

// Item 18: hybrid retrieval + SkillStore.
//
// Covers the three pure / isolated pieces so they stay correct without
// needing NLEmbedding or the real Application Support directory:
//   1. KeywordIndex BM25 scoring (term match, tf saturation, idf rarity)
//   2. HybridRetriever reciprocal-rank fusion ordering
//   3. SkillStore JSON round-trip via the injectable file URL seam
@MainActor
final class HybridMemorySkillsTests: XCTestCase {

    // MARK: - BM25

    func test_bm25_ranksTermMatchAboveNonMatch_andHigherTfFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        let index = KeywordIndex(documents: [
            (id: a, text: "the quick brown fox jumps"),
            (id: b, text: "swift package manager build pipeline"),
            (id: c, text: "fox hunting season and fox dens")
        ])

        let hits = index.score(query: "fox", topK: 10)
        XCTAssertEqual(hits.count, 2, "only documents containing 'fox' should score")
        XCTAssertEqual(hits.first?.id, c, "doc with tf=2 must outrank doc with tf=1")
        XCTAssertEqual(hits.last?.id, a)
        XCTAssertFalse(hits.contains { $0.id == b }, "non-matching doc must not appear")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func test_bm25_idfFavorsRareTerms() {
        let docs: [(id: UUID, text: String)] = [
            (id: UUID(), text: "common words everywhere zanzibar"),
            (id: UUID(), text: "common words again"),
            (id: UUID(), text: "common filler text"),
            (id: UUID(), text: "common noise")
        ]
        let index = KeywordIndex(documents: docs)
        XCTAssertGreaterThan(index.idf(term: "zanzibar"), index.idf(term: "common"),
                             "a term in 1 of 4 docs must have higher idf than a term in all 4")
        XCTAssertGreaterThanOrEqual(index.idf(term: "common"), 0, "idf must never go negative")
    }

    func test_bm25_tokenizeSplitsOnNonAlphanumerics() {
        let tokens = KeywordIndex.tokenize("qwen-image-edit-plus, $13 SKU: goat-milk!")
        XCTAssertEqual(tokens, ["qwen", "image", "edit", "plus", "13", "sku", "goat", "milk"])
    }

    func test_bm25_emptyQueryOrEmptyIndexReturnsNothing() {
        let index = KeywordIndex(documents: [(id: UUID(), text: "hello world")])
        XCTAssertTrue(index.score(query: "", topK: 5).isEmpty)
        let empty = KeywordIndex(documents: [])
        XCTAssertTrue(empty.score(query: "hello", topK: 5).isEmpty)
    }

    // MARK: - RRF fusion

    func test_rrf_fusionOrdering_rewardsConsistentRank() {
        // Lane 1: A, B, C. Lane 2: B, C, A.
        // With k=60: B = 1/62 + 1/61, A = 1/61 + 1/63, C = 1/63 + 1/62.
        // Expected order: B, A, C.
        let fused = HybridRetriever.reciprocalRankFusion(lanes: [["A", "B", "C"], ["B", "C", "A"]])
        XCTAssertEqual(fused, ["B", "A", "C"])
    }

    func test_rrf_singleLanePreservesOrder_andUnknownsAppendCorrectly() {
        let fused = HybridRetriever.reciprocalRankFusion(lanes: [["x", "y", "z"], []])
        XCTAssertEqual(fused, ["x", "y", "z"])
    }

    func test_rrf_itemInOneLaneStillSurfaces() {
        // "solo" only appears in lane 2 but at rank 1; it must beat lane 1's
        // deep tail items.
        let lane1 = ["a", "b", "c", "d", "e"]
        let lane2 = ["solo"]
        let fused = HybridRetriever.reciprocalRankFusion(lanes: [lane1, lane2])
        XCTAssertTrue(fused.contains("solo"))
        let soloIdx = fused.firstIndex(of: "solo")!
        let eIdx = fused.firstIndex(of: "e")!
        XCTAssertLessThan(soloIdx, eIdx, "rank-1 single-lane hit must outrank a rank-5 hit from the other lane")
    }

    func test_rrf_deterministicTieBreak() {
        // Identical lanes: ties on score broken by best rank, so input
        // order is preserved and repeated calls agree.
        let first = HybridRetriever.reciprocalRankFusion(lanes: [["p", "q"], ["p", "q"]])
        let second = HybridRetriever.reciprocalRankFusion(lanes: [["p", "q"], ["p", "q"]])
        XCTAssertEqual(first, ["p", "q"])
        XCTAssertEqual(first, second)
    }

    // MARK: - SkillStore round-trip

    private func tempSkillsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-tests-\(UUID().uuidString)-skills.json")
    }

    func test_skillStore_roundTrip() {
        let url = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillStore(fileURL: url)
        store.upsert(name: "weekly-release-notes",
                     trigger: "the user asks for weekly release notes",
                     procedure: "1. Pull merged PRs\n2. Group by area\n3. No em dashes")
        store.upsert(name: "deploy-check",
                     trigger: "before any deploy claim",
                     procedure: "Hit the endpoint, load the page, then say done")
        store.recordUsage(name: "deploy-check")
        store.flush()

        let reloaded = SkillStore(fileURL: url)
        XCTAssertEqual(reloaded.skills.count, 2)

        let notes = reloaded.skill(named: "Weekly-Release-Notes")
        XCTAssertNotNil(notes, "lookup must be case-insensitive")
        XCTAssertEqual(notes?.trigger, "the user asks for weekly release notes")
        XCTAssertTrue(notes?.procedure.contains("Group by area") == true)

        let deploy = reloaded.skill(named: "deploy-check")
        XCTAssertEqual(deploy?.usageCount, 1, "usage count must survive the round-trip")
    }

    func test_skillStore_upsertByNameReplacesNotDuplicates() {
        let url = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillStore(fileURL: url)
        let original = store.upsert(name: "triage", trigger: "old trigger", procedure: "old steps")
        let updated = store.upsert(name: "TRIAGE", trigger: "new trigger", procedure: "new steps")

        XCTAssertEqual(store.skills.count, 1)
        XCTAssertEqual(original.id, updated.id, "upsert must preserve identity")
        XCTAssertEqual(store.skills.first?.trigger, "new trigger")
        XCTAssertEqual(store.skills.first?.procedure, "new steps")
    }

    func test_skillStore_asSystemContext_emitsCompactBlock() {
        let url = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillStore(fileURL: url)
        XCTAssertEqual(store.asSystemContext(), "", "empty store emits no block")

        store.upsert(name: "hot-skill", trigger: "always", procedure: "step one")
        store.upsert(name: "cold-skill", trigger: "rarely", procedure: "step two")
        store.recordUsage(name: "hot-skill")

        let block = store.asSystemContext()
        XCTAssertTrue(block.hasPrefix("LEARNED_SKILLS"))
        XCTAssertTrue(block.contains("hot-skill | when: always"))
        let hotRange = block.range(of: "hot-skill")!
        let coldRange = block.range(of: "cold-skill")!
        XCTAssertLessThan(hotRange.lowerBound, coldRange.lowerBound,
                          "most-used skill must be listed first")
    }

    func test_skillStore_toolDispatch() {
        let url = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillStore(fileURL: url)
        XCTAssertEqual(store.executeTool(name: "list_skills", input: [:]), "(no learned skills yet)")

        let saved = store.executeTool(name: "save_skill", input: [
            "name": "git-style", "trigger": "any commit", "procedure": "conventional commits, named files only"
        ])
        XCTAssertEqual(saved, "ok: saved skill 'git-style'")

        let listed = store.executeTool(name: "list_skills", input: [:]) ?? ""
        XCTAssertTrue(listed.contains("git-style"))
        XCTAssertTrue(listed.contains("conventional commits"))

        XCTAssertNil(store.executeTool(name: "add_task", input: [:]),
                     "unrelated tool names must return nil so ChatService falls through")
    }

    // MARK: - Memory export schema sanity

    func test_memoryExport_codableRoundTrip() throws {
        let payload = GruxMemoryExport(
            schemaVersion: GruxMemoryExport.currentSchemaVersion,
            exportedAt: Date(),
            semanticEntries: [
                .init(kind: "fact", text: "the user ships on Fridays", timestamp: Date(), metadata: ["source": "test"])
            ],
            slang: [.init(term: "bop", meaning: "a great song")],
            facts: ["Bar soap is always a 2-pack"],
            skills: [.init(name: "x", trigger: "y", procedure: "z", usageCount: 3)]
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(payload)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(GruxMemoryExport.self, from: data)
        XCTAssertEqual(back.schemaVersion, 1)
        XCTAssertEqual(back.semanticEntries.first?.text, "the user ships on Fridays")
        XCTAssertEqual(back.slang.first?.term, "bop")
        XCTAssertEqual(back.skills.first?.usageCount, 3)
    }
}
