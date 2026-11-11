import XCTest
@testable import Grux

// D137: chat read Grux's own earlier replies back as memories. A made-up
// "I've noted your grocery run for tomorrow." came back on later turns as
// `[grux · Sep 27, 18:53] ...` under RELEVANT_MEMORIES, and the model
// repeated it as the person's plan. Retrieval for a chat turn reads what the
// person said, saw, heard and saved, never what Grux said; the thread's own
// messages already carry this conversation's replies.
final class ChatMemoryLeavesOutGruxRepliesTests: XCTestCase {

    func test_chatContextLeavesOutGruxsOwnReplies() {
        XCTAssertFalse(ChatService.chatContextMemoryKinds.contains(.chatAssistant),
                       "a chat turn must not read Grux's earlier replies back as memories")
    }

    func test_chatContextStillLeavesOutPastCommands() {
        XCTAssertFalse(ChatService.chatContextMemoryKinds.contains(.chatUser),
                       "past prompts replay as fresh commands")
    }

    func test_chatContextKeepsThePersonsOwnData() {
        let kept: Set<SemanticMemoryKind> = [.corpus, .ambient, .focus, .fact, .web]
        XCTAssertEqual(ChatService.chatContextMemoryKinds, kept)
    }

    /// The class: every retrieval in ChatService reads the one set, so a new
    /// call site cannot bring Grux's replies back with a literal list.
    func test_everyChatRetrievalReadsTheOneSet() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        var sites = 0
        for (i, line) in lines.enumerated() where line.contains("HybridRetriever.shared") {
            sites += 1
            let window = lines[i..<min(i + 4, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("chatContextMemoryKinds"),
                          "ChatService.swift:\(i + 1) retrieves memories without chatContextMemoryKinds")
        }
        XCTAssertGreaterThanOrEqual(sites, 2)
        XCTAssertFalse(source.contains(".chatAssistant, .ambient"),
                       "a literal memory kind list in ChatService")
    }
}
