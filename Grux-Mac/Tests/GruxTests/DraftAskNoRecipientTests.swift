import XCTest
@testable import Grux

/// D167, sense pass 21, live 6:59 AM Nov 5 on grux-local:2b: "Write a short,
/// polite reply declining a meeting on Friday" came back "I can't send meeting
/// invitations directly. I can draft the email for you to review, ..." with 9
/// tools offered. The ask names no recipient, so the "to <person>" grammar never
/// read it as a draft. A message whose kind is followed straight away by what it
/// says ("declining", "saying", "about") is a draft too; a note, a message for a
/// thing, or one that names a message that exists keeps its tools.
@MainActor
final class DraftAskNoRecipientTests: XCTestCase {

    static let drafts = [
        "Write a short, polite reply declining a meeting on Friday",
        "write an email declining the invite",
        "Draft a message saying I'll be late",
        "Write me a quick reply accepting the offer",
        "compose an email asking for a refund",
        "write a polite email thanking the host",
        "Can you write a letter about the noise upstairs?",
        "Grux, write a reply that says yes",
        "please draft a response apologizing for the delay",
        "write a text letting her know I landed",
    ]

    static let notDrafts = [
        // A note to keep, never a message.
        "Write a note about groceries", "write a note saying buy milk",
        // A message for a thing, not a person.
        "write a message for the commit", "write a text for my website",
        // Replying to a message that exists needs the tool that reads it.
        "Write a reply declining the email from Sam", "write a reply about Sarah's text",
        // Also wants something saved or sent.
        "write an email declining the invite and add it to my calendar",
        "Draft a message saying I'm sick, then send it to my boss",
        // All capitals, no content word, or no message at all.
        "WRITE AN EMAIL DECLINING THE INVITE", "Write a short email", "write a reply",
        "write a poem about the sea", "write the Q3 report about sales",
        "Remind me to write an email declining the invite",
    ]

    func testAMessageWithWhatItSaysAndNoRecipientIsADraft() {
        for ask in Self.drafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
        for ask in Self.notDrafts { XCTAssertFalse(DraftAsk.matches(ask), ask) }
        // The asks to a person still read as before.
        for ask in DraftAskTests.drafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
        for ask in DraftAskTests.notDrafts { XCTAssertFalse(DraftAsk.matches(ask), ask) }
    }

    /// The live turn: the local model is told to write it now and offered no tool.
    func testTheLiveAskIsToldToWriteItAndOffersNoTool() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: Self.drafts[0])]
        let p = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 16_384)
        let text = p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        XCTAssertTrue(text.contains("DRAFT: "), "the local turn was not told")
        XCTAssertTrue(p.tools.isEmpty, "offered \(p.tools.map(\.name).sorted())")
    }

    /// Live after the first fix (7:27 AM, 0 tools, the DRAFT line in the turn):
    /// grux-local:2b still answered "I can draft that message for you." Measured
    /// on the dumped wire (`logs/d167/probe-*.txt`): the line alone drafted 5 of
    /// 8, a reply that opens with the greeting already written drafted 6 of 6 and
    /// 3 of 3. So a local draft turn ends with the greeting as the start of the
    /// reply, marked so only a server that continues it receives it.
    func testALocalDraftTurnEndsWithTheGreetingItContinues() throws {
        XCTAssertEqual(DraftAsk.greeting(ask: Self.drafts[0]), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a short email to Sarah about lunch tomorrow"), "Hi Sarah,")
        XCTAssertEqual(DraftAsk.greeting(ask: "Could you write a letter to the editor about the bike lanes"), "Dear [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Draft a quick note to my boss that I'll be late tomorrow."), "Hi [Name],")
        for ask in Self.notDrafts + DraftAskTests.notDrafts { XCTAssertNil(DraftAsk.greeting(ask: ask), ask) }

        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: Self.drafts[0])]
        let local = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 16_384)
        let last = try XCTUnwrap(local.messages.last)
        XCTAssertEqual(last["role"] as? String, "assistant")
        XCTAssertEqual(last["content"] as? String, "Hi [Name],")
        XCTAssertEqual(last[DraftAsk.prefillKey] as? Bool, true)
        let cloud = ChatService.shared.assemblePendingContext(state: state, lean: false, window: 16_384)
        XCTAssertEqual(cloud.messages.last?["role"] as? String, "user", "a cloud turn carries the greeting")
    }

    /// Only an Ollama server, which continues a trailing assistant message, gets
    /// the greeting, and the reply then starts with it; any other server and the
    /// Claude API never see it.
    func testOnlyAServerThatContinuesItReceivesTheGreeting() {
        let user: [String: Any] = ["role": "user", "content": "Write a short, polite reply declining a meeting on Friday"]
        let pre: [String: Any] = ["role": "assistant", "content": "Hi [Name],", DraftAsk.prefillKey: true]
        let ollama = OpenAICompatBackend.prefilled([user, pre], ollama: true)
        XCTAssertEqual(ollama.prefix, "Hi [Name],")
        XCTAssertEqual(ollama.messages.count, 2)
        XCTAssertEqual(ollama.messages.last?["role"] as? String, "assistant")
        XCTAssertNil(ollama.messages.last?[DraftAsk.prefillKey], "the marker reached the wire")
        let other = OpenAICompatBackend.prefilled([user, pre], ollama: false)
        XCTAssertNil(other.prefix)
        XCTAssertEqual(other.messages.count, 1)
        XCTAssertEqual(other.messages.last?["role"] as? String, "user")
        let plain = OpenAICompatBackend.prefilled([user], ollama: true)
        XCTAssertNil(plain.prefix)
        XCTAssertEqual(plain.messages.count, 1)
        let laterHop = OpenAICompatBackend.prefilled([user, pre, ["role": "assistant", "content": "Hi [Name], no."]], ollama: true)
        XCTAssertNil(laterHop.prefix)
        XCTAssertEqual(laterHop.messages.count, 2, "a greeting from an earlier hop reached the wire")
        XCTAssertEqual(DraftAsk.withoutPrefill([user, pre]).count, 1)
        XCTAssertEqual(DraftAsk.withoutPrefill([user]).count, 1)
        // The Claude API never receives the marked greeting.
        XCTAssertEqual(ChatService.wireMessages([user, pre], for: ClaudeClient()).count, 1)
        XCTAssertEqual(ChatService.wireMessages([user, pre], for: OpenAICompatBackend(baseURL: "http://127.0.0.1:11434/v1")).count, 2)
    }
}
