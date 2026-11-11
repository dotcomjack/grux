import XCTest
@testable import Grux

/// D144, live 2026-11-02 9:58 PM on the installed build: an auto compaction
/// started at 9:58:57 PM and its summary took 43 seconds on the local model.
/// Four messages sent in that window ("How's the weather in Paris, TX", "weather
/// in boston", "Is it going to rain today?" with their replies, and "I'm feeling
/// under the weather today") vanished from the thread, on disk and on screen:
/// `compactActiveThread` chose the messages to keep BEFORE the summary call and
/// wrote that list back AFTER it, over everything sent meanwhile.
final class CompactionKeepsLateTurnsTests: XCTestCase {

    private func message(_ role: ChatRole, _ text: String, notice: Bool = false) -> ChatMessage {
        ChatMessage(role: role, content: text, isNotice: notice)
    }

    /// The kept list is what the thread holds once the summary returns, less
    /// exactly the messages the summary folded: every late turn survives.
    func testMessagesSentDuringTheSummaryAreKept() {
        let older = (0..<6).map { message($0 % 2 == 0 ? .user : .assistant, "old \($0)") }
        let notice = message(.assistant, "Something went wrong.", notice: true)
        let recent = (0..<4).map { message($0 % 2 == 0 ? .user : .assistant, "recent \($0)") }
        let late = (0..<5).map { message($0 % 2 == 0 ? .user : .assistant, "late \($0)") }
        let folded = older + [notice]

        let kept = ChatCompactor.kept(afterSummary: folded + recent + late, folded: folded)

        XCTAssertEqual(kept.map(\.content), (recent + late).map(\.content))
    }

    /// A message removed while the summary ran (a cleared thread) is not brought back.
    func testAThreadClearedDuringTheSummaryStaysCleared() {
        let older = (0..<6).map { message(.user, "old \($0)") }
        XCTAssertEqual(ChatCompactor.kept(afterSummary: [], folded: older).count, 0)
        let after = [message(.user, "new")]
        XCTAssertEqual(ChatCompactor.kept(afterSummary: after, folded: older).map(\.content), ["new"])
    }

    /// The call site reads the thread again after the summary and keeps it
    /// through `kept(afterSummary:folded:)`, and writes the visible chat only
    /// when that thread is still the one on screen.
    func testCompactionReReadsTheThreadAfterTheSummary() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AppState.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "func compactActiveThread"))
        let end = try XCTUnwrap(src.range(of: "func isWithinActiveHours", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        let summary = try XCTUnwrap(body.range(of: "await ChatCompactor.summarize("))
        let after = String(body[summary.upperBound...])
        XCTAssertTrue(after.contains("ChatThreadStore.shared.load(id: threadId)"),
                      "the thread must be read again after the summary returns")
        XCTAssertTrue(after.contains("ChatCompactor.kept(afterSummary:"))
        XCTAssertTrue(after.contains("activeThreadId == threadId"),
                      "the visible chat is replaced only while that thread is still the active one")
        XCTAssertFalse(after.contains("messages: keep,"),
                       "the list chosen before the summary must not be written back")
    }
}
