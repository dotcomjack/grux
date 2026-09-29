import XCTest
@testable import Grux

/// A thing Chat said was "pending" reports back in Chat when it is answered.
///
/// Measured live 2026-09-27 (ledger A10): "put lunch with Sarah on my calendar
/// Friday at 1pm" ran the PIM card, then Chat said the event was waiting in
/// the approval queue. Approving it later (tray, Jax HQ or `grux approvals`)
/// ran it or failed, and neither outcome ever reached the Chat thread that
/// said pending: the success lived in wake.log, the failure on the card.
@MainActor
final class ApprovalOutcomeReachesChatTests: XCTestCase {

    private func tempQueue() -> ApprovalQueue {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("approval-chat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = ApprovalQueue(storeURL: dir.appendingPathComponent("approvals.json"))
        queue.judgeRisk = nil
        return queue
    }

    private func item(tool: String, input: String, askedInChat: Bool) -> ProposedAction {
        var detail = ["tool": tool, "__replay_tool": tool, "__replay_input": input]
        if askedInChat { detail[ApprovalQueue.askedInKey] = ApprovalQueue.askedInChat }
        return ProposedAction(kind: .other, summary: "Run tool '\(tool)' (unclassified side effect).",
                              target: tool, detail: detail)
    }

    func test_theGateMarksWhatItAnswersPendingInChat() async throws {
        let shared = ApprovalQueue.shared
        let saved = shared.tellChat
        var told: [String] = []
        shared.tellChat = { told.append($0) }
        defer { shared.tellChat = saved }

        let title = "Loop A10 \(UUID().uuidString.prefix(6))"
        let result = await ChatService.dispatchTool(name: "create_event",
                                                    input: ["title": title, "start": "2026-10-02T13:00:00"])
        XCTAssertTrue(result.hasPrefix("pending"), result)
        let queued = try XCTUnwrap(shared.pending.last { ($0.action.detail["__replay_input"] ?? "").contains(title) })
        XCTAssertEqual(queued.action.detail[ApprovalQueue.askedInKey], ApprovalQueue.askedInChat,
                       "Chat was told pending, so the item says so")
        XCTAssertNil(ApprovalQueue.decodeInput(queued.action.detail["__replay_input"] ?? "")?[ApprovalQueue.askedInKey],
                     "the mark never rides into the replayed tool input")
        shared.skip(queued.id)
        XCTAssertEqual(told.count, 1)
    }

    func test_anApprovedItemThatRanSaysSoInChat() async throws {
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        let queued = queue.enqueue(item(tool: "list_tasks", input: "{}", askedInChat: true))

        let result = await queue.approveAndExecute(queued.id)
        XCTAssertFalse(result.hasPrefix("error"), result)
        XCTAssertEqual(told.count, 1)
        let line = try XCTUnwrap(told.first)
        XCTAssertTrue(line.hasPrefix("Approved and done."), line)
        XCTAssertTrue(line.contains(ToolReplyCopy.forPerson(tool: "list_tasks", input: [:], result: result)),
                      "the chat line carries what the tool answered, in the person's words")
        XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
    }

    func test_anApprovedItemThatFailedSaysWhyInChat() async throws {
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        // The suite never has calendar access, so this fails the way it does
        // on a Mac where Calendar is denied.
        let queued = queue.enqueue(item(tool: "create_event",
                                        input: "{\"start\":\"2026-10-02T13:00:00\",\"title\":\"Lunch with Sarah\"}",
                                        askedInChat: true))

        let result = await queue.approveAndExecute(queued.id)
        XCTAssertTrue(result.hasPrefix("error"), result)
        let line = try XCTUnwrap(told.first)
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(line.hasPrefix("Approved, but it did not go through."), line)
        XCTAssertTrue(line.contains(ToolReplyCopy.forPerson(tool: "create_event", input: [:], result: result)), line)
        XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        XCTAssertTrue(line.contains("still waiting"), "the item went back to waiting and the line says so")
    }

    func test_aSkippedItemSaysNothingRan() {
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        let queued = queue.enqueue(item(tool: "create_note", input: "{\"title\":\"x\"}", askedInChat: true))

        queue.skip(queued.id)
        XCTAssertEqual(told, ["Skipped your note \"x\" in Approvals. Nothing was run."])
        queue.skip(queued.id)
        XCTAssertEqual(told.count, 1, "an item already resolved is not reported twice")
    }

    func test_anItemChatNeverSawStaysOutOfChat() async {
        // A spoken command that asked first was never announced in Chat.
        let queue = tempQueue()
        var told: [String] = []
        queue.tellChat = { told.append($0) }
        let approved = queue.enqueue(item(tool: "list_tasks", input: "{}", askedInChat: false))
        let skipped = queue.enqueue(item(tool: "list_tasks", input: "{}", askedInChat: false))

        _ = await queue.approveAndExecute(approved.id)
        queue.skip(skipped.id)
        XCTAssertEqual(told, [])
    }
}
