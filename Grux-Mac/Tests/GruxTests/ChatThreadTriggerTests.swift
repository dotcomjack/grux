import XCTest
@testable import Grux

/// D186: every sense pass's stranger turns ran in one thread holding 90 older
/// turns, and Grux Local 2B copied its own earlier answers from it word for
/// word (7:08 AM Nov 7: the fixed prompt, the 6:36 AM replies). A stranger's
/// first chat has no history, and nothing but a click started one, so
/// `fire-chat-thread` does what New chat does ("new") or what picking a thread
/// does (its id), then writes `chat-status.json` with the thread now open.
@MainActor
final class ChatThreadTriggerTests: XCTestCase {
    private var savedThread: UUID?
    private var savedChat: [ChatMessage] = []
    private var made: [UUID] = []

    override func setUp() async throws {
        savedThread = AppState.shared.activeThreadId
        savedChat = AppState.shared.chat
    }

    override func tearDown() async throws {
        if let savedThread { AppState.shared.switchThread(savedThread) }
        AppState.shared.chat = savedChat
        for id in made { ChatThreadStore.shared.delete(id: id) }
        AppState.shared.refreshThreads()
    }

    private func fire(_ contents: String) throws -> [String: Any] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-thread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = TriggerWatcher(directory: dir)
        ChatTriggers.register(in: dir, on: watcher)
        try contents.write(to: dir.appendingPathComponent(ChatTriggers.thread), atomically: true, encoding: .utf8)
        watcher.sweepNow()
        let status = dir.appendingPathComponent(ChatTriggers.statusFile)
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: status.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let data = try Data(contentsOf: status)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_newStartsAnEmptyThreadAndSwitchingBackRestoresTheOldOne() throws {
        let old = ChatThreadStore.shared.create(title: "older")
        made.append(old.id)
        AppState.shared.switchThread(old.id)
        AppState.shared.chat = [ChatMessage(role: .user, content: "an older ask")]

        let fresh = try fire("new")
        let id = try XCTUnwrap(AppState.shared.activeThreadId)
        made.append(id)
        XCTAssertNotEqual(id, old.id, "no new thread was started")
        XCTAssertTrue(AppState.shared.chat.isEmpty, "the new thread carries the old history")
        XCTAssertEqual(fresh["activeThreadId"] as? String, id.uuidString)

        let back = try fire(old.id.uuidString)
        XCTAssertEqual(AppState.shared.activeThreadId, old.id)
        XCTAssertEqual(back["activeThreadId"] as? String, old.id.uuidString)
    }

    func test_anUnknownOrMalformedThreadChangesNothing() throws {
        let before = AppState.shared.activeThreadId
        for bad in ["", "old", UUID().uuidString] {
            _ = try fire(bad)
            XCTAssertEqual(AppState.shared.activeThreadId, before, "\"\(bad)\" moved the open thread")
        }
    }
}
