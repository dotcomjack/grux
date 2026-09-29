import Foundation

/// Writes the exact context the next Chat turn would send, with a size table,
/// to ~/.grux/chat-context-dump.txt (0600). A debug seam: when Chat answers
/// like something other than Chat, the only honest first step is to read
/// what the model was actually given, section by section, instead of
/// guessing from the source.
enum ChatContextDump {
    struct Row { let name: String; let chars: Int }

    /// Sizes for the report, pure so a test can pin them.
    static func rows(systemBlocks: [[String: Any]], messages: [[String: Any]], toolsJSONBytes: Int) -> [Row] {
        var rows: [Row] = []
        for (i, b) in systemBlocks.enumerated() {
            let text = b["text"] as? String ?? ""
            let cached = b["cache_control"] != nil ? " (cached)" : ""
            rows.append(Row(name: "system[\(i)]\(cached)", chars: text.count))
        }
        let msgChars = messages.reduce(0) { acc, m in
            if let s = m["content"] as? String { return acc + s.count }
            if let d = try? JSONSerialization.data(withJSONObject: m) { return acc + d.count }
            return acc
        }
        rows.append(Row(name: "messages[\(messages.count)]", chars: msgChars))
        rows.append(Row(name: "tools (json)", chars: toolsJSONBytes))
        return rows
    }

    /// Splits a block on its ALL-CAPS section headings so the report can say
    /// which section inside the stable block is the heavy one.
    static func sections(of text: String) -> [Row] {
        var out: [Row] = []
        var name = "(preamble)"
        var buf = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let isHeading = t.count >= 4 && t.count <= 48 && t == t.uppercased()
                && t.rangeOfCharacter(from: .letters) != nil && !t.hasPrefix("-") && !t.hasPrefix("\\(")
            if isHeading {
                out.append(Row(name: name, chars: buf.count))
                name = t; buf = ""
            } else {
                buf += line + "\n"
            }
        }
        out.append(Row(name: name, chars: buf.count))
        return out.filter { $0.chars > 0 }
    }

    static func report(systemBlocks: [[String: Any]], messages: [[String: Any]], toolsJSONBytes: Int,
                       toolRows: [Row] = [], modelId: String) -> String {
        let rs = rows(systemBlocks: systemBlocks, messages: messages, toolsJSONBytes: toolsJSONBytes)
        let total = rs.reduce(0) { $0 + $1.chars }
        var s = "model: \(modelId)\ntotal chars: \(total)  (~\(total / 4) tokens at chars/4)\n\n"
        for r in rs { s += String(format: "%8d  %@\n", r.chars, r.name) }
        if !toolRows.isEmpty {
            s += "\n--- tools by json size (\(toolRows.count)) ---\n"
            for r in toolRows.sorted(by: { $0.chars > $1.chars }) { s += String(format: "%8d  %@\n", r.chars, r.name) }
        }
        for (i, b) in systemBlocks.enumerated() {
            let text = b["text"] as? String ?? ""
            s += "\n--- system[\(i)] sections ---\n"
            for r in sections(of: text) { s += String(format: "%8d  %@\n", r.chars, r.name) }
        }
        for (i, b) in systemBlocks.enumerated() {
            let text = b["text"] as? String ?? ""
            s += "\n===== system[\(i)] full text =====\n\(text)\n"
        }
        s += "\n===== messages =====\n"
        for m in messages {
            let role = m["role"] as? String ?? "?"
            let content = (m["content"] as? String) ?? String(describing: m["content"] ?? "").prefix(400).description
            s += "[\(role)] \(content)\n\n"
        }
        return s
    }

    @MainActor
    static func write(to url: URL) {
        let pending = ChatService.shared.assemblePendingContext(state: AppState.shared)
        let toolsJSON = pending.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema] as [String: Any] }
        let toolBytes = (try? JSONSerialization.data(withJSONObject: toolsJSON))?.count ?? 0
        let toolRows = toolsJSON.map { Row(name: $0["name"] as? String ?? "?",
                                           chars: (try? JSONSerialization.data(withJSONObject: $0))?.count ?? 0) }
        let text = report(systemBlocks: pending.systemBlocks, messages: pending.messages,
                          toolsJSONBytes: toolBytes, toolRows: toolRows, modelId: pending.modelId)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        WakeLog.shared.log("chat context dump: \(text.count) chars written to \(url.lastPathComponent)")
    }
}
