import XCTest
@testable import Grux

/// D17: a local model reuses the part of a prompt that matches the last one it
/// read, and reads the rest again. Measured on a 16 GB Mac mini with qwen3.5:4b
/// (2026-10-29, ollama.log): every chat turn missed (`cache miss total=6365
/// matched=32`) and waited 15 to 20 s for its first word, because qwen3.5's
/// template puts the tools first and each turn offered a different set (16, 12,
/// 15 tools) in a different order, the tool JSON came out in a different key
/// order each time, and the history window slid by two messages a turn. Two
/// ordinary turns now send the same bytes up to what is new.
@MainActor
final class LocalTurnPrefixTests: XCTestCase {

    private var saved: [ChatMessage] = []
    override func setUp() async throws { saved = AppState.shared.chat }
    override func tearDown() async throws { AppState.shared.chat = saved }

    private func lean(_ chat: [ChatMessage], window: Int = 16_384) -> ChatService.PendingTurnContext {
        AppState.shared.chat = chat
        return ChatService.shared.assemblePendingContext(state: AppState.shared, lean: true, window: window)
    }

    private func systemText(_ p: ChatService.PendingTurnContext) -> String {
        p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    /// The blocks that stay system text on the wire (the rest ride on the newest message).
    private func stableText(_ p: ChatService.PendingTurnContext) -> String {
        p.systemBlocks.filter { $0["cache_control"] != nil }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    private func text(_ m: [String: Any]) -> String {
        if let s = m["content"] as? String { return s }
        let blocks = m["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private let u1 = ChatMessage(role: .user, content: "what is two plus two")
    private let a1 = ChatMessage(role: .assistant, content: "Four.")

    /// The second turn of a conversation sends what the first sent, then more.
    func test_twoOrdinaryTurnsShareTheirToolsAndSystemPrompt() {
        let first = lean([u1])
        let second = lean([u1, a1, ChatMessage(role: .user, content: "what's 12 times 17")])
        XCTAssertEqual(first.tools.map(\.name), second.tools.map(\.name), "the tool list changed between turns")
        XCTAssertEqual(stableText(first), stableText(second), "the system prompt changed between turns")
        XCTAssertEqual(text(second.messages[0]), "what is two plus two", "an earlier message carried this turn's context")
    }

    /// On the wire the minute and the rest of the per-turn block ride on the
    /// newest message under Grux's own label, and the system message is the same
    /// from turn to turn.
    func test_onTheWireTheSystemMessageStaysAndThePerTurnBlockRidesLast() throws {
        let first = lean([u1])
        let second = lean([u1, a1, ChatMessage(role: .user, content: "and five plus five")])
        let w1 = OpenAICompatBackend.withTurnContextAfterTools(systemBlocks: first.systemBlocks, messages: first.messages)
        let w2 = OpenAICompatBackend.withTurnContextAfterTools(systemBlocks: second.systemBlocks, messages: second.messages)
        XCTAssertEqual(w1.first?["role"] as? String, "system")
        XCTAssertEqual(w1.first?["content"] as? String, w2.first?["content"] as? String, "the system message changed between turns")
        XCTAssertFalse((w2.first?["content"] as? String ?? "").contains("NOW: "), "the minute is in the system message")
        let newest = text(try XCTUnwrap(w2.last))
        XCTAssertTrue(newest.hasPrefix(OpenAICompatBackend.turnContextLabel), "the per-turn block lost its label")
        XCTAssertTrue(newest.contains("NOW: "))
        XCTAssertTrue(newest.hasSuffix("and five plus five"), "the person's words are not last")
        XCTAssertEqual(text(w2[1]), "what is two plus two", "an earlier message carried this turn's context")
    }

    /// The same tools serialize to the same bytes on every turn.
    func test_theToolsSerializeToTheSameBytesEveryTurn() throws {
        func wire(_ p: ChatService.PendingTurnContext) throws -> Data {
            let body: [String: Any] = ["tools": p.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.inputSchema]] }]
            return try OpenAICompatBackend.wireData(body)
        }
        let a = try wire(lean([u1]))
        let b = try wire(lean([u1, a1, ChatMessage(role: .user, content: "what's 12 times 17")]))
        XCTAssertEqual(a, b)
        let reversed: [String: Any] = ["zeta": 1, "alpha": ["y": 1, "b": 2]]
        XCTAssertEqual(String(data: try OpenAICompatBackend.wireData(reversed), encoding: .utf8),
                       #"{"alpha":{"b":2,"y":1},"zeta":1}"#)
    }

    /// A long thread's history starts at the same message for several turns.
    func test_aLongThreadsHistoryStartsInPlaceForSeveralTurns() {
        var thread: [ChatMessage] = []
        for i in 0..<20 {
            thread.append(ChatMessage(role: .user, content: "question \(i)"))
            thread.append(ChatMessage(role: .assistant, content: "answer \(i)"))
        }
        let turnA = lean(thread + [ChatMessage(role: .user, content: "next one")])
        let turnB = lean(thread + [ChatMessage(role: .user, content: "next one"), a1,
                                   ChatMessage(role: .user, content: "and another")])
        XCTAssertEqual(text(turnA.messages[0]), text(turnB.messages[0]), "the history window slid")
        XCTAssertLessThanOrEqual(turnA.messages.count, 30)
    }

    func test_historyStartMovesInWholeSteps() {
        // release/3.2: one rule, `historyStart(count:fitting:)` (main's
        // signature, this file's semantics: the step moves the 30 window only).
        XCTAssertEqual(LocalTurn.historyStart(count: 0, fitting: 0), 0)
        XCTAssertEqual(LocalTurn.historyStart(count: 30, fitting: 30), 0, "all of it fits")
        XCTAssertEqual(LocalTurn.historyStart(count: 31, fitting: 31), 10, "one over moves a whole step")
        XCTAssertEqual(LocalTurn.historyStart(count: 40, fitting: 40), 10, "exactly on a step")
        XCTAssertEqual(LocalTurn.historyStart(count: 41, fitting: 41), 20)
        XCTAssertEqual(LocalTurn.historyStart(count: 5, fitting: 1), 4, "never past the newest message")
        XCTAssertEqual(LocalTurn.historyStart(count: 5, fitting: 0), 4, "the newest message always stays")
        XCTAssertEqual(LocalTurn.historyStart(count: 12, fitting: 3), 9, "a cut for room keeps exactly what fits")
    }

    /// A word that matches a tool still picks it, but never reorders the list.
    func test_theToolsGoOutInOneOrderWhateverWasAsked() {
        let plain = lean([ChatMessage(role: .user, content: "hi")]).tools.map(\.name)
        let calendar = lean([ChatMessage(role: .user, content: "what is on my calendar tomorrow")]).tools.map(\.name)
        let order = LocalTurn.canonicalOrder(ChatService.allTools())
        for names in [plain, calendar] {
            let positions = names.compactMap { order[$0] }
            XCTAssertEqual(positions, positions.sorted(), "tools went out in ranked order: \(names)")
        }
        XCTAssertTrue(calendar.contains("list_events"))
    }

    /// How much history there is does not change which tools ride.
    func test_historyLengthDoesNotChangeTheTools() {
        var long: [ChatMessage] = []
        for i in 0..<12 {
            long.append(ChatMessage(role: .user, content: "question number \(i) about nothing much"))
            long.append(ChatMessage(role: .assistant, content: String(repeating: "an answer ", count: 30)))
        }
        let ask = ChatMessage(role: .user, content: "and one more")
        XCTAssertEqual(lean([ask]).tools.map(\.name), lean(long + [ask]).tools.map(\.name))
    }

    /// The tools that open another app (D12) go last, so a turn that asks to open
    /// something adds to the end of the list instead of changing its middle.
    func test_theToolsThatOpenAnotherAppGoLast() {
        let order = LocalTurn.canonicalOrder(ChatService.allTools())
        let opens = ToolRelevance.otherAppsTools.compactMap { order[$0] }
        let rest = order.filter { ToolRelevance.group(for: $0.key) != .otherApps }.map(\.value)
        XCTAssertEqual(opens.count, ToolRelevance.otherAppsTools.count)
        XCTAssertGreaterThan(opens.min() ?? 0, rest.max() ?? Int.max)
        let open = lean([ChatMessage(role: .user, content: "open github.com")]).tools.map(\.name)
        let firstOpen = open.firstIndex { ToolRelevance.group(for: $0) == .otherApps }
        if let firstOpen {
            XCTAssertTrue(open[firstOpen...].allSatisfy { ToolRelevance.group(for: $0) == .otherApps }, "\(open)")
        } else {
            XCTFail("asking to open a page offered none of the tools that open one: \(open)")
        }
    }

    /// The line naming what was left out lists names in the same one order.
    func test_theCutLineNamesToolsInOneOrder() throws {
        let tight = lean([ChatMessage(role: .user, content: "what is on my calendar tomorrow")], window: 8_192)
        let line = try XCTUnwrap(tight.systemBlocks.compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("TOOLS NOT OFFERED IN THIS LOCAL TURN:") })
        let names = line.replacingOccurrences(of: "TOOLS NOT OFFERED IN THIS LOCAL TURN: ", with: "")
            .components(separatedBy: ". ").first?.components(separatedBy: ", ") ?? []
        let order = LocalTurn.canonicalOrder(ChatService.allTools())
        let positions = names.compactMap { order[$0] }
        XCTAssertGreaterThan(positions.count, 3)
        XCTAssertEqual(positions, positions.sorted())
    }

    /// Wave 10 review: when the token budget, not the 30-message window, limits
    /// the history, everything that fits is kept (the step applies to the window).
    func test_aBudgetLimitedHistoryKeepsEveryMessageThatFits() throws {
        let paste = ChatMessage(role: .user, content: String(repeating: "pasted words ", count: 1_000))
        let answer = ChatMessage(role: .assistant, content: String(repeating: "a shorter answer ", count: 35))
        let ask = ChatMessage(role: .user, content: "shorter please")
        let turn = lean([paste, answer, ask], window: 8_192)
        XCTAssertFalse(turn.messages.contains { text($0).hasPrefix("pasted words") }, "the paste fits, so this checks nothing")
        XCTAssertEqual(turn.messages.count, 2, "the answer fit and was dropped")
        XCTAssertTrue(text(turn.messages[0]).hasPrefix("a shorter answer"))
    }

    /// Wave 10 review: a plural finds its singular ("tasks", "task"), but "news"
    /// is not "new", which every "Add a new ..." tool says.
    func test_aPluralFindsItsSingularButNewsIsNotNew() {
        func tool(_ n: String, _ d: String) -> ClaudeTool { ClaudeTool(name: n, description: d, inputSchema: [:]) }
        let tools = [tool("add_task", "Add a new task"), tool("read_feed", "Read the latest news headlines")]
        XCTAssertEqual(LocalTurn.rank(tools, utterance: "what's the news").first?.name, "read_feed")
        XCTAssertEqual(LocalTurn.rank([tool("other", "Something else"), tool("add_task", "Add a task")],
                                      utterance: "my tasks").first?.name, "add_task")
    }
}
