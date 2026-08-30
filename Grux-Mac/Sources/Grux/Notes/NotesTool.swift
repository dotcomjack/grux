import Foundation

// Claude-tool adapter for quick notes. Registered by ChatService.allTools()
// and dispatched by ChatService.dispatchTool(). Thin switch over NotesStore
// on the main actor, mirroring FolderTool's shape.
enum NotesTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "create_note",
                description: "Create a quick note for the user. Use when they say 'make a note', 'write this down', 'note that', or dictates content worth keeping. Body is markdown. Prefer a short descriptive title; put the substance in body.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short note title, <60 chars."],
                        "body": ["type": "string", "description": "Note body, markdown. Bullets welcome."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional lowercase tags like 'work', 'ideas'."],
                        "pinned": ["type": "boolean", "description": "Pin to top of the list. Default false."]
                    ],
                    "required": ["title"]
                ]
            ),
            ClaudeTool(
                name: "search_notes",
                description: "Search the user's notes by keyword across title, body, and tags. Empty query lists everything (pinned first, newest first). Use for 'what notes do I have', 'find my note about X', or before updating a note to get its id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Keywords to match. Empty or omitted lists all notes."],
                        "limit": ["type": "integer", "description": "Max rows. Default 10, max 50."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "update_note",
                description: "Update an existing note: replace title/body/tags, append to the body, pin/unpin, or delete it. Resolve the note by id from search_notes, or by title keywords. Use `append` to add to a note without rewriting it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string", "description": "Note id (UUID) OR title keywords ('the packaging note')."],
                        "title": ["type": "string", "description": "Optional new title."],
                        "body": ["type": "string", "description": "Optional FULL replacement body (markdown)."],
                        "append": ["type": "string", "description": "Optional text appended to the existing body. Mutually exclusive with body."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional full replacement tag list."],
                        "pinned": ["type": "boolean", "description": "Optional pin/unpin."],
                        "delete": ["type": "boolean", "description": "true = delete the note instead of editing."]
                    ],
                    "required": ["note"]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = ["create_note", "search_notes", "update_note"]

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "create_note":
            let title = (input["title"] as? String) ?? ""
            let body = (input["body"] as? String) ?? ""
            let tags = (input["tags"] as? [String]) ?? []
            let pinned = (input["pinned"] as? Bool) ?? false
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty || !body.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: note needs a title or body"
            }
            return await MainActor.run {
                let n = NotesStore.shared.create(title: title, body: body, tags: tags, pinned: pinned)
                return "ok: created note '\(n.displayTitle)' id=\(n.id.uuidString)\(n.pinned ? " (pinned)" : "")"
            }

        case "search_notes":
            let query = (input["query"] as? String) ?? ""
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 10))
            return await MainActor.run {
                let hits = NotesStore.shared.search(query)
                if hits.isEmpty {
                    return query.isEmpty ? "(no notes yet)" : "(no notes matched '\(query)')"
                }
                let rows = hits.prefix(limit).map { formatRow($0) }.joined(separator: "\n")
                let suffix = hits.count > limit ? "\n(\(hits.count - limit) more, raise limit to see)" : ""
                return rows + suffix
            }

        case "update_note":
            let hint = (input["note"] as? String) ?? ""
            guard !hint.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: empty note reference"
            }
            return await MainActor.run {
                let store = NotesStore.shared
                guard let target = store.resolve(hint) else {
                    return "error: no note matched '\(hint)'"
                }
                if (input["delete"] as? Bool) == true {
                    store.delete(id: target.id)
                    return "ok: deleted note '\(target.displayTitle)'"
                }
                if let append = input["append"] as? String, !append.isEmpty {
                    _ = store.appendToBody(id: target.id, text: append)
                }
                let updated = store.update(
                    id: target.id,
                    title: input["title"] as? String,
                    body: input["body"] as? String,
                    tags: input["tags"] as? [String],
                    pinned: input["pinned"] as? Bool
                )
                guard let n = updated else { return "error: update failed" }
                return "ok: updated note '\(n.displayTitle)' id=\(n.id.uuidString)"
            }

        default:
            return "error: unknown notes tool '\(name)'"
        }
    }

    // MARK: - Formatting

    @MainActor
    private static func formatRow(_ n: GruxNote) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d h:mm a"
        df.timeZone = .current
        var flags: [String] = []
        if n.pinned { flags.append("pinned") }
        if !n.tags.isEmpty { flags.append(n.tags.map { "#\($0)" }.joined(separator: " ")) }
        let flagStr = flags.isEmpty ? "" : " · \(flags.joined(separator: " · "))"
        let preview = n.previewLine.isEmpty ? "" : "\n  → \(n.previewLine)"
        return "- id=\(n.id.uuidString) · \(n.displayTitle) · \(df.string(from: n.updatedAt))\(flagStr)\(preview)"
    }
}
