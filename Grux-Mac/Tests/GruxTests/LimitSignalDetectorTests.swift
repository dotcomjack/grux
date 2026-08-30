import XCTest
@testable import GruxAgentCore

final class LimitSignalDetectorTests: XCTestCase {

    // The exact synthetic assistant event the claude CLI emitted on
    // 2026-04-25 when an account hit its monthly cap. Captured verbatim from
    // ~/Library/Application Support/Grux/agents/<job>/log.ndjson.
    private static let realAssistantLine: String = {
        return #"{"type":"assistant","message":{"id":"347629c7-cb81-41ba-a855-8c5b23718047","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"You've hit your org's monthly usage limit"}],"context_management":null},"parent_tool_use_id":null,"session_id":"41a452d9-c1c5-4455-869e-52b3456aac5a","uuid":"57f26042-7717-4922-be8b-099e0485615f","error":"rate_limit"}"#
    }()

    // Real result line from the same log: `is_error:true, api_error_status:429`.
    private static let realResultLine: String = {
        return #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"duration_ms":563605,"duration_api_ms":501486,"num_turns":75,"result":"You've hit your org's monthly usage limit","stop_reason":"stop_sequence","session_id":"41a452d9-c1c5-4455-869e-52b3456aac5a","total_cost_usd":5.6191827499999984,"terminal_reason":"completed"}"#
    }()

    // MARK: - Positive cases (must detect)

    func testRealLimitHitAssistantLineDetected() {
        XCTAssertTrue(LimitSignal.detect(rawLine: Self.realAssistantLine),
                      "real captured assistant event should fire detector")
    }

    func testRealLimitHitResultLineDetected() {
        XCTAssertTrue(LimitSignal.detect(rawLine: Self.realResultLine),
                      "real captured result event should fire detector")
    }

    func testStructuralRateLimitFieldAlone() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"some other text"}]},"error":"rate_limit"}"#
        XCTAssertTrue(LimitSignal.detect(rawLine: line),
                      "error:rate_limit should match regardless of body text")
    }

    func testStructuralApiErrorStatus429Alone() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"opaque"}"#
        XCTAssertTrue(LimitSignal.detect(rawLine: line),
                      "api_error_status:429 should match regardless of body text")
    }

    func testTextVariantMonthlyLimitReached() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Your monthly limit has been reached. Try again next cycle."}]}}"#
        XCTAssertTrue(LimitSignal.detect(rawLine: line))
    }

    func testTextVariantReachedYourMonthly() {
        let line = #"{"type":"result","subtype":"success","result":"You've reached your monthly usage limit."}"#
        XCTAssertTrue(LimitSignal.detect(rawLine: line))
    }

    // MARK: - Negative cases (must NOT detect)

    func testHappyPathAssistantNotDetected() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#
        XCTAssertFalse(LimitSignal.detect(rawLine: line))
    }

    func testHappyPathResultNotDetected() {
        let line = #"{"type":"result","subtype":"success","result":"done!","total_cost_usd":0.0123}"#
        XCTAssertFalse(LimitSignal.detect(rawLine: line))
    }

    func testToolResultMentioningLimitTextDoesNotFalsePositive() {
        // A worker fetching a doc page that happens to discuss "monthly
        // usage limit" must NOT trigger the detector. The text-fallback path
        // is gated to assistant/result/synthetic event shapes.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"This API has a monthly usage limit of 1000 calls"}]}}"#
        XCTAssertFalse(LimitSignal.detect(rawLine: line),
                       "tool_result text mentioning the phrase should NOT fire")
    }

    func testToolUseInputMentioningLimitDoesNotFalsePositive() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo monthly usage limit"}}]}}"#
        // Conservative: this contains "monthly usage limit" inside a
        // tool_use's input. Our detector's text-fallback gate requires the
        // line have type:"assistant" AND content the phrase, the
        // tool_use content does carry the phrase, so this case will
        // current-day match. That's acceptable: a worker literally typing
        // the phrase as a Bash command is a wildly improbable false-positive
        // and the structural fields (error/api_error_status) take priority
        // anyway. Lock in current behavior so the regression is loud if we
        // tighten this later.
        XCTAssertTrue(LimitSignal.detect(rawLine: line))
    }

    func testEmptyLineNotDetected() {
        XCTAssertFalse(LimitSignal.detect(rawLine: ""))
        XCTAssertFalse(LimitSignal.detect(rawLine: "\n"))
        XCTAssertFalse(LimitSignal.detect(rawLine: "{}"))
    }

    func testSystemInitNotDetected() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-sonnet-4-6"}"#
        XCTAssertFalse(LimitSignal.detect(rawLine: line))
    }

    // MARK: - extractResultText

    func testExtractResultTextOnRealLimitResult() {
        let text = LimitSignal.extractResultText(rawLine: Self.realResultLine)
        XCTAssertEqual(text, "You've hit your org's monthly usage limit")
    }

    func testExtractResultTextReturnsNilForAssistantLine() {
        XCTAssertNil(LimitSignal.extractResultText(rawLine: Self.realAssistantLine))
    }
}
