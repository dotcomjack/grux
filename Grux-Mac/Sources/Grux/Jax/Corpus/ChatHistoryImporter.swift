import Foundation

// Imports Claude + ChatGPT conversation exports and indexes THE USER'S turns
// only. This is the highest-signal corpus source: the user reasoning in real
// time, in prose, about their own work. The assistant turns are NOT indexed
// (they are not the user's voice).
//
// Drop zone: ~/.grux/jax/imports/ (greppable from the CLI like the rest of the
// ~/.grux convention). The user drops the raw export files there:
//   - ChatGPT export: conversations.json (array of conversations, each with a
//     `mapping` of message nodes; author.role == "user" is the user).
//   - Claude export: conversations.json (array; each conversation has
//     `chat_messages` with sender == "human"). Some exports use `messages`
//     with role "human"/"user". We handle all shapes leniently.
//
// Zip handling: we do NOT bundle an unzip library. If a .zip is dropped we ask
// (via the run note) for it to be unzipped first, OR we shell out to /usr/bin/unzip
// into a temp dir. We take the shell-out path (Process is already used across
// Grux) so a dropped .zip "just works".
//
// Parsing is intentionally schema-lenient: exports change shape over time, so we
// walk JSON generically and pull any object that looks like a user-authored
// message, rather than binding to one rigid Codable shape that breaks on the
// next export format revision.
actor ChatHistoryImporter: CorpusIngester {
    nonisolated let source: CorpusSource = .chatHistory

    private let rag: RAGClient
    private var ledger: CorpusLedger

    static var importsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("jax")
            .appendingPathComponent("imports")
    }

    init(rag: RAGClient) {
        self.rag = rag
        self.ledger = CorpusLedger.load(source: .chatHistory)
    }

    func probe() async -> CorpusPermission {
        let dir = Self.importsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let relevant = files.filter { ["json", "zip"].contains($0.pathExtension.lowercased()) }
        return relevant.isEmpty ? .noData : .ready
    }

    func ingest() async -> CorpusRunResult {
        let dir = Self.importsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let candidates = files.filter { ["json", "zip"].contains($0.pathExtension.lowercased()) }
        guard !candidates.isEmpty else { return .blocked(.noData) }

        var indexed = 0, skipped = 0
        var docs: [RAGClient.Document] = []

        for file in candidates {
            let jsonURLs: [URL]
            if file.pathExtension.lowercased() == "zip" {
                jsonURLs = Self.unzipToTemp(file)
            } else {
                jsonURLs = [file]
            }
            for url in jsonURLs {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                let turns = Self.extractUserTurns(from: obj)
                for turn in turns {
                    let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 12 else { skipped += 1; continue }
                    let key = "chat-\(CorpusIndexer.stableHash(text))"
                    guard ledger.insert(key) else { skipped += 1; continue }

                    let ts = turn.timestampMillis
                    await MainActor.run {
                        CorpusIndexer.indexLocal(source: .chatHistory, text: text, timestampMillis: ts,
                                                 extraMetadata: ["platform": turn.platform])
                    }
                    docs.append(RAGClient.Document(
                        id: CorpusIndexer.docId(source: .chatHistory, key: key),
                        source: "chat",
                        text: text,
                        ts: ts.map { $0 / 1000 },
                        brandHint: ""
                    ))
                    indexed += 1
                }
            }
        }

        let pushed = await CorpusIndexer.pushToRAG(rag, source: .chatHistory, docs: docs)
        ledger.save(source: .chatHistory)
        return CorpusRunResult(indexed: indexed, pushedToRAG: pushed, skipped: skipped, permission: .ready,
                               note: "Indexed \(indexed) of your chat turns (\(skipped) dupes/short)")
    }

    // MARK: - Extraction

    struct UserTurn {
        let text: String
        let timestampMillis: Int?
        let platform: String   // "chatgpt" | "claude" | "unknown"
    }

    // Walk a decoded JSON tree and pull every user/human-authored message.
    // Handles both ChatGPT (`mapping` of nodes, author.role) and Claude
    // (`chat_messages` / `messages`, sender/role) shapes, plus nested arrays.
    static func extractUserTurns(from obj: Any) -> [UserTurn] {
        var out: [UserTurn] = []
        walk(obj, into: &out)
        return out
    }

    private static func walk(_ node: Any, into out: inout [UserTurn]) {
        if let arr = node as? [Any] {
            for el in arr { walk(el, into: &out) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        // Is THIS dict a user-authored message?
        if let turn = userTurn(from: dict) {
            out.append(turn)
        }

        // Recurse into known containers and any nested dict/array values.
        for (_, v) in dict {
            if v is [Any] || v is [String: Any] { walk(v, into: &out) }
        }
    }

    // Returns a UserTurn if `dict` is a message authored by the human.
    private static func userTurn(from dict: [String: Any]) -> UserTurn? {
        // Determine the author role across schema variants.
        var role: String?
        if let author = dict["author"] as? [String: Any], let r = author["role"] as? String { role = r }
        if role == nil, let r = dict["role"] as? String { role = r }
        if role == nil, let r = dict["sender"] as? String { role = r }
        guard let role else { return nil }
        let r = role.lowercased()
        guard r == "user" || r == "human" else { return nil }

        // Extract the text content across variants.
        let text = textContent(from: dict)
        guard !text.isEmpty else { return nil }

        let platform: String = (dict["sender"] != nil) ? "claude" : "chatgpt"
        return UserTurn(text: text, timestampMillis: timestamp(from: dict), platform: platform)
    }

    // Content shapes:
    //   ChatGPT: content.parts -> [String] (or [{type, text}])
    //   Claude:  text -> String, or content -> [{type:"text", text:"..."}]
    private static func textContent(from dict: [String: Any]) -> String {
        if let s = dict["text"] as? String, !s.isEmpty { return s }

        if let content = dict["content"] {
            if let s = content as? String { return s }
            if let c = content as? [String: Any] {
                if let parts = c["parts"] as? [Any] { return joinParts(parts) }
            }
            if let arr = content as? [Any] { return joinParts(arr) }
        }
        if let msg = dict["message"] as? [String: Any] {
            return textContent(from: msg)
        }
        return ""
    }

    private static func joinParts(_ parts: [Any]) -> String {
        var pieces: [String] = []
        for p in parts {
            if let s = p as? String { pieces.append(s) }
            else if let d = p as? [String: Any] {
                if let t = d["text"] as? String { pieces.append(t) }
            }
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(from dict: [String: Any]) -> Int? {
        // ChatGPT: create_time (unix seconds, Double). Claude: created_at (ISO).
        if let ct = dict["create_time"] as? Double, ct > 0 { return Int(ct * 1000) }
        if let ct = dict["created_at"] as? String, let d = ISO8601DateFormatter().date(from: ct) {
            return Int(d.timeIntervalSince1970 * 1000)
        }
        if let msg = dict["message"] as? [String: Any] { return timestamp(from: msg) }
        return nil
    }

    // Shell out to /usr/bin/unzip into a temp dir; return the .json files found.
    static func unzipToTemp(_ zip: URL) -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-jax-unzip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zip.path, "-d", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            WakeLog.shared.log("corpus[chatHistory]: unzip failed for \(zip.lastPathComponent): \(error)")
            return []
        }
        guard let en = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }
    }
}
