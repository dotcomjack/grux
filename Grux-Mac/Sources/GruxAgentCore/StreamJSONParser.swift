import Foundation

// Parses the line-delimited JSON that `claude --print --output-format stream-json`
// writes to stdout. Each line is one event. We do NOT depend on the full Claude
// Code event schema - we just extract what we need (assistant text, tool_use,
// tool_result, usage, final result) and pass the raw JSON through for fidelity.

public enum StreamJSONEvent: Sendable {
    case systemInit(sessionId: String?, model: String?, raw: String)
    case assistantText(text: String, raw: String)
    case toolUse(name: String, inputJSON: String, raw: String)
    case toolResult(text: String, raw: String)
    case usage(costUSD: Double?, inputTokens: Int?, outputTokens: Int?, raw: String)
    case finalResult(text: String, costUSD: Double?, success: Bool, raw: String)
    case unknown(String)
}

public enum StreamJSONParser {

    /// Parse one line of stream-json output. Returns nil on blank/malformed.
    public static func parse(line: String) -> StreamJSONEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "system":
            let subtype = obj["subtype"] as? String ?? ""
            if subtype == "init" {
                let sid = obj["session_id"] as? String
                let model = obj["model"] as? String
                return .systemInit(sessionId: sid, model: model, raw: trimmed)
            }
            return .unknown(trimmed)

        case "assistant":
            // Has a "message" key whose "content" is an array of blocks.
            // We extract any text and tool_use blocks.
            guard let msg = obj["message"] as? [String: Any],
                  let contents = msg["content"] as? [[String: Any]]
            else { return .unknown(trimmed) }

            // Prefer the first text block we find; if it's a tool_use, emit that.
            for block in contents {
                let bType = block["type"] as? String ?? ""
                if bType == "text", let text = block["text"] as? String {
                    return .assistantText(text: text, raw: trimmed)
                }
                if bType == "tool_use" {
                    let name = block["name"] as? String ?? "?"
                    var inputStr = ""
                    if let input = block["input"] {
                        if let d = try? JSONSerialization.data(withJSONObject: input),
                           let s = String(data: d, encoding: .utf8) {
                            inputStr = s
                        }
                    }
                    return .toolUse(name: name, inputJSON: inputStr, raw: trimmed)
                }
            }
            // Also check for usage at message level.
            if let usage = msg["usage"] as? [String: Any] {
                let cost = obj["total_cost_usd"] as? Double ?? msg["total_cost_usd"] as? Double
                let inT = usage["input_tokens"] as? Int
                let outT = usage["output_tokens"] as? Int
                return .usage(costUSD: cost, inputTokens: inT, outputTokens: outT, raw: trimmed)
            }
            return .unknown(trimmed)

        case "user":
            // tool_result lives in user-role messages with content blocks.
            guard let msg = obj["message"] as? [String: Any],
                  let contents = msg["content"] as? [[String: Any]]
            else { return .unknown(trimmed) }
            for block in contents {
                let bType = block["type"] as? String ?? ""
                if bType == "tool_result" {
                    var text = ""
                    if let raw = block["content"] as? String {
                        text = raw
                    } else if let arr = block["content"] as? [[String: Any]] {
                        for sub in arr {
                            if let t = sub["text"] as? String { text += t + "\n" }
                        }
                    }
                    return .toolResult(text: text, raw: trimmed)
                }
            }
            return .unknown(trimmed)

        case "result":
            // Final summary line. Includes total cost.
            let success = (obj["subtype"] as? String) == "success"
            let cost = obj["total_cost_usd"] as? Double
            let text = (obj["result"] as? String) ?? ""
            return .finalResult(text: text, costUSD: cost, success: success, raw: trimmed)

        default:
            return .unknown(trimmed)
        }
    }

    /// Parses a chunk of bytes into events; returns events + leftover unfinished line.
    public static func parseChunk(_ buffer: String) -> (events: [StreamJSONEvent], remainder: String) {
        guard let lastNewline = buffer.lastIndex(of: "\n") else {
            return ([], buffer)
        }
        let complete = buffer[..<lastNewline]
        let remainder = String(buffer[buffer.index(after: lastNewline)...])
        var events: [StreamJSONEvent] = []
        for raw in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            if let ev = parse(line: String(raw)) {
                events.append(ev)
            }
        }
        return (events, remainder)
    }
}
