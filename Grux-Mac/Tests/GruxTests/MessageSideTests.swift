import XCTest
@testable import Grux

/// A SYSTEM MESSAGE NEVER RENDERS AS THE PERSON, AND NEVER AS GRUX EITHER.
///
/// System messages are the app reporting something that happened: a meeting
/// saved, an audio recording recovered. They are appended from five places in
/// the tree. Labelling them GRUX put words in Grux's mouth; putting them on
/// the person's side would be worse.
final class MessageSideTests: XCTestCase {

    func test_everyRoleHasItsOwnSide() {
        XCTAssertEqual(MessageBubble.side(for: .user), .person)
        XCTAssertEqual(MessageBubble.side(for: .assistant), .grux)
        XCTAssertEqual(MessageBubble.side(for: .system), .system)
    }

    func test_onlyThePersonIsOnThePersonsSide() {
        for role in [ChatRole.assistant, .system] {
            XCTAssertNotEqual(MessageBubble.side(for: role), .person,
                              "\(role) renders as the person")
        }
    }

    func test_everySideHasItsOwnLabel() {
        let labels = [ChatRole.user, .assistant, .system].map { MessageBubble.label(for: $0, assistantName: "Jax") }
        XCTAssertEqual(Set(labels).count, 3, "two roles share a label: \(labels)")
        XCTAssertEqual(MessageBubble.label(for: .user, assistantName: "Jax"), "YOU")
        XCTAssertEqual(MessageBubble.label(for: .assistant, assistantName: "Jax"), "JAX")
    }

    /// D189 leftover: the bubble said GRUX over a reply that said "I'm Jax"
    /// (sense pass 25, `chat-page1.png`). The bubble names whoever the model is
    /// told it is (`AboutYou`: "Your name is Jax. The app is Grux AI."), so the
    /// two can never disagree.
    func test_theBubbleNamesTheAssistantTheReplyNames() {
        XCTAssertEqual(MessageBubble.label(for: .assistant, assistantName: "Jax"), "JAX")
        XCTAssertEqual(MessageBubble.label(for: .assistant, assistantName: "  Ada "), "ADA")
        XCTAssertEqual(MessageBubble.label(for: .user, assistantName: "Ada"), "YOU")
        XCTAssertEqual(MessageBubble.label(for: .system, assistantName: "Ada"), "NOTICE")
    }

    /// A name that is blank, or that reads as another side's label, never lets
    /// the assistant's bubble pass for the person or a notice.
    func test_aNameThatWouldPassForAnotherSideReadsGrux() {
        for name in ["", "   ", "you", "You", "notice", " NOTICE "] {
            XCTAssertEqual(MessageBubble.label(for: .assistant, assistantName: name), "GRUX", "name \"\(name)\"")
        }
        XCTAssertEqual(MessageBubble.label(for: .assistant, assistantName: "Yours"), "YOURS")
    }

    func test_aSystemMessageIsNotLabelledAsGrux() {
        for name in ["Jax", "", "Notice"] {
            XCTAssertNotEqual(MessageBubble.label(for: .system, assistantName: name),
                              MessageBubble.label(for: .assistant, assistantName: name),
                              "a system notice is labelled as the assistant speaking")
        }
        XCTAssertNotEqual(MessageBubble.label(for: .system, assistantName: "Jax"), MessageBubble.label(for: .user, assistantName: "Jax"))
    }

    /// The rule rots the moment one branch in the view asks the question its
    /// own way, so no branch is allowed to.
    func test_noBranchInTheBubbleAsksTheQuestionItsOwnWay() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "ChatView did not load")
        let bubble = try XCTUnwrap(text.range(of: "struct MessageBubble: View {"))
        let body = String(text[bubble.lowerBound...])
        XCTAssertFalse(body.contains("message.role == .user"),
                       "a branch in MessageBubble decides sidedness on its own again")
        XCTAssertFalse(body.contains("message.role != .user"),
                       "a branch in MessageBubble decides sidedness on its own again")
    }
}

/// Chat leads with the conversation. The task stack has its own tab.
final class ChatHeaderTests: XCTestCase {
    private func chatView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "ChatView did not load")
        return t
    }

    func test_theHeaderNamesTheConversationRatherThanTheTaskStack() throws {
        let t = try chatView()
        XCTAssertFalse(t.contains("Text(\"CURRENT TASK\")"),
                       "Chat still leads with the task stack, which has its own tab")
        XCTAssertFalse(t.contains("No current task. Ask me what to work on."),
                       "the task empty state is still on the face of Chat")
        XCTAssertTrue(t.contains("Text(activeThreadTitle)"),
                      "the header no longer names the thread")
    }

    /// An untitled thread must read the same word in the header and in the
    /// rail, which is why both take it from one place.
    func test_anUntitledThreadFallsBackToTheSameWordEverywhere() throws {
        let t = try chatView()
        XCTAssertTrue(t.contains("return ChatTitleHygiene.neutralDefault"),
                      "the header invents its own name for an untitled thread")
    }
}
