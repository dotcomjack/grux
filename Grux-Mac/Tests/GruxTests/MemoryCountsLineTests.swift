import XCTest
@testable import Grux

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// D200 items 17 and 2 (sense pass 28): Persistent memory read "0 chats" before
/// the memory was read; Integrations, Webhooks named a development step.
final class MemoryCountsLineTests: XCTestCase {

    func testNoCountsBeforeTheMemoryIsRead() {
        XCTAssertNil(MemoryCountsLine.stats(nil))
    }

    func testReadCountsAreShownAndAnEmptyMemoryReadsZero() throws {
        let read = try XCTUnwrap(MemoryCountsLine.stats([.chatUser: 900, .chatAssistant: 903, .web: 2, .corpus: 50]))
        XCTAssertEqual(read.map(\.label), ["chats", "ambient", "focus", "web"])
        XCTAssertEqual(read.map(\.count), [1803, 0, 0, 2])
        XCTAssertEqual(try XCTUnwrap(MemoryCountsLine.stats([:])).map(\.count), [0, 0, 0, 0])
    }

    /// The pane holds no counts until they are read, says so meanwhile, and
    /// says so plainly if the read outlasts the wait.
    func testSettingsWaitsForTheRead() throws {
        let s = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(s.contains("@State private var memoryCounts: [SemanticMemoryKind: Int]? = nil"))
        XCTAssertFalse(s.contains("memoryCounts[."), "a count read before the memory is read shows 0")
        XCTAssertTrue(s.contains("MemoryCountsLine.stats(memoryCounts)"))
        XCTAssertTrue(s.contains("MemoryCountsLine.counting"))
        XCTAssertTrue(s.contains("MemoryCountsLine.notRead"))
        // W69-FIX round 1 P3: a pane reopened after a timeout counts again.
        XCTAssertTrue(s.contains(".task {\n                            memoryCountsTimedOut = false\n                            let counts = await SemanticMemory.shared.countsWhenLoaded"))
    }

    func testWebhooksCaptionNamesNoDevelopmentStep() throws {
        let s = try macSource("Sources/Grux/Webhooks/WebhooksView.swift")
        XCTAssertFalse(s.contains("design pass"))
        XCTAssertFalse(s.contains("deferred"))
        XCTAssertFalse(s.contains("Grux does not receive webhooks."), "false with the Digest inbox on (W69-FIX round 1)")
        XCTAssertTrue(s.contains("Nothing here receives calls from outside; the Digest inbox switch in Settings is the one listener for another service's pushes, and it is off unless you turn it on."))
    }
}
