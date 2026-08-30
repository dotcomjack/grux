import Foundation

// Claude tool surface for items 32 + 33. Lets the user say "back everything up"
// in chat. Restore stays UI-only on purpose: it swaps the live data tree and
// needs an explicit confirm dialog, not a tool call.
enum BackupTool {

    nonisolated static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "backup_now",
                description: "Create a FULL Grux backup right now: zips everything under Application Support/Grux and ~/Documents/Grux (chats, agents, meetings, workday logs, memory, documents, commands) into one archive with a versioned manifest. Use when they say 'back everything up', 'make a full backup', 'snapshot Grux'. Distinct from export_memory which only exports memory. Optionally pass a destination folder; defaults to the configured backups folder (~/Documents/Grux/backups). Returns the archive path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "destination": ["type": "string", "description": "Optional absolute folder path to write the archive into. '~' is expanded. Omit to use the configured backups folder."]
                    ]
                ]
            )
        ]
    }

    @MainActor
    static func executeTool(name: String, input: [String: Any]) async -> String? {
        switch name {
        case "backup_now":
            let dest: URL
            if let raw = input["destination"] as? String, !raw.isEmpty {
                dest = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                dest = BackupScheduler.shared.destinationURL
            }
            do {
                let url = try await BackupManager.shared.createBackup(to: dest)
                let manifest = try? await BackupManager.shared.readManifest(fromArchive: url)
                let detail = manifest.map { " (\($0.totalFiles) files, \(ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file)))" } ?? ""
                BackupScheduler.shared.noteExternalSuccess()
                return "ok: full backup written to \(url.path)\(detail)"
            } catch {
                return "error: backup failed: \(error.localizedDescription)"
            }

        default:
            return nil
        }
    }
}
