import Foundation

// Claude-facing tools for Slack. Follows the ChatService.allTools() pattern:
// each tool returns a short string result that gets fed back to Claude as
// a tool_result. Errors are returned as "error: <human message>" so the LLM
// can recover or surface the problem to the user.

enum SlackTool {
    // The tool names this file handles. ChatService.dispatchTool uses a
    // `case _ where SlackTool.toolNames.contains(name):` arm to route here.
    static let toolNames: Set<String> = [
        "slack_send",
        "slack_list_channels",
        "slack_send_workday_log"
    ]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "slack_send",
                description: """
                Send a plain-text message to a Slack channel. Use when the user \
                says things like 'slack the team', 'post in #general', 'send \
                a slack to marketing', or 'tell the standup channel X'. Resolves \
                channel name or ID. Requires their Slack connection set up in \
                Settings → Integrations. Returns ok/<ts> on success, error \
                string on failure (channel not found, missing scope, etc).
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel": [
                            "type": "string",
                            "description": "Channel name (with or without #), or channel ID (C…/G…). Fuzzy match ok."
                        ],
                        "text": [
                            "type": "string",
                            "description": "The message body. Markdown-lite (Slack mrkdwn) is supported: *bold*, _italic_, `code`."
                        ]
                    ],
                    "required": ["channel", "text"]
                ]
            ),
            ClaudeTool(
                name: "slack_list_channels",
                description: """
                List the Slack channels the connected account can see \
                (public, plus private ones it belongs to). Use when the user asks \
                'what slack channels are there' or before slack_send when they \
                have not specified a channel clearly.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Optional substring to filter channels."
                        ]
                    ]
                ]
            ),
            ClaudeTool(
                name: "slack_send_workday_log",
                description: """
                Post today's (or yesterday's) workday log summary to a Slack \
                channel. This is the #1 morning-routine B2B move: post the \
                narrative + top shipped items to the team so they know what \
                the user did yesterday. If no workday log exists yet, returns an \
                error and the user should run the log generator first.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel": [
                            "type": "string",
                            "description": "Target channel (name or ID)."
                        ],
                        "date": [
                            "type": "string",
                            "description": "'today', 'yesterday', or an explicit yyyy-MM-dd. Default 'today'."
                        ]
                    ],
                    "required": ["channel"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "slack_send":
            let channel = (input["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channel.isEmpty else { return "error: channel required" }
            guard !text.isEmpty else { return "error: text required" }
            do {
                let res = try await SlackClient.shared.sendMessage(to: channel, text: text)
                WakeLog.shared.log("slack: sent to \(channel) ts=\(res.ts ?? "?")")
                return "ok: posted to \(channel) (ts=\(res.ts ?? "?"))"
            } catch let e as SlackError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        case "slack_list_channels":
            let filter = (input["query"] as? String ?? "").lowercased()
            do {
                let channels = try await SlackClient.shared.channels()
                let filtered = filter.isEmpty
                    ? channels
                    : channels.filter { $0.name.lowercased().contains(filter) }
                if filtered.isEmpty {
                    return filter.isEmpty
                        ? "(no channels visible)"
                        : "(no channels matched '\(filter)')"
                }
                let lines = filtered.prefix(40).map { "- \($0.displayName)  (\($0.id))" }
                return lines.joined(separator: "\n")
            } catch let e as SlackError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        case "slack_send_workday_log":
            let channel = (input["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let dateRaw = ((input["date"] as? String) ?? "today").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channel.isEmpty else { return "error: channel required" }
            let dayKey: String = await MainActor.run {
                switch dateRaw {
                case "today", "":    return WorkdayLogScheduler.currentDayKey()
                case "yesterday":    return WorkdayLogScheduler.previousDayKey()
                default:             return dateRaw
                }
            }
            guard let log = WorkdayLogStore.load(dayKey: dayKey) else {
                return "error: no workday log saved for \(dayKey). Open the Workday Log tab and generate one first."
            }
            let body = renderWorkdayLogForSlack(log)
            do {
                let res = try await SlackClient.shared.sendMessage(to: channel, text: body)
                WakeLog.shared.log("slack: workday log \(dayKey) posted to \(channel) ts=\(res.ts ?? "?")")
                return "ok: posted workday log \(dayKey) to \(channel) (ts=\(res.ts ?? "?"))"
            } catch let e as SlackError {
                return "error: \(e.localizedDescription)"
            } catch {
                return "error: \(error)"
            }

        default:
            return "error: unknown slack tool '\(name)'"
        }
    }

    // Compact Slack-friendly rendering. Slack mrkdwn supports *bold* and _italic_
    // (NOT **) and bulleted list just uses • lines. Kept <=39 500 chars so it
    // stays under Slack's 40k text limit with headroom.
    static func renderWorkdayLogForSlack(_ log: WorkdayLog) -> String {
        var out: [String] = []
        out.append("*Workday log · \(log.dayKey)*")
        if !log.narrative.isEmpty {
            out.append(log.narrative)
        }
        if !log.completedTasks.isEmpty {
            out.append("\n*Shipped*")
            for t in log.completedTasks.prefix(10) {
                let proj = t.project.isEmpty ? "" : " _(\(t.project))_"
                out.append("• \(t.title)\(proj)")
            }
        }
        if !log.codeShipped.isEmpty {
            let totalCommits = log.codeShipped.reduce(0) { $0 + $1.commits.count }
            if totalCommits > 0 {
                out.append("\n*Code* · \(totalCommits) commits across \(log.codeShipped.count) projects")
            }
        }
        if log.totalProductiveMinutes > 0 {
            let h = log.totalProductiveMinutes / 60
            let m = log.totalProductiveMinutes % 60
            out.append("\n*Productive time* · \(h)h \(m)m")
        }
        if !log.tags.isEmpty {
            out.append("_tags: \(log.tags.prefix(8).joined(separator: ", "))_")
        }
        let joined = out.joined(separator: "\n")
        if joined.count > 39_500 {
            return String(joined.prefix(39_500)) + "\n…_(truncated)_"
        }
        return joined
    }
}
