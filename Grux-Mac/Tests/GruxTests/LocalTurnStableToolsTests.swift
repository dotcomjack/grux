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
        // Red proof 2026-10-25: 400 characters never cross the 2,000 character
        // sizing step, so sizing by the message passed the check above. These
        // two differ by 2,600 characters.
        let shortList = stable("add a task to buy milk")?.map(\.name)
        let longList = stable("add a task to buy milk" + String(repeating: " and bread", count: 260))?.map(\.name)
        XCTAssertNotNil(shortList)
        XCTAssertEqual(shortList, longList, "the message's length changed the list")
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

    /// Measured 2026-10-25: "with" and "about" sent two everyday asks down the
    /// ranked path, and a research tool that only tied complete_task did too.
    func test_fillerWordsAndATieWithAnEverydayToolStayOnTheList() {
        let complete = tool("complete_task", "Mark a task complete")
        let inside = [tool("list_tasks", "List the tasks"), complete]
        let reports = tool("list_research_reports", "List research reports, complete with sources")
        XCTAssertNotEqual(ToolRelevance.group(for: reports.name), .core)
        XCTAssertFalse(LocalTurn.pointsPast(inside, candidates: inside + [reports],
                                            utterance: "done with the expense report, mark it complete"),
                       "a filler word or a tie with complete_task sent an everyday ask to the ranked list")
        let log = tool("read_workday_log", "Read the workday log, about each task, complete or not")
        XCTAssertFalse(LocalTurn.pointsPast(inside, candidates: inside + [log],
                                            utterance: "complete the task about the watercolor class"),
                       "\"about\" counted toward pointing past the list")
        XCTAssertTrue(LocalTurn.fillerWords.contains("with") && LocalTurn.fillerWords.contains("about"))
    }

    /// Review round 7: "make" and "know" are in real group tools' descriptions.
    func test_intentVerbsStillPointPast() {
        let inside = [tool("list_tasks", "List the tasks"), tool("add_task", "Add a task")]
        let folder = tool("create_folder", "Make a folder for meeting captures")
        XCTAssertNotEqual(ToolRelevance.group(for: folder.name), .core)
        XCTAssertTrue(LocalTurn.pointsPast(inside, candidates: inside + [folder], utterance: "make a folder for client notes"),
                      "\"make\" was dropped as filler, so the folder tool was cut")
        for verb in ["make", "know", "tell", "want", "need"] {
            XCTAssertFalse(LocalTurn.fillerWords.contains(verb), "\(verb) is an intent word, not filler")
        }
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

/// Ollama's saved prompt readings grow the local model to about 13 GB on a
/// 16 GB Mac; after an idle spell Grux resets it and warms the stable prefix.
@MainActor
final class LocalModelResetTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        RecentToolUse.shared.clear()
    }

    func test_theCeilingIsTheModelPlusATenthOfMemory() {
        let gb: Int64 = 1_000_000_000
        let model = 4_350_000_000 as Int64, sixteen = 17_179_869_184 as Int64, eight = 8_589_934_592 as Int64
        XCTAssertTrue(LocalModelReset.shouldReset(reportedBytes: 13_060_000_000, modelBytes: model, physicalBytes: sixteen),
                      "13.06 GB on a 16 GB Mac, measured, did not reset")
        XCTAssertFalse(LocalModelReset.shouldReset(reportedBytes: 4_440_000_000, modelBytes: model, physicalBytes: sixteen),
                       "a fresh load, 4.44 GB measured, was reset")
        XCTAssertFalse(LocalModelReset.shouldReset(reportedBytes: 4_440_000_000, modelBytes: model, physicalBytes: eight),
                       "a fresh load on an 8 GB Mac would reset on every check")
        XCTAssertTrue(LocalModelReset.shouldReset(reportedBytes: 6 * gb, modelBytes: model, physicalBytes: eight))
        // The tenth of memory is headroom: 1 GB of growth on 16 GB is not a reset.
        XCTAssertFalse(LocalModelReset.shouldReset(reportedBytes: model + model / 20 + gb, modelBytes: model,
                                                   physicalBytes: sixteen),
                       "1 GB of growth on a 16 GB Mac reset the model")
        XCTAssertFalse(LocalModelReset.shouldReset(reportedBytes: 9 * gb, modelBytes: 0, physicalBytes: sixteen),
                       "an unknown model size reset anyway")
        // A runner that allocates up front reads above its disk size fresh;
        // the smallest size seen is its baseline, so it does not reset forever.
        XCTAssertFalse(LocalModelReset.shouldReset(reportedBytes: 3 * gb, modelBytes: 2 * gb,
                                                   smallestSeen: 3 * gb, physicalBytes: eight),
                       "a fresh load above its disk size would reset on every idle spell")
        XCTAssertTrue(LocalModelReset.shouldReset(reportedBytes: 4 * gb, modelBytes: 2 * gb,
                                                  smallestSeen: 3 * gb, physicalBytes: eight / 2))
        XCTAssertTrue(LocalModelReset.sameModel("grux-local:latest", "grux-local"))
        XCTAssertFalse(LocalModelReset.sameModel("grux-local:2b", "grux-local"))
    }

    /// The warm-up only helps if it sends the bytes a real turn sends.
    func test_theWarmUpSendsTheSameSystemTextAndToolsAsAStableTurn() throws {
        let state = AppState.shared
        let saved = state.chat
        let savedSummary = state.activeThreadSummary
        defer { state.chat = saved; state.activeThreadSummary = savedSummary }
        state.chat = [ChatMessage(role: .user, content: "add a task to buy milk")]
        // A thread summary is a second cached block, so how the blocks are
        // joined shows (red proof 2026-10-25: with one block it cannot).
        state.activeThreadSummary = "Earlier the user planned a trip to Lisbon."
        let turn = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 16_384)
        XCTAssertGreaterThan(turn.systemBlocks.filter { $0["cache_control"] != nil }.count, 1,
                             "only one cached block, so this cannot see how they are joined")
        let prefix = try XCTUnwrap(ChatService.shared.localPrefix(state: state, window: 16_384))
        XCTAssertEqual(prefix.tools.map(\.name), turn.tools.map(\.name), "the warm-up offers different tools")
        XCTAssertEqual(prefix.tools.map(\.description), turn.tools.map(\.description))
        let wire = OpenAICompatBackend.withTurnContextAfterTools(systemBlocks: turn.systemBlocks, messages: turn.messages)
        XCTAssertEqual(wire.first?["role"] as? String, "system")
        XCTAssertEqual(wire.first?["content"] as? String, prefix.system, "the warm-up reads a different system text")
    }

    func test_theResetStartsAtLaunch() throws {
        XCTAssertTrue(try macSource("Sources/Grux/GruxApp.swift").contains("LocalModelReset.shared.startIfNeeded()"))
    }

    /// Measured 2026-10-25: a message sent into a running warm-up waited
    /// 24.73 s; with the warm-up cancelled, 11.53 s.
    func test_aChatTurnCancelsTheWarmUpBeforeItStarts() throws {
        let src = try macSource("Sources/Grux/ChatService.swift")
        let cancel = try XCTUnwrap(src.range(of: "LocalModelReset.shared.cancelWarmUp()"), "a turn no longer cancels the warm-up")
        let begin = try XCTUnwrap(src.range(of: "state.beginChatTurn()"))
        XCTAssertLessThan(cancel.lowerBound, begin.lowerBound, "the warm-up is cancelled after the turn begins")
        LocalModelReset.shared.cancelWarmUp()  // no warm-up running: a no-op
    }
}

/// Ollama keeps a tool's parameter keys in the order it receives them, so the
/// same tools must reach it as the same bytes every turn.
final class OllamaWireOrderTests: XCTestCase {
    func test_ollamaRequestsHaveSortedKeysAtEveryLevel() throws {
        // Twenty keys: the chance a Swift dictionary iterates them sorted by
        // accident is about one in 2.4 * 10^18.
        let names = (0..<20).map { String(format: "k%02d", $0) }
        var props: [String: Any] = [:]
        for n in names.shuffled() { props[n] = ["type": "string", "description": n] }
        let wire: [String: Any] = ["model": "m", "tools": [["type": "function", "function": [
            "name": "t", "description": "d", "parameters": ["type": "object", "properties": props]]]]]
        let text = String(decoding: try OpenAICompatBackend.wireData(wire, native: true), as: UTF8.self)
        let order = names.compactMap { n in text.range(of: "\"\(n)\":").map { ($0.lowerBound, n) } }
        XCTAssertEqual(order.count, names.count)
        XCTAssertEqual(order.sorted { $0.0 < $1.0 }.map(\.1), names, "tool parameter keys reached Ollama unsorted")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"model\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"tools\"")).lowerBound, "top-level keys unsorted")
    }

    func test_everyRequestIsEncodedThroughWireData() throws {
        let src = try macSource("Sources/Grux/Backend/OpenAICompatBackend.swift")
        XCTAssertTrue(src.contains("req.httpBody = try Self.wireData(wire, native: native)"),
                      "the request body no longer goes through wireData, so Ollama may get unsorted keys")
        XCTAssertFalse(src.contains("req.httpBody = try JSONSerialization.data(withJSONObject: wire"))
    }
}
