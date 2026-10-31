import XCTest
@testable import Grux

/// A DOWNLOAD IS TIMED ON THE PERSON'S OWN MAC BEFORE IT BECOMES THE DEFAULT.
///
/// The Cookbook ranks by quality measured on a GPU. Measured on a 16 GB Mac
/// mini (2026-10-22): gemma4:12b answered a dictation repair in 1.26 s and a
/// chat turn with tools in 35.8 s, so a dictation-only check would have made
/// a model the default whose chat is unusable. Every timing here runs on an
/// injected clock; no socket is opened.

/// A clock the fake backend moves.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

private struct NotExercised: Error {}

/// Records each call and spends the next scripted number of seconds on the
/// clock before answering.
private actor TimedBackend: ModelBackend {
    struct Call: Equatable {
        let kind: String
        let model: String
        let system: String?
        let user: String
        let tools: [String]
        let maxTokens: Int
        /// The whole conversation sent, as "role: content".
        var history: [String] = []
    }

    private(set) var calls: [Call] = []
    private var delays: [TimeInterval]
    private let clock: FakeClock
    private let empty: Bool

    init(clock: FakeClock, delays: [TimeInterval], empty: Bool = false) {
        self.clock = clock
        self.delays = delays
        self.empty = empty
    }

    private func spend() {
        clock.advance(delays.isEmpty ? 0 : delays.removeFirst())
    }

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String {
        calls.append(Call(kind: "complete", model: model, system: system,
                          user: messages.last?.content ?? "", tools: [], maxTokens: maxTokens))
        spend()
        return empty ? "" : "add a task to my list to call the plumber"
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String {
        throw NotExercised()
    }

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream<ClaudeStreamEvent, Error> { $0.finish(throwing: NotExercised()) }
    }

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse {
        calls.append(Call(kind: "tools", model: model, system: system,
                          user: messages.last?["content"] as? String ?? "",
                          tools: tools.map(\.name), maxTokens: maxTokens,
                          history: messages.map { "\($0["role"] as? String ?? "?"): \($0["content"] as? String ?? "?")" }))
        spend()
        return ClaudeToolsResponse(blocks: empty ? [] : [.text("I can help with tasks and your calendar.")],
                                   stopReason: "end_turn")
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) { (0, 0, 0, 0) }
}

final class LocalModelSpeedCheckTests: XCTestCase {

    private func model(_ id: String) throws -> CookbookModel {
        try XCTUnwrap(Cookbook.catalog.first { $0.id == id }, "\(id) is in the catalog")
    }

    /// Runs `firstMiss` with each call spending its seconds on a fake clock.
    private func miss(dictation: TimeInterval?, chat: TimeInterval?) async -> (LocalModelSpeedCheck.Miss?, [String]) {
        let clock = FakeClock()
        var ran: [String] = []
        let m = await LocalModelSpeedCheck.firstMiss(now: clock.now, dictation: {
            ran.append("dictation")
            clock.advance(dictation ?? 6)
            return dictation != nil
        }, chat: {
            ran.append("chat")
            clock.advance(chat ?? 16)
            return chat != nil
        })
        return (m, ran)
    }

    // MARK: - The limits

    func testTheLimitsAreDictationsOwnAndEightSecondsForChat() {
        XCTAssertEqual(LocalModelSpeedCheck.dictationLimit, 3.0)
        XCTAssertEqual(LocalModelSpeedCheck.dictationLimit, TranscriptCorrector.timeout,
                       "dictation is held to the limit dictation itself gives up at")
        XCTAssertEqual(LocalModelSpeedCheck.chatLimit, 8.0)
        XCTAssertEqual(LocalModelSpeedCheck.fallback?.id, "qwen3.5:4b")
        XCTAssertEqual(Cookbook.catalog.filter(\.speedFallback).map(\.id), ["qwen3.5:4b"], "exactly one fallback")
    }

    func testExactlyOnEachLimitPassesAndOneHundredthOverMisses() async {
        // On, under, over, for each limit.
        var r = await miss(dictation: 3.0, chat: 8.0)
        XCTAssertNil(r.0, "exactly on both limits is within them")
        r = await miss(dictation: 2.99, chat: 7.99)
        XCTAssertNil(r.0)
        r = await miss(dictation: 3.01, chat: 1)
        XCTAssertEqual(r.0?.check, .dictation)
        XCTAssertEqual(r.0?.seconds ?? 0, 3.01, accuracy: 1e-9)
        r = await miss(dictation: 1, chat: 8.01)
        XCTAssertEqual(r.0?.check, .chat)
        XCTAssertEqual(r.0?.seconds ?? 0, 8.01, accuracy: 1e-9)
    }

    func testAFastDictationDoesNotExcuseASlowChat() async {
        // The measured gemma4:12b shape on a 16 GB Mac. Chat is timed first,
        // straight after the warm call, so its prompt is still cached.
        let r = await miss(dictation: 1.26, chat: 35.8)
        XCTAssertEqual(r.0?.check, .chat)
        XCTAssertEqual(r.0?.seconds ?? 0, 35.8, accuracy: 1e-9)
        XCTAssertEqual(r.1, ["chat"], "a chat miss stops before the dictation call")
    }

    func testAFastChatDoesNotExcuseASlowDictation() async {
        let r = await miss(dictation: 4.0, chat: 1)
        XCTAssertEqual(r.0?.check, .dictation)
        XCTAssertEqual(r.0?.seconds ?? 0, 4.0, accuracy: 1e-9)
        XCTAssertEqual(r.1, ["chat", "dictation"])
    }

    func testNoAnswerIsAMissWithNoTime() async {
        var r = await miss(dictation: nil, chat: 1)
        XCTAssertEqual(r.0, LocalModelSpeedCheck.Miss(check: .dictation, seconds: nil))
        r = await miss(dictation: 1, chat: nil)
        XCTAssertEqual(r.0, LocalModelSpeedCheck.Miss(check: .chat, seconds: nil))
    }

    func testEachTimedCallIsReportedWithItsSeconds() async {
        let clock = FakeClock()
        var heard: [String] = []
        let backend = TimedBackend(clock: clock, delays: [50, 1.28, 0.58])
        _ = await LocalModelSpeedCheck.measure(model: "qwen3.5:4b", backend: backend, apiKey: "ollama",
                                               chatSystem: "LEAN", chatTools: [], knownTerms: [], now: clock.now,
                                               report: { heard.append(String(format: "%@ %.2f %@", $0.rawValue, $1, $2 ? "y" : "n")) })
        XCTAssertEqual(heard, ["chat 1.28 y", "dictation 0.58 y"], "the untimed warm turn is not reported")
    }

    // MARK: - Which picks are timed

    func testOnlyAPickBiggerThanTheFallbackIsTimed() throws {
        XCTAssertTrue(LocalModelSpeedCheck.applies(to: try model("gemma4:12b")))
        XCTAssertTrue(LocalModelSpeedCheck.applies(to: try model("gemma4:26b")))
        XCTAssertFalse(LocalModelSpeedCheck.applies(to: try model("qwen3.5:4b")), "the fallback itself")
        XCTAssertFalse(LocalModelSpeedCheck.applies(to: try model("qwen3.5:2b")), "smaller than the fallback")
    }

    /// Wave 10 review: the fallback (Qwen 3.5 4B) needs Ollama 0.30.0. On an older
    /// Ollama there is nothing to fall back to, so the pick is not timed and no
    /// pull is tried (it would fail and blame the download).
    func testNoFallbackIsTriedOnAnOllamaTooOldToRunIt() async throws {
        let grux4b = try model("gruxai.com/grux/grux-local:4b")
        XCTAssertFalse(LocalModelSpeedCheck.applies(to: grux4b, ollamaVersion: "0.29.9"), "one under the fallback's minimum")
        XCTAssertTrue(LocalModelSpeedCheck.applies(to: grux4b, ollamaVersion: "0.30.0"), "exactly the fallback's minimum")
        XCTAssertTrue(LocalModelSpeedCheck.applies(to: grux4b, ollamaVersion: nil), "an unknown version hides nothing")
        var measured = false, fetched = false
        let o = await LocalModelSpeedCheck.settle(pick: grux4b, ollamaVersion: "0.22.0",
                                                  measure: { _ in measured = true; return .init(check: .chat, seconds: 30) },
                                                  fetch: { _ in fetched = true; return false })
        XCTAssertEqual(o.adopt.id, grux4b.id)
        XCTAssertNil(o.note)
        XCTAssertFalse(measured)
        XCTAssertFalse(fetched, "a pull of a model this Ollama cannot run was tried")
    }

    // MARK: - The line

    func testTheLineSaysWhichCheckMissedAndByHowMuch() throws {
        let gemma = try model("gemma4:12b"), qwen = try model("qwen3.5:4b")
        XCTAssertEqual(
            LocalModelSpeedCheck.line(model: gemma, miss: .init(check: .chat, seconds: 35.8), kept: qwen, keptIsFallback: true),
            "Grux kept Qwen 3.5 4B as the default: Gemma 4 12B took 35.8 s for a chat reply on this Mac, 27.8 s over the 8.0 s limit.")
        XCTAssertEqual(
            LocalModelSpeedCheck.line(model: gemma, miss: .init(check: .dictation, seconds: 3.4), kept: qwen, keptIsFallback: true),
            "Grux kept Qwen 3.5 4B as the default: Gemma 4 12B took 3.4 s for a dictation repair on this Mac, 0.4 s over the 3.0 s limit.")
        XCTAssertEqual(
            LocalModelSpeedCheck.line(model: gemma, miss: .init(check: .chat, seconds: nil), kept: qwen, keptIsFallback: true),
            "Grux kept Qwen 3.5 4B as the default: Gemma 4 12B did not answer a chat reply within 16.0 s on this Mac (limit 8.0 s).")
        XCTAssertEqual(
            LocalModelSpeedCheck.line(model: gemma, miss: .init(check: .chat, seconds: 9.0), kept: qwen, keptIsFallback: false),
            "Gemma 4 12B took 9.0 s for a chat reply on this Mac, 1.0 s over the 8.0 s limit, and Qwen 3.5 4B could not be downloaded in its place, so Gemma 4 12B stays the default.")
    }

    // MARK: - Settling on a default

    func testAFastPickIsKeptAndNothingElseIsDownloaded() async throws {
        let gemma = try model("gemma4:12b")
        var fetched: [String] = []
        let o = await LocalModelSpeedCheck.settle(pick: gemma, measure: { _ in nil },
                                                  fetch: { fetched.append($0.id); return true })
        XCTAssertEqual(o, .init(adopt: gemma, note: nil))
        XCTAssertEqual(fetched, [])
    }

    func testASlowPickFetchesAndKeepsTheFallbackAndSaysSo() async throws {
        let gemma = try model("gemma4:12b"), qwen = try model("qwen3.5:4b")
        var fetched: [String] = []
        let o = await LocalModelSpeedCheck.settle(pick: gemma, measure: { _ in .init(check: .chat, seconds: 35.8) },
                                                  fetch: { fetched.append($0.id); return true })
        XCTAssertEqual(o.adopt, qwen)
        XCTAssertEqual(fetched, ["qwen3.5:4b"])
        XCTAssertEqual(o.note, LocalModelSpeedCheck.line(model: gemma, miss: .init(check: .chat, seconds: 35.8),
                                                         kept: qwen, keptIsFallback: true))
    }

    func testAFallbackThatCannotBeDownloadedLeavesThePickAndSaysWhy() async throws {
        let gemma = try model("gemma4:12b")
        let o = await LocalModelSpeedCheck.settle(pick: gemma, measure: { _ in .init(check: .dictation, seconds: 5) },
                                                  fetch: { _ in false })
        XCTAssertEqual(o.adopt, gemma)
        XCTAssertTrue(o.note?.contains("could not be downloaded") == true, o.note ?? "nil")
    }

    func testAPickThatIsNotTimedIsNeverMeasured() async throws {
        for id in ["qwen3.5:4b", "qwen3.5:2b"] {
            let pick = try model(id)
            var measured = false
            let o = await LocalModelSpeedCheck.settle(pick: pick, measure: { _ in measured = true; return nil },
                                                      fetch: { _ in true })
            XCTAssertFalse(measured, id)
            XCTAssertEqual(o, .init(adopt: pick, note: nil))
        }
    }

    // MARK: - The real requests, on a fake clock

    private let tools = ["list_tasks", "add_task", "search_web"].map {
        ClaudeTool(name: $0, description: "d", inputSchema: ["type": "object"])
    }

    func testItTimesTheRequestsGruxReallySendsAndNotTheLoad() async {
        let clock = FakeClock()
        // Warm turn 120 s (untimed), chat 35.8 s, dictation never reached.
        let backend = TimedBackend(clock: clock, delays: [120, 35.8, 1.26])
        let m = await LocalModelSpeedCheck.measure(model: "gemma4:12b", backend: backend, apiKey: "ollama",
                                                   chatSystem: "LEAN PROMPT", chatTools: tools,
                                                   knownTerms: ["Grux"], now: clock.now)
        XCTAssertEqual(m?.check, .chat)
        XCTAssertEqual(m?.seconds ?? 0, 35.8, accuracy: 1e-9)
        let calls = await backend.calls
        XCTAssertEqual(calls.map(\.kind), ["tools", "tools"], "a chat miss stops before dictation")
        XCTAssertEqual(Set(calls.map(\.model)), ["gemma4:12b"])
        // WARM MEANS THE SAME PROMPT. Measured on a 16 GB Mac mini: a warm call
        // with a different prompt left the chat turn to process all 4,172
        // tokens of the lean prompt cold, 11.96 s for qwen3.5:4b. The warm
        // turn is the real chat request with another user line, as the turn
        // before it in a conversation would be.
        XCTAssertEqual(calls[0].system, "LEAN PROMPT")
        XCTAssertEqual(calls[0].tools, ["list_tasks", "add_task", "search_web"])
        XCTAssertNotEqual(calls[0].user, calls[1].user)
        // Chat: the lean prompt handed in, the tools handed in, a local reply budget.
        XCTAssertEqual(calls[1].system, "LEAN PROMPT")
        XCTAssertEqual(calls[1].tools, ["list_tasks", "add_task", "search_web"])
        XCTAssertEqual(calls[1].maxTokens, LocalTurn.replyTokens)
    }

    // THE TIMED TURN IS THE NEXT TURN, NOT A REPLACEMENT. Measured on a 16 GB Mac mini
    // (2026-10-22 10:57 PM, qwen3.5:4b, no other client on Ollama): the warm turn "Hello."
    // and a timed turn that swapped in another user line diverged 19 tokens before the end
    // of the cached prompt, and Ollama reused nothing (`cache miss total=4478 matched=4459
    // cached=0`), 13.11 s. qwen3.5 is a hybrid recurrent model: its cache resumes only
    // from the end of an earlier request, which is exactly what a person's next turn
    // does. So the timed chat turn carries the warm turn and its reply, then a new line.
    func testTheTimedChatTurnContinuesTheWarmConversation() async {
        let clock = FakeClock()
        let backend = TimedBackend(clock: clock, delays: [20, 1.28, 0.58])
        _ = await LocalModelSpeedCheck.measure(model: "qwen3.5:4b", backend: backend, apiKey: "ollama",
                                               chatSystem: "LEAN", chatTools: tools,
                                               knownTerms: [], now: clock.now)
        let calls = await backend.calls
        XCTAssertEqual(calls[0].history, ["user: \(LocalModelSpeedCheck.warmSample)"])
        XCTAssertEqual(calls[1].history, [
            "user: \(LocalModelSpeedCheck.warmSample)",
            "assistant: I can help with tasks and your calendar.",
            "user: \(LocalModelSpeedCheck.chatSample)",
        ], "the timed request must extend the warm one, so the server's cache covers all but the new turn")
        XCTAssertEqual(Array(calls[1].history.prefix(calls[0].history.count)), calls[0].history)
    }

    func testDictationIsTimedWithTheCorrectorsOwnRequest() async {
        let clock = FakeClock()
        let backend = TimedBackend(clock: clock, delays: [20, 1.28, 0.58])
        let m = await LocalModelSpeedCheck.measure(model: "qwen3.5:4b", backend: backend, apiKey: "ollama",
                                                   chatSystem: "LEAN", chatTools: tools,
                                                   knownTerms: ["Grux"], now: clock.now)
        XCTAssertNil(m)
        let calls = await backend.calls
        XCTAssertEqual(calls.map(\.kind), ["tools", "tools", "complete"])
        XCTAssertEqual(calls[2].system, TranscriptCorrector.systemPrompt(knownTerms: ["Grux"]))
        XCTAssertEqual(calls[2].maxTokens, TranscriptCorrector.replyTokens)
        XCTAssertEqual(calls[2].user.split(separator: " ").count, 10)
    }

    func testAModelFastOnBothIsWithinTheLimits() async {
        let clock = FakeClock()
        // The measured qwen3.5:4b shape: 1.28 s chat, 0.58 s dictation.
        let backend = TimedBackend(clock: clock, delays: [30, 1.28, 0.58])
        let m = await LocalModelSpeedCheck.measure(model: "qwen3.5:4b", backend: backend, apiKey: "ollama",
                                                   chatSystem: "LEAN", chatTools: tools, knownTerms: [], now: clock.now)
        XCTAssertNil(m)
    }

    func testAnEmptyReplyIsNotAnAnswer() async {
        let clock = FakeClock()
        let backend = TimedBackend(clock: clock, delays: [1, 0.5, 0.5], empty: true)
        let m = await LocalModelSpeedCheck.measure(model: "gemma4:12b", backend: backend, apiKey: "ollama",
                                                   chatSystem: "LEAN", chatTools: tools, knownTerms: [], now: clock.now)
        XCTAssertEqual(m, .init(check: .chat, seconds: nil))
    }

    @MainActor
    func testTheChatToolsAreTheEverydayOnesInTheirOrder() {
        let all = ChatService.allTools()
        let picked = LocalModelSpeedCheck.everydayTools(from: all).map(\.name)
        XCTAssertEqual(picked, LocalTurn.everyday.filter { n in all.contains { $0.name == n } })
        XCTAssertTrue(picked.contains("list_tasks"), "\(picked)")
    }

    // MARK: - Both download paths go through it

    func testBothDownloadPathsTimeThePickBeforeAdoptingIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/Grux/Settings/ConnectModelSection.swift", "Sources/Grux/Onboarding/OnboardingView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let settle = try XCTUnwrap(text.range(of: "LocalModelSpeedGuard.settle(pick: pick"), "\(path) times the pick")
            let pull = try XCTUnwrap(text.range(of: "pullToEnd(pick.id)"), path)
            let adopt = try XCTUnwrap(text.range(of: "installedModelToAdopt("), path)
            XCTAssertLessThan(pull.lowerBound, settle.lowerBound, "\(path): timed after the download")
            XCTAssertLessThan(settle.lowerBound, adopt.lowerBound, "\(path): timed before it becomes the default")
            XCTAssertTrue(text.contains("settledPick") || text.contains("headline: settled.id"),
                          "\(path) adopts what the check settled on")
        }
    }

    // MARK: - A kept fallback is recorded, so discovery cannot undo it

    /// Wave 4 review, P1: first run re-discovered BEFORE it adopted the
    /// settled pick, and discovery, seeing the shipped default, wrote the
    /// hardware headline (the slow pick, now installed). The adopt step then
    /// saw an installed configured model and kept it, so chat ran on the
    /// model that missed while the pane said Grux had kept the faster one.
    func testAKeptFallbackIsRecordedSoDiscoveryLeavesItAlone() throws {
        let gemma = try model("gemma4:12b"), qwen = try model("qwen3.5:4b")
        let kept = LocalModelSpeedCheck.Outcome(adopt: qwen, note: "kept")
        let installed = ["gemma4:12b", "qwen3.5:4b", "llama3.2:3b"]
        let mac32 = HardwareProfile(chipName: "Test Chip", physicalMemoryBytes: 32 * 1_073_741_824,
                                    gpuWorkingSetBytes: 24 * 1_073_741_824, cpuCoreCount: 10,
                                    hasUnifiedMemory: true, isAppleSilicon: true)
        // The shape of the bug: with the shipped default in config, discovery writes the
        // hardware headline, which is not the kept fallback. (It was gemma4:12b itself
        // until Grux Local became the 32 GB headline; the shape is the same.)
        XCTAssertNotEqual(Cookbook.defaultModelID(for: mac32, userHasChosen: false,
                                                  current: GruxConfig.defaultLocalModel), "qwen3.5:4b")
        for configured in [GruxConfig.defaultLocalModel, "gemma4:12b", "", "not-installed:7b"] {
            let recorded = LocalModelSpeedCheck.modelToRecord(outcome: kept, pick: gemma,
                                                              configured: configured, installed: installed)
            XCTAssertEqual(recorded, "qwen3.5:4b", "configured \(configured)")
            let after = try XCTUnwrap(recorded)
            XCTAssertEqual(Cookbook.defaultModelID(for: mac32, userHasChosen: Cookbook.userHasChosenModel(after),
                                                   current: after), "qwen3.5:4b", "discovery leaves it")
            XCTAssertNil(GruxConfig.installedModelToAdopt(configured: after, installed: installed,
                                                          headline: "gemma4:12b"), "adopt leaves it")
        }
        // A model the person chose and has installed is theirs: never overwritten.
        XCTAssertNil(LocalModelSpeedCheck.modelToRecord(outcome: kept, pick: gemma,
                                                        configured: "llama3.2:3b-custom", installed: installed + ["llama3.2:3b-custom"]))
        // A pick that passed, or was not timed, records nothing here.
        XCTAssertNil(LocalModelSpeedCheck.modelToRecord(outcome: .init(adopt: gemma, note: nil), pick: gemma,
                                                        configured: GruxConfig.defaultLocalModel, installed: installed))
        XCTAssertNil(LocalModelSpeedCheck.modelToRecord(outcome: .init(adopt: gemma, note: "could not be downloaded"),
                                                        pick: gemma, configured: GruxConfig.defaultLocalModel,
                                                        installed: installed))
    }

    func testTheGuardWritesTheRecordedModelToBothFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Grux/LocalModelCookbook/LocalModelSpeedCheck.swift"), encoding: .utf8)
        let guardBody = try XCTUnwrap(text.range(of: "enum LocalModelSpeedGuard")).upperBound
        let rest = String(text[guardBody...])
        XCTAssertTrue(rest.contains("modelToRecord("), "the guard records a kept fallback")
        XCTAssertTrue(rest.contains("config.offlineLLMModel = recorded"))
        XCTAssertTrue(rest.contains("config.localLLMModel = recorded"))
    }

    // MARK: - The line is kept

    func testTheLineSurvivesInCookbookStateAndOldFilesStillDecode() throws {
        var s = CookbookState()
        s.speedNote = "Grux kept Qwen 3.5 4B as the default."
        let back = try JSONDecoder().decode(CookbookState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.speedNote, s.speedNote)
        let old = try JSONDecoder().decode(CookbookState.self, from: Data(#"{"pulledModelIds":["qwen3.5:4b"]}"#.utf8))
        XCTAssertNil(old.speedNote)
        XCTAssertEqual(old.pulledModelIds, ["qwen3.5:4b"])
    }
}
