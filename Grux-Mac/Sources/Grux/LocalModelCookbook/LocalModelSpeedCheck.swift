import Foundation

/// Times a freshly downloaded local model on THIS Mac before Grux makes it
/// the default.
///
/// The Cookbook ranks by quality measured on a GPU, and quality is not speed.
/// Measured on a 16 GB Mac mini (2026-10-22, `"think": false`, 16K window):
/// gemma4:12b, the 32 GB pick, took 35.8 s p50 for a chat turn with tools
/// and 1.26 s for a dictation repair; qwen3.5:4b took 1.28 s and 0.58 s. A
/// dictation-only check would have passed a model whose chat is unusable, so
/// a download is timed on both: one dictation repair (TranscriptCorrector's
/// own prompt and limit) and one warm chat turn with the lean local prompt and
/// the everyday tools. Missing either keeps `fallback` as the default and
/// says which check missed and by how much.
enum LocalModelSpeedCheck {

    // THE LIMITS, IN ONE PLACE.

    /// TranscriptCorrector's own: past it, dictation keeps the raw words.
    static let dictationLimit: TimeInterval = TranscriptCorrector.timeout

    /// To the end of a chat reply.
    static let chatLimit: TimeInterval = 8.0

    /// A timed call is cut off at this multiple of its limit, so a model that
    /// hangs is reported as missing without holding the download screen.
    static let cutoffFactor: Double = 2.0

    /// The first call loads the model and its chat prompt, which is not what
    /// a person waits on turn after turn, so it is untimed and only bounded.
    static let warmLimit: TimeInterval = 180

    /// Ten words, the size of a dictated command.
    static let dictationSample = "add a tusk to my list to call the plumber"

    static let chatSample = "Hi, what can you help me with today?"

    /// The turn before the timed one.
    static let warmSample = "Hello."

    enum Check: String, Equatable {
        case dictation, chat

        var limit: TimeInterval { self == .dictation ? dictationLimit : chatLimit }

        var what: String { self == .dictation ? "a dictation repair" : "a chat reply" }
    }

    /// The first check a model missed. `seconds` is how long it took, or nil
    /// when it did not answer before the cutoff (or failed).
    struct Miss: Equatable {
        let check: Check
        let seconds: TimeInterval?
    }

    /// The model kept when a bigger pick is too slow: the catalog entry marked
    /// `speedFallback` (Qwen 3.5 4B, 0.58 s dictation and 1.28 s chat on that
    /// 16 GB Mac mini).
    static var fallback: CookbookModel? { Cookbook.catalog.first { $0.speedFallback } }

    /// Only a pick bigger than the fallback is timed: nothing faster is kept
    /// for an 8 GB Mac's smaller pick, or for the fallback itself, or on an
    /// Ollama too old to run the fallback (D25: nothing to fall back to, and a
    /// pull of it would fail).
    static func applies(to pick: CookbookModel, ollamaVersion: String? = Cookbook.knownOllamaVersion) -> Bool {
        guard let fallback, Cookbook.runs(fallback, onOllama: ollamaVersion) else { return false }
        return pick.id != fallback.id && pick.estimatedMemoryGB > fallback.estimatedMemoryGB
    }

    /// Runs the timed calls, chat then dictation, and returns the first miss, nil when both
    /// are within their limits. A call returns whether it answered. Exactly
    /// on a limit is within it. `report` hears each timed call: the check,
    /// its seconds, and whether it answered.
    static func firstMiss(now: () -> TimeInterval,
                          report: (Check, TimeInterval, Bool) -> Void = { _, _, _ in },
                          dictation: () async -> Bool,
                          chat: () async -> Bool) async -> Miss? {
        // Chat first: it runs straight after the warm turn, while the server
        // still holds that prompt.
        if let miss = await time(.chat, now: now, report: report, chat) { return miss }
        return await time(.dictation, now: now, report: report, dictation)
    }

    private static func time(_ check: Check, now: () -> TimeInterval,
                             report: (Check, TimeInterval, Bool) -> Void,
                             _ call: () async -> Bool) async -> Miss? {
        let start = now()
        let answered = await call()
        let took = now() - start
        report(check, took, answered)
        if !answered { return Miss(check: check, seconds: nil) }
        return took > check.limit ? Miss(check: check, seconds: took) : nil
    }

    /// The one plain line. `kept` is what stays the default.
    static func line(model: CookbookModel, miss: Miss, kept: CookbookModel, keptIsFallback: Bool) -> String {
        let name = "\(model.displayName) \(model.parameterLabel)"
        let limit = String(format: "%.1f s", miss.check.limit)
        let measured: String
        if let s = miss.seconds {
            measured = String(format: "%@ took %.1f s for %@ on this Mac, %.1f s over the %@ limit",
                              name, s, miss.check.what, s - miss.check.limit, limit)
        } else {
            measured = String(format: "%@ did not answer %@ within %.1f s on this Mac (limit %@)",
                              name, miss.check.what, miss.check.limit * cutoffFactor, limit)
        }
        let keptName = "\(kept.displayName) \(kept.parameterLabel)"
        if keptIsFallback {
            return "Grux kept \(keptName) as the default: \(measured)."
        }
        return "\(measured), and \(keptName) could not be downloaded in its place, so \(name) stays the default."
    }

    struct Outcome: Equatable {
        /// The model to make the default.
        let adopt: CookbookModel
        /// The line to show, nil when the pick was fast enough or not timed.
        let note: String?
    }

    /// After `pick` downloaded: time it, and on a miss fetch the fallback and
    /// keep it. `measure` and `fetch` are the seams tests drive; `fetch`
    /// returns whether the model is installed afterwards.
    static func settle(pick: CookbookModel,
                       ollamaVersion: String? = Cookbook.knownOllamaVersion,
                       measure: (CookbookModel) async -> Miss?,
                       fetch: (CookbookModel) async -> Bool) async -> Outcome {
        guard applies(to: pick, ollamaVersion: ollamaVersion), let fallback else { return Outcome(adopt: pick, note: nil) }
        guard let miss = await measure(pick) else { return Outcome(adopt: pick, note: nil) }
        if await fetch(fallback) {
            return Outcome(adopt: fallback, note: line(model: pick, miss: miss, kept: fallback, keptIsFallback: true))
        }
        return Outcome(adopt: pick, note: line(model: pick, miss: miss, kept: fallback, keptIsFallback: false))
    }

    /// The model to write into config when the check kept the fallback, nil
    /// when it did not. Written at once, not left to the caller's adopt step:
    /// any discovery in between (first run runs one straight after, and the
    /// Cookbook pane or Settings can run one during a check that takes
    /// minutes) sees the shipped default and writes the hardware headline,
    /// which is the slow pick, now installed. A recorded fallback reads as
    /// chosen, so discovery leaves it alone. A model the person chose that is
    /// installed and is not the pick stays theirs.
    static func modelToRecord(outcome: Outcome, pick: CookbookModel,
                              configured: String, installed: [String]) -> String? {
        guard let fallback, outcome.adopt.id == fallback.id, outcome.adopt.id != pick.id else { return nil }
        let personChoseAnInstalledModel = Cookbook.userHasChosenModel(configured)
            && configured != pick.id
            && GruxConfig.usableLocalModels(installed).contains(configured)
        return personChoseAnInstalledModel ? nil : fallback.id
    }

    // MARK: - The real calls

    /// Times `model` on `backend` with the requests Grux really sends: the
    /// lean local system prompt with the everyday tools, and the dictation
    /// repair prompt.
    ///
    /// WARM MEANS THE SAME PROMPT. Measured on a 16 GB Mac mini (2026-10-22,
    /// qwen3.5:4b): with a one-line warm call, the timed chat turn processed
    /// all 4,172 tokens of the lean prompt cold (Ollama's prefix cache keeps
    /// the last request) and took 11.96 s. So the untimed warm turn is the real
    /// chat request, the turn before it in a conversation, and the timed chat
    /// turn follows it directly.
    ///
    /// AND THE TIMED TURN IS THE NEXT TURN. Measured again (10:57 PM, nothing
    /// else on Ollama): a timed turn that replaced the warm user line diverged
    /// 19 tokens before the end of the cached prompt and Ollama reused none of
    /// it (`matched=4459 cached=0`, 13.11 s). qwen3.5 is a hybrid recurrent
    /// model whose cache resumes only from the end of an earlier request, as a
    /// person's next turn does, so the timed request carries the warm turn and
    /// its reply before the new line.
    static func measure(model: String, backend: ModelBackend, apiKey: String,
                        chatSystem: String, chatTools: [ClaudeTool],
                        knownTerms: [String],
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        report: (Check, TimeInterval, Bool) -> Void = { _, _, _ in }) async -> Miss? {
        let warmReply = await TranscriptCorrector.withTimeout(seconds: warmLimit) {
            try? await backend.completeWithTools(apiKey: apiKey, model: model, system: chatSystem,
                                                 messages: [["role": "user", "content": warmSample]],
                                                 tools: chatTools, maxTokens: LocalTurn.replyTokens,
                                                 temperature: 0.3,
                                                 spanName: "cookbook.speed.warm", feature: "model_speed_check")
        }
        let warmText = warmReply?.allText ?? ""
        let dictationSystem = TranscriptCorrector.systemPrompt(knownTerms: knownTerms)
        return await firstMiss(now: now, report: report, dictation: {
            let reply = await TranscriptCorrector.withTimeout(seconds: dictationLimit * cutoffFactor) {
                try? await backend.complete(apiKey: apiKey, model: model, system: dictationSystem,
                                            messages: [ClaudeMessage(role: "user", content: dictationSample)],
                                            maxTokens: TranscriptCorrector.replyTokens, temperature: 0.0,
                                            spanName: "cookbook.speed.dictation", feature: "model_speed_check")
            }
            return !(reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }, chat: {
            let reply = await TranscriptCorrector.withTimeout(seconds: chatLimit * cutoffFactor) {
                try? await backend.completeWithTools(apiKey: apiKey, model: model, system: chatSystem,
                                                     messages: [["role": "user", "content": warmSample],
                                                                ["role": "assistant", "content": warmText],
                                                                ["role": "user", "content": chatSample]],
                                                     tools: chatTools, maxTokens: LocalTurn.replyTokens,
                                                     temperature: 0.3,
                                                     spanName: "cookbook.speed.chat", feature: "model_speed_check")
            }
            guard let reply else { return false }
            return !reply.allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reply.toolUses.isEmpty
        })
    }

    /// The tools a local chat turn offers first when nothing points elsewhere.
    static func everydayTools(from all: [ClaudeTool]) -> [ClaudeTool] {
        LocalTurn.everyday.compactMap { name in all.first { $0.name == name } }
    }
}

/// The app's side: the local server, the live prompt, the download, and where
/// the line is shown.
@MainActor
enum LocalModelSpeedGuard {
    /// Called by both download paths (first run and Settings, Connect a
    /// model) once `pick` is installed. Returns the model to adopt.
    static func settle(pick: CookbookModel, onPulling: (CookbookModel?) -> Void) async -> CookbookModel {
        let outcome = await LocalModelSpeedCheck.settle(pick: pick, measure: { model in
            await measure(modelId: model.id)
        }, fetch: { fallback in
            if OllamaManager.shared.isInstalled(fallback.id) { return true }
            onPulling(fallback)
            _ = await OllamaManager.shared.pullToEnd(fallback.id)
            onPulling(nil)
            await OllamaManager.shared.refreshInstalled()
            return OllamaManager.shared.isInstalled(fallback.id)
        })
        if let note = outcome.note {
            WakeLog.shared.log("speed-check: \(note)")
        } else if LocalModelSpeedCheck.applies(to: pick) {
            WakeLog.shared.log("speed-check: \(pick.id) is within \(LocalModelSpeedCheck.dictationLimit) s dictation and \(LocalModelSpeedCheck.chatLimit) s chat")
        }
        CookbookStore.shared.noteSpeed(outcome.note)
        if let recorded = LocalModelSpeedCheck.modelToRecord(
            outcome: outcome, pick: pick,
            configured: AppState.shared.config.offlineLLMModel,
            installed: OllamaManager.shared.installedTags) {
            AppState.shared.config.offlineLLMModel = recorded
            AppState.shared.config.localLLMModel = recorded
            AppState.shared.saveConfig()
            WakeLog.shared.log("speed-check: \(recorded) recorded as the default")
        }
        return outcome.adopt
    }

    /// Times an installed model with the real requests on this Mac's local
    /// server and logs each call. Changes nothing: the `fire-speed-check`
    /// trigger uses it to show the timings without a download.
    static func measure(modelId: String) async -> LocalModelSpeedCheck.Miss? {
        let base = AppState.shared.config.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend: ModelBackend = ModelRegistry.shared.local
            ?? OpenAICompatBackend(baseURL: base.isEmpty ? "http://localhost:11434" : base)
        let terms = WhisperVocab.baseTerms + ProfileMemoryStore.shared.slang.prefix(20).map { $0.term }
        WakeLog.shared.log("speed-check: timing \(modelId) on this Mac")
        return await LocalModelSpeedCheck.measure(
            model: modelId, backend: backend, apiKey: ModelRegistry.shared.localApiKey(),
            chatSystem: ChatService.shared.leanSystemText(state: AppState.shared),
            chatTools: LocalModelSpeedCheck.everydayTools(from: ChatService.allTools()),
            knownTerms: terms,
            report: { check, seconds, answered in
                WakeLog.shared.log(String(format: "speed-check: %@ %@ %.2f s (limit %.1f s)", modelId,
                                          answered ? check.what : "\(check.what), no answer,", seconds, check.limit))
            })
    }
}
