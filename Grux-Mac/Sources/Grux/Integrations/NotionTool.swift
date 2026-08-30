import Foundation

// Claude-facing tools for Notion. Push-only (one-way): the LLM can send
// memories and workday logs into the user's configured Notion database.
// Pull/two-way sync is intentionally out of scope for v1 - Notion has no
// native content webhooks and polling every page is wasteful for a local-
// first app. If the user wants what's in Notion, they open Notion.

enum NotionTool {
    static let toolNames: Set<String> = [
        "notion_push_memory",
        "notion_push_workday_log",
        "notion_sync_all_logs",
        "notion_list_databases"
    ]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "notion_push_memory",
                description: """
                Push an inbox memory (or any piece of text) to the user's \
                configured Notion database as a new page. Use when they say \
                'save that to Notion', 'put that in my Notion', or you just \
                captured a memory they explicitly wanted archived to Notion. \
                Do NOT call automatically for every capture_memory - only \
                when Notion is mentioned.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Short title for the Notion page."
                        ],
                        "body": [
                            "type": "string",
                            "description": "The full content. Can be multi-paragraph (use \\n\\n between)."
                        ]
                    ],
                    "required": ["title", "body"]
                ]
            ),
            ClaudeTool(
                name: "notion_push_workday_log",
                description: """
                Push a specific day's workday log to Notion as a new page. \
                Use when the user says 'log today/yesterday's workday to Notion', \
                'archive the workday log', or after a 6am rollup completes.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "'today', 'yesterday', or yyyy-MM-dd. Default 'today'."
                        ]
                    ]
                ]
            ),
            ClaudeTool(
                name: "notion_sync_all_logs",
                description: """
                Push every workday log that hasn't yet been synced to Notion. \
                Idempotent: tracks synced dayKeys in ~/Library/Application \
                Support/Grux/notion-sync.json so replays don't dupe. Use when \
                the user first connects Notion and wants to backfill history.
                """,
                inputSchema: ["type": "object", "properties": [:]]
            ),
            ClaudeTool(
                name: "notion_list_databases",
                description: """
                List the Notion databases the connected integration can see (to \
                help the user pick one). Use when they ask 'what notion dbs do I \
                have' or when they are first setting up.
                """,
                inputSchema: ["type": "object", "properties": [:]]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "notion_push_memory":
            let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = ((input["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else { return "error: title and body required" }
            let paragraphs = body.split(whereSeparator: { $0.isNewline }).map(String.init)
            do {
                let id = try await NotionClient.shared.createPage(
                    title: title,
                    bodyParagraphs: paragraphs.isEmpty ? [body] : paragraphs
                )
                WakeLog.shared.log("notion: pushed memory '\(title.prefix(40))' → \(id)")
                return "ok: pushed to Notion (page id \(id.prefix(8))…)"
            } catch let e as NotionError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        case "notion_push_workday_log":
            let dateRaw = ((input["date"] as? String) ?? "today").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let dayKey: String = await MainActor.run {
                switch dateRaw {
                case "today", "":    return WorkdayLogScheduler.currentDayKey()
                case "yesterday":    return WorkdayLogScheduler.previousDayKey()
                default:             return dateRaw
                }
            }
            guard let log = WorkdayLogStore.load(dayKey: dayKey) else {
                return "error: no workday log saved for \(dayKey)"
            }
            do {
                let id = try await pushLog(log)
                NotionSyncLedger.shared.markSynced(dayKey: dayKey, pageID: id)
                WakeLog.shared.log("notion: pushed workday \(dayKey) → \(id)")
                return "ok: pushed workday log \(dayKey) (page id \(id.prefix(8))…)"
            } catch let e as NotionError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        case "notion_sync_all_logs":
            let entries = WorkdayLogStore.list()
            let ledger = NotionSyncLedger.shared
            let pending = entries.filter { !ledger.isSynced(dayKey: $0.dayKey) }
            guard !pending.isEmpty else { return "ok: nothing to sync (all \(entries.count) logs already in Notion)" }
            var pushed = 0
            var failed: [String] = []
            for entry in pending {
                guard let log = WorkdayLogStore.load(dayKey: entry.dayKey) else { continue }
                do {
                    let id = try await pushLog(log)
                    ledger.markSynced(dayKey: entry.dayKey, pageID: id)
                    pushed += 1
                } catch {
                    failed.append(entry.dayKey)
                }
            }
            if failed.isEmpty {
                return "ok: pushed \(pushed) workday logs to Notion"
            }
            return "partial: pushed \(pushed), failed \(failed.count) (\(failed.prefix(3).joined(separator: ", "))…)"

        case "notion_list_databases":
            do {
                let dbs = try await NotionClient.shared.listDatabases()
                if dbs.isEmpty {
                    return "(no databases shared with the integration - open Notion, share a page/db with your integration)"
                }
                return dbs.prefix(20).map { "- \($0.title) · id: \($0.id)" }.joined(separator: "\n")
            } catch let e as NotionError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        default:
            return "error: unknown notion tool '\(name)'"
        }
    }

    // Convert a WorkdayLog into Notion paragraph lines.
    @discardableResult
    static func pushLog(_ log: WorkdayLog) async throws -> String {
        var lines: [String] = []
        if !log.narrative.isEmpty { lines.append(log.narrative) }

        if !log.completedTasks.isEmpty {
            lines.append("")
            lines.append("Shipped:")
            for t in log.completedTasks.prefix(40) {
                let proj = t.project.isEmpty ? "" : " (\(t.project))"
                lines.append("• \(t.title)\(proj)")
            }
        }
        if !log.codeShipped.isEmpty {
            let total = log.codeShipped.reduce(0) { $0 + $1.commits.count }
            if total > 0 {
                lines.append("")
                lines.append("Code: \(total) commits across \(log.codeShipped.count) projects")
                for shipment in log.codeShipped.prefix(10) {
                    lines.append("• \(shipment.project): \(shipment.commits.count) commits")
                }
            }
        }
        if log.totalProductiveMinutes > 0 {
            let h = log.totalProductiveMinutes / 60
            let m = log.totalProductiveMinutes % 60
            lines.append("")
            lines.append("Productive time: \(h)h \(m)m")
        }
        if !log.insights.isEmpty {
            lines.append("")
            lines.append("Insights:")
            for i in log.insights.prefix(10) { lines.append("• \(i)") }
        }

        return try await NotionClient.shared.createPage(
            title: "Workday Log · \(log.dayKey)",
            bodyParagraphs: lines
        )
    }
}

// Tiny JSON file that records which dayKeys have already been pushed to
// Notion, so notion_sync_all_logs and the auto-sync hook (WorkdayLogStore
// save callback) can be called repeatedly without creating duplicate pages.
//
// Stored at ~/Library/Application Support/Grux/notion-sync.json.
final class NotionSyncLedger {
    static let shared = NotionSyncLedger()

    private struct State: Codable {
        var syncedDayKeys: [String: String]  // dayKey → Notion page id
    }

    private var state: State
    private let url: URL
    private let queue = DispatchQueue(label: "grux.notion-sync-ledger")

    private init() {
        self.url = Persistence.supportDir.appendingPathComponent("notion-sync.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State(syncedDayKeys: [:])
        }
    }

    func isSynced(dayKey: String) -> Bool {
        queue.sync { state.syncedDayKeys[dayKey] != nil }
    }

    func pageID(forDayKey dayKey: String) -> String? {
        queue.sync { state.syncedDayKeys[dayKey] }
    }

    func markSynced(dayKey: String, pageID: String) {
        queue.sync {
            state.syncedDayKeys[dayKey] = pageID
            persist()
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
