import CryptoKit
import Foundation

/// The tools Grux Local v3 was trained on, and the one-line signature a local
/// turn sends for each instead of its full description.
///
/// Grux 3.1 sent about 6,360 prompt tokens per local turn, most of them tool
/// descriptions, and time to first word on a local model is the prompt's
/// length (LocalTurn.promptCeiling). A model trained on the short form needs
/// only the short form. Every other model, and every tool the model was not
/// trained on (new, changed, MCP), keeps its full description.
///
/// A tool is compacted only when BOTH hold: the turn's model is a Grux Local
/// tag ending `-v3` (`isTrainedModel`), and the tool's name is in `v3` with the
/// hash of its full definition unchanged since training (`schemaHash`). The
/// training run reads Resources/GruxLocal/trained-tools-v3.json, written from
/// these same functions (`contract`), so it trains on the bytes the app sends.
/// TrainedToolsContractTests fails when a trained tool changes.
enum TrainedTools {

    /// The contract and the model tag suffix it was trained for.
    static let version = 3
    static let tagSuffix = "-v3"

    /// Whether `modelId` is a Grux Local tag trained on this contract:
    /// `grux-local:4b-v3`, `gruxai.com/grux/grux-local:4b-v3`. Older tags
    /// (`grux-local:4b`) and every other model are not.
    static func isTrainedModel(_ modelId: String) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        guard let colon = id.lastIndex(of: ":") else { return false }
        let repo = id[..<colon].split(separator: "/").last.map(String.init) ?? ""
        return repo == "grux-local" && id[id.index(after: colon)...].hasSuffix(tagSuffix)
    }

    /// The tool as a local turn puts it on the wire, before any compaction:
    /// OpenAICompatBackend.openAITools's function object.
    static func function(_ t: ClaudeTool) -> [String: Any] {
        ["name": t.name, "description": t.description, "parameters": t.inputSchema]
    }

    /// The bytes Ollama receives for `object`: OpenAICompatBackend.wireData's
    /// options, so a hash or a contract line is the request's own bytes.
    static func wire(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// SHA-256 of the tool's full definition (name, description, parameters)
    /// as it goes on the wire. Any change to any of them changes it.
    static func schemaHash(_ t: ClaudeTool) -> String {
        SHA256.hash(data: wire(function(t))).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of `text`'s UTF-8, hex.
    static func schemaHashOfText(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Abbreviations that end in a full stop without ending the sentence.
    private static let abbreviations = ["e.g.", "i.e.", "etc.", "vs.", "approx."]

    /// The first sentence of `text`, at most `limit` characters, cut at a word.
    static func firstSentence(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var end = flat.endIndex
        var i = flat.startIndex
        while i < flat.endIndex {
            let c = flat[i]
            let next = flat.index(after: i)
            if ".!?".contains(c), next == flat.endIndex || flat[next] == " " {
                let head = flat[..<next].lowercased()
                if !abbreviations.contains(where: { head.hasSuffix($0) }) { end = next; break }
            }
            i = next
        }
        let sentence = String(flat[..<end])
        guard sentence.count > limit else { return sentence }
        let cut = sentence.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "..."
    }

    /// One parameter's type, short: `string`, `[string]`, `now|next|later`.
    static func typeName(_ p: [String: Any]) -> String {
        if let options = p["enum"] as? [Any] { return options.map { "\($0)" }.joined(separator: "|") }
        let type = p["type"] as? String ?? "any"
        if type == "array", let items = p["items"] as? [String: Any] { return "[\(typeName(items))]" }
        return type
    }

    /// The one-line signature: `add_task(title: string, priority?: now|next|later): Add a new task ...`.
    /// Required parameters first, in the schema's `required` order, then the
    /// optional ones by name, so it reads the same on every run.
    static func signature(_ t: ClaudeTool) -> String {
        let properties = t.inputSchema["properties"] as? [String: Any] ?? [:]
        let required = (t.inputSchema["required"] as? [String] ?? []).filter { properties[$0] != nil }
        let optional = properties.keys.filter { !required.contains($0) }.sorted()
        let params = (required.map { ($0, "") } + optional.map { ($0, "?") }).map { name, mark in
            "\(name)\(mark): \(typeName(properties[name] as? [String: Any] ?? [:]))"
        }
        return "\(t.name)(\(params.joined(separator: ", "))): \(firstSentence(t.description))"
    }

    /// `t` with its signature in place of its description. The parameters
    /// stay exactly as they were.
    static func compacted(_ t: ClaudeTool) -> ClaudeTool {
        ClaudeTool(name: t.name, description: signature(t), inputSchema: t.inputSchema)
    }

    /// Whether `t` is the definition v3 was trained on.
    static func isTrained(_ t: ClaudeTool) -> Bool {
        v3[t.name].map { $0 == schemaHash(t) } ?? false
    }

    /// The tools a local turn on `modelId` sends: each trained, unchanged tool
    /// as its signature when the model is a v3 Grux Local tag, every other
    /// tool, and every tool for every other model, exactly as given.
    static func forModel(_ modelId: String, _ tools: [ClaudeTool]) -> [ClaudeTool] {
        guard isTrainedModel(modelId) else { return tools }
        return tools.map { isTrained($0) ? compacted($0) : $0 }
    }

    /// Tools that never go in the contract: everything outside the core group
    /// and the tools that open another app, because a heavy group's or an MCP
    /// server's definitions depend on what is installed or switched on.
    static func isContractCandidate(_ t: ClaudeTool) -> Bool {
        let group = ToolRelevance.group(for: t.name)
        return (group == .core || group == .otherApps) && !t.name.hasPrefix("mcp_")
    }

    /// One tool as the `tools` array carries it on the wire.
    static func wireTool(_ t: ClaudeTool) -> [String: Any] { ["type": "function", "function": function(t)] }

    /// The training contract for `tools` (the app's own, ChatService.allTools):
    /// every contract candidate in the one order a local turn sends
    /// (LocalTurn.stableOrder), with its hash, its signature, its full
    /// description and the exact object and bytes it goes out as in compact
    /// mode; the whole compact list as one request's `tools` value; and the
    /// fixed text and options around them. Deterministic, so a test can hold
    /// the committed file to it. Real request bodies are in the samples file
    /// (`samples`), which carries the minute and so cannot be.
    static func contract(_ tools: [ClaudeTool]) -> [String: Any] {
        let trained = LocalTurn.stableOrder(tools.filter(isContractCandidate))
        let compact = trained.map(compacted)
        let entries: [[String: Any]] = zip(trained, compact).map { full, short in
            ["name": full.name,
             "group": ToolRelevance.group(for: full.name).rawValue,
             "schema_sha256": schemaHash(full),
             "signature": short.description,
             "full_description": full.description,
             "compact": wireTool(short),
             "compact_wire": String(decoding: wire(wireTool(short)), as: UTF8.self)]
        }
        let contexts: [String: Int] = ["under_12_gb": LocalTurn.contextTokens(memoryGB: 8),
                                       "12_to_24_gb": LocalTurn.contextTokens(memoryGB: 16),
                                       "24_gb_and_up": LocalTurn.contextTokens(memoryGB: 32)]
        return [
            "contract": "grux-local-trained-tools",
            "version": version,
            "model_tag_suffix": tagSuffix,
            "mode": "tools_array",
            "regenerate": "a debug build run as `Grux --trained-tools-contract <dir>` under a clean HOME (also writes "
                + "the samples file), or TrainedToolsContractTests with GRUX_WRITE_TRAINED_TOOLS=<dir>; both call "
                + "TrainedTools.contract on ChatService.allTools()",
            "schema_sha256_of": "the full tool object {name, description, parameters} as JSON with sorted keys, no "
                + "whitespace, slashes escaped (Foundation JSONSerialization, .sortedKeys): the bytes the app sends",
            "compact_rule": "description replaced by signature; parameters unchanged; only on a grux-local tag ending "
                + "\(tagSuffix), only for a tool whose schema_sha256 still matches. Every other tool keeps its full "
                + "description on the same turn",
            "stable_head": LocalTurn.stableHead,
            "system": [
                "template": "{persona}\n\n{tool_note}\n\n{identity}\n\n{profile}\n\n{capabilities}",
                "persona": "the install's system prompt up to \"\(LocalTurn.leanCut)\" (LocalTurn.leanStable); "
                    + "varies per install",
                "tool_note": LocalTurn.toolNote,
                "cached_blocks_joined_with": "\n\n",
            ],
            "turn_context_template": "\(OpenAICompatBackend.turnContextLabel)\n{per_turn_block}\n\nTHE USER'S MESSAGE:\n{user_text}",
            "cut_line_template": LocalTurn.cutToolsLine(["{names, comma separated, in the order above}"]) ?? "",
            "fallback": "A turn takes the ranked list instead of the stable one when a message points past it, a tool "
                + "used in the last 15 minutes is off it, the message has an image, a tool that opens another app "
                + "was switched on by the words, or the turn would not fit. The ranked list is a subset of the "
                + "same tools, sent in the same order; tools outside this contract keep their full description",
            "num_ctx": contexts,
            "num_predict": ChatService.chatMaxTokens,
            "temperature": ChatService.chatTemperature,
            "think": false,
            "keep_alive": LocalTurn.keepAlive,
            "tools": entries,
            "tools_wire_json": String(decoding: wire(compact.map(wireTool)), as: UTF8.self),
        ]
    }

    /// The contract file's bytes: pretty, sorted, one trailing newline.
    static func contractData(_ tools: [ClaudeTool]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: contract(tools),
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// The names whose live definition no longer matches `v3`: each one now
    /// goes out with its full description, which a v3 model was not trained on.
    static func drifted(_ tools: [ClaudeTool]) -> [String] {
        let live = Dictionary(tools.map { ($0.name, schemaHash($0)) }, uniquingKeysWith: { a, _ in a })
        return v3.keys.sorted().filter { live[$0] != v3[$0] }
    }
}

extension TrainedTools {
    /// TrainedToolsV3.swift's text for `tools`: the names and hashes `v3`
    /// holds, written by the same run that writes the contract file.
    static func tableSource(_ tools: [ClaudeTool]) -> String {
        let rows = LocalTurn.stableOrder(tools.filter(isContractCandidate))
            .map { "        \"\($0.name)\": \"\(schemaHash($0))\"," }
        return """
        // Written by TrainedTools.tableSource with Resources/GruxLocal/trained-tools-v3.json.
        // Do not edit by hand: TrainedToolsContractTests compares the two.

        extension TrainedTools {
            /// Tool name to the schema hash Grux Local v3 was trained on.
            static let v3: [String: String] = [
        \(rows.joined(separator: "\n"))
            ]
        }

        """
    }
}

extension TrainedTools {
    /// One local turn's exact `/api/chat` bytes, from the app's own path:
    /// `assemblePendingContext`, the turn's `forModel` step,
    /// `withTurnContextAfterTools`, `streamedChatBody`, `ollamaChatBody` and
    /// `wireData`. `memoryGB` picks the window as a Mac of that size would;
    /// `lines` replaces whole lines of the per-turn block by their label
    /// ("NOW", "ACTIVE_APP_RIGHT_NOW"), so a training set holds no minute or
    /// machine of its own. Debug flag only (GruxApp), under a clean HOME.
    @MainActor
    static func request(ask: String, model: String, memoryGB: Double,
                        lines: [String: String] = [:]) -> (body: String, stable: Bool, tools: [ClaudeTool]) {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: ask)]
        let window = LocalTurn.contextTokens(memoryGB: memoryGB)
        let turn = ChatService.shared.assemblePendingContext(state: state, lean: true, window: window)
        let tools = forModel(model, turn.tools)
        let blocks = turn.systemBlocks.map { block -> [String: Any] in
            guard let text = block["text"] as? String, !lines.isEmpty else { return block }
            var out = block
            out["text"] = text.components(separatedBy: "\n").map { line in
                lines.first { line.hasPrefix($0.key + ":") }.map { "\($0.key): \($0.value)" } ?? line
            }.joined(separator: "\n")
            return out
        }
        let messages = OpenAICompatBackend.withTurnContextAfterTools(
            systemBlocks: blocks, messages: OpenAICompatBackend.openAIChatMessages(turn.messages))
        let body = OpenAICompatBackend.ollamaChatBody(
            OpenAICompatBackend.streamedChatBody(model: model, maxTokens: ChatService.chatMaxTokens,
                                                 temperature: ChatService.chatTemperature,
                                                 messages: messages, tools: tools),
            stream: true, contextTokens: window)
        return (String(decoding: (try? OpenAICompatBackend.wireData(body)) ?? Data(), as: UTF8.self),
                turn.localStable, turn.tools)
    }

    /// Two of `request`: an everyday turn (the stable list) and one that asks
    /// to open a page (the ranked list), on a 16 GB Mac's window.
    @MainActor
    static func samples(model: String = "gruxai.com/grux/grux-local:4b-v3") -> [String: Any] {
        var out: [[String: Any]] = []
        for (name, ask) in [("stable", "what is on my plate today?"), ("ranked", "open github.com")] {
            let r = request(ask: ask, model: model, memoryGB: 16)
            out.append(["turn": name, "ask": ask, "path": r.stable ? "stable" : "fallback",
                        "tools": r.tools.map(\.name),
                        "compacted": isTrainedModel(model) ? r.tools.filter(isTrained).count : 0,
                        "body": r.body])
        }
        return ["model": model, "num_ctx": LocalTurn.contextTokens(memoryGB: 16), "requests": out]
    }

    /// `--dump-local-requests <in.jsonl> <out.jsonl>`: one `request` per input
    /// line {id, utterance, memory_gb, model, now?, active_app?}, written as
    /// {id, path ("stable" or "fallback"), body}.
    @MainActor
    static func dumpRequests(from input: URL, to output: URL) throws -> Int {
        let text = try String(contentsOf: input, encoding: .utf8)
        var lines: [String] = []
        for raw in text.split(separator: "\n") where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let item = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let id = item["id"], let ask = item["utterance"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var over: [String: String] = [:]
            if let now = item["now"] as? String { over["NOW"] = now }
            if let app = item["active_app"] as? String { over["ACTIVE_APP_RIGHT_NOW"] = app }
            RecentToolUse.shared.clear()
            let r = request(ask: ask, model: item["model"] as? String ?? "gruxai.com/grux/grux-local:4b-v3",
                            memoryGB: (item["memory_gb"] as? NSNumber)?.doubleValue ?? 16, lines: over)
            let row: [String: Any] = ["id": id, "path": r.stable ? "stable" : "fallback", "body": r.body]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output)
        return lines.count
    }
}
