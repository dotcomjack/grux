import XCTest
@testable import Grux

/// D175, live on grux-local:2b (sense pass 22, 9:25 PM Nov 5): "Make a packing
/// list for a weekend in Chicago" came back "I can't create a physical packing
/// list for you to print out. I can draft a digital checklist instead if you'd
/// like". A list the person asks for is text for them to read: on a local turn
/// it carries one line saying so, no tool is offered, and the reply starts
/// "Here is <the list asked for>:". Measured on this turn's own prompt
/// (`logs/d175/probe-*.txt`): no line and no tool 6 of 15 lists, the line 11
/// of 15, the line and the start 20 of 20.
@MainActor
final class ListAskTests: XCTestCase {

    /// The live ask, and the shapes around it, with the reply's start.
    static let lists: [(ask: String, start: String)] = [
        ("Make a packing list for a weekend in Chicago", "Here is a packing list for a weekend in Chicago:"),
        ("Give me a shopping list for taco night", "Here is a shopping list for taco night:"),
        ("Can you put together a checklist for a camping trip?", "Here is a checklist for a camping trip:"),
        ("Make a list of 10 dinner ideas", "Here is a list of 10 dinner ideas:"),
        ("Create a moving checklist for a two bedroom apartment", "Here is a moving checklist for a two bedroom apartment:"),
        ("make me a grocery list for the week", "Here is a grocery list for the week:"),
        ("Grux, write a list of things to do in Paris", "Here is a list of things to do in Paris:"),
        ("Please come up with a list of baby names, please", "Here is a list of baby names:"),
        ("Draw up a checklist for my first day at a new job", "Here is a checklist for your first day at a new job:"),
        ("give me a list of gift ideas for my dad", "Here is a list of gift ideas for your dad:"),
        ("Could you make a packing list?", "Here is a packing list:"),
        ("Make a list of questions to ask a landlord", "Here is a list of questions to ask a landlord:"),
        ("Make a packing list for St. Louis", "Here is a packing list for St. Louis:"),
        ("Make a reading list for Mr. Smith's class", "Here is a reading list for Mr. Smith's class:"),
        ("Make a packing list for a 9 a.m. flight to St. Louis.", "Here is a packing list for a 9 a.m. flight to St. Louis:"),
        ("Make a packing list for Chicago, please", "Here is a packing list for Chicago:"),
        ("Make a packing list for Chicago. Thanks!", "Here is a packing list for Chicago:"),
        ("Make a list of chores for my kids", "Here is a list of chores for your kids:"),
        ("Make an itinerary checklist for our trip to Rome", "Here is an itinerary checklist for your trip to Rome:"),
        ("Make a packing list for me", "Here is a packing list for you:"),
        // A list placed in the world, not in something the person holds (wave 58 round 9 P3).
        ("Make a list of things to do in the city", "Here is a list of things to do in the city:"),
        ("Make a list of fun things to do on the weekend", "Here is a list of fun things to do on the weekend:"),
        ("Make a list of tips for staying warm in the winter", "Here is a list of tips for staying warm in the winter:"),
        ("Make a grocery list for the week", "Here is a grocery list for the week:"),
        ("Make a shopping list with healthy snacks", "Here is a shopping list with healthy snacks:"),
    ]

    /// Not a list to write: the person's task list, something to add or save,
    /// a list of the person's own things that a tool reads, a question about a
    /// list, a playlist, an all-caps ask, or a list with no topic.
    static let notLists = [
        "Make a to-do list", "make a todo list for tomorrow", "Make a to do list for the weekend",
        "make a task list for the launch", "Make a reminder list for Monday",
        "Add milk to my shopping list", "Put eggs on the list", "Make my shopping list",
        "Make a shopping list and add it to my tasks", "Make a packing list and save it",
        "make a packing list then remind me tomorrow", "Make a packing list & send it to Sam",
        "Give me a list of my meetings tomorrow", "Make a list of my tasks", "Give me a list of today's events",
        "Make a list of everything on my calendar this week", "give me a list of my emails from Sam",
        "Make a list of my favorite books", "make a list of notes about the launch",
        "Make a list of contacts at Acme", "make a list of reminders for the trip",
        "list my tasks", "List the things on my calendar", "Show me my packing list",
        "Where is my packing list?", "What should go on a packing list?",
        "MAKE A PACKING LIST FOR CHICAGO", "Make a list", "make a playlist for running",
        "Make a listing for my couch", "I made a packing list", "Did you make the packing list?",
        "Make a note of the packing list", "write down a packing list for Chicago",
        "Write it down: a packing list for Chicago", "Make a list of songs for a road trip", "",
        // Wave 58 round 1 (P2-1): a list of what the person did or has is read
        // by a tool, and with none offered the model makes it up.
        "Make a list of things I need to do today", "Give me a list of everyone I emailed this week",
        "Give me a list of all my upcoming deadlines", "Make a list of what I have tomorrow",
        "Make a list of people I texted yesterday", "make a list of every website I visited today",
        "Make a list of books I've read", "Make a list of places we\u{2019}ve been", "Make a list of things you can do",
        "Make a list of questions to ask a landlord before I sign", "give me a list of gift ideas for my dad and my mom",
        // Wave 58 round 1 (P2-2): an action in a later sentence or after a comma.
        "Make a grocery list for the week. Add it to my reminders.", "Make a packing list for Chicago. Save it as a note.",
        "Make a packing list, save it to my desktop", "Make a shopping list for tacos, then text it to Sam",
        "Make a packing list for Chicago. Put it in my files.", "Make a shopping list for tacos. Share it with Sam.",
        // Wave 58 round 2 (P1): a list of what is due, on, installed or running
        // is read by a tool. Only a known kind, a known head after "of", or an
        // occasion after "for" is a list to write.
        "Give me a list of everything due this week", "Give me a list of the things due today",
        "Make a list of what's on tomorrow", "Make a list of this week's deadlines", "Make a list of today's agenda",
        "Give me a list of all the macros", "Give me a list of the skills installed", "Give me a list of the agents running",
        "Give me a list of the slack channels", "Make a list of research reports", "Give me a list of the folders",
        "Make a list of today's calls", "Make a list of who called today", "Make a list of upcoming birthdays",
        "Make a list of open items", "Make a deadline list", "Make a macro list for Monday", "Make a list for Plan B",
        "Make a list of things to do today", "Make a list of ideas from yesterday",
        // Wave 58 round 2 (P2): a later sentence about the list asks for a tool.
        "Make a grocery list for tacos. Remember it.", "Make a packing list for Chicago. Remember this for next week.",
        "Make a packing list for Chicago. Also capture it.", "Make a packing list for Chicago. Keep it somewhere safe.",
        "Make a packing list for Chicago. Make it a doc.", "Make a packing list for Chicago. Drop it in a new doc.",
        "Make a packing list for Chicago. Push it to Notion.", "Make a packing list for Chicago. Write it to Notion.",
        "Make a packing list for Chicago. Message it to Sam.", "Make a packing list for Chicago. iMessage it to Sam.",
        "Make a packing list for Chicago, then texting it to Sam", "Make a packing list for Chicago, and remember them",
        // Wave 58 round 3 (P2): an action joined by "and" or "to" in the list's own sentence.
        "Make a packing list for Chicago and share it with Sam", "Make a grocery list for tacos and message it to Sam",
        "Make a shopping list for tacos to send to Sam", "Make a packing list for Chicago and upload it to Drive",
        "Make a packing list for Chicago and pin it", "Make a shopping list for tacos and export it",
        "Make a packing list to share with Sam", "Make a list of things to do in Paris and share them with Sam",
        // Wave 58 round 4 (P2): any instruction joined after the topic, whatever its verb.
        "Make a packing list for Chicago and slack it to Sam", "Make a list of places to visit and Slack them to Sam",
        "Make a checklist for a move and slack it to the team", "Make a shopping list for tacos and turn it into a to-do",
        "Make a packing list for Chicago and memorize it", "Make a packing list for Chicago and log it in Notion",
        "Make a packing list for Chicago and print it", "Make a packing list for Chicago and copy it to the clipboard",
        "Make a packing list for Chicago and tell Sam", "Make a packing list for Chicago and notify the team",
        "Make a packing list for Chicago and mark it done", "Make a packing list for Chicago + airdrop it to Sam",
        "Make a packing list for Chicago so Sam knows", "Make a packing list for Chicago, plus whatsapp it",
        // Wave 58 round 5 (P2): an instruction in a later sentence or after a
        // comma, or joined, whatever its verb. Cut (wave 57's lesson): the list
        // ask must be the whole message, one clause, so none of these can be one.
        "Make a packing list for Chicago. Slack Sam.", "Make a packing list for Chicago. Slack Sam a copy.",
        "Make a packing list for Chicago. Search the web for deals.", "Make a packing list for Chicago, Slack Sam",
        "Make a packing list for Chicago and Slack Sam", "Make a packing list for Chicago, and Slack Sam",
        "Make a packing list for Chicago and WhatsApp Mom", "Make a packing list for Chicago and Slack #general",
        "Make a packing list for Chicago and slack @sam", "Make a packing list for Chicago and print",
        "Make a packing list for Chicago andSlack it", "Make a packing list for Chicago &Sam",
        "Make a packing list for Sam on Slack", "Make a packing list for Chicago in my Drive",
        // Wave 58 round 6 (P1): a list from a meeting, a video or the screen is
        // read by a tool. A list ask brings in no tool group beyond the core
        // (`ToolRelevance.groups`), the same words that pick the turn's tools.
        "Make a list of action items from the standup", "Make a list of action items from the transcript",
        "Make a list of action items from the standup recording", "Make a checklist of action items from the kickoff meeting",
        "Make a list of questions from the transcript", "Make a list of names of the speakers",
        "Make a list of steps from the youtube video", "Make a list of things on screen",
        "Make a shopping list for the recipe on the screen", "Make a shopping list of the ingredients in the video",
        "Make a list of ideas from the research report", "Make a list of things to post to the channel",
        // Wave 58 round 7 (P2): a list from something the person holds, which
        // only a tool reads. A list to write comes from nothing, so a source
        // word ("from", "based on", "using", "attached") keeps the tools.
        "Make a list of tips from the PDF", "Make a list of questions from the PDF", "Make a list of tips from the attached PDF",
        "Make a list of steps from the instructions in the PDF", "Make a list of questions from the resume",
        "Make a list of things from the contract", "Make a list of steps from the manual",
        "Make a list of action items from the memo", "Make a list of words from the voice memo",
        "Make a list of names from the spreadsheet", "Make a list of tips from the ebook",
        "Make a list of tips using the guide", "Make a packing list based on the forecast",
        "Make a list of ideas in the attached slides", "Make a list of questions about chapter 3",
        "Make a list of the following items",
        // Wave 58 round 8 (P2): a list of what is in a thing the person holds.
        // A list to write is indefinite: "a list of the ..." names a set that
        // exists, and so does one "in the" or "on that" thing.
        "Make a list of the action items in the proposal", "Make a list of the items on the agenda",
        "Make a list of the action items in the minutes", "Make a list of the items on the invoice",
        "Make a list of the items in the receipt", "Make a list of the names in the address book",
        "Make a list of the steps in the README", "Make a list of the rules in the handbook",
        "Make a list of action items in the proposal", "Make a list of names in that chat",
        "Make a list of questions on this survey", "Make a list of these ideas",
        // Wave 58 round 9 (P2): the same with a kind before "list", or a
        // possessive for "the".
        "Make a gift list of the names in the address book", "Make a reading list of the books in the syllabus",
        "Make a grocery list of the ingredients in the recipe", "Make a shopping list of the ingredients in this recipe",
        "Make a shopping list of the items in the meal plan", "Make a list of action items in Sam's proposal",
        "Make a list of action items in their proposal", "Make a list of questions in Sam\u{2019}s survey",
        "Make a list of steps in his README", "Make a list of Sam's ideas", "Make a reading list of her books",
        // Wave 58 round 10 (P2): "with" or "about" in place of "of".
        "Make a grocery list with the ingredients in the recipe", "Make a shopping list with everything in this recipe",
        "Make a grocery list with the ingredients in Sam's recipe", "Make a shopping list with the items in the meal plan",
        "Make a gift list with the names in the address book", "Make a reading list with the books on the syllabus",
        "Make a reading list about the books in the syllabus",
        // What the cut costs: the LIST line only (the model answers with its tools, as before D175).
        "Make a packing list for a weekend in Chicago. We fly out Friday.", "Make a shopping list for tacos and drinks",
        "Make a packing list for me and the kids", "Make a packing list for Rome/Florence",
    ]
    /// Every list this writes picks no tool group but the core, so taking the
    /// tools away takes none the words asked for.
    func testAListToWriteCallsForNoToolGroup() {
        for l in Self.lists {
            XCTAssertEqual(ToolRelevance.groups(for: .init(utterance: l.ask)), [.core], l.ask)
        }
    }
    /// A closing word is taken off only as a closing.
    func testOnlyAClosingIsTakenOff() {
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a list of ways to say thanks"), "Here is a list of ways to say thanks:")
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a packing list for Chicago please"), "Here is a packing list for Chicago:")
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a packing list for Chicago, thank you."), "Here is a packing list for Chicago:")
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a list of ways to say please"), "Here is a list of ways to say please:")
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a packing list for Chicago thanks"), "Here is a packing list for Chicago:")
    }

    /// The one joined phrase a list is named by.
    func testProsAndConsIsOneThing() {
        XCTAssertEqual(ListAsk.replyStart(ask: "Make a list of pros and cons of renting"), "Here is a list of pros and cons of renting:")
        XCTAssertNil(ListAsk.replyStart(ask: "Make a list of pros and cons and send it"))
    }

    func testAListToWriteMatchesAndNothingElseDoes() {
        for l in Self.lists { XCTAssertTrue(ListAsk.matches(l.ask), l.ask) }
        for ask in Self.notLists { XCTAssertFalse(ListAsk.matches(ask), ask) }
    }

    /// The reply starts with the list the person named, said back to them
    /// ("my" becomes "your"), up to the end of its first sentence.
    func testTheReplyStartsWithTheListAskedFor() {
        for l in Self.lists { XCTAssertEqual(ListAsk.replyStart(ask: l.ask), l.start, l.ask) }
        for ask in Self.notLists { XCTAssertNil(ListAsk.replyStart(ask: ask), ask) }
        // A list named at length is not said back whole.
        let long = "Make a packing list for a two week trip through the mountains of northern Portugal "
            + "with two small kids in a rented camper van in the rainy season"
        XCTAssertTrue(ListAsk.matches(long))
        XCTAssertEqual(ListAsk.replyStart(ask: long), "Here is your list:")
        let pre = ListAsk.prefillMessage(ask: Self.lists[0].ask)
        XCTAssertEqual(pre?["role"] as? String, "assistant")
        XCTAssertEqual(pre?["content"] as? String, Self.lists[0].start)
        XCTAssertNotNil(pre?[DraftAsk.prefillKey])
    }

    func testTheLineSaysWriteTheListNowAndDoNotSaveIt() throws {
        for l in Self.lists {
            let note = try XCTUnwrap(ListAsk.localNote(ask: l.ask), l.ask)
            XCTAssertTrue(note.hasPrefix("LIST: "), note)
            XCTAssertTrue(note.contains("Do not say you cannot"), note)
            XCTAssertTrue(note.contains("not a task, note or reminder to save"), note)
            XCTAssertLessThanOrEqual(LocalTurn.tokens(chars: note.count), 90, "the list line grew: \(note.count) chars")
        }
        for ask in Self.notLists { XCTAssertNil(ListAsk.localNote(ask: ask), ask) }
    }

    /// A list Grux was asked to write is writing, so the action-claim guard
    /// keeps it ("I've put together a packing list" gets the written-only note).
    func testAListAskIsWriting() {
        for l in Self.lists { XCTAssertTrue(DraftAsk.asksForWriting(l.ask), l.ask) }
        for ask in ["Make a to-do list", "Add milk to my shopping list", "Make a list of my tasks"] {
            XCTAssertFalse(DraftAsk.asksForWriting(ask), ask)
        }
    }

    /// The live turn offered 10 tools; a list turn offers none, carries the
    /// line and ends with the reply's start. The person's task list keeps its
    /// tool, and a cloud turn is unchanged.
    func testALocalListTurnCarriesTheLineTheStartAndNoTool() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        func turn(_ lean: Bool, _ ask: String) -> (text: String, tools: Set<String>, last: [String: Any]?) {
            state.chat = [ChatMessage(role: .user, content: ask)]
            let p = ChatService.shared.assemblePendingContext(state: state, lean: lean, window: 16_384)
            return (p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n"),
                    Set(p.tools.map(\.name)), p.messages.last)
        }
        let chicago = turn(true, "Make a packing list for a weekend in Chicago")
        XCTAssertTrue(chicago.text.contains("LIST: "), "the local turn was not told")
        XCTAssertTrue(chicago.tools.isEmpty, "offered \(chicago.tools.sorted())")
        XCTAssertEqual(chicago.last?["content"] as? String, "Here is a packing list for a weekend in Chicago:")
        XCTAssertNotNil(chicago.last?[DraftAsk.prefillKey])
        let todo = turn(true, "Make a to-do list for the weekend")
        XCTAssertFalse(todo.text.contains("LIST: "))
        XCTAssertNil(todo.last?[DraftAsk.prefillKey])
        let cloud = turn(false, "Make a packing list for a weekend in Chicago")
        XCTAssertFalse(cloud.text.contains("LIST: "), "a cloud turn carries it")
        XCTAssertFalse(cloud.tools.isEmpty, "a cloud turn lost its tools")
        XCTAssertNil(cloud.last?[DraftAsk.prefillKey])
        // A draft keeps its own line and greeting.
        let draft = turn(true, "Write a short email to my landlord saying the kitchen sink is leaking.")
        XCTAssertTrue(draft.text.contains("DRAFT: "))
        XCTAssertFalse(draft.text.contains("LIST: "))
        XCTAssertEqual(draft.last?["content"] as? String, "Hi [Name],")
    }
}
