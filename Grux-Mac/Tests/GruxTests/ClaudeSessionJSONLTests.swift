import XCTest
@testable import Grux

final class ClaudeSessionJSONLTests: XCTestCase {

    // MARK: - parseLine

    func testPermissionModeLineExtractsSessionId() {
        let line = #"{"type":"permission-mode","permissionMode":"auto","sessionId":"abc-123"}"#
        guard case let .permissionMode(sid) = ClaudeSessionJSONL.parseLine(line) else {
            XCTFail("expected .permissionMode entry")
            return
        }
        XCTAssertEqual(sid, "abc-123")
    }

    func testUserEntryWithStringContent() {
        let line = #"{"type":"user","message":{"role":"user","content":"hello world"},"cwd":"/tmp","sessionId":"s1","timestamp":"2026-04-23T05:16:45.497Z","gitBranch":"main"}"#
        guard case let .user(_, text, cwd, branch) = ClaudeSessionJSONL.parseLine(line) else {
            XCTFail("expected .user entry")
            return
        }
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(branch, "main")
    }

    func testUserEntryWithToolResultContent() {
        // When the user entry contains a tool_result array, text field picks up the tool_result string content.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file contents"}]},"sessionId":"s1","timestamp":"2026-04-23T05:00:00Z"}"#
        guard case let .user(_, text, _, _) = ClaudeSessionJSONL.parseLine(line) else {
            XCTFail("expected .user entry")
            return
        }
        XCTAssertEqual(text, "file contents")
    }

    func testAssistantEntryAggregatesUsageAndPickUpTool() {
        let line = """
{"type":"assistant","message":{"model":"claude-opus-4-7","role":"assistant","content":[{"type":"text","text":"sure"},{"type":"tool_use","id":"t1","name":"Read","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200,"cache_creation_input_tokens":10}},"timestamp":"2026-04-23T05:16:50Z","cwd":"/tmp","sessionId":"s1"}
"""
        guard case let .assistant(_, text, toolUseName, usage, model, stopReason, _, _) = ClaudeSessionJSONL.parseLine(line) else {
            XCTFail("expected .assistant entry")
            return
        }
        XCTAssertEqual(text, "sure")
        XCTAssertEqual(toolUseName, "Read")
        XCTAssertEqual(usage, ClaudeSessionUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 200, cacheCreationTokens: 10))
        XCTAssertEqual(model, "claude-opus-4-7")
        XCTAssertEqual(stopReason, "tool_use")
    }

    func testAttachmentLinesAreParsedButFoldedAsNoise() {
        let line = #"{"type":"attachment","attachment":{"type":"hook_success"},"timestamp":"2026-04-23T05:00:00Z","sessionId":"s1"}"#
        if case .attachment = ClaudeSessionJSONL.parseLine(line) {
            // ok
        } else {
            XCTFail("expected .attachment entry")
        }
    }

    func testInvalidJSONLineReturnsNil() {
        XCTAssertNil(ClaudeSessionJSONL.parseLine("not-json"))
        XCTAssertNil(ClaudeSessionJSONL.parseLine(""))
    }

    // MARK: - snapshot folding

    func testSnapshotFoldsSessionWithPendingTool() {
        let lines = [
            #"{"type":"permission-mode","sessionId":"s1","permissionMode":"auto"}"#,
            #"{"type":"user","message":{"role":"user","content":"do thing"},"cwd":"/Users/x/proj","sessionId":"s1","timestamp":"2026-04-23T05:16:45Z","gitBranch":"main"}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[{"type":"text","text":"starting"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-04-23T05:16:50Z","cwd":"/Users/x/proj","sessionId":"s1","gitBranch":"main"}"#
        ]
        let snap = ClaudeSessionJSONL.snapshot(fromLines: lines, sessionId: "s1")
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.sessionId, "s1")
        XCTAssertEqual(snap?.cwd, "/Users/x/proj")
        XCTAssertEqual(snap?.gitBranch, "main")
        XCTAssertEqual(snap?.title, "proj")
        XCTAssertEqual(snap?.currentTool, "Bash")
        XCTAssertEqual(snap?.totalInputTokens, 1000)
        XCTAssertEqual(snap?.totalOutputTokens, 50)
        XCTAssertEqual(snap?.model, "claude-opus-4-8")
        XCTAssertEqual(snap?.lastAssistantSummary, "starting")
        // Opus 4.8 rates: 1000 * 5 / 1e6 = 0.005 ; 50 * 25 / 1e6 = 0.00125
        XCTAssertEqual(snap?.totalCostUSD ?? 0, 0.00625, accuracy: 0.0001)
    }

    func testSnapshotClearsPendingToolAfterEndTurnAssistant() {
        let lines = [
            // Assistant emits tool_use
            #"{"type":"assistant","message":{"model":"claude-opus-4-7","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-04-23T05:16:50Z","cwd":"/p","sessionId":"s1"}"#,
            // User returns tool_result
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"cwd":"/p","sessionId":"s1","timestamp":"2026-04-23T05:16:51Z"}"#,
            // Assistant finalizes
            #"{"type":"assistant","message":{"model":"claude-opus-4-7","role":"assistant","content":[{"type":"text","text":"done!"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-04-23T05:16:52Z","cwd":"/p","sessionId":"s1"}"#
        ]
        let snap = ClaudeSessionJSONL.snapshot(fromLines: lines, sessionId: "s1")
        XCTAssertNotNil(snap)
        XCTAssertNil(snap?.currentTool, "end_turn stop_reason clears pending tool")
        XCTAssertEqual(snap?.lastAssistantSummary, "done!")
    }

    func testSnapshotTitleFallsBackToUserTextWhenNoCwd() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"implement the thing"},"sessionId":"s1","timestamp":"2026-04-23T05:00:00Z"}"#
        ]
        let snap = ClaudeSessionJSONL.snapshot(fromLines: lines, sessionId: "s1")
        XCTAssertEqual(snap?.title, "implement the thing")
    }

    func testSnapshotSummaryTruncatesFirstLineAt120Chars() {
        let long = String(repeating: "x", count: 200)
        let line = """
{"type":"assistant","message":{"model":"claude-haiku-4-5","role":"assistant","content":[{"type":"text","text":"\(long)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-04-23T05:00:00Z","sessionId":"s1"}
"""
        let snap = ClaudeSessionJSONL.snapshot(fromLines: [line], sessionId: "s1")
        XCTAssertEqual(snap?.lastAssistantSummary.count, 120)
        XCTAssertTrue(snap?.lastAssistantSummary.hasSuffix("...") == true)
    }

    func testSnapshotSummaryKeepsOnlyFirstLine() {
        let line = """
{"type":"assistant","message":{"model":"claude-haiku-4-5","role":"assistant","content":[{"type":"text","text":"line one\\nline two\\nline three"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-04-23T05:00:00Z","sessionId":"s1"}
"""
        let snap = ClaudeSessionJSONL.snapshot(fromLines: [line], sessionId: "s1")
        XCTAssertEqual(snap?.lastAssistantSummary, "line one")
    }

    func testSnapshotReturnsNilForNoEvents() {
        XCTAssertNil(ClaudeSessionJSONL.snapshot(fromLines: [], sessionId: "s1"))
    }

    // MARK: - pricing

    func testHaikuPricingMatchesTable() {
        let u = ClaudeSessionUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 0, cacheCreationTokens: 0)
        // Haiku rates: $1/M in + $5/M out = $6
        XCTAssertEqual(ClaudeModelPricing.cost(model: "claude-haiku-4-5", usage: u), 6.0, accuracy: 0.0001)
    }

    func testCacheTokensAreCheaperThanRegularInput() {
        let regular = ClaudeSessionUsage(inputTokens: 100_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        let cached = ClaudeSessionUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 100_000, cacheCreationTokens: 0)
        let reg = ClaudeModelPricing.cost(model: "claude-opus-4-8", usage: regular)
        let cac = ClaudeModelPricing.cost(model: "claude-opus-4-8", usage: cached)
        XCTAssertGreaterThan(reg, cac)
    }

    func testUnknownModelHasZeroCost() {
        let u = ClaudeSessionUsage(inputTokens: 10000, outputTokens: 5000, cacheReadTokens: 0, cacheCreationTokens: 0)
        XCTAssertEqual(ClaudeModelPricing.cost(model: "some-future-model", usage: u), 0, accuracy: 0)
    }

    func testModelPrefixMatches() {
        // "claude-opus-4-8-20251020" should match the opus rate via prefix fallback.
        let u = ClaudeSessionUsage(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        XCTAssertEqual(ClaudeModelPricing.cost(model: "claude-opus-4-8-20251020", usage: u), 5.0, accuracy: 0.0001)
    }
}
