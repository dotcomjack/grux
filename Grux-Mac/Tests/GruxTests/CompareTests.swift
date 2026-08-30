import XCTest
@testable import Grux

// Item 5 (blind model comparison) coverage. Pure logic, zero network:
//   1. Label shuffling is deterministic for a given seed, a valid permutation,
//      and actually varies across seeds.
//   2. Fan-out collects every contender's output in contender order, with
//      latency + token usage, via mock ModelBackend actors.
//   3. Errors from one backend don't sink the others.
//   4. Vote recording validates record + output ids.
//   5. Store round-trips through JSON on disk (temp file, never the real one).
//   6. Synthesis prompt anonymizes candidates and skips failed outputs.

// Canned in-memory backend. Conforms to ModelBackend (an Actor-constrained
// protocol) so plain actor methods satisfy every requirement.
private actor CompareMockBackend: ModelBackend {
    let reply: String
    let failWith: String?
    let inputTokens: Int
    let outputTokens: Int
    let delaySeconds: Double

    init(reply: String, inputTokens: Int = 11, outputTokens: Int = 22,
         failWith: String? = nil, delaySeconds: Double = 0) {
        self.reply = reply
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.failWith = failWith
        self.delaySeconds = delaySeconds
    }

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String {
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let failWith {
            throw NSError(domain: "CompareMock", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failWith])
        }
        return reply
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String {
        reply
    }

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.finish()
        }
    }

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse {
        ClaudeToolsResponse(blocks: [.text(reply)], stopReason: "end_turn")
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (inputTokens, outputTokens, 0, 0)
    }
}

final class CompareTests: XCTestCase {

    // MARK: - Shuffle determinism

    func test_shuffle_sameSeedSameOrder() {
        let a = ComparisonShuffle.shuffledIndices(count: 6, seed: 42)
        let b = ComparisonShuffle.shuffledIndices(count: 6, seed: 42)
        XCTAssertEqual(a, b, "same seed must reproduce the same permutation")
    }

    func test_shuffle_isValidPermutation() {
        for count in [0, 1, 2, 3, 5, 8, 26, 30] {
            let order = ComparisonShuffle.shuffledIndices(count: count, seed: 7)
            XCTAssertEqual(order.sorted(), Array(0..<count),
                           "count \(count): shuffle must be a permutation of 0..<count")
        }
    }

    func test_shuffle_variesAcrossSeeds() {
        // With 8 slots there are 40320 permutations; 20 distinct seeds all
        // colliding onto one ordering would mean the seed is being ignored.
        let baseline = ComparisonShuffle.shuffledIndices(count: 8, seed: 0)
        let anyDiffers = (1...20).contains { seed in
            ComparisonShuffle.shuffledIndices(count: 8, seed: UInt64(seed)) != baseline
        }
        XCTAssertTrue(anyDiffers, "different seeds should produce different orders")
    }

    func test_shuffle_labels() {
        XCTAssertEqual(ComparisonShuffle.label(forSlot: 0), "A")
        XCTAssertEqual(ComparisonShuffle.label(forSlot: 1), "B")
        XCTAssertEqual(ComparisonShuffle.label(forSlot: 25), "Z")
        XCTAssertEqual(ComparisonShuffle.label(forSlot: 26), "A2")
    }

    func test_record_displayOrder_stableAcrossReads() {
        let outputs = (0..<4).map {
            ComparisonOutput(backendName: "m\($0)", modelId: "m\($0)", text: "t\($0)", latencySeconds: 0.1)
        }
        let rec = ComparisonRecord(prompt: "p", outputs: outputs, labelSeed: 99)
        XCTAssertEqual(rec.displayOrder, rec.displayOrder)
        XCTAssertEqual(rec.displayOrder.sorted(), [0, 1, 2, 3])
    }

    // MARK: - Fan-out with mock backends

    func test_fanOut_collectsAllOutputsInContenderOrder() async {
        let contenders = [
            ComparisonContender(key: "mock/alpha", name: "Alpha", modelId: "alpha",
                                apiKey: "x", backend: CompareMockBackend(reply: "alpha says hi")),
            ComparisonContender(key: "mock/beta", name: "Beta", modelId: "beta",
                                apiKey: "x", backend: CompareMockBackend(reply: "beta says hi", inputTokens: 5, outputTokens: 9)),
            ComparisonContender(key: "mock/gamma", name: "Gamma", modelId: "gamma",
                                apiKey: "x", backend: CompareMockBackend(reply: "gamma says hi"))
        ]
        let outputs = await ComparisonService.fanOut(prompt: "hello", system: nil, contenders: contenders)
        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(outputs.map { $0.backendName }, ["Alpha", "Beta", "Gamma"],
                       "outputs must come back in contender order, not completion order")
        XCTAssertEqual(outputs[0].text, "alpha says hi")
        XCTAssertEqual(outputs[1].inputTokens, 5)
        XCTAssertEqual(outputs[1].outputTokens, 9)
        XCTAssertNil(outputs[0].errorText)
        for o in outputs { XCTAssertGreaterThanOrEqual(o.latencySeconds, 0) }
    }

    func test_fanOut_oneFailureDoesNotSinkOthers() async {
        let contenders = [
            ComparisonContender(key: "mock/good", name: "Good", modelId: "good",
                                apiKey: "x", backend: CompareMockBackend(reply: "fine")),
            ComparisonContender(key: "mock/bad", name: "Bad", modelId: "bad",
                                apiKey: "x", backend: CompareMockBackend(reply: "", failWith: "server exploded"))
        ]
        let outputs = await ComparisonService.fanOut(prompt: "hello", system: nil, contenders: contenders)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertNil(outputs[0].errorText)
        XCTAssertEqual(outputs[0].text, "fine")
        XCTAssertTrue(outputs[1].failed)
        XCTAssertEqual(outputs[1].errorText, "server exploded")
        XCTAssertEqual(outputs[1].text, "")
    }

    // A single hung/very-slow backend must not block the whole Compare run.
    // With a short per-contender timeout, the slow one yields a timed-out
    // error output while the fast one returns normally, and the run finishes
    // in well under the slow backend's delay.
    func test_fanOut_slowContenderTimesOutWithoutBlockingOthers() async {
        let contenders = [
            ComparisonContender(key: "mock/fast", name: "Fast", modelId: "fast",
                                apiKey: "x", backend: CompareMockBackend(reply: "quick")),
            ComparisonContender(key: "mock/slow", name: "Slow", modelId: "slow",
                                apiKey: "x", backend: CompareMockBackend(reply: "eventually", delaySeconds: 5))
        ]
        let started = Date()
        let outputs = await ComparisonService.fanOut(
            prompt: "hello", system: nil, contenders: contenders, contenderTimeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0].text, "quick")
        XCTAssertNil(outputs[0].errorText)
        XCTAssertTrue(outputs[1].failed, "the slow contender must surface a timeout, not hang the run")
        XCTAssertLessThan(elapsed, 4.0, "run must not wait for the 5s backend (timed out at 0.3s)")
    }

    // MARK: - Vote recording

    @MainActor
    func test_voteRecording() {
        let store = ComparisonStore(fileURL: tempURL())
        let outputs = [
            ComparisonOutput(backendName: "A", modelId: "a", text: "one", latencySeconds: 0.2),
            ComparisonOutput(backendName: "B", modelId: "b", text: "two", latencySeconds: 0.3)
        ]
        let rec = ComparisonRecord(prompt: "which", outputs: outputs, labelSeed: 1)
        store.add(rec)

        XCTAssertFalse(store.recordVote(recordId: UUID(), outputId: outputs[0].id),
                       "unknown record id must not record a vote")
        XCTAssertFalse(store.recordVote(recordId: rec.id, outputId: UUID()),
                       "unknown output id must not record a vote")
        XCTAssertNil(store.record(id: rec.id)?.votedOutputId)

        XCTAssertTrue(store.recordVote(recordId: rec.id, outputId: outputs[1].id))
        XCTAssertEqual(store.record(id: rec.id)?.votedOutputId, outputs[1].id)
        XCTAssertEqual(store.record(id: rec.id)?.votedOutput?.backendName, "B")
        XCTAssertEqual(store.winCounts(), ["B": 1])
        XCTAssertEqual(store.votedCount, 1)
    }

    // MARK: - Store round-trip

    @MainActor
    func test_storeRoundTrip() {
        let url = tempURL()
        let store = ComparisonStore(fileURL: url)
        let outputs = [
            ComparisonOutput(backendName: "A", modelId: "a", text: "one", latencySeconds: 0.5,
                             inputTokens: 3, outputTokens: 4),
            ComparisonOutput(backendName: "B", modelId: "b", text: "", latencySeconds: 1.5,
                             errorText: "timeout")
        ]
        let rec = ComparisonRecord(prompt: "round trip me", outputs: outputs,
                                   labelSeed: 123456789, blind: true)
        store.add(rec)
        store.recordVote(recordId: rec.id, outputId: outputs[0].id)
        store.setSynthesis(recordId: rec.id, text: "merged answer", by: "Judge")
        store.setRevealed(recordId: rec.id, revealed: true)
        store.saveNow()

        let reloaded = ComparisonStore(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        let got = reloaded.record(id: rec.id)
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.prompt, "round trip me")
        XCTAssertEqual(got?.labelSeed, 123456789)
        XCTAssertEqual(got?.blind, true)
        XCTAssertEqual(got?.revealed, true)
        XCTAssertEqual(got?.votedOutputId, outputs[0].id)
        XCTAssertEqual(got?.synthesis, "merged answer")
        XCTAssertEqual(got?.synthesizedBy, "Judge")
        XCTAssertEqual(got?.outputs, outputs)
        // Shuffle order must survive persistence byte-for-byte (same seed).
        XCTAssertEqual(got?.displayOrder, rec.displayOrder)

        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    func test_delete_removesRecord() {
        let store = ComparisonStore(fileURL: tempURL())
        let rec = ComparisonRecord(prompt: "bye", outputs: [], labelSeed: 1)
        store.add(rec)
        XCTAssertEqual(store.records.count, 1)
        store.delete(recordId: rec.id)
        XCTAssertEqual(store.records.count, 0)
    }

    // MARK: - Synthesis prompt

    func test_synthesisPrompt_anonymizesAndSkipsFailures() {
        let outputs = [
            ComparisonOutput(backendName: "Claude (haiku)", modelId: "haiku",
                             text: "answer from cloud", latencySeconds: 0.4),
            ComparisonOutput(backendName: "Local (llama3.1)", modelId: "llama3.1",
                             text: "answer from local", latencySeconds: 0.9),
            ComparisonOutput(backendName: "Local (broken)", modelId: "broken",
                             text: "", latencySeconds: 2.0, errorText: "boom")
        ]
        let rec = ComparisonRecord(prompt: "the question", outputs: outputs, labelSeed: 5)
        let prompt = ComparisonService.synthesisPrompt(for: rec)
        XCTAssertTrue(prompt.contains("the question"))
        XCTAssertTrue(prompt.contains("answer from cloud"))
        XCTAssertTrue(prompt.contains("answer from local"))
        XCTAssertFalse(prompt.contains("Claude"), "judge prompt must not leak model names")
        XCTAssertFalse(prompt.contains("llama3.1"), "judge prompt must not leak model ids")
        XCTAssertFalse(prompt.contains("boom"), "failed outputs stay out of the judge prompt")
        XCTAssertTrue(prompt.contains("[Candidate "))
    }

    func test_strongestContender_prefersClaude() {
        let localOnly = [
            ComparisonContender(key: "mock/a", name: "A", modelId: "a", apiKey: "x",
                                backend: CompareMockBackend(reply: "")),
            ComparisonContender(key: "mock/b", name: "B", modelId: "b", apiKey: "x",
                                backend: CompareMockBackend(reply: ""))
        ]
        XCTAssertEqual(ComparisonService.strongestContender(among: localOnly)?.key, "mock/a",
                       "no Claude contender falls back to the first")
        let withClaude = localOnly + [
            ComparisonContender(key: "anthropic/haiku", name: "Claude", modelId: "haiku",
                                apiKey: "k", backend: ClaudeClient())
        ]
        XCTAssertEqual(ComparisonService.strongestContender(among: withClaude)?.key, "anthropic/haiku")
        XCTAssertNil(ComparisonService.strongestContender(among: []))
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-compare-tests-\(UUID().uuidString).json")
    }
}
