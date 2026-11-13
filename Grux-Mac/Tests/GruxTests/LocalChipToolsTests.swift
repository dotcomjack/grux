import XCTest
@testable import Grux

/// The starter chips on Grux Local, and the task tools a model may not use unasked.
///
/// Measured 2026-11-12 on the Mac mini, Grux Local 2b, real chat turns: every chip ask got
/// the same 15 tools as "write a list", none of them a recovery tool, because a lean local
/// turn sent its stable core list whatever the words said. And "write a list" called
/// complete_task three times on the person's real tasks, which ran with no approval.
@MainActor
final class LocalChipToolsTests: XCTestCase {
    private var savedChat: [ChatMessage] = []
    private var savedTasks: [FocusTask] = []
    private var queuedBefore: Set<UUID> = []

    override func setUp() async throws {
        savedChat = AppState.shared.chat
        savedTasks = AppState.shared.tasks
        queuedBefore = Set(ApprovalQueue.shared.pending.map(\.id))
        RecentToolUse.shared.clear()
    }

    override func tearDown() async throws {
        for item in ApprovalQueue.shared.pending where !queuedBefore.contains(item.id) {
            ApprovalQueue.shared.skip(item.id)
        }
        AppState.shared.chat = savedChat
        AppState.shared.tasks = savedTasks
        RecentToolUse.shared.clear()
    }

    private func leanTools(_ ask: String) -> [String] {
        AppState.shared.chat = [ChatMessage(role: .user, content: ask)]
        return ChatService.shared.assemblePendingContext(state: AppState.shared, lean: true, window: 16_384)
            .tools.map(\.name)
    }

    // MARK: - The chips reach a local model

    /// Each chip's ask, as ChatStarterChips writes it, carries the tools that answer it.
    func test_eachChipAskCarriesItsToolsOnALocalTurn() {
        let cases: [(String, [String])] = [
            ("Undo `rm notes.txt` from 5:00 PM", [ShellRecoveryTools.listTool, ShellRecoveryTools.restoreTool]),
            ("Why did you refuse `afplay /tmp/x.aiff`?", [ShellRecoveryTools.auditTool]),
            ("What did you run today? (3 commands)", [ShellRecoveryTools.auditTool]),
        ]
        for (ask, needed) in cases {
            let names = leanTools(ask)
            for tool in needed { XCTAssertTrue(names.contains(tool), "\(ask): \(names)") }
        }
    }

    /// They take slots, they do not add them: a chip turn sends no more tools than an
    /// ordinary turn, and an ordinary turn still sends none of them.
    func test_theChipToolsDisplaceCoreToolsAndNeverGrowTheList() {
        let ordinary = leanTools("write a list")
        XCTAssertFalse(ordinary.contains { ShellRecoveryTools.names.contains($0) }, "\(ordinary)")
        for ask in ["Undo `rm notes.txt` from 5:00 PM", "Why did you refuse `afplay /tmp/x.aiff`?",
                    "What did you run today? (3 commands)"] {
            XCTAssertLessThanOrEqual(leanTools(ask).count, ordinary.count, ask)
        }
        // The undo chip needs no audit log, and the log chips restore nothing.
        XCTAssertFalse(leanTools("What did you run today? (3 commands)").contains(ShellRecoveryTools.restoreTool))
    }

    /// Only the chip SHAPES do it, so a bare "undo" or "today" keeps the stable list.
    func test_wordsThatAreNotAChipKeepTheOrdinaryList() {
        for ask in ["undo that paste", "what did I do today", "why did you say that"] {
            XCTAssertEqual(ToolRelevance.chipTools(for: ask), [], ask)
        }
    }

    // MARK: - A model's task change waits in Approvals

    private func addTask(_ title: String) -> UUID {
        let task = AppState.shared.addTask(title, project: "", priority: .next)
        return task!.id
    }

    /// THE GATE. The call a local "write a list" turn made, through the real chat door:
    /// nothing changes until the person says yes in Approvals, and then it does.
    func test_aModelsCompleteTaskWaitsForApproval() async throws {
        let title = "Gate probe water the ferns"
        let id = addTask(title)
        let r = await ChatService.dispatchTool(name: "complete_task", input: ["match": "water the ferns"])
        XCTAssertTrue(r.hasPrefix("pending:"), r)
        XCTAssertEqual(AppState.shared.tasks.first { $0.id == id }?.completed, false, "the task changed before a yes")
        let card = try XCTUnwrap(ApprovalQueue.shared.pending.first {
            !queuedBefore.contains($0.id) && $0.action.detail["__replay_tool"] == "complete_task" })
        XCTAssertEqual(ToolReplyCopy.approvalSummary(tool: "complete_task", input: ["match": "water the ferns"]),
                       "Check off your task \"water the ferns\".")
        _ = await ApprovalQueue.shared.approveAndExecute(card.id)
        XCTAssertEqual(AppState.shared.tasks.first { $0.id == id }?.completed, true, "the yes did not run it")
    }

    /// Every task and action mutation a model can call waits the same way.
    func test_everyTaskMutationWaits() async {
        _ = addTask("Gate probe label the cables")
        let before = AppState.shared.tasks
        for (tool, input) in [("add_task", ["title": "Gate probe new task"]),
                              ("remove_task", ["match": "label the cables"]),
                              ("focus_on_task", ["match": "label the cables"]),
                              ("promote_action", ["match": "anything"]),
                              ("dismiss_action", ["match": "anything"])] as [(String, [String: Any])] {
            let r = await ChatService.dispatchTool(name: tool, input: input)
            XCTAssertTrue(r.hasPrefix("pending:"), "\(tool): \(r)")
            XCTAssertNotNil(ToolReplyCopy.approvalSummary(tool: tool, input: input), tool)
        }
        XCTAssertEqual(AppState.shared.tasks.map(\.id), before.map(\.id), "a task appeared or went before a yes")
    }

    /// The person's own "add a task: X" still runs at once: its card is the confirmation.
    func test_thePersonsOwnTaskCommandStillRunsAtOnce() async {
        let r = await PIMConfirmationController.dispatch(name: "add_task", input: ["title": "Gate probe asked by the person"],
                                                         personAsked: true)
        XCTAssertTrue(r.hasPrefix("ok:"), r)
        XCTAssertTrue(AppState.shared.tasks.contains { $0.title == "Gate probe asked by the person" })
    }
}
