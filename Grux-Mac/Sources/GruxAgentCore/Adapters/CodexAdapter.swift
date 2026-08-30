import Foundation

// MARK: - CodexAdapter
//
// OpenAI Codex CLI. Non-interactive mode is `codex exec --json`, which streams
// one JSON object per line describing the agent's progress. Codex reads the
// prompt from stdin when no positional prompt is given, so we feed it there
// (long prompts stay off the arg list).
//
// The exact event schema shifts between Codex versions, so the parser is
// tolerant by construction: any line it does not recognize becomes
// .unknown(raw) rather than an error. The documented fixture shape it targets:
//
//   {"type":"session.created","session_id":"..."}
//   {"type":"agent_message","message":"assistant text"}
//   {"type":"item.completed","item":{"type":"assistant_message","text":"..."}}
//   {"type":"exec_command","command":"ls -la"}
//   {"type":"command_output","output":"...stdout..."}
//   {"type":"token_count","input_tokens":123,"output_tokens":456}
//   {"type":"task_complete","last_agent_message":"final","cost_usd":0.02}
//
// When the real CLI is installed, capture a live `codex exec --json` transcript
// and reconcile the type strings here (see INTEGRATION.md residual gaps).

public struct CodexAdapter: AgentAdapter {
    public let id = "codex"
    public let displayName = "OpenAI Codex"

    public init() {}

    public var detectionCandidates: AdapterDetectionCandidates {
        AdapterDetectionCandidates(
            toolName: "codex",
            envVar: "CODEX_BIN",
            candidatePaths: [
                "~/.local/bin/codex",
                "~/.bun/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/usr/bin/codex"
            ],
            versionArgs: ["--version"]
        )
    }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(supportsResume: false, supportsStreamJSON: true, promptViaStdin: true)
    }

    public func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation {
        let execPath = AgentCLIRegistry.resolveExecutablePath(for: detectionCandidates)
        var args: [String] = ["exec", "--json"]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: extraArgs)
        // Prompt via stdin (codex exec reads stdin when no positional prompt).
        return AdapterInvocation(
            executablePath: execPath,
            args: args,
            env: ProcessInfo.processInfo.environment,
            stdinPayload: prompt + "\n",
            cwd: cwd
        )
    }

    public func makeStreamParser() -> any AdapterStreamParsing {
        CodexStreamAdapterParser()
    }
}

public final class CodexStreamAdapterParser: AdapterStreamParsing {
    public init() {}

    public func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String) {
        guard let lastNewline = chunk.lastIndex(of: "\n") else {
            return ([], chunk)
        }
        let complete = chunk[..<lastNewline]
        let remainder = String(chunk[chunk.index(after: lastNewline)...])
        var events: [AdapterEvent] = []
        for rawSub in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(rawSub)
            events.append(Self.parseLine(raw))
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
        switch type {
        case "session.created", "session_created", "session_configured":
            let sid = (obj["session_id"] as? String) ?? (obj["id"] as? String)
            let model = obj["model"] as? String
            return .systemInit(sessionId: sid, model: model, raw: raw)

        case "agent_message", "assistant_message", "message":
            let text = firstText(in: obj)
            if let text { return .assistantText(text: text, raw: raw) }
            return .unknown(raw: raw)

        case "item.completed", "item_completed", "item.updated":
            // Codex wraps content in an "item" object. Dispatch on its subtype.
            if let item = obj["item"] as? [String: Any] {
                let itemType = (item["type"] as? String) ?? ""
                switch itemType {
                case "assistant_message", "agent_message", "message":
                    if let t = firstText(in: item) { return .assistantText(text: t, raw: raw) }
                case "command_execution", "exec_command", "tool_call", "function_call":
                    let name = (item["command"] as? String)
                        ?? (item["name"] as? String)
                        ?? "command"
                    return .toolUse(name: name, inputJSON: jsonString(item), raw: raw)
                case "command_output", "tool_result", "function_output":
                    let out = (item["output"] as? String) ?? firstText(in: item) ?? ""
                    return .toolResult(text: out, raw: raw)
                default:
                    if let t = firstText(in: item) { return .assistantText(text: t, raw: raw) }
                }
            }
            return .unknown(raw: raw)

        case "exec_command", "command", "tool_call", "function_call":
            let name = (obj["command"] as? String) ?? (obj["name"] as? String) ?? "command"
            return .toolUse(name: name, inputJSON: jsonString(obj), raw: raw)

        case "command_output", "tool_result", "function_output":
            let out = (obj["output"] as? String) ?? firstText(in: obj) ?? ""
            return .toolResult(text: out, raw: raw)

        case "token_count", "usage", "token_usage":
            let inT = intField(obj, ["input_tokens", "prompt_tokens", "input"])
            let outT = intField(obj, ["output_tokens", "completion_tokens", "output"])
            let cost = doubleField(obj, ["cost_usd", "total_cost_usd", "cost"])
            return .usage(costUSD: cost, inputTokens: inT, outputTokens: outT, raw: raw)

        case "task_complete", "result", "turn.completed", "task.completed":
            let text = (obj["last_agent_message"] as? String)
                ?? (obj["result"] as? String)
                ?? firstText(in: obj)
                ?? ""
            let cost = doubleField(obj, ["cost_usd", "total_cost_usd", "cost"])
            // Codex signals failure via an "error"/"is_error" field; absence = ok.
            let isError = (obj["is_error"] as? Bool) ?? (obj["error"] != nil)
            return .finalResult(text: text, costUSD: cost, success: !isError, raw: raw)

        case "error":
            let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "error"
            return .finalResult(text: msg, costUSD: nil, success: false, raw: raw)

        default:
            return .unknown(raw: raw)
        }
    }

    // MARK: - field helpers (shared shape across the tolerant adapters)

    private static func firstText(in obj: [String: Any]) -> String? {
        if let t = obj["message"] as? String { return t }
        if let t = obj["text"] as? String { return t }
        if let t = obj["content"] as? String { return t }
        if let arr = obj["content"] as? [[String: Any]] {
            var acc = ""
            for block in arr {
                if let t = block["text"] as? String { acc += t }
            }
            if !acc.isEmpty { return acc }
        }
        return nil
    }

    private static func intField(_ obj: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let n = obj[k] as? Int { return n }
            if let n = obj[k] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private static func doubleField(_ obj: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            if let n = obj[k] as? Double { return n }
            if let n = obj[k] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
