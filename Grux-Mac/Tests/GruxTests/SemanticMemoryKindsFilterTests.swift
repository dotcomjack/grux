import XCTest
@testable import Grux

// Regression test for the "Grux randomly replays past music commands" bug.
//
// The bug: SemanticMemory was retrieving past `.chatUser` turns (e.g.
// "play Lose Yourself by Eminem") into the system prompt under
// RELEVANT_MEMORIES. On a later, unrelated turn Claude would see that
// retrieved past command and re-fire play_music_track, even though the
// song had already been handled in its original turn.
//
// The fix: retrieve + retrievedAsSystemBlock gained a `kinds` filter,
// and ChatService now passes a set that EXCLUDES `.chatUser`. Past user
// prompts can still inform embeddings internally, but they no longer
// surface back into the prompt as if they were fresh commands.
@MainActor
final class SemanticMemoryKindsFilterTests: XCTestCase {

    func test_retrieve_honorsKindsFilter_excludingChatUser() throws {
        let mem = SemanticMemory.shared
        guard mem.isReady else {
            throw XCTSkip("NLEmbedding unavailable in this test environment")
        }

        let beacon = "play Lose Yourself by Eminem please"
        mem.store(kind: .chatUser, text: beacon)
        mem.store(kind: .fact, text: "The user prefers dark mode.")

        // Retrieval that excludes chatUser MUST NOT surface the past
        // command even when the query is an exact match.
        let safeKinds: Set<SemanticMemoryKind> = [.chatAssistant, .ambient, .focus, .fact, .web]
        let safe = mem.retrieve(query: beacon, topK: 10, kinds: safeKinds)
        XCTAssertFalse(safe.contains(where: { $0.text == beacon }),
                       "chatUser entries must not surface when excluded from the kinds filter")

        // Sanity: without the filter, the beacon IS retrievable, proves
        // the entry was stored and the filter is doing the work.
        let unfiltered = mem.retrieve(query: beacon, topK: 10)
        XCTAssertTrue(unfiltered.contains(where: { $0.text == beacon }),
                      "beacon should still be retrievable when no kinds filter is applied")
    }

    func test_retrievedAsSystemBlock_honorsKindsFilter() throws {
        let mem = SemanticMemory.shared
        guard mem.isReady else {
            throw XCTSkip("NLEmbedding unavailable in this test environment")
        }

        // Use a UUID marker unique to this test run so the assertion is
        // isolated from whatever real chatAssistant history exists on disk.
        // If the kinds filter is working, the marker stays out of the block.
        // If it regresses and chatUser bleeds through, the marker appears.
        let uniqueMarker = UUID().uuidString
        let beacon = "play Lose Yourself by Eminem please \(uniqueMarker)"
        mem.store(kind: .chatUser, text: beacon)

        let safeKinds: Set<SemanticMemoryKind> = [.chatAssistant, .ambient, .focus, .fact, .web]
        let block = mem.retrievedAsSystemBlock(query: beacon, topK: 6, kinds: safeKinds)

        if let block = block {
            XCTAssertFalse(block.contains(uniqueMarker),
                           "RELEVANT_MEMORIES block must not contain past chatUser commands when kinds excludes .chatUser")
        }
        // nil is also an acceptable outcome (means nothing else matched).
    }
}
