import XCTest
@testable import Grux

final class ChatNoticeExclusionTests: XCTestCase {
    func test_noticeDefaultsFalse_andRoundTrips() throws {
        let plain = ChatMessage(role: .assistant, content: "hello")
        XCTAssertFalse(plain.isNotice)
        let notice = ChatMessage(role: .assistant, content: "\u{26A0}\u{FE0F} The API key was rejected", isNotice: true)
        let data = try JSONEncoder().encode(notice)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertTrue(back.isNotice)
        // Saved before the flag existed: a plain reply stays a real turn, and
        // an old warning-sign bubble becomes a notice on decode.
        let legacyPlain = #"{"id":"11111111-1111-1111-1111-111111111111","role":"assistant","content":"hello","timestamp":0}"#
        XCTAssertFalse(try JSONDecoder().decode(ChatMessage.self, from: legacyPlain.data(using: .utf8)!).isNotice)
        let legacyNotice = #"{"id":"11111111-1111-1111-1111-111111111111","role":"assistant","content":"⚠️ The API key was rejected","timestamp":0}"#
        XCTAssertTrue(try JSONDecoder().decode(ChatMessage.self, from: legacyNotice.data(using: .utf8)!).isNotice)
    }

    func test_noticesNeverReachTheModel() {
        let history = [
            ChatMessage(role: .user, content: "what time is it"),
            ChatMessage(role: .assistant, content: "\u{26A0}\u{FE0F} The API key was rejected (HTTP 401).", isNotice: true),
            ChatMessage(role: .user, content: "and the day"),
        ]
        let wire = ChatService.modelFacingMessages(history)
        XCTAssertEqual(wire.count, 2)
        XCTAssertFalse(wire.contains { ($0["content"] as? String)?.contains("rejected") == true })
    }
}

final class CompactionNoticeExclusionTests: XCTestCase {
    /// The compaction call site filters notices before summarizing. Pinned at
    /// the source because the summarizer needs a live model to run: a thread
    /// summary that carried "UNPROCESSED FAILED SWARM" as something the user
    /// said was measured on 2026-09-20.
    func test_compactionFiltersNoticesBeforeSummarizing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/AppState.swift"), encoding: .utf8)
        let site = try XCTUnwrap(src.range(of: "let toCompact = "))
        let line = src[site.lowerBound...].split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(line.contains(".filter { !$0.isNotice }"), "toCompact must drop notices: \(line)")
    }
}
