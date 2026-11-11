import XCTest
@testable import Grux

/// D183, live 2026-11-07 12:26 AM on grux-local:2b (sense pass 23): "Rewrite
/// this to sound friendlier: Send me the report by 5." came back "I can send
/// that to you by 5.": the model answered the person's own text as a request to
/// it. D174 made Grux keep a summary, rewrite or translation of pasted text,
/// but the turn itself told the model nothing, and offered it nine tools.
///
/// A local turn that transforms text the person put in the message carries one
/// line saying the text is theirs to change, not a request, and offers no tool,
/// as a draft (D159) and a list (D175) do. Asks that name the person's own
/// things, or ask Grux to keep or send the result too, keep their tools.
@MainActor
final class PastedTextLocalTurnTests: XCTestCase {

    private let material = "The meeting moved to Thursday because two people were out sick, and the budget review now happens first."

    private var transforms: [String] {
        [
            "Rewrite this to sound friendlier: Send me the report by 5.",
            "Summarize this in one sentence: " + material,
            "Can you please shorten this for me: " + material,
            "Translate this into French: The order has been shipped and the invoice is now updated.",
            "Paraphrase the following:\n" + material,
            material + "\n\nSummarize this in one line.",
            "Translate \"your table has been booked for eight\" into Spanish",
            "Proofread this: Your order has shipped and we've sent the tracking number.",
        ]
    }

    private var others: [String] {
        [
            "Summarize my meeting with Sam",
            "Summarize this and save it to my notes: " + material,
            "Translate this and send it to Maria: " + material,
            "Rewrite: hi there",
            "Summarize my inbox: what's new?",
            "Move my meeting to Thursday",
        ]
    }

    func testTheLineSaysTheTextIsTheirsToChange() throws {
        for ask in transforms {
            let note = try XCTUnwrap(DraftAsk.pastedTextNote(ask: ask), ask)
            XCTAssertTrue(note.hasPrefix("TEXT: "), note)
            XCTAssertTrue(note.contains("not a request to you"), note)
            XCTAssertTrue(note.contains("only the result"), note)
        }
        for ask in others { XCTAssertNil(DraftAsk.pastedTextNote(ask: ask), ask) }
    }

    /// The live turn offered 9 tools; a pasted-text turn offers none and carries
    /// the line. The other asks keep their tools, and a cloud turn is unchanged.
    func testALocalPastedTextTurnCarriesTheLineAndNoTool() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        func turn(_ lean: Bool, _ ask: String) -> (text: String, tools: Set<String>) {
            state.chat = [ChatMessage(role: .user, content: ask)]
            let p = ChatService.shared.assemblePendingContext(state: state, lean: lean, window: 16_384)
            return (p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n"),
                    Set(p.tools.map(\.name)))
        }
        for ask in transforms {
            let local = turn(true, ask)
            XCTAssertTrue(local.text.contains("TEXT: "), "the local turn was not told: \(ask)")
            XCTAssertTrue(local.tools.isEmpty, "\(ask) offered \(local.tools.sorted())")
            let cloud = turn(false, ask)
            XCTAssertFalse(cloud.text.contains("TEXT: "), "a cloud turn carries it: \(ask)")
            XCTAssertFalse(cloud.tools.isEmpty, "a cloud turn lost its tools: \(ask)")
        }
        for ask in others {
            let local = turn(true, ask)
            XCTAssertFalse(local.text.contains("TEXT: "), ask)
        }
        // The asks that keep or send the result keep the tools that do it.
        XCTAssertFalse(turn(true, "Summarize this and save it to my notes: " + material).tools.isEmpty)
        // A draft keeps its own line, never both.
        let draft = turn(true, "Write a short email to my landlord saying the kitchen sink is leaking.")
        XCTAssertTrue(draft.text.contains("DRAFT: "))
        XCTAssertFalse(draft.text.contains("TEXT: "))
    }
}
