import Foundation

// Claude-tool adapter for folder management. Registered by
// ChatService.allTools() and dispatched by ChatService.dispatchTool().
// Thin switch that calls into FolderStore / MeetingStore on the main actor.
enum FolderTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "list_folders",
                description: "List all of the user's meeting/memory folders with their ids, names, descriptions, icons, and member counts. Use whenever they mention 'folders', 'where is X', 'what folders do I have', or you're about to create one and want to check for duplicates first.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            ClaudeTool(
                name: "create_folder",
                description: "Create a new folder. The `description` doubles as the AI classifier's steering prompt - it tells Grux what KIND of meetings/memories belong here. Be specific: 'product work - shipping, roadmap, infra' beats 'work stuff'. Use when the user says 'make a folder for X', 'add a folder called X', 'create a Y folder'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Folder display name, <40 chars. Title case."],
                        "description": ["type": "string", "description": "What belongs here. Doubles as AI classifier steering prompt. 1-2 sentences."],
                        "color": ["type": "string", "description": "Optional hex color like '#F59E0B'. Defaults to purple."],
                        "icon": ["type": "string", "description": "Optional SF Symbol name (e.g. 'briefcase.fill', 'heart.fill', 'music.note'). Defaults to 'folder.fill'."]
                    ],
                    "required": ["name"]
                ]
            ),
            ClaudeTool(
                name: "rename_folder",
                description: "Rename or update an existing folder's description/color/icon. Call whenever the user asks to 'rename X to Y', 'change the description of X', 'make the work folder blue', etc.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "folder": ["type": "string", "description": "Folder id OR exact name OR substring ('work', 'the Sabbath folder')."],
                        "new_name": ["type": "string", "description": "Optional new display name."],
                        "description": ["type": "string", "description": "Optional new description / classifier prompt."],
                        "color": ["type": "string", "description": "Optional new hex color."],
                        "icon": ["type": "string", "description": "Optional new SF Symbol name."]
                    ],
                    "required": ["folder"]
                ]
            ),
            ClaudeTool(
                name: "delete_folder",
                description: "Delete a user-created folder. System folders (Work / Personal / Projects) can't be deleted. All member meetings are moved to the default folder, or to `reassign_to` if specified.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "folder": ["type": "string", "description": "Folder id OR exact name OR substring."],
                        "reassign_to": ["type": "string", "description": "Optional target folder (id or name) that orphaned meetings should be moved to. Defaults to the default folder."]
                    ],
                    "required": ["folder"]
                ]
            ),
            ClaudeTool(
                name: "move_meeting_to_folder",
                description: "Move a specific captured meeting into a folder. Use after list_meetings / search_meetings when the user says 'put that one in the work folder', 'move the meeting from yesterday into personal'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": ["type": "string", "description": "The meeting's UUID."],
                        "folder": ["type": "string", "description": "Folder id OR exact name OR substring."]
                    ],
                    "required": ["meeting_id", "folder"]
                ]
            ),
            ClaudeTool(
                name: "list_meetings_in_folder",
                description: "List the meetings belonging to a specific folder (most recent first). Same row shape as list_meetings. Use for 'show me my work meetings', 'what's in the personal folder'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "folder": ["type": "string", "description": "Folder id OR exact name OR substring."],
                        "limit": ["type": "integer", "description": "Max rows to return. Default 10, max 50."]
                    ],
                    "required": ["folder"]
                ]
            ),
            ClaudeTool(
                name: "classify_meeting_to_folder",
                description: "Ask Grux to auto-assign a meeting to the best-matching folder using AI based on each folder's description. Use when the user says 'file that meeting somewhere smart', 'put it in the right folder', or after creating a new folder and wanting to retro-assign older meetings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": ["type": "string", "description": "The meeting's UUID."]
                    ],
                    "required": ["meeting_id"]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = [
        "list_folders", "create_folder", "rename_folder", "delete_folder",
        "move_meeting_to_folder", "list_meetings_in_folder", "classify_meeting_to_folder"
    ]

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "list_folders":
            return await MainActor.run { formatFolderList() }

        case "create_folder":
            let n = (input["name"] as? String) ?? ""
            let d = (input["description"] as? String) ?? ""
            let c = (input["color"] as? String) ?? ""
            let ic = (input["icon"] as? String) ?? ""
            return await MainActor.run {
                guard let f = FolderStore.shared.create(
                    name: n,
                    description: d,
                    colorHex: c.isEmpty ? "#8B5CF6" : c,
                    icon: ic.isEmpty ? "folder.fill" : ic
                ) else {
                    return "error: couldn't create folder (name empty, duplicate, or 50-folder cap reached)"
                }
                return "ok: created folder '\(f.name)' id=\(f.id.uuidString)"
            }

        case "rename_folder":
            let hint = (input["folder"] as? String) ?? ""
            return await MainActor.run { () -> String in
                guard let target = FolderStore.shared.resolve(hint) else {
                    return "error: no folder matched '\(hint)'"
                }
                _ = FolderStore.shared.update(
                    id: target.id,
                    name: input["new_name"] as? String,
                    description: input["description"] as? String,
                    colorHex: input["color"] as? String,
                    icon: input["icon"] as? String
                )
                return "ok: updated folder '\(target.name)' id=\(target.id.uuidString)"
            }

        case "delete_folder":
            let hint = (input["folder"] as? String) ?? ""
            let moveHint = input["reassign_to"] as? String
            return await MainActor.run { () -> String in
                guard let target = FolderStore.shared.resolve(hint) else {
                    return "error: no folder matched '\(hint)'"
                }
                if target.isSystem {
                    return "error: '\(target.name)' is a system folder and can't be deleted (rename it if you want)"
                }
                let reassign: UUID? = {
                    guard let h = moveHint, !h.isEmpty else { return nil }
                    return FolderStore.shared.resolve(h)?.id
                }()
                guard let result = FolderStore.shared.delete(id: target.id, reassignTo: reassign) else {
                    return "error: delete failed"
                }
                return "ok: deleted '\(result.deleted.name)', members moved to '\(result.newHome.name)'"
            }

        case "move_meeting_to_folder":
            guard let idStr = input["meeting_id"] as? String, let mid = UUID(uuidString: idStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            let hint = (input["folder"] as? String) ?? ""
            return await MainActor.run { () -> String in
                guard let folder = FolderStore.shared.resolve(hint) else {
                    return "error: no folder matched '\(hint)'"
                }
                guard let _ = MeetingStore.shared.assign(meetingId: mid, folderId: folder.id) else {
                    return "error: meeting \(mid.uuidString) not found"
                }
                return "ok: meeting moved to '\(folder.name)'"
            }

        case "list_meetings_in_folder":
            let hint = (input["folder"] as? String) ?? ""
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 10))
            return await MainActor.run { () -> String in
                guard let folder = FolderStore.shared.resolve(hint) else {
                    return "error: no folder matched '\(hint)'"
                }
                let rows = MeetingStore.shared.list(limit: limit, folderId: folder.id)
                if rows.isEmpty { return "(no meetings in '\(folder.name)' yet)" }
                return "folder: \(folder.name) (\(rows.count))\n" + formatMeetingRows(rows)
            }

        case "classify_meeting_to_folder":
            guard let idStr = input["meeting_id"] as? String, let mid = UUID(uuidString: idStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            guard let rec = await MainActor.run(body: { MeetingStore.shared.loadRecord(id: mid) }) else {
                return "error: meeting not found"
            }
            guard let assignment = await FolderClassifier.classify(record: rec) else {
                return "skipped: classifier unavailable (missing key or LLM error) - left folder unchanged"
            }
            let chosen: Folder? = await MainActor.run { FolderStore.shared.folder(id: assignment.folderId) }
            guard let folder = chosen else {
                return "skipped: classifier returned unknown folder id"
            }
            if assignment.confidence < FolderClassifier.minConfidence {
                return "skipped: low-confidence match (\(String(format: "%.0f%%", assignment.confidence * 100))) - left folder unchanged"
            }
            _ = await MainActor.run { MeetingStore.shared.assign(meetingId: mid, folderId: folder.id) }
            let pct = String(format: "%.0f%%", assignment.confidence * 100)
            return "ok: classified into '\(folder.name)' (confidence \(pct)) - \(assignment.reasoning)"

        default:
            return "error: unknown folder tool '\(name)'"
        }
    }

    // MARK: - Formatting

    @MainActor
    private static func formatFolderList() -> String {
        let store = FolderStore.shared
        let folders = store.ordered
        let counts = MeetingStore.shared.folderCounts()
        if folders.isEmpty { return "(no folders yet)" }
        return folders.map { f in
            var flags: [String] = []
            if f.isDefault { flags.append("DEFAULT") }
            if f.isSystem { flags.append("system") }
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            let descPart = f.description.isEmpty ? "" : "\n    → \(f.description)"
            let count = counts[f.id] ?? 0
            return "- id=\(f.id.uuidString) · \(f.name) · \(count) meeting\(count == 1 ? "" : "s")\(flagStr)\(descPart)"
        }.joined(separator: "\n")
    }

    private static func formatMeetingRows(_ entries: [MeetingIndexEntry]) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d h:mm a"
        df.timeZone = .current
        return entries.map { e in
            let dur: String = {
                guard let ended = e.endedAt else { return "in-progress" }
                let secs = Int(ended.timeIntervalSince(e.startedAt))
                return "\(secs / 60)m \(secs % 60)s"
            }()
            let head = "\(df.string(from: e.startedAt)) · \(dur) · \(e.title ?? e.sourceAppName ?? "Meeting")"
            let tail = e.summaryExcerpt.map { "\n  → \($0)" } ?? ""
            return "- id=\(e.id.uuidString) · \(head)\(tail)"
        }.joined(separator: "\n")
    }
}
