import XCTest
@testable import Grux

// Pin the wire shape of ChatService.composeSystemBlocks. Anthropic's
// automatic lookback only works when the breakpoint structure stays
// consistent across calls, these tests catch any accidental reshuffle
// (extra block, missing cache_control, wrong ordering) that would silently
// destroy the cache hit rate.
final class ChatServiceSystemBlocksTests: XCTestCase {

    // MARK: - Block count

    func test_emitsTwoBlocks_whenSummaryIsNil() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "stable persona text",
            summary: nil,
            volatile: "volatile turn text"
        )
        XCTAssertEqual(blocks.count, 2)
    }

    func test_emitsTwoBlocks_whenSummaryIsEmpty() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "stable persona text",
            summary: "",
            volatile: "volatile turn text"
        )
        XCTAssertEqual(blocks.count, 2, "empty-string summary must collapse to 2 blocks, not emit a zero-token cache breakpoint")
    }

    func test_emitsThreeBlocks_whenSummaryIsPresent() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "stable",
            summary: "rolling summary content",
            volatile: "volatile"
        )
        XCTAssertEqual(blocks.count, 3)
    }

    // MARK: - Ordering

    func test_orderingIsStableSummaryVolatile() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "STABLE_HERE",
            summary: "SUMMARY_HERE",
            volatile: "VOLATILE_HERE"
        )
        XCTAssertEqual(blocks[0]["text"] as? String, "STABLE_HERE")
        XCTAssertEqual(blocks[1]["text"] as? String, "SUMMARY_HERE")
        XCTAssertEqual(blocks[2]["text"] as? String, "VOLATILE_HERE")
    }

    func test_orderingIsStableVolatile_whenNoSummary() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "STABLE_HERE",
            summary: nil,
            volatile: "VOLATILE_HERE"
        )
        XCTAssertEqual(blocks[0]["text"] as? String, "STABLE_HERE")
        XCTAssertEqual(blocks[1]["text"] as? String, "VOLATILE_HERE")
    }

    // MARK: - Cache control placement

    func test_stableBlockAlwaysCached() {
        let withSummary = ChatService.composeSystemBlocks(stable: "s", summary: "x", volatile: "v")
        let withoutSummary = ChatService.composeSystemBlocks(stable: "s", summary: nil, volatile: "v")
        XCTAssertNotNil(withSummary[0]["cache_control"])
        XCTAssertNotNil(withoutSummary[0]["cache_control"])
    }

    func test_summaryBlockCached_whenPresent() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "s",
            summary: "rolling summary",
            volatile: "v"
        )
        XCTAssertNotNil(blocks[1]["cache_control"], "summary block must carry cache_control so the cached prefix extends to include it")
    }

    func test_volatileBlockNeverCached() {
        let withSummary = ChatService.composeSystemBlocks(stable: "s", summary: "x", volatile: "v")
        let withoutSummary = ChatService.composeSystemBlocks(stable: "s", summary: nil, volatile: "v")
        XCTAssertNil(withSummary.last?["cache_control"], "volatile block must NOT be cached (it changes every turn)")
        XCTAssertNil(withoutSummary.last?["cache_control"], "volatile block must NOT be cached (it changes every turn)")
    }

    // MARK: - cache_control payload shape

    func test_cacheControlIsEphemeral() {
        let blocks = ChatService.composeSystemBlocks(
            stable: "s",
            summary: "sum",
            volatile: "v"
        )
        let stableCC = blocks[0]["cache_control"] as? [String: String]
        XCTAssertEqual(stableCC?["type"], "ephemeral")
        let summaryCC = blocks[1]["cache_control"] as? [String: String]
        XCTAssertEqual(summaryCC?["type"], "ephemeral")
    }

    // MARK: - Block content

    func test_summaryContent_isPassedThrough() {
        let summary = "The user agreed to ship by Friday. Open thread on the Stripe webhook."
        let blocks = ChatService.composeSystemBlocks(
            stable: "stable",
            summary: summary,
            volatile: "volatile"
        )
        XCTAssertEqual(blocks[1]["text"] as? String, summary)
    }

    // MARK: - Breakpoint count (Anthropic limit is 4 across system+tools+messages)

    func test_doesNotExceedFourCacheBreakpoints() {
        // 2 cache_control markers in the worst case (stable + summary). Tools
        // and messages may add more, so leave headroom.
        let blocks = ChatService.composeSystemBlocks(
            stable: "s",
            summary: "x",
            volatile: "v"
        )
        let cacheCount = blocks.filter { $0["cache_control"] != nil }.count
        XCTAssertLessThanOrEqual(cacheCount, 2, "stable+summary breakpoints must fit inside the 4-breakpoint API limit with room for tool/message caches")
    }

    // MARK: - Assistant text dash guard (zero em/en dash house rule)

    // ChatService now runs every assistant reply through DashSanitizer before it
    // is stored + shown (send()'s streamed final text and the deterministic
    // short-circuit replies). This pins the helper's contract on the exact live
    // failure: an em dash slipped past the persona prompt into a rendered reply.
    func test_dashSanitizer_stripsEmAndEnDashesFromAssistantText_keepsHyphens() {
        // The literal reply observed live 2026-07-18, plus an en-dash case and a
        // legitimate hyphen that MUST survive.
        let dirty = "break containment\u{2014}injection attack, range 5\u{2013}9, cruelty-free"
        let clean = DashSanitizer.clean(dirty)
        XCTAssertFalse(clean.contains("\u{2014}"), "em dash (U+2014) must not survive in assistant text")
        XCTAssertFalse(clean.contains("\u{2013}"), "en dash (U+2013) must not survive in assistant text")
        XCTAssertTrue(clean.contains("cruelty-free"), "ASCII hyphen must survive (cruelty-free)")
        XCTAssertTrue(clean.contains("-"), "ASCII hyphen-minus must be left untouched")
    }
}
