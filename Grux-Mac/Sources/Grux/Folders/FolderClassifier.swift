import Foundation

// Auto-assigns a freshly-summarized meeting to one of the user's folders by
// asking Claude to pick the best match given each folder's description. This
// is the Omi-parity feature - the `description` field is the user-written
// instruction to the classifier. Local-first posture: if no Anthropic key is
// set, we silently skip and the meeting lands in the default folder.
//
// The classifier never overrides a manual assignment: callers must guard with
// `record.folderId == nil`.
@MainActor
enum FolderClassifier {

    struct Assignment {
        let folderId: UUID
        let confidence: Double
        let reasoning: String
    }

    static let minConfidence: Double = 0.55

    static func classify(record: MeetingRecord) async -> Assignment? {
        let folders = FolderStore.shared.ordered
        guard !folders.isEmpty else { return nil }
        let state = AppState.shared
        // When useLocalQwenForAmbient is on, AmbientLLM will route through the
        // companion service and only fall back to Claude on error. When off, we need a key.
        if !state.config.useLocalQwenForAmbient && state.anthropicKey.isEmpty { return nil }

        let foldersContext: String = folders.map { f in
            let desc = f.description.isEmpty ? "(no description)" : f.description
            let flags: String = {
                var parts: [String] = []
                if f.isDefault { parts.append("DEFAULT - fallback when nothing else fits") }
                if f.isSystem { parts.append("system") }
                return parts.isEmpty ? "" : "  [\(parts.joined(separator: ", "))]"
            }()
            return "- \(f.id.uuidString) | \"\(f.name)\"\(flags): \(desc)"
        }.joined(separator: "\n")

        let excerpt = record.flatText().prefix(3_500)
        let summaryPart: String = {
            guard let s = record.summary, !s.isEmpty else { return "(no summary yet)" }
            return s
        }()

        let system = """
        You are a quiet classifier. Pick the single best folder for this \
        meeting given each folder's description. Respond with STRICT JSON:
          {"folder_id": "<uuid>", "confidence": <0.0-1.0>, "reasoning": "<one short sentence>"}
        - folder_id MUST be one of the ids in the list; never invent a new one.
        - If nothing fits well, pick the DEFAULT folder and set confidence below 0.5.
        - Confidence is your honest read, not a target.
        - No prose outside the JSON. No markdown fences.
        """

        let user = """
        User folders (id | name: description):
        \(foldersContext)

        Meeting title: \(record.displayTitle)
        Duration: \(Int(record.durationSeconds))s
        Source app: \(record.sourceAppName ?? "unknown")
        Summary: \(summaryPart)

        Transcript excerpt:
        ---
        \(excerpt)
        ---

        Respond with JSON only.
        """

        do {
            let reply = try await AmbientLLM.complete(
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 200,
                temperature: 0.1,
                featureTag: "folder_classifier"
            )
            return parse(reply, validIds: Set(folders.map { $0.id }))
        } catch {
            WakeLog.shared.log("folder-classifier: failed \(error.localizedDescription)")
            return nil
        }
    }

    static func parse(_ raw: String, validIds: Set<UUID>) -> Assignment? {
        let cleaned = stripFences(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let idStr = obj["folder_id"] as? String, let id = UUID(uuidString: idStr) else { return nil }
        guard validIds.contains(id) else { return nil }
        let confidence = (obj["confidence"] as? Double)
            ?? Double((obj["confidence"] as? NSNumber)?.doubleValue ?? 0.0)
        let reasoning = (obj["reasoning"] as? String) ?? ""
        return Assignment(folderId: id, confidence: confidence, reasoning: reasoning)
    }

    private static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let first = s.firstIndex(of: "\n") { s = String(s[s.index(after: first)...]) }
            if let last = s.range(of: "```", options: .backwards) { s = String(s[..<last.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
