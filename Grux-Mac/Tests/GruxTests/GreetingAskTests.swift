import XCTest
@testable import Grux

/// D211: a stranger's first "hey" waited 8.5 s on Grux Local 2B and came back
/// "Hey. How's your Monday off starting?" (sense pass 32, 8:12 PM Nov 9).
@MainActor
final class GreetingAskTests: XCTestCase {

    func testAGreetingAloneIsAnsweredAtOnce() {
        for text in [
            "hey", "Hey", "hi", "Hi!", "hello", "Hello.", "hi there", "Hey there!", "Hello there", "yo", "hiya",
            "howdy", "Good morning", "Good evening!", "Good day", "Hey Grux", "Hi, Grux.", "Grux hi",
            "hey hey", "Hello again", "\u{1F44B}", "\u{1F44B}\u{1F3FD}", "  hey  ",
            "hey buddy", "hi there grux",
        ] {
            XCTAssertTrue(GreetingAsk.matches(text), text)
        }
    }

    /// The assistant's own name (Settings) before or after it, as "Grux" is read.
    func testTheAssistantsNameIsReadAsGruxIs() {
        for text in ["Hey Jax", "Hi, Jax!", "Jax, hello", "good morning jax"] {
            XCTAssertTrue(GreetingAsk.matches(text, name: "Jax"), text)
        }
        XCTAssertFalse(GreetingAsk.matches("Hey Jax", name: ""), "a name Grux does not go by is a word")
    }

    /// A message that asks anything stays with the rest of chat.
    func testAMessageThatAsksSomethingIsLeftAlone() {
        for text in [
            "Hey, what's on my calendar?", "hi can you add milk to my list", "Hello, I just installed you. What should I try first?",
            "How are you?", "good morning, what's the weather", "hey jude", "hello world", "hi mom",
            "Say hi to Sam", "hey what can you do", ":)", "?", "", "   ", "ok", "thanks", "evening plans",
            "Morning", "Evening", "afternoon", "Evening, please", "morning works", "What's up?", "sup",
            "\u{1F44B} what time is it",
        ] {
            XCTAssertFalse(GreetingAsk.matches(text), text)
        }
    }

    /// The reply says nothing about the person, and in a chat that has asked
    /// nothing yet it names the ask that shows what works on this Mac.
    func testTheReplyNamesWhatCanYouDoOnlyInAFreshChat() {
        XCTAssertEqual(GreetingAsk.reply(for: "hey", earlier: []), GreetingAsk.firstReply)
        XCTAssertEqual(GreetingAsk.reply(for: "hey", earlier: ["hello", "Who are you?"]), GreetingAsk.firstReply)
        XCTAssertEqual(GreetingAsk.reply(for: "hey", earlier: ["Plan my move to Denver"]), GreetingAsk.reply)
        XCTAssertNil(GreetingAsk.reply(for: "hey, plan my move", earlier: []))
        XCTAssertTrue(GreetingAsk.firstReply.contains("\u{201C}What can you do?\u{201D}"))
        XCTAssertTrue(CapabilityAsk.matches("What can you do?"), "the ask the reply names is answered by Grux")
        for line in [GreetingAsk.reply, GreetingAsk.firstReply] {
            XCTAssertNil(line.range(of: #"\b(your|you're|day off|monday|morning|evening)\b"#, options: [.regularExpression, .caseInsensitive]),
                         "nothing about the person or the day: \(line)")
            XCTAssertEqual(DashSanitizer.stripDashesOnly(line), line)
        }
    }

    /// Chat answers it before any model is asked, right below the readiness
    /// guard (with no model the guard says what to set up), only for a message
    /// with no image, and marks the message answered without a model.
    func testChatAnswersItBelowTheReadinessGuardBeforeTheModel() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let readiness = try XCTUnwrap(source.range(of: "let readiness = ChatReadiness.current()"))
        let gate = try XCTUnwrap(source.range(of: "if imageData == nil,\n           let reply = GreetingAsk.reply(for: trimmed"))
        let confidence = try XCTUnwrap(source.range(of: "let verdict = await ConfidenceGate.assessGrounded("))
        XCTAssertLessThan(readiness.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, confidence.lowerBound, "no model call before the greeting is answered")
        let body = source[gate.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("answeredByGrux = true"))
        XCTAssertTrue(body.contains("WakeLog.shared.log(\"chat: greeting fast-path\")"))
    }
}
