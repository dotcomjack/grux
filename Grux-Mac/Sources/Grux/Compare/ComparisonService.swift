import Foundation

// Fans one prompt to N selected backends concurrently and collects every
// output with latency + token usage. Built on the ModelBackend protocol so a
// contender can be the Anthropic backend, any discovered local model, or a
// test mock, the fan-out logic never knows the difference.
//
// Each contender gets its OWN backend instance (fresh ClaudeClient or
// OpenAICompatBackend per contender) so the per-backend usageSnapshot()
// "most recent call" counters can't race when two models share a server.

// Runtime-only contender descriptor. Not Codable, the backend is a live actor.
// `key` is stable across rebuilds ("anthropic/<model>" or "local/<tag>") so
// the view's selection set survives availableContenders() being recomputed.
struct ComparisonContender: Identifiable {
    let key: String
    let name: String
    let modelId: String
    let apiKey: String
    let backend: ModelBackend
    var id: String { key }
}

@MainActor
final class ComparisonService: ObservableObject {
    static let shared = ComparisonService()

    @Published private(set) var isRunning = false
    @Published private(set) var isSynthesizing = false
    @Published private(set) var lastError: String?

    private init() {}

    // MARK: - Contender discovery

    // Everything the user can currently route a turn through: the cloud Anthropic
    // model (when a key is set) plus every model tag the local server reported.
    func availableContenders() -> [ComparisonContender] {
        var out: [ComparisonContender] = []
        let key = AppState.shared.anthropicKey
        let cloudModel = AppState.shared.config.model
        // NOT ROUTED, and this is the one construction the backend sweep must
        // leave standing. Compare's whole job is to run Anthropic BESIDE each
        // local model in the same fan-out, so asking the registry which single
        // provider to use would collapse the comparison to one column. Each
        // contender also needs its OWN client: usageSnapshot() reports the most
        // recent call on that instance, so sharing ModelRegistry.shared.anthropic
        // would make two contenders overwrite each other's token counts.
        if !key.isEmpty {
            out.append(ComparisonContender(
                key: "anthropic/\(cloudModel)",
                name: "Claude (\(cloudModel))",
                modelId: cloudModel,
                apiKey: key,
                backend: ClaudeClient()
            ))
        }
        if ModelRegistry.shared.local != nil {
            let baseURL = AppState.shared.config.ollamaBaseURL
            for tag in ModelRegistry.shared.localTags {
                out.append(ComparisonContender(
                    key: "local/\(tag)",
                    name: "Local (\(tag))",
                    modelId: tag,
                    apiKey: "ollama",
                    backend: OpenAICompatBackend(baseURL: baseURL)
                ))
            }
        }
        return out
    }

    // MARK: - Fan-out

    // Run one comparison: fan the prompt to every selected contender, build a
    // record with a fresh shuffle seed, persist it, and return it for display.
    func runComparison(prompt: String, contenders: [ComparisonContender],
                       blind: Bool) async -> ComparisonRecord? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, contenders.count >= 2 else {
            lastError = contenders.count < 2
                ? "Pick at least 2 models to compare."
                : "Type a prompt first."
            return nil
        }
        lastError = nil
        isRunning = true
        defer { isRunning = false }
        let outputs = await Self.fanOut(prompt: trimmed, system: nil, contenders: contenders)
        let record = ComparisonRecord(
            prompt: trimmed,
            outputs: outputs,
            labelSeed: UInt64.random(in: UInt64.min...UInt64.max),
            blind: blind
        )
        ComparisonStore.shared.add(record)
        return record
    }

    // Pure concurrent fan-out, nonisolated + static so tests can drive it with
    // mock backends and zero MainActor / AppState involvement. Results come
    // back in CONTENDER order regardless of completion order.
    // Upper bound on a single contender's response. A backend that accepts the
    // POST but never streams (or streams glacially) would otherwise block the
    // whole Compare run for up to OpenAICompatBackend's 600s resource timeout
    // with the spinner stuck. Past this deadline that contender yields a
    // timed-out error output so the rest of the comparison returns its partial
    // results instead of freezing.
    static let perContenderTimeoutSeconds: TimeInterval = 90

    nonisolated static func fanOut(prompt: String, system: String?,
                                   contenders: [ComparisonContender],
                                   maxTokens: Int = 1024,
                                   temperature: Double = 0.4,
                                   contenderTimeout: TimeInterval = perContenderTimeoutSeconds) async -> [ComparisonOutput] {
        await withTaskGroup(of: (Int, ComparisonOutput).self) { group in
            for (idx, c) in contenders.enumerated() {
                group.addTask {
                    let started = Date()
                    do {
                        let text = try await completeWithTimeout(
                            contender: c, prompt: prompt, system: system,
                            maxTokens: maxTokens, temperature: temperature,
                            timeout: contenderTimeout
                        )
                        let usage = await c.backend.usageSnapshot()
                        return (idx, ComparisonOutput(
                            backendName: c.name, modelId: c.modelId, text: text,
                            latencySeconds: Date().timeIntervalSince(started),
                            inputTokens: usage.input, outputTokens: usage.output
                        ))
                    } catch {
                        return (idx, ComparisonOutput(
                            backendName: c.name, modelId: c.modelId, text: "",
                            latencySeconds: Date().timeIntervalSince(started),
                            errorText: error.localizedDescription
                        ))
                    }
                }
            }
            var slots = [ComparisonOutput?](repeating: nil, count: contenders.count)
            for await (idx, out) in group { slots[idx] = out }
            return slots.compactMap { $0 }
        }
    }

    // Races one contender's completion against a deadline. Whichever child
    // finishes first wins; the loser is cancelled. A hung backend therefore
    // costs at most `timeout` seconds, not the URLSession resource timeout.
    private struct ContenderTimedOut: Error, LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "timed out after \(Int(seconds))s" }
    }

    nonisolated private static func completeWithTimeout(
        contender c: ComparisonContender, prompt: String, system: String?,
        maxTokens: Int, temperature: Double, timeout: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await c.backend.complete(
                    apiKey: c.apiKey, model: c.modelId, system: system,
                    messages: [ClaudeMessage(role: "user", content: prompt)],
                    maxTokens: maxTokens, temperature: temperature,
                    spanName: "compare.fanout", feature: "compare"
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ContenderTimedOut(seconds: timeout)
            }
            defer { group.cancelAll() }
            // First child to finish (real result or the deadline) wins.
            guard let first = try await group.next() else {
                throw ContenderTimedOut(seconds: timeout)
            }
            return first
        }
    }

    // MARK: - Synthesis

    // Send every (anonymized) output to the strongest available backend and
    // ask for one merged best answer. Anonymized so the judge can't play
    // favorites with its own provider. Result lands on the record in the store.
    func synthesize(record: ComparisonRecord, contenders: [ComparisonContender]) async {
        let usable = record.outputs.filter { !$0.failed && !$0.text.isEmpty }
        guard usable.count >= 2 else {
            lastError = "Need at least 2 successful outputs to synthesize."
            return
        }
        guard let judge = Self.strongestContender(among: contenders) else {
            lastError = "No backend available for synthesis."
            return
        }
        lastError = nil
        isSynthesizing = true
        defer { isSynthesizing = false }
        let prompt = Self.synthesisPrompt(for: record)
        do {
            let merged = try await judge.backend.complete(
                apiKey: judge.apiKey, model: judge.modelId,
                system: "You are an expert editor. You merge candidate answers into a single best answer. Output only the merged answer, no preamble, no commentary about the candidates.",
                messages: [ClaudeMessage(role: "user", content: prompt)],
                maxTokens: 2048, temperature: 0.3,
                spanName: "compare.synthesize", feature: "compare"
            )
            ComparisonStore.shared.setSynthesis(
                recordId: record.id,
                text: merged.trimmingCharacters(in: .whitespacesAndNewlines),
                by: judge.name
            )
        } catch {
            lastError = "Synthesis failed: \(error.localizedDescription)"
        }
    }

    // The strongest backend wins judge duty: prefer the Anthropic cloud model,
    // fall back to the first contender (a local model is better than nothing).
    nonisolated static func strongestContender(among contenders: [ComparisonContender]) -> ComparisonContender? {
        contenders.first(where: { $0.backend is ClaudeClient }) ?? contenders.first
    }

    // Anonymous synthesis prompt. Candidates appear in the record's display
    // order under their blind labels so even the judge prompt leaks nothing.
    nonisolated static func synthesisPrompt(for record: ComparisonRecord) -> String {
        var lines: [String] = []
        lines.append("Original question:")
        lines.append(record.prompt)
        lines.append("")
        lines.append("Candidate answers from different anonymous models:")
        for (slot, idx) in record.displayOrder.enumerated() {
            let output = record.outputs[idx]
            guard !output.failed, !output.text.isEmpty else { continue }
            lines.append("")
            lines.append("[Candidate \(ComparisonShuffle.label(forSlot: slot))]")
            lines.append(output.text)
        }
        lines.append("")
        lines.append("Merge the candidates into the single best possible answer. Keep the strongest points from each, drop anything wrong or redundant, and resolve any contradictions in favor of the most accurate claim.")
        return lines.joined(separator: "\n")
    }
}
