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

    /// Tools that never go in the contract: their definitions depend on what
    /// is installed or switched on, so no one training run can hold them.
    static func isContractCandidate(_ t: ClaudeTool) -> Bool {
        ToolRelevance.group(for: t.name) == .core && !t.name.hasPrefix("mcp_")
    }

    /// The training contract for `tools` (the app's own, ChatService.allTools):
    /// every contract candidate, in the order a local turn sends them
    /// (LocalTurn.stableOrder), with its hash, its signature, its full
    /// description, and the exact bytes Ollama receives for it in compact
    /// mode; then the whole compact list as one request's `tools` value, and
    /// the fixed text a lean turn's system prompt carries.
    static func contract(_ tools: [ClaudeTool]) -> [String: Any] {
        let trained = LocalTurn.stableOrder(tools.filter(isContractCandidate))
        let compact = trained.map(compacted)
        func wireTool(_ t: ClaudeTool) -> [String: Any] { ["type": "function", "function": function(t)] }
        let entries: [[String: Any]] = zip(trained, compact).map { full, short in
            ["name": full.name,
             "schema_sha256": schemaHash(full),
             "signature": short.description,
             "full_description": full.description,
             "compact_wire": String(decoding: wire(wireTool(short)), as: UTF8.self)]
        }
        return [
            "contract": "grux-local-trained-tools",
            "version": version,
            "model_tag_suffix": tagSuffix,
            "regenerate": "Grux --trained-tools-contract <dir> (a debug build), or TrainedToolsContractTests with "
                + "GRUX_WRITE_TRAINED_TOOLS=<dir>; both call TrainedTools.contract on ChatService.allTools().",
            "schema_sha256_of": "the full tool object {name, description, parameters} as JSON with sorted keys, "
                + "no whitespace, slashes escaped (Foundation JSONSerialization, .sortedKeys): the bytes the app sends Ollama",
            "compact_rule": "description replaced by signature; parameters unchanged; only on a grux-local tag ending "
                + "\(tagSuffix), only for a tool whose schema_sha256 still matches",
            "tool_note": LocalTurn.toolNote,
            "turn_context_label": OpenAICompatBackend.turnContextLabel,
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
