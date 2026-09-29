import XCTest
@testable import Grux

/// Row A30 (found live 2026-09-28): Approvals and `grux approvals` listed a
/// calendar event a person asked for as `Run tool 'create_event' (unclassified
/// side effect).`, the gate's fallback summary. Every knowingly gated tool
/// reaches the queue through that fallback, so every one of them read like a
/// log line. The queue now names what is waiting the way a person would.
@MainActor
final class ApprovalSummaryForPersonTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("approval-summary-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func queue(at dir: URL) -> ApprovalQueue {
        let q = ApprovalQueue(storeURL: dir.appendingPathComponent("approvals.json"))
        q.judgeRisk = nil
        return q
    }

    /// Exactly what `JaxToolGate.resolve` stores for an unclassified tool.
    private func gated(_ tool: String, _ input: [String: Any]) -> ProposedAction {
        var detail = ["tool": tool, "__replay_tool": tool]
        if let json = JaxToolGate.encodeInput(input) { detail["__replay_input"] = json }
        return ProposedAction(kind: .other, summary: "Run tool '\(tool)' (unclassified side effect).",
                              target: tool, detail: detail)
    }

    private static let sampleInput: [String: Any] = [
        "title": "Lunch with Sarah", "name": "focus_mode", "folder": "Clients",
        "document": "Release notes", "command": "ls -la", "command_id": "smoke-hello-world"
    ]

    func test_aCalendarEventIsNamedAsTheEvent() {
        let q = queue(at: tempDir())
        let item = q.enqueue(gated("create_event", ["title": "Lunch with Sarah", "start": "2026-10-02T13:00"]))
        XCTAssertEqual(item.summary, "Add your event \"Lunch with Sarah\" to your calendar.")
        XCTAssertEqual(q.items.first?.summary, item.summary)
    }

    func test_everyKnowinglyGatedToolReadsAsAPersonWouldSayIt() {
        let q = queue(at: tempDir())
        for tool in JaxToolGate.knowinglyGated.sorted() {
            let summary = q.enqueue(gated(tool, Self.sampleInput)).summary
            XCTAssertFalse(summary.contains("Run tool"), "\(tool): \(summary)")
            XCTAssertFalse(summary.contains("unclassified"), "\(tool): \(summary)")
            XCTAssertEqual(ToolReplyCopy.problems(in: summary), [], "\(tool): \(summary)")
            XCTAssertTrue(summary.hasSuffix("."), "\(tool): \(summary)")
        }
    }

    /// Items already waiting from before the fix read the same way once loaded.
    func test_anItemQueuedBeforeTheFixIsRenamedOnLoad() throws {
        let dir = tempDir()
        let old = queue(at: dir)
        var item = PendingApproval(action: gated("create_note", ["title": "Groceries"]))
        item.action.summary = "Run tool 'create_note' (unclassified side effect)."
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode([item]).write(to: old.storeFileURL)

        let fresh = queue(at: dir)
        fresh.load()
        XCTAssertEqual(fresh.items.first?.summary, "Save your note \"Groceries\".")
    }

    /// A summary some other door wrote on purpose is left alone.
    func test_aClassifiedSummaryIsKept() {
        let q = queue(at: tempDir())
        var action = gated("slack_send", ["channel": "#general"])
        action.summary = "Post a Slack message to #general."
        XCTAssertEqual(q.enqueue(action).summary, "Post a Slack message to #general.")
    }
}
