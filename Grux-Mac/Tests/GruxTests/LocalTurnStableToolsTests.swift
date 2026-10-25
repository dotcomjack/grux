import XCTest
@testable import Grux

/// A local turn offers the same tools in the same order turn after turn, so
/// Ollama reuses the prompt it already read instead of reading every tool
/// again (LocalTurn.stableHead). Measured 2026-10-24 on a MacBook Pro, the
/// 265 chat turns of held-out v2 on grux-local:4b: 8.54 s a turn at the
/// median with a list ranked per message, about 1.1 s with one list.
@MainActor
final class LocalTurnStableToolsTests: XCTestCase {
    /// A tool another test ran stays recent for fifteen minutes and would
    /// send these turns down the ranked path.
    override func setUp() async throws {
        try await super.setUp()
        RecentToolUse.shared.clear()
    }

    /// A real lean turn. The default window is a 16 GB Mac's, so the turn
    /// block on the Mac running the tests (its tasks, memories, macros) has
    /// room and these turns take the stable path whatever that Mac holds.
    private func lean(_ text: String, window: Int = 16_384) -> ChatService.PendingTurnContext {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: text)]
        return ChatService.shared.assemblePendingContext(state: state, lean: true, window: window)
    }

    private func cutLine(_ p: ChatService.PendingTurnContext) -> String? {
        p.systemBlocks.compactMap { $0["text"] as? String }.first { $0.hasPrefix("TOOLS NOT OFFERED IN THIS LOCAL TURN:") }
    }

    private func tool(_ n: String, _ d: String) -> ClaudeTool { ClaudeTool(name: n, description: d, inputSchema: [:]) }

    private let cached: [[String: Any]] = [
        ["type": "text", "text": String(repeating: "a", count: 6_000), "cache_control": ["type": "ephemeral"]],
        ["type": "text", "text": "NOW: Monday"],
    ]

    private func stable(_ text: String, ranked: [ClaudeTool]? = nil, hasImage: Bool = false,
                        recent: [String] = [], contextWindow: Int = 16_384) -> [ClaudeTool]? {
        // The tools ToolRelevance keeps for this message, as assemblePendingContext passes them.
        let kept = ToolRelevance.filter(ChatService.allTools(), signals: .init(utterance: text))
        return ChatService.stableLocalTools(systemBlocks: cached, messages: [["role": "user", "content": text]],
                                            ranked: ranked ?? kept, utterance: text, hasImage: hasImage,
                                            recentToolNames: recent, presetApp: nil, sizingWindow: 8_192,
                                            contextWindow: contextWindow)
    }

    func test_everydayMessagesGetTheSameToolsAndTheSameCutLine() {
        let a = lean("what is on my plate today?")
        let b = lean("add a task to call the dentist tomorrow")
        let c = lean("what's the tallest mountain in Africa")
        XCTAssertFalse(a.tools.isEmpty)
        XCTAssertEqual(a.tools.map(\.name), b.tools.map(\.name), "two everyday messages got different tools, so Ollama reads them all again")
        XCTAssertEqual(a.tools.map(\.name), c.tools.map(\.name))
        XCTAssertEqual(Array(a.tools.map(\.name).prefix(LocalTurn.stableHead.count)), LocalTurn.stableHead,
                       "the stable list does not lead with its head")
        XCTAssertNotNil(cutLine(a), "nothing was cut, so the cut line checks nothing")
        XCTAssertEqual(cutLine(a), cutLine(b), "the cut line changes with the message, so it is read again every turn")
    }

    func test_messageLengthDoesNotChangeTheList() {
        let short = lean("add a task to buy milk").tools.map(\.name)
        let longer = lean("add a task to buy milk" + String(repeating: " and bread", count: 40)).tools.map(\.name)
        XCTAssertEqual(short, longer)
    }

    /// Either path, a local turn fits an 8 GB Mac's window.
    func test_aLocalTurnStillFitsAnEightGigabyteWindow() {
        let p = lean("add a task to buy milk", window: 8_192)
        let prompt = LocalTurn.tokens(chars: p.systemBlocks.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count })
            + p.messages.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
            + p.tools.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
        XCTAssertLessThanOrEqual(prompt + p.maxTokens, 8_192)
    }

    func test_stableOrderLeadsWithTheHeadThenKeepsTheUsualOrder() {
        let tools = [tool("zeta", "z"), tool("add_task", "a"), tool("alpha", "a"), tool("list_tasks", "l")]
        XCTAssertEqual(LocalTurn.stableOrder(tools).map(\.name), ["list_tasks", "add_task", "zeta", "alpha"])
    }

    func test_pointsPastNeedsAStrongMatchOutsideTheList() {
        let inside = [tool("list_tasks", "List the tasks"), tool("add_task", "Add a task")]
        // A core-group name, so only the three-word rule applies (group tools: the next test).
        let all = inside + [tool("transcript_fetcher", "Fetch the transcript of a youtube video")]
        XCTAssertEqual(ToolRelevance.group(for: "transcript_fetcher"), .core)
        XCTAssertTrue(LocalTurn.pointsPast(inside, candidates: all, utterance: "fetch the transcript of this youtube video"))
        XCTAssertFalse(LocalTurn.pointsPast(inside, candidates: all, utterance: "add a task to watch a youtube video"),
                       "two words is not a strong match")
        XCTAssertFalse(LocalTurn.pointsPast(inside, candidates: all, utterance: "what is on my plate"))
    }

    func test_aShortAskForAGroupToolPointsPast() {
        let inside = [tool("list_tasks", "List the tasks"), tool("get_current_activity", "Read what is on the screen now")]
        let meeting = tool("start_meeting_capture", "Start capturing a meeting recording")
        let screen = tool("read_screen", "Read the screen")
        XCTAssertNotEqual(ToolRelevance.group(for: meeting.name), .core, "the test tool is not in a group")
        XCTAssertTrue(LocalTurn.pointsPast(inside, candidates: inside + [meeting], utterance: "record a meeting"))
        XCTAssertTrue(LocalTurn.pointsPast(inside, candidates: inside + [screen], utterance: "read my screen"),
                      "a tie with a tool on the list goes to the group's tool")
        XCTAssertFalse(LocalTurn.pointsPast(inside, candidates: inside + [tool("create_note", "Write a note")],
                                            utterance: "write a note"),
                       "control: a core tool needs three words")
    }

    func test_aMessageThatPointsPastTheListKeepsTheRankedList() {
        // Core tools only, so the outside tool is the one thing that can point past the list.
        let core = ChatService.allTools().filter { ToolRelevance.group(for: $0.name) == .core }
        let outside = tool("zz_transcript_fetcher", "Fetch the transcript of a youtube video")
        XCTAssertNotNil(stable("fetch the transcript of this youtube video", ranked: core),
                        "control: without the outside tool nothing points past the list")
        XCTAssertNil(stable("fetch the transcript of this youtube video", ranked: core + [outside]))
        XCTAssertNotNil(stable("add a task to buy milk", ranked: core + [outside]), "control")
    }

    func test_aRecentToolOffTheListKeepsTheRankedList() {
        let list = stable("add a task to buy milk")
        XCTAssertNotNil(list, "control")
        let offList = ChatService.allTools().map(\.name).first { name in !(list ?? []).contains { $0.name == name } }
        XCTAssertNotNil(offList, "every tool is on the list, so this checks nothing")
        XCTAssertNil(stable("add a task to buy milk", recent: [offList ?? ""]), "a loop lost the tool it was using")
        XCTAssertNotNil(stable("add a task to buy milk", recent: ["list_tasks"]))
    }

    func test_anImageTurnKeepsTheRankedList() {
        XCTAssertNil(stable("what is this?", hasImage: true))
        XCTAssertNotNil(stable("what is this?"), "control")
    }

    func test_aLargeTurnBlockKeepsTheRankedListOnEightGigabytesOnly() {
        let big: [[String: Any]] = [cached[0], ["type": "text", "text": String(repeating: "m", count: 12_000)]]
        let text = "add a task to buy milk"
        let kept = ToolRelevance.filter(ChatService.allTools(), signals: .init(utterance: text))
        func attempt(_ contextWindow: Int) -> [ClaudeTool]? {
            ChatService.stableLocalTools(systemBlocks: big, messages: [["role": "user", "content": text]], ranked: kept,
                                         utterance: text, hasImage: false, recentToolNames: [], presetApp: nil,
                                         sizingWindow: 8_192, contextWindow: contextWindow)
        }
        XCTAssertNil(attempt(8_192), "an 8 GB window took a turn that does not fit it")
        XCTAssertNotNil(attempt(16_384), "control: a 16 GB window holds it")
        XCTAssertEqual(attempt(16_384)?.map(\.name), stable(text)?.map(\.name),
                       "a long turn block changed the list, so Ollama reads the tools again")
    }

    func test_aTurnThatWouldNotFitItsWindowKeepsTheRankedList() {
        let huge = String(repeating: "word ", count: 8_000)
        XCTAssertNil(stable(huge, contextWindow: 8_192))
        XCTAssertNotNil(stable("add a task to buy milk", contextWindow: 8_192), "control")
    }
}

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// Ollama unloads a model after 5 idle minutes by default, and with it the
/// prompt it already read, so the next two turns are cold again. A server on
/// this Mac keeps the model for LocalTurn.keepAlive, and Grux lets go itself on
/// critical memory pressure and on quit.
final class LocalModelKeepAliveTests: XCTestCase {
    func test_onlyAServerOnThisMacIsAskedToKeepTheModel() {
        let local = OpenAICompatBackend.ollamaChatBody(["model": "m", "messages": []], stream: false, contextTokens: 8_192)
        XCTAssertEqual(local["keep_alive"] as? String, LocalTurn.keepAlive)
        let remote = OpenAICompatBackend.ollamaChatBody(["model": "m", "messages": []], stream: false, contextTokens: nil)
        XCTAssertNil(remote["keep_alive"], "a server elsewhere was told how long to hold a model")
    }

    func test_onlyModelsGruxAskedToKeepAreUnloaded() {
        _ = LocalModelUnload.takeRequests()
        XCTAssertTrue(LocalModelUnload.takeRequests().isEmpty, "nothing was kept, so nothing may be unloaded")
        LocalModelUnload.noteKept(baseURL: "http://127.0.0.1:11434", model: "grux-local:4b")
        LocalModelUnload.noteKept(baseURL: "http://127.0.0.1:11434", model: "grux-local:4b")
        LocalModelUnload.noteKept(baseURL: "http://studio.local:11434", model: "other")
        let reqs = LocalModelUnload.takeRequests()
        XCTAssertEqual(reqs.count, 1, "one model on this Mac was kept; a server elsewhere is never unloaded")
        XCTAssertTrue(LocalModelUnload.takeRequests().isEmpty, "an unloaded model was unloaded again")
    }

    func test_theUnloadCallIsOllamasAndLocalOnly() throws {
        let req = try XCTUnwrap(LocalModelUnload.request(baseURL: "http://127.0.0.1:11434/", model: "grux-local:4b"))
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "grux-local:4b")
        XCTAssertEqual(body["keep_alive"] as? Int, 0)
        XCTAssertNil(LocalModelUnload.request(baseURL: "http://studio.local:11434", model: "m"), "a server elsewhere was unloaded")
        XCTAssertNil(LocalModelUnload.request(baseURL: "http://localhost:11434", model: ""))
    }

    func test_criticalMemoryAndQuitUnloadTheModel() throws {
        XCTAssertTrue(try macSource("Sources/Grux/MachineLoad.swift").contains("if pressure == .critical { LocalModelUnload.unload() }"))
        XCTAssertTrue(try macSource("Sources/Grux/GruxApp.swift").contains("LocalModelUnload.unloadBeforeQuit()"))
    }
}
