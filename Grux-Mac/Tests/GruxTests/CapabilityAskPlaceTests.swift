import XCTest
@testable import Grux

/// D196: "What can you do on my Mac?" is the same question as "What can you
/// do?". Sense pass 27 (6:43 AM Nov 8) asked it on grux-local:2b and, with no
/// fast path, the model said "I'm also ready to listen to your voice" while
/// the microphone was not granted.
final class CapabilityAskPlaceTests: XCTestCase {
    func testTheSenseAskMatches() {
        XCTAssertTrue(CapabilityAsk.matches("What can you do on my Mac?"))
    }

    func testAPlaceOrForMeAfterTheAskStillAsksIt() {
        for text in ["what can you do on this mac", "What can you do on my computer?", "what can you do on my MacBook",
                     "What can you help me with on my Mac?", "Hi Grux, what can you do for me on my Mac?",
                     "what can you do exactly?", "What are you able to do here?", "what can grux do on my mac",
                     "What can you do on my Mac, Grux?", "How can you help me on my Mac?"] {
            XCTAssertTrue(CapabilityAsk.matches(text), text)
        }
        // A first-run form takes the same places, under the same first-run rule.
        XCTAssertTrue(CapabilityAsk.matches("What should I try first on my Mac?"))
        XCTAssertFalse(CapabilityAsk.matches("What should I try first on my Mac?", earlier: ["help me plan my move"]))
    }

    /// Wave 67 round 1 P2-3: "How can you help me here?" after the person
    /// described a problem asks about that problem. "here", "for me" and
    /// "exactly" take the ask only where the first-run rule would.
    func testHereMidConversationAsksAboutTheConversation() {
        let earlier = ["My landlord kept my whole deposit."]
        for text in ["How can you help me here?", "What can you help with here?", "what can you do here exactly",
                     "What can you do exactly?", "How can you help for me?"] {
            XCTAssertFalse(CapabilityAsk.matches(text, earlier: earlier), text)
        }
        XCTAssertTrue(CapabilityAsk.matches("How can you help me here?"), "a chat with no real ask yet")
        XCTAssertTrue(CapabilityAsk.matches("I'm new here. How can you help me here?", earlier: earlier), "beside an introduction")
        XCTAssertTrue(CapabilityAsk.matches("What can you do on my Mac?", earlier: earlier), "the Mac is not the conversation")
        XCTAssertTrue(CapabilityAsk.matches("What can you do?", earlier: earlier), "about Grux wherever it is asked")
    }

    /// Wave 67 round 2 P2-3: after "My landlord kept my whole deposit." the next
    /// message "How can you help me?" asks about the deposit. The help-shaped
    /// asks take the first-run rule; the ones about Grux itself do not.
    func testHelpShapedAsksMidConversationStayWithTheConversation() {
        let earlier = ["My landlord kept my whole deposit."]
        for text in ["How can you help me?", "How can you help?", "What can you do for me?", "What can you do here?",
                     "What can you help me with?", "What can you help with?", "What can you help me do?"] {
            XCTAssertFalse(CapabilityAsk.matches(text, earlier: earlier), text)
            XCTAssertTrue(CapabilityAsk.matches(text), "\(text) in a fresh chat")
            XCTAssertTrue(CapabilityAsk.matches("I just installed you. " + text, earlier: earlier), "\(text) beside an introduction")
        }
        for text in ["What can you do?", "What are your capabilities?", "What else can you do?", "What can Grux do?",
                     "Tell me what you can do", "What are you capable of?"] {
            XCTAssertTrue(CapabilityAsk.matches(text, earlier: earlier), text)
        }
    }

    /// Wave 67 rounds 3 to 5: after an ask Grux answered itself (weather, a
    /// sum, the calendar, a privacy or voice question, a calendar card) the chat
    /// is still fresh, so "What can you do for me?" gets the list; a help form
    /// with a Mac place asks about Grux anywhere. The mark is on the person's
    /// message, set when Grux takes it, so a reply that lands later (a card's,
    /// after its undo window) or never cannot leave it unmarked.
    private func ask(_ text: String, byGrux: Bool) -> ChatMessage {
        ChatMessage(role: .user, content: text, answeredWithoutModel: byGrux)
    }

    func testAnAskGruxAnsweredItselfLeavesTheChatFresh() {
        for first in ["What's the weather in Boston?", "What's on my calendar tomorrow?", "Does anything I type leave my Mac?",
                      "Put lunch with Sarah on my calendar Friday at 1pm", "Boston"] {
            // No reply yet (a card inside its undo window) or a reply after another line.
            for chat in [[ask(first, byGrux: true)],
                         [ask(first, byGrux: true), ChatMessage(role: .assistant, content: "Approved: x"),
                          ChatMessage(role: .assistant, content: "Added.")]] {
                let earlier = CapabilityAsk.modelAsks(chat)
                XCTAssertTrue(earlier.isEmpty, first)
                XCTAssertTrue(CapabilityAsk.matches("What can you do for me?", earlier: earlier), first)
                XCTAssertTrue(CapabilityAsk.matches("How can you help me?", earlier: earlier), first)
            }
        }
        XCTAssertEqual(CapabilityAsk.modelAsks([ask("What's the weather in Boston?", byGrux: false),
                                                ChatMessage(role: .assistant, content: "Sunny.")]),
                       ["What's the weather in Boston?"], "the same words answered by the model are a real ask")
        let deposit = CapabilityAsk.modelAsks([ask("My landlord kept my whole deposit.", byGrux: false)])
        XCTAssertEqual(deposit, ["My landlord kept my whole deposit."])
        XCTAssertFalse(CapabilityAsk.matches("How can you help me?", earlier: deposit))
        XCTAssertTrue(CapabilityAsk.matches("How can you help me on my Mac?", earlier: deposit))
        XCTAssertTrue(CapabilityAsk.matches("What can you do for me on this computer?", earlier: deposit))
        XCTAssertFalse(CapabilityAsk.matches("What should I try first on my Mac?", earlier: deposit))
        XCTAssertEqual(CapabilityAsk.modelAsks([ChatMessage(role: .user, content: "x", isNotice: true)]), [])
    }

    /// ChatService marks the person's message on every exit between the
    /// capability ask and the readiness guard (any fast path, any card, any
    /// added later), and only reaching the model path disarms it.
    func testChatMarksEveryMessageItAnswersWithoutAModel() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/GruxTests/CapabilityAskPlaceTests.swift",
                                                                              with: "Sources/Grux/ChatService.swift"), encoding: .utf8)
        // W73-P3 item 1: and with the assistant's own name, read as a lead-in.
        XCTAssertTrue(src.contains("CapabilityAsk.matches(trimmed, earlier: CapabilityAsk.modelAsks(Array(state.chat.dropLast())),\n"
                                   + "                                                   name: UserIdentity.assistantName)"))
        let arm = try XCTUnwrap(src.range(of: "defer { if answeredByGrux { state.markAnsweredWithoutModel(userMsg.id) } }"))
        let first = try XCTUnwrap(src.range(of: "if imageData == nil, CapabilityAsk.matches(trimmed"))
        let disarm = try XCTUnwrap(src.range(of: "answeredByGrux = false\n        let readiness = ChatReadiness.current()"))
        XCTAssertLessThan(arm.lowerBound, first.lowerBound, "armed before the first fast path")
        // Nothing but comments between arming and the first fast path.
        let gap = src[arm.upperBound..<first.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(gap, [], "the capability ask is the first thing after arming")
        XCTAssertLessThan(first.lowerBound, disarm.lowerBound)
        XCTAssertEqual(src.components(separatedBy: "answeredByGrux = false").count, 2, "disarmed in one place only")
    }

    func testTheMarkSurvivesSavingAndAnOlderThreadReadsAsTheModels() throws {
        let m = ChatMessage(role: .assistant, content: "It's 7:30 PM.", answeredWithoutModel: true)
        let back = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(m))
        XCTAssertTrue(back.answeredWithoutModel)
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"hi","timestamp":0}"#
        XCTAssertFalse(try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8)).answeredWithoutModel)
    }

    func testAnythingElseAfterTheAskStaysWithTheModel() {
        for text in ["What can you do about my Mac?", "what can you do on my mac's disk", "What can you do on my phone?",
                     "what can you do on my mac to free up space", "What can you do on my Mac on my Mac?",
                     "what can you do for my mom", "what can you do with my mac", "What can you do on Windows?",
                     "on my mac", "for me", "here"] {
            XCTAssertFalse(CapabilityAsk.matches(text), text)
        }
    }
}
