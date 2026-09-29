import XCTest
@testable import Grux

/// An approved item that fails says why, where the person who approved it looks.
///
/// Measured live 2026-09-27: "put lunch with Sarah on my calendar Friday at
/// 1pm" queued `create_event` for approval; approving it failed on a Mac with
/// Calendar access denied, and the item went back to waiting with only the
/// gate's original "Not clearly routine" reason. The failure itself reached
/// wake.log and nothing else, because every approve caller (tray, Jax HQ, the
/// grux_approvals tool) drops the result. Approving again failed the same way,
/// forever, with no reason anywhere a person reads.
@MainActor
final class ApprovalFailureStaysVisibleTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("approval-fail-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("approvals.json")
    }

    /// The exact item the PIM calendar fast path queued live. The suite never
    /// has calendar access (`CalendarService.isUnderTest`), so replaying it
    /// fails the way it does on a Mac where Calendar is denied.
    private var queuedEvent: PendingApproval {
        PendingApproval(action: ProposedAction(kind: .other, summary: "Run tool 'create_event' (unclassified side effect).",
                                               target: "create_event",
                                               detail: ["tool": "create_event", "__replay_tool": "create_event",
                                                        "__replay_input": "{\"start\":\"2026-10-02T13:00:00\",\"title\":\"Lunch with Sarah\"}"]),
                        urgent: false, reason: "Not clearly routine and reversible. Pausing for your call.")
    }

    func test_aFailedApprovalStaysWaitingAndKeepsWhyOnDisk() async throws {
        let url = tempURL()
        let queue = ApprovalQueue(storeURL: url)
        queue.judgeRisk = nil
        let item = queue.enqueue(queuedEvent)

        let result = await queue.approveAndExecute(item.id)
        XCTAssertTrue(result.hasPrefix("error"), result)

        let after = try XCTUnwrap(queue.items.first { $0.id == item.id })
        XCTAssertEqual(after.state, .pending, "a failed approval is still waiting")
        XCTAssertEqual(after.lastFailure, result, "the failure is kept on the item")
        XCTAssertEqual(after.reason, item.reason, "the gate's reason is not overwritten")

        // It survives a relaunch: the file is the queue.
        let reloaded = ApprovalQueue(storeURL: url)
        reloaded.judgeRisk = nil
        XCTAssertEqual(reloaded.items.first { $0.id == item.id }?.lastFailure, result)
    }

    func test_theToolRowCarriesTheFailure() async throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let item = queue.enqueue(queuedEvent)
        let fresh = GruxControlTools.approvalsRow(item, stamp: ISO8601DateFormatter())
        XCTAssertNil(fresh["last_failure"], "nothing failed yet")

        let result = await queue.approveAndExecute(item.id)
        let failed = try XCTUnwrap(queue.items.first { $0.id == item.id })
        let row = GruxControlTools.approvalsRow(failed, stamp: ISO8601DateFormatter())
        XCTAssertEqual(row["last_failure"] as? String, result)
    }

    func test_anOlderFileWithoutTheKeyStillLoads() throws {
        let url = tempURL()
        let legacy = """
        [{"id":"C017EA5A-6BBD-41DF-ABBA-73933836C436","createdAt":"2026-09-27T09:12:33Z","state":"pending",
          "reason":"Not clearly routine and reversible. Pausing for your call.","urgent":false,"persona":"none",
          "action":{"id":"DACD9689-0B96-4B96-9BD4-C2561225CC6A","kind":"other","summary":"Run tool 'create_event'",
                    "target":"create_event","detail":{"tool":"create_event"},"isSpend":false,"isExternalComms":false,
                    "isPublicPost":false,"touchesSecrets":false}}]
        """
        try Data(legacy.utf8).write(to: url)
        let queue = ApprovalQueue(storeURL: url)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertNil(queue.pending.first?.lastFailure)
    }

    // MARK: - Calendar denied is not "open the tab to get the prompt"

    /// macOS never shows the Calendar prompt again once it was declined, so
    /// sending someone to the Calendar tab "to trigger the prompt" sends them
    /// to a screen that cannot help.
    func test_deniedCalendarPointsOnlyAtSystemSettings() {
        let denied = CalendarTool.noAccessMessage(for: .denied)
        XCTAssertTrue(denied.hasPrefix("error: "), denied)
        XCTAssertTrue(denied.contains("System Settings > Privacy & Security > Calendars"), denied)
        XCTAssertFalse(denied.contains("prompt"), denied)

        let unasked = CalendarTool.noAccessMessage(for: .notDetermined)
        XCTAssertTrue(unasked.hasPrefix("error: "), unasked)
        XCTAssertTrue(unasked.contains("Calendar tab"), unasked)
    }
}
