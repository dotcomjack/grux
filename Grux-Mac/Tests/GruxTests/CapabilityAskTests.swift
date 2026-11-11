import XCTest
@testable import Grux

/// D145: "What can you do?" is answered from what works on this Mac, with no model.
final class CapabilityAskTests: XCTestCase {
    func testTheWholeAskMatchesAndNothingElse() {
        for text in ["Hi! What can you do for me?", "what can you do", "Grux, what can you do?",
                     "Hey Grux what can you help me with", "What are your capabilities?",
                     "what can I ask you?",
                     "How can you help?", "OK, what else can you do?", "What can you do, Grux?",
                     "Hi there, what can you do?", "Tell me what you can do", "What are you capable of?",
                     "What can you help me do?"] {
            XCTAssertTrue(CapabilityAsk.matches(text), text)
        }
        for text in ["What can you do about my inbox?", "what can you do with this pdf", "Can you do my taxes",
                     "What do you do when the app crashes?", "hi", "Grux", "", "what can't you do",
                     "Write a poem about what you can do"] {
            XCTAssertFalse(CapabilityAsk.matches(text), text)
        }
    }

    /// D176, live on grux-local:2b (sense pass 22): "Hello, I just installed you.
    /// What should I try first?" got "Welcome to the team. I'm ready to help ..."
    /// with nothing to try. A first-run ask is the same question, and a line
    /// saying the person is new comes before it; any other sentence beside the
    /// ask is something else and stays with the model.
    func testTheFirstRunAsksMatchAfterAnIntroduction() {
        for text in ["Hello, I just installed you. What should I try first?", "What should I try first?",
                     "where do I start?", "Hi! I'm new here. How do I get started?", "How do I use you?",
                     "I just downloaded Grux. What can you do?", "Nice to meet you! What should I ask you?",
                     "Thanks. What can I try?", "This is my first time. Where should I start?",
                     "What can you do? I just installed you.", "Hi. Hi. What should I do first?"] {
            XCTAssertTrue(CapabilityAsk.matches(text), text)
        }
        for text in ["I just installed you.", "Hello. I'm new here.", "Hi!",
                     "I just installed you. Add milk to my list. What can you do?",
                     "What should I try first, the blue or the red dress?", "Where do I start with my taxes?",
                     "How do I use you to book a flight?", "I just installed Zoom. What should I try first?",
                     "What should I try first? Also remind me to call Mom."] {
            XCTAssertFalse(CapabilityAsk.matches(text), text)
        }
    }

    /// Wave 58 round 1 (P2-3): "Where do I start?" after "I need to move next
    /// month, help me plan" is about the move. A first-run form is the
    /// capability ask only in a chat with nothing real asked before it, or
    /// beside a line saying the person is new; "What can you do?" is one always.
    func testAFirstRunFormMidConversationStaysWithTheModel() {
        let move = ["I need to move apartments next month, help me plan"]
        for text in ["Where do I start?", "What should I do first?", "What should I ask?", "How do I start?",
                     "what should i try first"] {
            XCTAssertFalse(CapabilityAsk.matches(text, earlier: move), text)
            XCTAssertTrue(CapabilityAsk.matches(text, earlier: []), text)
            XCTAssertTrue(CapabilityAsk.matches(text, earlier: ["Hi", "hello grux", "What can you do?"]), text)
            XCTAssertTrue(CapabilityAsk.matches("I just installed you. " + text, earlier: move), text)
        }
        XCTAssertTrue(CapabilityAsk.matches("What can you do?", earlier: move))
        XCTAssertTrue(CapabilityAsk.matches("what can I ask you?", earlier: move))
        XCTAssertFalse(CapabilityAsk.matches("Where do I start?", earlier: ["hi", "Add milk to my list"]))
    }

    /// D207, sense pass 30 (thread DE570310, 6:13 AM Nov 9, grux-local:2b): a
    /// stranger typed "hello", "Who are you?", then "What should I try
    /// first?", and the model answered "Since you're looking to back up the
    /// Mini, let's start there." from a memory. Asking who Grux is, or how it
    /// is, opens a chat as a greeting does; beside the ask in one message it is
    /// a second question, which the capability answer would drop.
    func testAskingWhoGruxIsOpensAChat() {
        let openers = ["Who are you?", "who are you grux", "What are you?", "What's your name?", "What is your name?",
                       "How are you?", "How are you doing today?", "How's it going?", "What's up?", "Good morning!",
                       "Good evening, Grux.", "Are you there?", "What is Grux?", "What's Grux?",
                       "Hi, who are you?", "Hello. How are you?"]
        for text in openers {
            XCTAssertTrue(CapabilityAsk.isOpening(text), text)
            XCTAssertFalse(CapabilityAsk.matches(text), text)
            XCTAssertTrue(CapabilityAsk.matches("What should I try first?", earlier: ["hello", text]), text)
            XCTAssertTrue(CapabilityAsk.matches("Where do I start?", earlier: [text]), text)
        }
        for text in ["Who are you? What can you do?", "How are you? What should I try first?",
                     "What's your name? Where do I start?"] {
            XCTAssertFalse(CapabilityAsk.matches(text), text)
        }
        for text in ["Who are you voting for?", "What are you doing tomorrow?", "How are you so slow?",
                     "What's up with my Wi-Fi?", "Who are you texting", "What is Grux doing right now?"] {
            XCTAssertFalse(CapabilityAsk.isOpening(text), text)
            XCTAssertFalse(CapabilityAsk.matches("What should I try first?", earlier: [text]), text)
        }
    }

    private func reply(_ states: [String: FeatureState], canSend: Bool = true, chatStep: String? = nil,
                       calendarReadable: Bool = true, memoryOn: Bool = true) -> String {
        CapabilityAsk.reply(state: { states[$0] }, chatCanSend: canSend, chatStep: chatStep,
                            calendarReadable: calendarReadable,
                            label: { ["calendar": "Calendar", "mailbox": "Mailbox", "agents": "Agents",
                                      "meetings": "Meetings", "research": "Research"][$0] },
                            memoryOn: memoryOn)
    }

    func testOnlyWhatWorksIsClaimed() {
        let all = reply(["chat": .ready, "tasks": .ready, "calendar": .ready, "contacts": .degraded])
        XCTAssertEqual(all, "On this Mac right now I can tell you the weather anywhere, keep your task list, "
            + "read your calendar and add events, look up a contact, remember what you tell me, and answer questions "
            + "and help you write. Try \u{201C}What's on my calendar tomorrow?\u{201D} or \u{201C}What's the weather in Boston?\u{201D}")

        let bare = reply(["chat": .needsSetup, "tasks": .notChosen, "calendar": .needsSetup, "contacts": .unavailable],
                         canSend: false, chatStep: "Chat needs a model first: run a local model, or add your own API key.",
                         calendarReadable: false, memoryOn: false)
        XCTAssertEqual(bare, "On this Mac right now I can tell you the weather anywhere. Try \u{201C}What's the weather "
            + "in Boston?\u{201D} Chat needs a model first: run a local model, or add your own API key. "
            + "One step away: Calendar. Settings says what it needs.")
    }

    /// D166 item 14: "Settings says what each one needs" followed a single
    /// name. One thing reads "it", two or more read "each one".
    func testTheSettingsLineAgreesWithHowManyAreNamed() {
        let one = reply(["chat": .ready, "mailbox": .needsSetup])
        XCTAssertTrue(one.hasSuffix(" One step away: Mailbox. Settings says what it needs."), one)
        let two = reply(["chat": .ready, "mailbox": .needsSetup, "agents": .needsSetup])
        XCTAssertTrue(two.hasSuffix(" One step away: Mailbox and Agents. Settings says what each one needs."), two)
        let three = reply(["chat": .ready, "mailbox": .needsSetup, "agents": .needsSetup, "meetings": .needsSetup])
        XCTAssertTrue(three.hasSuffix("Settings says what each one needs."), three)
        let none = reply(["chat": .ready])
        XCTAssertFalse(none.contains("Settings says"), none)
        // The chat step takes a place: two left, one picked, still "it".
        let withStep = reply(["chat": .needsSetup, "research": .needsSetup], canSend: false, chatStep: "Chat x.")
        XCTAssertTrue(withStep.hasSuffix("Chat x. One step away: Research. Settings says what it needs."), withStep)
    }

    /// Wave 44 P2 2: what goes through the model is claimed only when a chat
    /// turn can be sent, whatever the registry rows say (a local model found
    /// but not routed reads Chat ready in the registry and refuses every send).
    func testWhatNeedsTheModelIsClaimedOnlyWhenATurnCanBeSent() {
        let out = reply(["chat": .ready, "tasks": .ready, "calendar": .ready, "contacts": .ready],
                        canSend: false, chatStep: "Chat needs one switch: turn it on.")
        XCTAssertEqual(out, "On this Mac right now I can tell you the weather anywhere and tell you what's on your "
            + "calendar. Try \u{201C}What's on my calendar tomorrow?\u{201D} or \u{201C}What's the weather in Boston?\u{201D} "
            + "Chat needs one switch: turn it on.")
        for word in ["task", "add events", "contact", "remember", "answer questions"] {
            XCTAssertFalse(out.contains(word), word)
        }
    }

    /// Reading the calendar is the fast path's own access (full access), so
    /// write-only access never claims it; adding events needs the model.
    func testTheCalendarClaimFollowsReadAccessAndTheModel() {
        let rows: [String: FeatureState] = ["calendar": .ready]
        XCTAssertTrue(reply(rows, canSend: true, calendarReadable: true).contains("read your calendar and add events"))
        // W44-P3 item 1: adding an event needs full access too (`createEvent`).
        let writeOnly = reply(rows, canSend: true, calendarReadable: false)
        XCTAssertFalse(writeOnly.contains("calendar"), writeOnly)
        XCTAssertTrue(reply(rows, canSend: false, chatStep: "x", calendarReadable: true).contains("tell you what's on your calendar"))
        let neither = reply(rows, canSend: false, chatStep: "x", calendarReadable: false)
        XCTAssertFalse(neither.contains("calendar"), neither)
        XCTAssertFalse(reply(["calendar": .needsSetup], canSend: true, calendarReadable: false).contains("add events"))
    }

    /// Names only: the registry's setup steps read as commands after "needs"
    /// ("needs Install the agent command line tool"), and either-or needs
    /// read as both (wave 44 P2 1).
    func testAtMostThreeThingsOneStepAwayAndOnlyThosePicked() {
        let out = reply(["chat": .ready, "mailbox": .needsSetup, "agents": .needsSetup, "meetings": .needsSetup,
                         "research": .needsSetup, "calendar": .notChosen])
        XCTAssertTrue(out.hasSuffix(" One step away: Mailbox, Agents, and Meetings. Settings says what each one needs."), out)
        XCTAssertFalse(out.contains("Research"))
        XCTAssertFalse(out.contains("Calendar"))
        XCTAssertFalse(out.contains("needs ") && !out.contains("what each one needs"))
        let two = reply(["chat": .needsSetup, "mailbox": .needsSetup, "agents": .needsSetup, "meetings": .needsSetup],
                        canSend: false, chatStep: "Chat x.")
        XCTAssertTrue(two.hasSuffix("Chat x. One step away: Mailbox and Agents. "
            + "Settings says what each one needs."), two)
    }

    /// What chat needs, from the send path's own readiness: either route, never both.
    func testTheChatStepFollowsReadiness() {
        XCTAssertNil(CapabilityAsk.chatStep(for: .ready))
        XCTAssertEqual(CapabilityAsk.chatStep(for: .needsModel),
                       "Chat needs a model first: run a local model, or add your own API key; both are in Settings.")
        // W44-P3 item 2: one is running, so it needs a switch, not a model.
        XCTAssertEqual(CapabilityAsk.chatStep(for: .localModelFoundButNotRouted),
                       "Chat needs one switch: turn on Offline mode in Settings, Models to use the local model already running.")
        // W44-P3 item 6: no key is promised when none may be stored.
        XCTAssertEqual(CapabilityAsk.chatStep(for: .offlinePinnedButNoLocalModel),
                       "Chat needs your local model server: start it, or turn offline mode off in Settings, Models.")
    }

    /// Every id the reply reads is a real registry row, so a renamed row
    /// cannot silently drop out of the answer.
    func testEveryIdIsARegistryRow() {
        let ids = Set(FeatureRegistry.rows.map(\.id))
        for id in CapabilityAsk.abilities.map(\.id) + CapabilityAsk.worthNaming {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    /// Never music, macros, or another app: a local model is kept from those (D12).
    @MainActor
    func testTheReplyNeverOffersWhatChatIsKeptFrom() {
        let out = CapabilityAsk.reply(memoryOn: true)
        for word in ["music", "macro", "ambient", "YouTube", "Chrome", "promote"] {
            XCTAssertFalse(out.localizedCaseInsensitiveContains(word), word)
        }
        XCTAssertTrue(out.hasPrefix("On this Mac right now I can tell you the weather anywhere"), out)
    }

    /// Order in send(): before the calendar ask and the readiness guard, so it needs no model.
    func testTheRouteSitsBeforeTheCalendarAskAndTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let route = try XCTUnwrap(src.range(of: "CapabilityAsk.matches(trimmed, earlier:"))
        let calendar = try XCTUnwrap(src.range(of: "CalendarAsk.window(for: trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(route.lowerBound < calendar.lowerBound && calendar.lowerBound < readiness.lowerBound)
    }
}
