import XCTest
@testable import Grux

/// D180 item 2: a local draft or list turn starts the reply for the model
/// ("Hi Sam,", "Here is a packing list for the beach:"), and the model writes
/// on. When the continuation came back empty, the reply was only that start.
/// The hop is asked once more without it, so the person gets the model's own
/// answer instead of a greeting with nothing after it.
final class PrefillOnlyReplyTests: XCTestCase {
    private func turn(_ start: String) -> [[String: Any]] {
        [["role": "user", "content": "Write a packing list for the beach"],
         ["role": "assistant", "content": start, DraftAsk.prefillKey: true]]
    }

    func testOnlyTheStartIsAnEmptyContinuation() {
        let start = "Here is a packing list for the beach:"
        XCTAssertTrue(ChatService.onlyPrefilledStart(start, messages: turn(start)))
        XCTAssertTrue(ChatService.onlyPrefilledStart(start + "\n\n", messages: turn(start)))
        XCTAssertTrue(ChatService.onlyPrefilledStart("Hi [Name], ", messages: turn("Hi [Name],")))
    }

    func testAnythingWrittenAfterTheStartIsAReply() {
        let start = "Hi Sam,"
        XCTAssertFalse(ChatService.onlyPrefilledStart(start + " thanks for lunch.", messages: turn(start)))
        XCTAssertFalse(ChatService.onlyPrefilledStart(start + "\n-", messages: turn(start)))
    }

    /// No prefill on the turn (a cloud model, or a later hop after a tool):
    /// never retried, whatever the text.
    func testWithoutAPrefillNothingIsRetried() {
        let plain: [[String: Any]] = [["role": "user", "content": "Hi"]]
        XCTAssertFalse(ChatService.onlyPrefilledStart("", messages: plain))
        XCTAssertFalse(ChatService.onlyPrefilledStart("Hi Sam,", messages: plain))
        var afterTool = turn("Hi Sam,")
        afterTool.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": "1", "content": "ok"]]])
        XCTAssertFalse(ChatService.onlyPrefilledStart("Hi Sam,", messages: afterTool))
        // An empty start is not a start.
        XCTAssertFalse(ChatService.onlyPrefilledStart("", messages: turn("")))
    }

    /// The hop loop asks again once, without the start, before the empty hop
    /// joins the reply.
    func testTheHopLoopAsksAgainWithoutTheStartOnce() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let check = try XCTUnwrap(src.range(of: "if toolUses.isEmpty, !askedWithoutStart, Self.onlyPrefilledStart(hopText, messages: messages)"))
        let joins = try XCTUnwrap(src.range(of: "finalTextFromAllHops += (finalTextFromAllHops.isEmpty"))
        XCTAssertTrue(check.lowerBound < joins.lowerBound)
        let tail = String(src[check.lowerBound...].prefix(1200))
        XCTAssertTrue(tail.contains("askedWithoutStart = true"), tail)
        XCTAssertTrue(tail.contains("DraftAsk.withoutPrefill(messages)"), tail)
        XCTAssertTrue(tail.contains("continue hopLoop"), tail)
    }
}
