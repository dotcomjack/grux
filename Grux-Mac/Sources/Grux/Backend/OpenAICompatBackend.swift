import Foundation

// OpenAI-compatible chat backend. Targets `{baseURL}/v1/chat/completions`, the
// schema Ollama (http://localhost:11434/v1), vLLM, llama.cpp, and OpenRouter all
// speak. It conforms to ModelBackend so ChatService can route a turn through it
// transparently, the translation happens entirely at this boundary, so callers
// never see OpenAI shapes. Streaming yields the EXACT same ClaudeStreamEvent
// sequence the Anthropic backend emits, so ChatService's hop loop, sentence
// flushing, and usageSnapshot logging keep working with no further edits.
actor OpenAICompatBackend: ModelBackend {

    /// Said once, in one place, so both entry points cannot drift.
    static let thinkingBudgetMessage =
        "The local model used its whole reply budget thinking and returned no answer. "
      + "Pick a model without a thinking mode, or raise the reply limit."

    /// A TEXT FIELD USED TO CRASH THE APP, and this sentence is the fix.
    ///
    /// `chatCompletionsURL` force-unwrapped `URL(string:)`, and `init` falls back
    /// to the raw trimmed string when EndpointValidator cannot normalize it. The
    /// Settings "Base URL" field writes straight into config with no validation
    /// (unlike the custom-endpoint form, which validates before save), and
    /// resolvedRouting builds this backend directly from that value. So a base URL
    /// with a space in it made URL(string:) return nil and the force unwrap trap:
    /// one typo, whole process gone, no message, nothing to retry.
    ///
    /// It names the offending string because the whole failure is that the user
    /// cannot see what is wrong with what they typed.
    static func invalidBaseURLMessage(_ base: String) -> String {
        "Grux cannot build a request URL from the base URL \"\(base)\". "
      + "Fix it in Settings under Base URL: it must be a plain http(s) URL with no "
      + "spaces, for example http://localhost:11434."
    }

    private let baseURL: String
    private let session: URLSession

    // Usage stats from the most recent completion, mirrors ClaudeClient's
    // last* caching pattern so usageSnapshot() behaves identically. Local
    // servers don't report cache tokens, so those stay 0.
    private(set) var lastInputTokens: Int = 0
    private(set) var lastOutputTokens: Int = 0
    private(set) var lastCacheCreationTokens: Int = 0
    private(set) var lastCacheReadTokens: Int = 0

    init(baseURL: String) {
        // Normalize through the SINGLE source of truth (EndpointValidator) so
        // the live request URL agrees with the apiKey/custom-endpoint lookup,
        // which also normalizes via EndpointValidator. The old ad-hoc trim was
        // case-sensitive on the /v1 suffix, so an uppercase "/V1" base produced
        // a double-appended ".../V1/v1/chat/completions" (404) AND sent the key
        // to the wrong URL while the key lookup matched the normalized base.
        // Fall back to the raw (trimmed) string only when the URL is unusable,
        // which EndpointValidator already screened before construction.
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = EndpointValidator.normalizeBaseURL(baseURL) ?? trimmed
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120   // local models can be slow to first token
        cfg.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: cfg)
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (lastInputTokens, lastOutputTokens, lastCacheCreationTokens, lastCacheReadTokens)
    }

    // Fallible on purpose. Every entry point below reaches the wire through
    // makeRequest, so throwing here is what turns an unusable base URL into a
    // sentence the user can act on instead of a crash.
    //
    // ClaudeError.localConfiguration is the case for it, and it exists because
    // this throw had nowhere honest to go. It shipped first as .decoding, on
    // the true observation that .decoding was the only case whose payload
    // survives ChatService.humanMessage unchanged (.http is remapped to a
    // generic sentence by status code, which discards the base URL the user
    // has to read). The user then met a request that never left the machine as
    // "Decoding error: Grux cannot build a request URL from ...", which names
    // a response nobody received. The right fix was a case for a LOCAL refusal,
    // not a borrowed one that renders well.
    private func chatCompletionsURL() throws -> URL {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw ClaudeError.localConfiguration(Self.invalidBaseURLMessage(baseURL))
        }
        return url
    }

    // Build the per-request URLRequest. apiKey is a placeholder for local
    // servers ("ollama"), they ignore it, but we send it as a Bearer token
    // anyway so OpenRouter / hosted compat endpoints also work.
    private func makeRequest(stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: try chatCompletionsURL())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        return req
    }

    private func authorize(_ req: inout URLRequest, apiKey: String) {
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Message translation

    // [ClaudeMessage] -> OpenAI [{role, content}], with `system` prepended as a
    // leading {role:"system"} message.
    private func openAIMessages(system: String?, messages: [ClaudeMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let system, !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for m in messages {
            out.append(["role": m.role, "content": m.content])
        }
        return out
    }

    // systemBlocks [[String:Any]] -> a single concatenated system message.
    // cache_control is dropped (no-op on local servers).
    private func systemMessageFromBlocks(_ systemBlocks: [[String: Any]]) -> [String: Any]? {
        let text = systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return ["role": "system", "content": text]
    }

    // ClaudeTool -> OpenAI {type:"function", function:{name, description, parameters}}.
    private func openAITools(_ tools: [ClaudeTool]) -> [[String: Any]] {
        tools.map { t in
            [
                "type": "function",
                "function": [
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.inputSchema
                ]
            ]
        }
    }

    // MARK: - complete (non-stream, plain text)

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int = 1024, temperature: Double = 0.2,
                  spanName: String = "openai.complete", feature: String = "uncategorized") async throws -> String {
        var req = try makeRequest(stream: false)
        authorize(&req, apiKey: apiKey)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": openAIMessages(system: system, messages: messages)
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ClaudeError.http(http.statusCode, errBody)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("openai: top-level not dict")
        }
        let (inTok, outTok) = Self.usageFrom(obj)
        self.lastInputTokens = inTok
        self.lastOutputTokens = outTok
        self.lastCacheCreationTokens = 0
        self.lastCacheReadTokens = 0
        let choices = obj["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        // A REASONING MODEL THAT RAN OUT OF BUDGET RETURNS NOTHING, SILENTLY.
        //
        // Measured on qwen3.5:4b through this exact endpoint: 14.3s, 2,433
        // characters in the `reasoning` field, and `content` EMPTY. Twice in a
        // row, at an 800 token budget that had produced an answer minutes
        // earlier, so it is not even deterministic. The user sees a long wait
        // and then nothing at all, with no way to tell whether Grux broke or
        // the model did.
        //
        // Empty content plus non-empty reasoning is a diagnosable state, so
        // diagnose it instead of returning "" up the stack.
        if content.isEmpty, let reasoning = message?["reasoning"] as? String, !reasoning.isEmpty {
            throw ClaudeError.http(200, Self.thinkingBudgetMessage)
        }
        return content
    }

    // MARK: - completeVision (degraded on most local models)

    /// The one degrade this path is allowed to make, said once so the backend
    /// and the test that guards it cannot end up holding two different copies.
    static let visionUnsupportedMessage = "vision unsupported by local backend"

    /// The status codes where a non-2xx genuinely means THE MODEL REJECTED THE
    /// PICTURE, rather than the call never being allowed or served at all.
    ///
    /// A text-only model answers an `image_url` content block with 400, and a
    /// schema-validating server (vLLM) answers the same block with 422. Every
    /// other code is a statement about the CALL, not about the image.
    private static let visionRejectionCodes: Set<Int> = [400, 422]

    /// The words a provider's own sentence uses when what it rejected is the
    /// PICTURE. Matched case-insensitively against that sentence, and it is
    /// openly a HEURISTIC OVER PROVIDER PROSE: there is no machine-readable
    /// field for "this model has no eyes", so the sentence is all there is.
    ///
    /// Each word earns its place from a real rejection line. "image" is the
    /// object the servers name ("This model does not support image input"),
    /// and it covers the `image_url` content-block type they quote back by
    /// substring; "vision" is the capability; "multimodal" and "modality" are
    /// what vLLM and llama.cpp call the class of model they refused to be.
    ///
    /// IT ERRS TOWARD PASSING THE PROVIDER'S SENTENCE THROUGH. A vision
    /// rejection phrased with none of these words loses the automatic degrade
    /// and shows the server's own words instead, which is never a false claim.
    /// The other direction is the one that hurt: a 400 for a blown context
    /// window wearing "vision unsupported by local backend" sends somebody to
    /// change models when the fix was to shorten the prompt, and that is the
    /// wrong-cause defect `visionFailure` exists to undo.
    private static let visionRejectionWords = ["image", "vision", "multimodal", "modality"]

    private static func namesTheImage(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return visionRejectionWords.contains { lowered.contains($0) }
    }

    /// Turn a non-2xx from the vision endpoint into an error that names the
    /// RIGHT failure.
    ///
    /// EVERY non-2xx USED TO COLLAPSE INTO `http(400, visionUnsupportedMessage)`,
    /// and that is the defect this function exists to undo. A wrong or expired
    /// key (401), a key without access (403), a rate limit (429) and a provider
    /// outage (5xx) all came back reading "your model cannot see images". So a
    /// user holding a stale key was told to pick a different model, which is
    /// the one move that cannot help, while the real reason sat unread in the
    /// response body this code had just thrown away. Someone told the wrong
    /// cause fixes the wrong thing, and then concludes the product is broken.
    ///
    /// Only 400 and 422 are ELIGIBLE for the degrade, because those are the
    /// codes a server returns after reading the request and rejecting its
    /// SHAPE (what makes one of them earn it is below). 422 is reported as
    /// 400 so the status does not depend on which server answered.
    ///
    /// NO CALLER OBSERVES THIS TODAY, and the doc used to claim otherwise.
    /// It said `VisionTool` and `FocusWatcher` "both name `http(400, ...)` as
    /// the contract they degrade on". Neither does: all three completeVision
    /// call sites (`VisionTool`, `FocusWatcher`, `UXAuditSource`) ask
    /// `ModelRegistry.resolvedRouting(provider: "anthropic", ...)`, which
    /// returns the Anthropic client unconditionally, so this method is
    /// unreachable from Sources and no caller branches on the status at all.
    /// The normalization is kept because it is right for the day a vision
    /// call is routed locally; the claim that something depends on it was
    /// false, and a false rationale is what the next edit trusts.
    /// The contract is the STATUS CODE, so the degrade's MESSAGE keeps the
    /// provider's own sentence when it wrote one. Nothing in Sources matches
    /// on the message's equality (only tests do, and they assert the constant
    /// as a prefix), so composing here breaks no caller.
    ///
    /// THE STATUS ALONE DOES NOT MEAN THE MODEL CANNOT SEE, and that was the
    /// half-fix. Compat servers answer 400 for a blown context window and for
    /// an oversized payload too, so keeping the degrade on the code alone
    /// composed "vision unsupported by local backend. The provider said: This
    /// model's maximum context length is 4096 tokens", which is the same
    /// wrong-cause shape in a longer sentence: the reader is told to change
    /// models by the first clause and to shorten the prompt by the second.
    /// So a 400 or 422 whose sentence does NOT name the picture (see
    /// `visionRejectionWords`) passes through at its OWN status carrying that
    /// sentence and nothing else. The degrade, and with it the 422-to-400
    /// normalization, is kept for a genuine shape rejection and for a 400 or
    /// 422 with no usable sentence, where the status is the only evidence
    /// there is.
    ///
    /// Every other status passes through with its OWN status, carrying the
    /// provider's own sentence when it wrote one. That sentence is extracted by
    /// the SAME reader the chat path uses (`ChatService.providerMessage`), so
    /// the two surfaces cannot drift, and what it returns is a line written for
    /// a person rather than a slab of JSON. With nothing quotable the raw body
    /// goes through untouched: `ClaudeError.errorDescription` caps its length,
    /// and `ChatService.humanMessage` already turns a bare 401, 403, 429 or 5xx
    /// into an actionable sentence without reading the body at all.
    static func visionFailure(status: Int, body: String) -> ClaudeError {
        if visionRejectionCodes.contains(status) {
            guard let provider = ChatService.providerMessage(from: body) else {
                return .http(400, visionUnsupportedMessage)
            }
            if namesTheImage(provider) {
                return .http(400, "\(visionUnsupportedMessage). The provider said: \(provider)")
            }
            return .http(status, provider)
        }
        if let provider = ChatService.providerMessage(from: body) {
            return .http(status, provider)
        }
        return .http(status, body)
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String = "image/jpeg",
                        maxTokens: Int = 500, temperature: Double = 0.15,
                        spanName: String = "openai.completeVision", feature: String = "vision") async throws -> String {
        var req = try makeRequest(stream: false)
        authorize(&req, apiKey: apiKey)
        // OpenAI multimodal content shape: a user message with an image_url block
        // (data URI) followed by a text block. Many local models lack vision and
        // will 400 / 422, and only those two surface as ClaudeError.http(400, ...)
        // so callers degrade ("image analysis needs network") rather than crash.
        // Every other status keeps its own meaning, see visionFailure above.
        let base64 = imageJPEG.base64EncodedString()
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]],
                ["type": "text", "text": userText]
            ]
        ])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // NO `catch` HERE, DELIBERATELY, AND THAT IS PART OF THE FIX.
        //
        // This body used to sit inside a `do` whose final clause turned ANY
        // thrown error into the vision degrade. So a local server that was not
        // running, a DNS failure, a timeout and a truncated JSON body all told
        // the user "vision unsupported by local backend": four different fixes,
        // one sentence, and none of them the right one. `complete` and
        // `completeWithTools` above never had that catch and let the transport
        // error speak for itself, which is how a refused connection reads as
        // "Could not connect to the server" instead of as a missing feature.
        // This path now matches its siblings.
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.visionFailure(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        // A 2xx whose body is not JSON at all is a proxy answering the vision
        // POST with an HTML error page. JSONSerialization throws its own
        // NSError for that, before any dictionary cast can run, and raw it
        // renders as "The data couldn't be read because it isn't in the
        // correct format": no status, no action. Caught around this one parse
        // only, so a transport failure above still speaks for itself.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeError.decoding("openai: vision 2xx body not JSON")
        }
        guard let obj = parsed as? [String: Any] else {
            // Valid JSON whose top level is not an object, named the same way
            // the siblings name it.
            throw ClaudeError.decoding("openai: vision top-level not dict")
        }
        let (inTok, outTok) = Self.usageFrom(obj)
        self.lastInputTokens = inTok
        self.lastOutputTokens = outTok
        self.lastCacheCreationTokens = 0
        self.lastCacheReadTokens = 0
        let choices = obj["choices"] as? [[String: Any]] ?? []
        let msg = choices.first?["message"] as? [String: Any]
        let text = msg?["content"] as? String ?? ""
        if text.isEmpty, let reasoning = msg?["reasoning"] as? String, !reasoning.isEmpty {
            throw ClaudeError.http(200, Self.thinkingBudgetMessage)
        }
        return text
    }

    // MARK: - streamCompleteWithTools (SSE, the routed chat path)

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int = 2048, temperature: Double = 0.3,
                                 spanName: String = "openai.streamCompleteWithTools", feature: String = "chat")
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var finalStopReason: String? = nil
                // Accumulated usage if the server reports it on the final chunk
                // (Ollama sends usage when stream_options.include_usage is set).
                var inTok = 0, outTok = 0
                do {
                    var req = try makeRequest(stream: true)
                    authorize(&req, apiKey: apiKey)
                    // Prepend the concatenated system blocks as a system message.
                    var oaMessages: [[String: Any]] = []
                    if let sys = systemMessageFromBlocks(systemBlocks) { oaMessages.append(sys) }
                    oaMessages.append(contentsOf: messages)
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "temperature": temperature,
                        "messages": oaMessages,
                        "stream": true,
                        "stream_options": ["include_usage": true]
                    ]
                    if !tools.isEmpty {
                        body["tools"] = openAITools(tools)
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

                    // ONE AT A TIME. There is one GPU, and six concurrent
                    // prompts against an 8B model were measured turning 0.38s of
                    // work into 102s of waiting. Queueing here instead of inside
                    // the server costs nothing in throughput and keeps the
                    // machine responsive. `defer` so a thrown error still frees
                    // the slot, otherwise one failure deadlocks every later call.
                    await LocalModelGate.shared.acquire()
                    defer { Task { await LocalModelGate.shared.release() } }

                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line + "\n"; if errBody.count > 800 { break } }
                        throw ClaudeError.http(http.statusCode, errBody)
                    }

                    // SSE parser state. OpenAI streams text via choices[].delta.content
                    // and tool calls via choices[].delta.tool_calls[], where each
                    // tool_call has an `index`, an `id`/`function.name` on first
                    // appearance, and `function.arguments` string fragments that
                    // accumulate. We map these to the Claude event sequence
                    // ChatService consumes: toolUseStart -> InputDelta* -> toolUseStop.
                    var textBlockOpen = false
                    // Per-index tool-call accumulators.
                    struct ToolAccum { var id: String = ""; var name: String = ""; var args: String = ""; var started = false }
                    var toolAccums: [Int: ToolAccum] = [:]

                    func closeTextBlockIfOpen() {
                        if textBlockOpen {
                            continuation.yield(.textBlockStop)
                            textBlockOpen = false
                        }
                    }

                    // MALFORMED TOOL ARGUMENTS BECOME AN EMPTY DICTIONARY AND
                    // THE TOOL RUNS ANYWAY, and that is named here rather than
                    // fixed, so the next reader inherits it knowingly instead of
                    // by accident. `try?` cannot tell "the model streamed
                    // truncated JSON" apart from "the model sent no arguments",
                    // so a tool that needed a path or a query is dispatched with
                    // neither and fails somewhere further down, where the cause
                    // is no longer visible. A local model producing broken tool
                    // JSON is the ordinary case, not the exotic one, which is
                    // what makes this worth a sentence. Left alone deliberately:
                    // it is pre-existing behaviour, ChatService's hop loop is
                    // what would have to decide the alternative, and changing it
                    // here would be a routing change wearing a parser's clothes.
                    //
                    // The `?? [:]` fills in for a nil parse. There is no second
                    // one, because `try?` flattens the nested optional: the
                    // coalesce below already produced a non-optional dictionary
                    // and a second one was dead code the compiler warned about.
                    func finishToolCall(_ idx: Int) {
                        guard var acc = toolAccums[idx], acc.started else { return }
                        let input = (try? JSONSerialization.jsonObject(with: Data(acc.args.utf8)) as? [String: Any]) ?? [:]
                        continuation.yield(.toolUseStop(id: acc.id, name: acc.name, input: input))
                        acc.started = false
                        toolAccums[idx] = acc
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard !payload.isEmpty,
                              let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        // Usage can arrive on its own final chunk (choices empty).
                        if let usage = obj["usage"] as? [String: Any] {
                            inTok = usage["prompt_tokens"] as? Int ?? inTok
                            outTok = usage["completion_tokens"] as? Int ?? outTok
                        }

                        guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                        if let fr = choice["finish_reason"] as? String, !fr.isEmpty {
                            finalStopReason = fr
                        }
                        guard let delta = choice["delta"] as? [String: Any] else { continue }

                        // Text content delta.
                        if let txt = delta["content"] as? String, !txt.isEmpty {
                            if !textBlockOpen {
                                continuation.yield(.textBlockStart)
                                textBlockOpen = true
                            }
                            continuation.yield(.textDelta(txt))
                        }

                        // Tool-call deltas.
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            // A tool call starting means any open text block ends.
                            closeTextBlockIfOpen()
                            for tc in toolCalls {
                                let idx = tc["index"] as? Int ?? 0
                                var acc = toolAccums[idx] ?? ToolAccum()
                                if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
                                if let fn = tc["function"] as? [String: Any] {
                                    if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                                    if let args = fn["arguments"] as? String, !args.isEmpty {
                                        acc.args += args
                                        if !acc.started {
                                            // First fragment for this index, open the block.
                                            acc.started = true
                                            toolAccums[idx] = acc
                                            continuation.yield(.toolUseStart(id: acc.id, name: acc.name))
                                        }
                                        continuation.yield(.toolUseInputDelta(partial: args))
                                    }
                                }
                                // If the start arrived with a name but no args yet, still open.
                                if !acc.started, !acc.name.isEmpty {
                                    acc.started = true
                                    continuation.yield(.toolUseStart(id: acc.id, name: acc.name))
                                }
                                toolAccums[idx] = acc
                            }
                        }

                        // finish_reason == "tool_calls" means the model is done
                        // streaming tool args, close every open tool block.
                        if (choice["finish_reason"] as? String) == "tool_calls" {
                            for idx in toolAccums.keys.sorted() { finishToolCall(idx) }
                        }
                    }

                    // Stream ended. Close anything still open so ChatService's
                    // block bookkeeping stays balanced.
                    closeTextBlockIfOpen()
                    for idx in toolAccums.keys.sorted() { finishToolCall(idx) }
                    continuation.yield(.messageStop(stopReason: finalStopReason))

                    self.lastInputTokens = inTok
                    self.lastOutputTokens = outTok
                    self.lastCacheCreationTokens = 0
                    self.lastCacheReadTokens = 0
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - completeWithTools (non-stream tool variant)

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int = 2048, temperature: Double = 0.3,
                           spanName: String = "openai.completeWithTools", feature: String = "tool_use") async throws -> ClaudeToolsResponse {
        var req = try makeRequest(stream: false)
        authorize(&req, apiKey: apiKey)
        var oaMessages: [[String: Any]] = []
        if let system, !system.isEmpty { oaMessages.append(["role": "system", "content": system]) }
        oaMessages.append(contentsOf: messages)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": oaMessages
        ]
        if !tools.isEmpty { body["tools"] = openAITools(tools) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ClaudeError.http(http.statusCode, errBody)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("openai: top-level not dict")
        }
        let (inTok, outTok) = Self.usageFrom(obj)
        self.lastInputTokens = inTok
        self.lastOutputTokens = outTok
        self.lastCacheCreationTokens = 0
        self.lastCacheReadTokens = 0
        let choices = obj["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        var blocks: [ClaudeBlock] = []
        if let text = message?["content"] as? String, !text.isEmpty {
            blocks.append(.text(text))
        }
        if let toolCalls = message?["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let id = tc["id"] as? String ?? ""
                if let fn = tc["function"] as? [String: Any] {
                    let name = fn["name"] as? String ?? ""
                    let argsStr = fn["arguments"] as? String ?? "{}"
                    // Same swallowed parse as finishToolCall above, same
                    // reasoning, and unchanged for the same reason: a malformed
                    // arguments blob dispatches the tool with an empty input
                    // dictionary. Both sites, one behaviour, so whoever fixes it
                    // fixes it twice or not at all.
                    let input = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                    blocks.append(.toolUse(id: id, name: name, input: input))
                }
            }
        }
        return ClaudeToolsResponse(blocks: blocks, stopReason: choices.first?["finish_reason"] as? String)
    }

    // Read OpenAI-style usage from a response object: usage.prompt_tokens ->
    // input, usage.completion_tokens -> output. Returns (0,0) when absent.
    private static func usageFrom(_ obj: [String: Any]) -> (Int, Int) {
        guard let usage = obj["usage"] as? [String: Any] else { return (0, 0) }
        let inTok = usage["prompt_tokens"] as? Int ?? 0
        let outTok = usage["completion_tokens"] as? Int ?? 0
        return (inTok, outTok)
    }
}
