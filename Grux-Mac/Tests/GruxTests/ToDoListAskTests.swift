import XCTest
@testable import Grux

/// D180 item 1, live 8:19 AM Nov 6: with the task card gone, "Make a to-do list
/// for the weekend" reached grux-local:2b, which tried add_task with the whole
/// ask as the task (not offered: the "list" word ranked every list_* tool above
/// it) and answered "You'll need to use one of the available functions like
/// `add_task`". An ask to start a list with nothing on it is answered by Grux:
/// what goes on it, in the shape Grux adds at once.
@MainActor
final class ToDoListAskTests: XCTestCase {
    func testTheBareAskMatchesAndNothingElse() {
        for text in ["Make a to-do list for the weekend", "make a todo list", "Create a task list for Saturday.",
                     "Can you make me a to do list for the week?", "Start a new to-do list", "Grux, make a to-do list",
                     "please make a todo list for my trip", "Make a to-do list for Saturday", "make a todo list for Monday morning"] {
            XCTAssertTrue(ToDoListAsk.matches(text), text)
        }
        for text in ["Make a to-do list: milk, eggs, call Mom", "Make a to-do list for the weekend with laundry and groceries",
                     "Make a packing list for Chicago", "add milk to my to-do list", "What's on my to-do list?",
                     "Show me my task list", "make a to-do for the laundry", "Make a to-do list and add it to my calendar",
                     "Make a to-do list for the weekend. Also what's the weather?",
                     // W59-FIX P3: a list somewhere else is not Grux's task list.
                     "Make a to-do list for my team in Notion", "Make a to-do list for us on Trello",
                     "Make a to-do list for Notion", "make a to-do list for my Notion", "Make a to-do list for Apple Reminders"] {
            XCTAssertFalse(ToDoListAsk.matches(text), text)
        }
    }

    func testTheReplyAsksWhatGoesOnItInAShapeGruxAdds() throws {
        let r = ToDoListAsk.reply
        XCTAssertTrue(r.contains("What should go on it?"), r)
        // The example it gives is one Grux adds with no model.
        let example = try XCTUnwrap(r.range(of: #"(?<=\x{201C})add [^\x{201D}]+(?=\x{201D})"#, options: .regularExpression))
        let plan = try XCTUnwrap(PIMIntents.plan(for: String(r[example])), String(r[example]))
        XCTAssertEqual(plan.kind, .addTask)
        XCTAssertFalse(plan.isJudged)
    }

    /// "to-do" is a task word when tools are ranked, so a list with its items
    /// on a local turn is offered add_task (live it was not among the 10).
    func testAToDoListRanksTheTaskTools() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        for ask in ["Make a to-do list: milk, eggs, call Mom", "Make a to-do list for the weekend"] {
            state.chat = [ChatMessage(role: .user, content: ask)]
            let p = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 16_384)
            XCTAssertTrue(p.tools.map(\.name).contains("add_task"), "\(ask): \(p.tools.map(\.name))")
        }
        let ranked = LocalTurn.rank(ChatService.allTools(), utterance: "Make a to-do list: milk, eggs").map(\.name)
        XCTAssertLessThan(ranked.firstIndex(of: "add_task") ?? .max, ranked.firstIndex(of: "list_meetings") ?? .max)
    }

    /// Order in send(): before the readiness guard, so it answers with no model.
    func testTheRouteSitsBeforeTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let route = try XCTUnwrap(src.range(of: "ToDoListAsk.matches(trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(route.lowerBound < readiness.lowerBound)
    }

    /// W59-P3: a place after "to", a person's own day ("Mom's birthday") and a
    /// holiday name of two words are not somewhere else; an app named after
    /// "for", or after a possessive, still is.
    func testPlacesPeopleAndHolidaysAreWhatTheListIsFor() {
        for text in ["Make a to-do list for my trip to Paris", "Make a to-do list for Mom's birthday",
                     "Make a to-do list for Christmas Eve", "Make a to-do list for moving to New York",
                     "Make a to-do list for New Year's Eve", "Create a task list for Sarah's wedding"] {
            XCTAssertTrue(ToDoListAsk.matches(text), text)
        }
        for text in ["Make a to-do list for Notion", "Make a to-do list for Apple Reminders",
                     "Make a to-do list for Apple's Reminders", "Make a to-do list for Things",
                     "Create a task list for Trello", "make a to-do list for my Notion",
                     "Make a to-do list for Jira's board", "Make a to-do list for the team's workspace",
                     // W60-FIX P2: an app after "to" or before a possessive.
                     "Make a to-do list for syncing to Notion", "Make a task list for exporting to Todoist",
                     "Make a to-do list for Notion's inbox", "Create a task list for Asana's project tracker"] {
            XCTAssertFalse(ToDoListAsk.matches(text), text)
        }
        // W60-FIX P3: lists for a launch or a page matched before the app words.
        for text in ["Make a to-do list for my app launch", "Make a to-do list for the landing page",
                     // Round 2 P3: a board or a sheet on its own is a day's list.
                     "Make a to-do list for the board meeting", "Make a to-do list for the spreadsheet cleanup"] {
            XCTAssertTrue(ToDoListAsk.matches(text), text)
        }
    }
}
