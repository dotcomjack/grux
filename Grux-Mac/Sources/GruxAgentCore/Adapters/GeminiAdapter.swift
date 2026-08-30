import Foundation

// MARK: - GeminiAdapter
//
// Google Gemini CLI. Non-interactive: `gemini --prompt <p> --output-format json`.
// The prompt rides as an arg (the CLI's documented flag), so promptViaStdin is
// false. Depending on version the CLI emits either a single terminal JSON object
// or a stream of NDJSON lines; the line-based tolerant parser handles both,
// because a single final object arrives as one complete line and NDJSON arrives
// as many. Unknown shapes degrade to .unknown(raw).
//
// Documented fixture shape the parser targets:
//
//   {"type":"content","text":"assistant chunk"}
//   {"type":"tool_call","name":"read_file","args":{"path":"x"}}
//   {"type":"tool_result","name":"read_file","result":"...file..."}
//   {"type":"usage","input_tokens":10,"output_tokens":20}
//   {"type":"result","response":"final answer","stats":{"totalTokens":30}}
//
// and the single-object terminal form: {"response":"...","stats":{...}}.

public struct GeminiAdapter: AgentAdapter {
    public let id = "gemini"
    public let displayName = "Google Gemini"

    public init() {}

    public var detectionCandidates: AdapterDetectionCandidates {
        AdapterDetectionCandidates(
            toolName: "gemini",
            envVar: "GEMINI_BIN",
            candidatePaths: [
                "~/.local/bin/gemini",
                "~/.bun/bin/gemini",
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
                "/usr/bin/gemini"
            ],
            versionArgs: ["--version"]
        )
    }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(supportsResume: false, supportsStreamJSON: true, promptViaStdin: false)
    }

    public func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation {
        let execPath = AgentCLIRegistry.resolveExecutablePath(for: detectionCandidates)
        var args: [String] = ["--prompt", prompt, "--output-format", "json"]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: extraArgs)
        return AdapterInvocation(
            executablePath: execPath,
            args: args,
            env: ProcessInfo.processInfo.environment,
            stdinPayload: nil,
            cwd: cwd
        )
    }

    public func makeStreamParser() -> any AdapterStreamParsing {
        GeminiStreamAdapterParser()
    }
}

public final class GeminiStreamAdapterParser: AdapterStreamParsing {
    public init() {}

    public func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String) {
        guard let lastNewline = chunk.lastIndex(of: "\n") else {
            return ([], chunk)
        }
        let complete = chunk[..<lastNewline]
        let remainder = String(chunk[chunk.index(after: lastNewline)...])
        var events: [AdapterEvent] = []
        for rawSub in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            events.append(Self.parseLine(String(rawSub)))
        }
        return (events, remainder)
    }

    static func parseLine(_ raw: String) -> AdapterEvent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown(raw: raw) }

        let type = (obj["type"] as? String) ?? ""

        // Terminal single-object form has no "type" but carries "response".
        if type.isEmpty, let response = obj["response"] as? String {
            let usage = obj["stats"] as? [String: Any]
            let inT = usage.flatMap { intField($0, ["inputTokens", "input_tokens", "promptTokenCount"]) }
            let outT = usage.flatMap { intField($0, ["outputTokens", "output_tokens", "candidatesTokenCount"]) }
            _ = inT; _ = outT
            return .finalResult(text: response, costUSD: nil, success: true, raw: raw)
        }

        switch type {
        case "session", "init", "session.created":
            let sid = (obj["session_id"] as? String) ?? (obj["id"] as? String)
            let model = obj["model"] as? String
            return .systemInit(sessionId: sid, model: model, raw: raw)

        case "content", "text", "assistant", "message", "thought":
            if let t = firstText(in: obj) { return .assistantText(text: t, raw: raw) }
            return .unknown(raw: raw)

        case "tool_call", "tool_use", "function_call":
            let name = (obj["name"] as? String) ?? "tool"
            let input = (obj["args"] as? [String: Any]) ?? (obj["input"] as? [String: Any]) ?? [:]
            return .toolUse(name: name, inputJSON: jsonString(input), raw: raw)

        case "tool_result", "function_response", "tool_output":
            let out = (obj["result"] as? String)
                ?? (obj["output"] as? String)
                ?? firstText(in: obj)
                ?? ""
            return .toolResult(text: out, raw: raw)

        case "usage", "stats", "token_usage":
            let inT = intField(obj, ["input_tokens", "inputTokens", "promptTokenCount"])
            let outT = intField(obj, ["output_tokens", "outputTokens", "candidatesTokenCount"])
            return .usage(costUSD: nil, inputTokens: inT, outputTokens: outT, raw: raw)

        case "result", "final", "response":
            let text = (obj["response"] as? String)
                ?? (obj["result"] as? String)
                ?? firstText(in: obj)
                ?? ""
            let isError = (obj["is_error"] as? Bool) ?? (obj["error"] != nil)
            return .finalResult(text: text, costUSD: nil, success: !isError, raw: raw)

        case "error":
            let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "error"
            return .finalResult(text: msg, costUSD: nil, success: false, raw: raw)

        default:
            return .unknown(raw: raw)
        }
    }

    private static func firstText(in obj: [String: Any]) -> String? {
        if let t = obj["text"] as? String { return t }
        if let t = obj["content"] as? String { return t }
        if let t = obj["message"] as? String { return t }
        if let t = obj["response"] as? String { return t }
        return nil
    }

    private static func intField(_ obj: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let n = obj[k] as? Int { return n }
            if let n = obj[k] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
