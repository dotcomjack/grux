import Foundation

struct ClaudeMessage: Codable {
    let role: String
    let content: String
}

struct ClaudeRequest: Codable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [ClaudeMessage]
    let temperature: Double?
}

struct ClaudeContentBlock: Codable { let type: String; let text: String? }
struct ClaudeResponse: Codable {
    let content: [ClaudeContentBlock]
    let stop_reason: String?
    let usage: ClaudeUsage?
}
struct ClaudeUsage: Codable {
    let input_tokens: Int?
    let output_tokens: Int?
    // Anthropic-specific cache counters. Optional because they're only
    // present when the request used cache_control breakpoints.
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

enum ClaudeError: Error, LocalizedError {
    /// A LOCAL refusal, never a provider response.
    ///
    /// This used to be thrown as `.http(400, "skipped locally...")`, which made
    /// `errorDescription` render "Anthropic HTTP 400: ..." for a call that never
    /// left the machine. That both lied to the user and poisoned the exact
    /// metric the 563-call incident was diagnosed with: grepping WakeLog for
    /// "Anthropic HTTP 400". The remedy was corrupting the diagnostic.
    case standDown

    /// A LOCAL REFUSAL TOO, and for the same reason `standDown` is one: nothing
    /// was sent, so no provider gets to be blamed for it.
    ///
    /// This one covers a configuration the machine cannot act on at all, and
    /// today that is exactly one thing: a base URL no `URL(string:)` will
    /// accept. It was thrown as `.decoding` first, because that was the only
    /// existing case whose payload survives `ChatService.humanMessage`
    /// unchanged (`.http` is remapped to a generic sentence by status code,
    /// which would discard the base URL the user has to see). It worked and it
    /// read as "Decoding error: Grux cannot build a request URL from ...",
    /// which names the wrong thing and sends the reader looking for a corrupt
    /// response to a request that was never made.
    ///
    /// The payload is rendered VERBATIM, with no label in front of it. The
    /// strings that reach here are already whole sentences written for the
    /// person reading them, naming what is wrong and where to fix it, so a
    /// prefix could only add a category the user cannot act on. `standDown`
    /// carries its own sentence for the same reason.
    case localConfiguration(String)

    case missingKey
    case http(Int, String)
    case decoding(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Missing Anthropic API key. Add it in Settings."
        case .standDown:
            // Never says "Anthropic". Nothing was sent.
            return "Skipped locally: the provider account has no funds, so background work stood down."
        case .http(let code, let body): return "Anthropic HTTP \(code): \(body.prefix(200))"
        case .localConfiguration(let msg):
            // Verbatim. Never says "Anthropic", and never says "error" about a
            // response, because nothing was sent and nothing came back.
            return msg
        case .decoding(let msg): return "Decoding error: \(msg)"
        }
    }
}

// A single tool Claude can call. `inputSchema` is a JSON schema object (Any
// because JSON schemas aren't cleanly typed in Swift).
struct ClaudeTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

// Parsed content blocks from a Claude response. Anthropic returns an array
// of blocks that can mix text and tool_use.
enum ClaudeBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
}

// Streaming events emitted while Claude is responding. Enables us to start
// TTS on the first sentence instead of waiting for the full reply. Tool-use
// blocks stream as `toolUseStart` → many `toolUseInputDelta` → `toolUseStop`,
// at which point the caller has the full JSON input and can dispatch.
enum ClaudeStreamEvent {
    case textDelta(String)            // text content block, partial chunk
    case textBlockStart
    case textBlockStop
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(partial: String)
    case toolUseStop(id: String, name: String, input: [String: Any])
    case messageStop(stopReason: String?)
}

// Extended response that preserves tool_use blocks so the caller can execute
// tools and continue the conversation.
struct ClaudeToolsResponse {
    let blocks: [ClaudeBlock]
    let stopReason: String?
    var allText: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
    var toolUses: [(id: String, name: String, input: [String: Any])] {
        blocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) } else { return nil }
        }
    }
}

actor ClaudeClient {
    private let session: URLSession
    // Stats from the most recent completion - useful to confirm cache hits.
    private(set) var lastCacheCreationTokens: Int = 0
    private(set) var lastCacheReadTokens: Int = 0
    private(set) var lastInputTokens: Int = 0
    private(set) var lastOutputTokens: Int = 0

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: cfg)
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (lastInputTokens, lastOutputTokens, lastCacheCreationTokens, lastCacheReadTokens)
    }

    // Opus 4.8 (and newer reasoning models) deprecate the `temperature` request
    // param: sending it returns HTTP 400 "temperature is deprecated for this
    // model." Omit it for those models. Sonnet 4.6 / Haiku 4.5 still accept it.
    nonisolated static func modelDeprecatesTemperature(_ model: String) -> Bool {
        model.contains("opus-4-8") || model.contains("opus-4.8")
    }

    func complete(apiKey: String, model: String, system: String?, messages: [ClaudeMessage], maxTokens: Int = 1024, temperature: Double = 0.2, spanName: String = "claude.complete", feature: String = "uncategorized") async throws -> String {
        // STAND DOWN WHEN THE ACCOUNT HAS ALREADY SAID NO.
        // Four autonomous loops once fired 563 calls at an exhausted balance,
        // announcing 190 of them through a paid voice API. A person pressing a
        // button is never blocked here: they may have topped up a second ago.
        if ProviderHealth.shared.shouldSkipCall(backgroundWork: ProviderHealth.backgroundWork) {
            throw ClaudeError.standDown
        }
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let temp: Double? = Self.modelDeprecatesTemperature(model) ? nil : temperature
        let body = ClaudeRequest(model: model, max_tokens: maxTokens, system: system, messages: messages, temperature: temp)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "<binary>"
            // Feed the breaker from the places this path can fail, so every
            // caller reports without any of them remembering to.
            ProviderHealth.shared.record(failureBody: errBody, statusCode: http.statusCode)
            throw ClaudeError.http(http.statusCode, errBody)
        }
        ProviderHealth.shared.recordSuccess()
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        self.lastInputTokens = decoded.usage?.input_tokens ?? 0
        self.lastOutputTokens = decoded.usage?.output_tokens ?? 0
        self.lastCacheCreationTokens = decoded.usage?.cache_creation_input_tokens ?? 0
        self.lastCacheReadTokens = decoded.usage?.cache_read_input_tokens ?? 0
        return decoded.content.compactMap { $0.text }.joined()
    }

    // Non-streaming complete with a CACHED system prefix. `cachedSystem` is sent
    // as a cache_control:ephemeral block so repeated calls that share it (e.g.
    // the quality gate firing one reviewer per dimension over the SAME large
    // diff) pay the big prefix once (cacheCreate) and read it at ~0.1x on every
    // later call. `tailSystem` is an optional uncached per-call suffix (the
    // dimension-specific instruction). Caller must warm the cache (one call
    // first, then fan out) since the cache is readable only after the first
    // response begins; concurrent cold calls would each pay full prefix cost.
    func completeCached(apiKey: String, model: String, cachedSystem: String, tailSystem: String?,
                        messages: [ClaudeMessage], maxTokens: Int = 1024, temperature: Double = 0.2,
                        spanName: String = "claude.completeCached", feature: String = "uncategorized") async throws -> String {
        // Same stand-down as `complete`. Review found this missing here, and it
        // mattered more than the one that existed: the ambient extractor, the
        // single loop that produced 184 of the 563 wasted calls, routes through
        // completeVision and sailed straight past the breaker.
        if ProviderHealth.shared.shouldSkipCall(backgroundWork: ProviderHealth.backgroundWork) {
            throw ClaudeError.standDown
        }
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var systemBlocks: [[String: Any]] = [[
            "type": "text", "text": cachedSystem, "cache_control": ["type": "ephemeral"]
        ]]
        if let tail = tailSystem, !tail.isEmpty {
            systemBlocks.append(["type": "text", "text": tail])
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemBlocks,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if !Self.modelDeprecatesTemperature(model) { body["temperature"] = temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            ProviderHealth.shared.record(failureBody: bodyStr, statusCode: http.statusCode)
            throw ClaudeError.http(http.statusCode, bodyStr)
        }
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        self.lastInputTokens = decoded.usage?.input_tokens ?? 0
        self.lastOutputTokens = decoded.usage?.output_tokens ?? 0
        self.lastCacheCreationTokens = decoded.usage?.cache_creation_input_tokens ?? 0
        self.lastCacheReadTokens = decoded.usage?.cache_read_input_tokens ?? 0
        return decoded.content.compactMap { $0.text }.joined()
    }

    // Vision completion. Sends a user message whose content is an array with
    // one image block (base64-encoded JPEG) followed by a text block. Returns
    // the concatenated text output.
    func completeVision(
        apiKey: String,
        model: String,
        system: String?,
        userText: String,
        imageJPEG: Data,
        mediaType: String = "image/jpeg",
        maxTokens: Int = 500,
        temperature: Double = 0.15,
        spanName: String = "claude.completeVision",
        feature: String = "vision"
    ) async throws -> String {
        // Same stand-down as `complete`. Review found this missing here, and it
        // mattered more than the one that existed: the ambient extractor, the
        // single loop that produced 184 of the 563 wasted calls, routes through
        // completeVision and sailed straight past the breaker.
        if ProviderHealth.shared.shouldSkipCall(backgroundWork: ProviderHealth.backgroundWork) {
            throw ClaudeError.standDown
        }
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let base64 = imageJPEG.base64EncodedString()
        let content: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": base64
                ]
            ],
            [
                "type": "text",
                "text": userText
            ]
        ]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        if !Self.modelDeprecatesTemperature(model) { body["temperature"] = temperature }
        if let system, !system.isEmpty { body["system"] = system }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "<binary>"
            // Feed the breaker from the places this path can fail, so every
            // caller reports without any of them remembering to.
            ProviderHealth.shared.record(failureBody: errBody, statusCode: http.statusCode)
            throw ClaudeError.http(http.statusCode, errBody)
        }
        ProviderHealth.shared.recordSuccess()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArr = obj["content"] as? [[String: Any]] else {
            throw ClaudeError.decoding("vision: bad top-level shape")
        }
        if let usage = obj["usage"] as? [String: Any] {
            let inTok = usage["input_tokens"] as? Int ?? self.lastInputTokens
            let outTok = usage["output_tokens"] as? Int ?? self.lastOutputTokens
            self.lastInputTokens = inTok
            self.lastOutputTokens = outTok
            self.lastCacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
            self.lastCacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
        }
        return contentArr.compactMap { $0["text"] as? String }.joined()
    }

    // Streaming tool-use completion. System passed as content blocks so the
    // caller can mark stable blocks with `cache_control` for prompt caching.
    // Events arrive as they're emitted - caller can start TTS on first text
    // delta instead of waiting for the full response.
    func streamCompleteWithTools(
        apiKey: String,
        model: String,
        systemBlocks: [[String: Any]],
        messages: [[String: Any]],
        tools: [ClaudeTool],
        maxTokens: Int = 2048,
        temperature: Double = 0.3,
        spanName: String = "claude.streamCompleteWithTools",
        feature: String = "chat"
    ) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "messages": messages,
                        "system": systemBlocks,
                        "stream": true
                    ]
                    if !Self.modelDeprecatesTemperature(model) { body["temperature"] = temperature }
                    if !tools.isEmpty {
                        // No cache_control on tools - we cache at the system
                        // boundary instead, which scopes the cached prefix as
                        // (tools + stable-system-block). Multiple breakpoints
                        // require each tier to individually clear the token
                        // minimum; a single breakpoint at the end of a
                        // combined tools+system prefix is simpler and reliably
                        // hits the 1024-token minimum.
                        body["tools"] = tools.map { t in
                            ["name": t.name, "description": t.description, "input_schema": t.inputSchema]
                        }
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

                    // One-time sanity log: size of system + whether cache_control made it into JSON
                    let bodyJSON = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                    let hasCC = bodyJSON.contains("cache_control")
                    WakeLog.shared.log("claude req: bytes=\(req.httpBody?.count ?? 0) cacheCtrlPresent=\(hasCC)  systemPreview=\((systemBlocks.first?["text"] as? String ?? "").prefix(40))")

                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n"; if body.count > 800 { break } }
                        ProviderHealth.shared.record(failureBody: body, statusCode: http.statusCode)
                        throw ClaudeError.http(http.statusCode, body)
                    }
                    // CLOSES A LIVELOCK I INTRODUCED. Background calls are gated
                    // while the breaker is latched, so background can never
                    // produce the success that clears it. Chat streams through
                    // here and is NOT gated, so without this line a user who
                    // topped up would have working chat and permanently dead
                    // background work until they happened to press Test Key.
                    ProviderHealth.shared.recordSuccess()

                    // State for the SSE parser
                    var activeToolID: String?
                    var activeToolName: String?
                    var activeToolInputAccum: String = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        // SSE lines: "event: ..." / "data: ..." / blank separator
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]", !payload.isEmpty else { continue }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }

                        switch type {
                        case "content_block_start":
                            if let cb = obj["content_block"] as? [String: Any],
                               let t = cb["type"] as? String {
                                if t == "text" {
                                    continuation.yield(.textBlockStart)
                                } else if t == "tool_use" {
                                    activeToolID = cb["id"] as? String ?? ""
                                    activeToolName = cb["name"] as? String ?? ""
                                    activeToolInputAccum = ""
                                    continuation.yield(.toolUseStart(id: activeToolID!, name: activeToolName!))
                                }
                            }
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any], let t = delta["type"] as? String {
                                if t == "text_delta", let txt = delta["text"] as? String {
                                    continuation.yield(.textDelta(txt))
                                } else if t == "input_json_delta", let p = delta["partial_json"] as? String {
                                    activeToolInputAccum += p
                                    continuation.yield(.toolUseInputDelta(partial: p))
                                }
                            }
                        case "content_block_stop":
                            if let id = activeToolID, let name = activeToolName {
                                let input = (try? JSONSerialization.jsonObject(with: Data(activeToolInputAccum.utf8)) as? [String: Any]) ?? [:]
                                continuation.yield(.toolUseStop(id: id, name: name, input: input))
                                activeToolID = nil
                                activeToolName = nil
                                activeToolInputAccum = ""
                            } else {
                                continuation.yield(.textBlockStop)
                            }
                        case "message_delta":
                            if let usage = obj["usage"] as? [String: Any] {
                                self.lastOutputTokens = usage["output_tokens"] as? Int ?? self.lastOutputTokens
                            }
                        case "message_start":
                            if let msg = obj["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any] {
                                self.lastInputTokens = usage["input_tokens"] as? Int ?? 0
                                self.lastCacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                                self.lastCacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                                let usageDebug = (try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                                WakeLog.shared.log("claude usage raw: \(usageDebug)")
                            }
                        case "message_stop":
                            continuation.yield(.messageStop(stopReason: nil))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Tool-use-aware completion. Messages are passed as pre-built JSON so the
    // caller can include mixed content blocks (text + tool_use + tool_result).
    // Returns parsed content blocks the caller can dispatch.
    func completeWithTools(
        apiKey: String,
        model: String,
        system: String?,
        messages: [[String: Any]],
        tools: [ClaudeTool],
        maxTokens: Int = 2048,
        temperature: Double = 0.3,
        spanName: String = "claude.completeWithTools",
        feature: String = "tool_use"
    ) async throws -> ClaudeToolsResponse {
        // Same stand-down as `complete`. Review found this missing here, and it
        // mattered more than the one that existed: the ambient extractor, the
        // single loop that produced 184 of the 563 wasted calls, routes through
        // completeVision and sailed straight past the breaker.
        if ProviderHealth.shared.shouldSkipCall(backgroundWork: ProviderHealth.backgroundWork) {
            throw ClaudeError.standDown
        }
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
            "tools": tools.map { t in
                ["name": t.name, "description": t.description, "input_schema": t.inputSchema]
            }
        ]
        if !Self.modelDeprecatesTemperature(model) { body["temperature"] = temperature }
        if let system, !system.isEmpty { body["system"] = system }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "<binary>"
            // Feed the breaker from the places this path can fail, so every
            // caller reports without any of them remembering to.
            ProviderHealth.shared.record(failureBody: errBody, statusCode: http.statusCode)
            throw ClaudeError.http(http.statusCode, errBody)
        }
        ProviderHealth.shared.recordSuccess()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("top-level not dict")
        }
        let contentArr = obj["content"] as? [[String: Any]] ?? []
        var blocks: [ClaudeBlock] = []
        for c in contentArr {
            let type = c["type"] as? String ?? ""
            if type == "text" {
                blocks.append(.text(c["text"] as? String ?? ""))
            } else if type == "tool_use" {
                let id = c["id"] as? String ?? ""
                let name = c["name"] as? String ?? ""
                let input = c["input"] as? [String: Any] ?? [:]
                blocks.append(.toolUse(id: id, name: name, input: input))
            }
        }
        let stop = obj["stop_reason"] as? String
        if let usage = obj["usage"] as? [String: Any] {
            self.lastInputTokens = usage["input_tokens"] as? Int ?? 0
            self.lastOutputTokens = usage["output_tokens"] as? Int ?? 0
            self.lastCacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
            self.lastCacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
        }
        return ClaudeToolsResponse(blocks: blocks, stopReason: stop)
    }
}
