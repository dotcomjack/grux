import XCTest
@testable import Grux

/// A thread title names what the PERSON asked about, never Grux's own reply.
///
/// Measured in sense pass 31 (2026-11-09) on grux-local:2b: a fresh thread
/// whose person said "hi there", "What can you do?" and "Explain what an API
/// is in one sentence." was titled "weather and task assistant", from Grux's
/// capability list; another whose person said "hello", "Who are you?", "What
/// should I try first?" and "What is Grux?" was titled "whats your name". The
/// generator was handed Grux's replies and named them. Two halves: only the
/// person's words reach it, and a title that shares no word with them falls
/// back to what the person said.
final class ChatTitleGroundingTests: XCTestCase {

    private func msg(_ role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: text)
    }

    private let capabilityThread: [(ChatRole, String)] = [
        (.user, "hi there"),
        (.assistant, "Hi Sam. How can I help you today?"),
        (.user, "What can you do?"),
        (.assistant, "On this Mac right now I can tell you the weather anywhere, keep your task list, read your calendar"),
        (.user, "Explain what an API is in one sentence."),
        (.assistant, "An API is a way for different software applications to talk to each other."),
    ]

    func test_theTitlePayloadCarriesOnlyThePersonsWords() {
        let payload = ChatCompactor.buildTitlePayload(messages: capabilityThread.map { msg($0.0, $0.1) })
        XCTAssertTrue(payload.contains("What can you do?"))
        XCTAssertTrue(payload.contains("Explain what an API is in one sentence."))
        XCTAssertFalse(payload.contains("weather"), "Grux's capability list reached the title generator")
        XCTAssertFalse(payload.contains("How can I help"), "Grux's greeting reached the title generator")
        XCTAssertFalse(payload.contains("Grux:"), "an assistant turn reached the title generator")
    }

    func test_theTitlePromptAsksForWhatThePersonAskedAbout() {
        XCTAssertTrue(ChatCompactor.titleSystemPrompt.contains("the person"),
                      "the title prompt does not say whose words to name")
    }

    /// The two titles sense pass 31 measured.
    func test_aTitleNamingWhatWasNeverAskedFallsBackToThePersonsOwnLine() {
        XCTAssertEqual(
            ChatTitleHygiene.clean(generated: "weather and task assistant",
                                   userLines: ["hi there", "What can you do?",
                                               "Explain what an API is in one sentence."]),
            "What can you do?")
        XCTAssertEqual(
            ChatTitleHygiene.clean(generated: "whats your name",
                                   userLines: ["hello", "Who are you?", "What should I try first?", "What is Grux?"]),
            "Who are you?")
    }

    func test_aTitleBuiltFromThePersonsWordsIsKept() {
        let cases: [(String, [String])] = [
            ("filament order", ["can you check my filament order", "and the price"]),
            ("API explanation", ["hi", "Explain what an API is in one sentence."]),
            ("coffee poems", ["Write a poem about coffee"]),
            ("weekend trip planning", ["help me plan a trip for the weekend"]),
            ("Grux overview", ["What is Grux?"]),
        ]
        for (title, lines) in cases {
            XCTAssertEqual(ChatTitleHygiene.clean(generated: title, userLines: lines), title,
                           "\(title) was dropped although the person wrote \(lines)")
        }
    }

    /// A title of only small words carries no evidence it is about this chat.
    func test_aTitleOfOnlySmallWordsFallsBack() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "what you can do",
                                              userLines: ["hey", "what can you do for me"]),
                       "What can you do for me")
    }

    /// Greetings are skipped for the fallback; a chat of only greetings keeps
    /// the person's first line, never an invented name.
    func test_theFallbackSkipsGreetingsButNeverInvents() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "friendly greetings",
                                              userLines: ["hi", "hello there"]),
                       "Hi")
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "friendly greetings",
                                              userLines: ["Good morning!", "Thanks", "Is it going to rain"]),
                       "Is it going to rain")
    }

    func test_aStatusCodeTitleIsStillNeverShown() {
        let out = ChatTitleHygiene.clean(generated: "order error 500",
                                         userLines: ["why did my order error 500", "can you look at the order"])
        XCTAssertEqual(out, "Can you look at the order")
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "HTTP 500", userLines: []),
                       ChatTitleHygiene.neutralDefault)
    }

    /// One word, one under, one over the 4-letter stem: "trip" matches
    /// "trips", "plan" matches "planning", a 3-letter word matches only
    /// itself ("api" not "apiary"), and a shared 3-letter prefix is no match.
    func test_theStemRuleAtItsBoundary() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "trips", userLines: ["one trip"]), "trips")
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "planning", userLines: ["plan it"]), "planning")
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "apiary", userLines: ["the api"]), "The api")
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "carpet", userLines: ["my car"]), "My car")
    }

    func test_appStateHandsThePersonsLinesToTheCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AppState.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(t.contains("ChatTitleHygiene.clean(generated: title, userLines: userLines)"),
                      "the generated title is not checked against what the person wrote")
    }
}
