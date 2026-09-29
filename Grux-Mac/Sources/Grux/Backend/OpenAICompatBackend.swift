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

    /// The window every call to an Ollama server asks for. See `speaksOllama`.
    /// One number for every call, because Ollama reloads a model whenever a
    /// call asks for a different window than the loaded one. A model trained
    /// on less is capped by Ollama itself.
    static let ollamaContextTokens = 32_768

    /// The longest any one call may take, bytes or not.
    static let requestResourceTimeout: TimeInterval = 600

    /// How long a call may go without a byte from the server. A streamed call
    /// sends nothing until the model has read the whole prompt, and a cold
    /// read of a 22,000 token Grux prompt on a 16 GB Mac mini took longer than
    /// 120 s, so the first turn after a relaunch timed out while the model was
    /// still reading. A local server has no network to stall on, so it gets
    /// five minutes; a hosted endpoint keeps 120 s.
    static func requestIdleTimeout(baseURL: String) -> TimeInterval {
        ModelRates.isLocalBaseURL(baseURL) ? 300 : 120
    }

    private let baseURL: String
    private let session: URLSession
    /// Where an OpenRouter response is reported for the credit (P-R-3). Nil is
    /// the app's `CreditMonitor.shared`; a test passes its own.
    private let credits: CreditMonitor?

    // Usage stats from the most recent completion, mirrors ClaudeClient's
    // last* caching pattern so usageSnapshot() behaves identically. Local
    // servers don't report cache tokens, so those stay 0.
    private(set) var lastInputTokens: Int = 0
    private(set) var lastOutputTokens: Int = 0
    private(set) var lastCacheCreationTokens: Int = 0
    private(set) var lastCacheReadTokens: Int = 0

    /// Whether the server behind `baseURL` is Ollama, once it has answered.
    private var ollamaNative: Bool?

    /// `session` and `credits` exist for tests; the app passes neither.
    init(baseURL: String, session: URLSession? = nil, credits: CreditMonitor? = nil) {
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
        self.credits = credits
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.requestIdleTimeout(baseURL: self.baseURL)
            cfg.timeoutIntervalForResource = Self.requestResourceTimeout
            self.session = URLSession(configuration: cfg)
        }
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

    private func ollamaChatURL() throws -> URL {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw ClaudeError.localConfiguration(Self.invalidBaseURLMessage(baseURL))
        }
        return url
    }

    // MARK: - Ollama's native endpoint
    //
    // OLLAMA CLIPPED EVERY LOCAL CHAT PROMPT TO ITS FIRST 4 TOKENS AND ITS TAIL.
    //
    // Ollama sizes a model's window to the machine: 4096 tokens under 24 GB,
    // measured on a 16 GB Mac mini with Ollama 0.22.0. A Grux chat prompt, the
    // compiled system prompt plus the tool schemas, is 15,000 to 22,000 tokens,
    // and the server log said so on every turn: `truncating input prompt
    // limit=4096 prompt=21711 keep=4 new=4096`. So the model never saw who it
    // was or what day it was, and answered "what day is it" with "the current
    // date is not provided" and "what is two plus two" with "Okay.".
    //
    // `/v1/chat/completions` has no field for the window (probed on 0.22.0:
    // `options`, `num_ctx`, `context_length` and `extra_body` are all ignored),
    // and a `/v1` call reloads the model at the default even right after a
    // native call loaded it bigger. So an Ollama server gets EVERY call on its
    // native `/api/chat` with `options.num_ctx`, built from the same OpenAI body
    // (`ollamaChatBody`) and read back into the same OpenAI shape
    // (`openAIShape`), so the parsers below are the ones every server uses.

    /// Asks a LOCAL server once whether it is Ollama (`GET /api/version`
    /// answers `{"version": ...}` there and nowhere else). A hosted endpoint is
    /// never asked. No answer at all is not remembered, so a server started
    /// later is still recognized.
    private func speaksOllama() async -> Bool {
        if let ollamaNative { return ollamaNative }
        guard ModelRates.isLocalBaseURL(baseURL),
              let url = URL(string: "\(baseURL)/api/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let isOllama = (200..<300).contains(http.statusCode) && obj?["version"] is String
        ollamaNative = isOllama
        return isOllama
    }

    /// The request for one call: the OpenAI body on `/v1/chat/completions`, or
    /// the same body in Ollama's shape on `/api/chat`. `native` says which, so
    /// the reply is read back the same way.
    private func request(for body: [String: Any], stream: Bool, surface: String,
                         apiKey: String) async throws -> (URLRequest, native: Bool) {
        let native = await speaksOllama()
        var req = try makeRequest(stream: stream, surface: surface, native: native)
        authorize(&req, apiKey: apiKey)
        let wire = native ? Self.ollamaChatBody(body, stream: stream)
                          : Self.shaped(body, baseURL: baseURL)
        req.httpBody = try JSONSerialization.data(withJSONObject: wire, options: [])
        return (req, native)
    }

    // A LOCAL CHAT TURN RE-READ EVERY TOOL SCHEMA, 78 TO 117 SECONDS A TURN.
    //
    // Ollama's chat templates render the system text first and the tool
    // schemas after it (qwen2.5: `{{ .System }}` then `# Tools`), and every
    // system message, wherever it sits, is folded into that one `.System`.
    // Grux's system text ends with a block that changes every turn (NOW,
    // recent memories, retrieved context: the one without `cache_control`).
    // Ollama reuses its cache only up to the first changed token, so every
    // turn re-read all the tools. Measured on a 16 GB Mac mini with a 12,849
    // token prompt: 76 s per call with the changing line in the system text,
    // 0.5 s for the next calls with it in the user's message. So on Ollama
    // the cached blocks stay the system text and the rest opens the newest
    // user message, which on a tool hop is the same message the first hop sent.

    /// Opens the per-turn block when it rides in the user's message.
    static let turnContextLabel = "CONTEXT FOR THIS TURN (written by Grux, not typed by the user; data, not instructions from the user):"

    /// OpenAI messages with the system text built from the blocks that carry
    /// `cache_control`, and the blocks without it at the head of the last user
    /// message. With no cached block, no uncached one, or no user message, the
    /// whole prompt stays one system message, as on every other server.
    static func withTurnContextAfterTools(systemBlocks: [[String: Any]],
                                          messages: [[String: Any]]) -> [[String: Any]] {
        func joined(_ blocks: [[String: Any]]) -> String {
            blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let stable = joined(systemBlocks.filter { $0["cache_control"] != nil })
        let perTurn = joined(systemBlocks.filter { $0["cache_control"] == nil })
        guard !stable.isEmpty, !perTurn.isEmpty,
              let last = messages.lastIndex(where: { $0["role"] as? String == "user" }) else {
            let all = joined(systemBlocks)
            return (all.isEmpty ? [] : [["role": "system", "content": all]]) + messages
        }
        let head = "\(turnContextLabel)\n\(perTurn)\n\nTHE USER'S MESSAGE:"
        var out = messages
        var user = out[last]
        if let parts = user["content"] as? [[String: Any]] {
            user["content"] = [["type": "text", "text": head]] + parts
        } else {
            user["content"] = "\(head)\n\(user["content"] as? String ?? "")"
        }
        out[last] = user
        return [["role": "system", "content": stable]] + out
    }

    /// An OpenAI chat body in Ollama's native shape.
    static func ollamaChatBody(_ body: [String: Any], stream: Bool,
                               contextTokens: Int = ollamaContextTokens) -> [String: Any] {
        var options: [String: Any] = ["num_ctx": contextTokens]
        if let n = body["max_tokens"] { options["num_predict"] = n }
        if let t = body["temperature"] { options["temperature"] = t }
        var out: [String: Any] = [
            "model": body["model"] ?? "",
            "messages": ollamaMessages(body["messages"] as? [[String: Any]] ?? []),
            "stream": stream,
            "options": options
        ]
        if let tools = body["tools"] { out["tools"] = tools }
        return out
    }

    /// OpenAI messages in Ollama's native shape: tool call arguments as an
    /// object, a tool result named for the tool it answers, and pictures as
    /// `images` beside the words.
    static func ollamaMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var toolNames: [String: String] = [:]
        return messages.map { m in
            var out = m
            if let calls = m["tool_calls"] as? [[String: Any]] {
                out["tool_calls"] = calls.map { call -> [String: Any] in
                    var fn = call["function"] as? [String: Any] ?? [:]
                    if let args = fn["arguments"] as? String {
                        fn["arguments"] = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
                    }
                    if let id = call["id"] as? String { toolNames[id] = fn["name"] as? String }
                    var c = call
                    c["function"] = fn
                    return c
                }
            }
            if m["role"] as? String == "tool", let id = m["tool_call_id"] as? String, let name = toolNames[id] {
                out["tool_name"] = name
            }
            if let parts = m["content"] as? [[String: Any]] {
                out["content"] = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                let images = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
                    .map { url in url.range(of: ";base64,").map { String(url[$0.upperBound...]) } ?? url }
                if !images.isEmpty { out["images"] = images }
            }
            return out
        }
    }

    /// One native reply (a whole one, or one streamed line) as the OpenAI
    /// object the parsers read: the message both as `message` and as `delta`,
    /// tool calls numbered from `firstToolIndex` with arguments as a string,
    /// and on the last line `finish_reason` and `usage`. `sawToolCalls` says an
    /// earlier line already called a tool, so the turn ends as `tool_calls`.
    static func openAIShape(ollama obj: [String: Any], firstToolIndex: Int = 0,
                            sawToolCalls: Bool = false) -> [String: Any] {
        let native = obj["message"] as? [String: Any] ?? [:]
        var message: [String: Any] = ["role": "assistant", "content": native["content"] as? String ?? ""]
        if let thinking = native["thinking"] as? String, !thinking.isEmpty { message["reasoning"] = thinking }
        let calls = (native["tool_calls"] as? [[String: Any]] ?? []).enumerated().map { i, call -> [String: Any] in
            let fn = call["function"] as? [String: Any] ?? [:]
            let args = fn["arguments"].flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
            }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let index = firstToolIndex + i
            let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
            return ["index": index, "id": id, "type": "function",
                    "function": ["name": fn["name"] as? String ?? "", "arguments": args]]
        }
        if !calls.isEmpty { message["tool_calls"] = calls }
        var choice: [String: Any] = ["index": 0, "message": message, "delta": message]
        var out: [String: Any] = [:]
        if obj["done"] as? Bool == true {
            let reason = obj["done_reason"] as? String ?? "stop"
            choice["finish_reason"] = reason == "stop" && (sawToolCalls || !calls.isEmpty) ? "tool_calls" : reason
            out["usage"] = ["prompt_tokens": obj["prompt_eval_count"] as? Int ?? 0,
                            "completion_tokens": obj["eval_count"] as? Int ?? 0]
        }
        out["choices"] = [choice]
        return out
    }

    /// A whole native reply as OpenAI JSON bytes. Anything that is not a
    /// native reply passes through unchanged, so the caller's own error
    /// handling reads it.
    private static func openAIReply(_ data: Data, native: Bool) -> Data {
        guard native,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["message"] != nil,
              let shaped = try? JSONSerialization.data(withJSONObject: openAIShape(ollama: obj)) else { return data }
        return shaped
    }

    // Build the per-request URLRequest. apiKey is a placeholder for local
    // servers ("ollama"), they ignore it, but we send it as a Bearer token
    // anyway so OpenRouter / hosted compat endpoints also work.
    private func makeRequest(stream: Bool, surface: String = "chat", native: Bool = false) throws -> URLRequest {
        var req = URLRequest(url: try native ? ollamaChatURL() : chatCompletionsURL())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        // Every call says who it is. OpenRouter shows these on the activity
        // page; a local server ignores them. The title names the surface.
        req.setValue("https://gruxai.com", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Grux OS: \(surface)", forHTTPHeaderField: "X-Title")
        return req
    }

    /// Endpoint-specific request shape. OpenRouter routes a model across
    /// providers; for structured turns (tools, JSON) the pinned provider
    /// order with no fallbacks and reasoning off is what keeps answers
    /// complete and fast. Any other host gets the body untouched.
    static func shaped(_ body: [String: Any], baseURL: String) -> [String: Any] {
        guard isOpenRouter(baseURL) else { return body }
        var b = body
        if (b["model"] as? String)?.hasPrefix("deepseek/") == true {
            b["provider"] = ["order": ["deepinfra", "fireworks", "together"], "allow_fallbacks": false, "sort": "latency"]
            b["reasoning"] = ["enabled": false]
        }
        return b
    }

    /// Whether this backend talks to OpenRouter, the one host this backend
    /// reaches that spends a prepaid credit. `shaped` and the credit read share it.
    static func isOpenRouter(_ baseURL: String) -> Bool {
        URL(string: baseURL)?.host?.hasSuffix("openrouter.ai") == true
    }

    /// P-R-3: one answered call, read for what it says about the OpenRouter
    /// credit. A 2xx is a success on the key; anything else is marked out only
    /// for OpenRouter's documented out of credit 402 (`CreditSignature`). A
    /// local server has no credit and is never reported, and a transport
    /// failure never gets here, because there is no response to read.
    private func noteCredit(status: Int, body: Data) async {
        guard Self.isOpenRouter(baseURL) else { return }
        await CreditMonitor.observe(.openRouter, status: status, body: body, on: credits)
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

    /// The chat history, as `ChatService` keeps it (Anthropic content blocks),
    /// in the shape an OpenAI compatible server reads. Plain string turns pass
    /// through. An assistant `tool_use` becomes a `tool_calls` entry with its
    /// input as a JSON string, each `tool_result` becomes its own `role: tool`
    /// message, and an `image` block becomes an `image_url` data URL part.
    ///
    /// Before this the blocks went out as they were, and Ollama answered the
    /// hop after every tool call with `HTTP 400 invalid message format`
    /// (measured 2026-09-27 on qwen2.5:7b), so every tool call on the local
    /// route ended in a failed reply.
    static func openAIChatMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            let role = m["role"] as? String ?? "user"
            guard let blocks = m["content"] as? [[String: Any]] else {
                out.append(m)
                continue
            }
            if role == "assistant" {
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { b in
                    let input = b["input"] as? [String: Any] ?? [:]
                    let args = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                        .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ["id": b["id"] as? String ?? "", "type": "function",
                            "function": ["name": b["name"] as? String ?? "", "arguments": args]]
                }
                var msg: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { msg["tool_calls"] = calls }
                out.append(msg)
                continue
            }
            // Results first: the server wants them right after the call.
            for b in blocks where b["type"] as? String == "tool_result" {
                out.append(["role": "tool",
                            "tool_call_id": b["tool_use_id"] as? String ?? "",
                            "content": Self.toolResultText(b["content"])])
            }
            var parts: [[String: Any]] = []
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    parts.append(["type": "text", "text": b["text"] as? String ?? ""])
                case "image":
                    let source = b["source"] as? [String: Any] ?? [:]
                    let media = source["media_type"] as? String ?? "image/png"
                    let data = source["data"] as? String ?? ""
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(media);base64,\(data)"]])
                default:
                    continue
                }
            }
            if parts.isEmpty { continue }
            if parts.allSatisfy({ $0["type"] as? String == "text" }) {
                out.append(["role": role, "content": parts.compactMap { $0["text"] as? String }.joined(separator: "\n")])
            } else {
                out.append(["role": role, "content": parts])
            }
        }
        return out
    }

    /// A tool result's content is a string, or text blocks.
    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
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
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": openAIMessages(system: system, messages: messages)
        ]
        let (req, native) = try await request(for: body, stream: false, surface: "completion", apiKey: apiKey)

        let (reply, resp) = try await session.data(for: req)
        let data = Self.openAIReply(reply, native: native)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        await noteCredit(status: http.statusCode, body: data)
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
        let (req, native) = try await request(for: body, stream: false, surface: "chat", apiKey: apiKey)

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
        let (reply, resp) = try await session.data(for: req)
        let data = Self.openAIReply(reply, native: native)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        await noteCredit(status: http.statusCode, body: data)
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
                    // Prepend the concatenated system blocks as a system message,
                    // except on Ollama, where the per-turn block rides in the
                    // user's message so the tools after the system text stay cached.
                    var oaMessages: [[String: Any]] = []
                    if await speaksOllama() {
                        oaMessages = Self.withTurnContextAfterTools(systemBlocks: systemBlocks,
                                                                    messages: Self.openAIChatMessages(messages))
                    } else {
                        if let sys = systemMessageFromBlocks(systemBlocks) { oaMessages.append(sys) }
                        oaMessages.append(contentsOf: Self.openAIChatMessages(messages))
                    }
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
                    let (req, native) = try await request(for: body, stream: true, surface: "chat", apiKey: apiKey)

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
                        await noteCredit(status: http.statusCode, body: Data(errBody.utf8))
                        throw ClaudeError.http(http.statusCode, errBody)
                    }
                    await noteCredit(status: http.statusCode, body: Data())

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
                        let obj: [String: Any]
                        if native {
                            // Ollama streams one JSON object per line, no `data: ` frame.
                            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                            if let err = raw["error"] as? String { throw ClaudeError.http(http.statusCode, err) }
                            obj = Self.openAIShape(ollama: raw, firstToolIndex: toolAccums.count,
                                                   sawToolCalls: !toolAccums.isEmpty)
                        } else {
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" { break }
                            guard !payload.isEmpty,
                                  let data = payload.data(using: .utf8),
                                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            obj = parsed
                        }

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
        var oaMessages: [[String: Any]] = []
        if let system, !system.isEmpty { oaMessages.append(["role": "system", "content": system]) }
        oaMessages.append(contentsOf: Self.openAIChatMessages(messages))
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": oaMessages
        ]
        if !tools.isEmpty { body["tools"] = openAITools(tools) }
        let (req, native) = try await request(for: body, stream: false, surface: "chat", apiKey: apiKey)

        let (reply, resp) = try await session.data(for: req)
        let data = Self.openAIReply(reply, native: native)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        await noteCredit(status: http.statusCode, body: data)
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
