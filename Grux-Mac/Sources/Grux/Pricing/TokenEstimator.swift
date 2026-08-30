import Foundation

// Pure, local token estimation for the pre-run cost meter. There is no
// tokenizer anywhere in the app, so we reuse the same chars/4 heuristic the
// chat compactor already trusts (ChatThread.approximateTokens) over the exact
// bytes a turn will put on the wire: the JSON-serialized system blocks, the
// message window, and every tool's schema. An optional live path can ask
// Anthropic's /v1/messages/count_tokens for an exact number, but it is a
// separate async method the pure path never touches, so unit tests never reach
// the network.
enum TokenEstimator {

    // The one heuristic: 4 characters per token, rounded up. A token is never
    // fewer than the byte estimate suggests for English + JSON, so rounding up
    // keeps the pre-run figure an honest ceiling rather than an undercount.
    static func estimateTokens(chars: Int) -> Int {
        guard chars > 0 else { return 0 }
        return Int((Double(chars) / 4.0).rounded(.up))
    }

    static func estimateTokens(text: String) -> Int {
        estimateTokens(chars: text.count)
    }

    // Estimate the INPUT (prompt-side) tokens a chat turn will send: system
    // blocks + message window + tool schemas. Output-side tokens are the
    // caller's maxTokens ceiling, priced separately. Base64 image payloads are
    // deliberately skipped: they are not text tokens and a single staged image
    // would otherwise blow the estimate up by hundreds of thousands of "tokens".
    static func estimateInputTokens(systemBlocks: [[String: Any]],
                                    messages: [[String: Any]],
                                    tools: [ClaudeTool]) -> Int {
        var chars = 0
        chars += jsonChars(systemBlocks)
        chars += messageChars(messages)
        for t in tools {
            chars += t.name.count + t.description.count + jsonChars(t.inputSchema)
        }
        return estimateTokens(chars: chars)
    }

    // MARK: - Live path (opt-in, never hit by tests)

    // POST Anthropic's token-counting endpoint for an exact prompt-token count.
    // Returns nil on any failure (missing key, timeout, non-200, decode) so the
    // caller falls back to the heuristic. 5s timeout: this runs pre-send and
    // must not stall the composer. This method is the ONLY network surface in
    // the estimator; the pure paths above are what the tests exercise.
    static func liveInputTokens(apiKey: String,
                                model: String,
                                systemBlocks: [[String: Any]],
                                messages: [[String: Any]],
                                tools: [ClaudeTool]) async -> Int? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")
        else { return nil }

        var body: [String: Any] = [
            "model": model,
            "system": systemBlocks,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["name": t.name, "description": t.description, "input_schema": t.inputSchema] as [String: Any]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (respData, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let n = obj["input_tokens"] as? Int
            else { return nil }
            return n
        } catch {
            return nil
        }
    }

    // MARK: - Internals

    // Byte length of a JSON-serialized object, a good char proxy for ASCII
    // schemas and system prose. Sorted keys only for determinism.
    private static func jsonChars(_ object: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return 0 }
        return data.count
    }

    // Sum the textual weight of the message window, skipping image blocks.
    private static func messageChars(_ messages: [[String: Any]]) -> Int {
        var total = 0
        for m in messages {
            if let role = m["role"] as? String { total += role.count }
            if let s = m["content"] as? String {
                total += s.count
            } else if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks {
                    if (b["type"] as? String) == "image" { continue }
                    total += jsonChars(b)
                }
            }
        }
        return total
    }
}
