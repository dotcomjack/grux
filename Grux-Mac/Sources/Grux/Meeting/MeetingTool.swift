import Foundation

// Claude-tool adapter for the meeting capture subsystem. Registered by
// ChatService.allTools() and dispatched by ChatService.dispatchTool().
// Keeps parity with Grux's other tool adapters (ShellTool, IOSTool): thin
// switch → call into MeetingCaptureService / MeetingStore.
enum MeetingTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "start_meeting_capture",
                description: "Start capturing system audio + mic for a meeting (Zoom / Meet / FaceTime / Teams / Webex). Transcribed on-device via WhisperKit, mono-summed both sides, stored locally, summarized with action items when the meeting ends. Ambient listening pauses for the duration. Call BEFORE the meeting starts or right at the top - we can't backfill audio that already happened. The first time ever, this asks the user to confirm they will tell the other people on the call that it is being recorded; if they decline, nothing is recorded.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Optional title for the meeting. If omitted, we'll auto-name from the source app (e.g. 'Meeting · Zoom')."
                        ]
                    ]
                ]
            ),
            ClaudeTool(
                name: "stop_meeting_capture",
                description: "End the active meeting capture. Flushes the last audio chunk, runs an LLM summary + action-item extraction, resumes ambient listening. Returns the duration, utterance count, and final summary.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            ClaudeTool(
                name: "list_meetings",
                description: "List recent captured meetings (most recent first). Returns id, title, startedAt, duration, utterance count, and a short summary excerpt per row. Use when the user asks 'what meetings did I have this week', 'find my call with X', 'show me last Friday's meetings'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Max number of rows to return. Default 10, max 50."
                        ],
                        "since": [
                            "type": "string",
                            "description": "Optional ISO date (YYYY-MM-DD) - only include meetings that started on or after this date."
                        ]
                    ]
                ]
            ),
            ClaudeTool(
                name: "get_meeting_transcript",
                description: "Fetch the full transcript of a captured meeting by id. Returns the timestamped, speaker-labeled utterance list plus any stored summary and action items. Use when the user asks to pull up a specific meeting.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": [
                            "type": "string",
                            "description": "The meeting's UUID from list_meetings."
                        ]
                    ],
                    "required": ["meeting_id"]
                ]
            ),
            ClaudeTool(
                name: "summarize_meeting",
                description: "(Re-)generate an LLM summary + action items for a stored meeting. Use when an existing meeting's summary is stale or was never generated (e.g. capture ended without network access). Writes the new summary back to the record.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": [
                            "type": "string",
                            "description": "The meeting's UUID."
                        ]
                    ],
                    "required": ["meeting_id"]
                ]
            ),
            ClaudeTool(
                name: "search_meetings",
                description: "Full-text search across captured meeting titles, summaries, and utterance text. Returns the same shape as list_meetings. Use when the user asks 'find the meeting where we talked about X'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Plain-text search query."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max rows to return. Default 10, max 50."
                        ]
                    ],
                    "required": ["query"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "start_meeting_capture":
            let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rec = await MeetingCaptureService.shared.start(title: title?.isEmpty == false ? title : nil)
            if let rec {
                return "ok: meeting_capture_started id=\(rec.id.uuidString) title=\(rec.displayTitle)"
            }
            let err = await MeetingCaptureService.shared.lastError ?? "unknown error"
            // A declined consent prompt is not a failure, it is the user answering. Returned
            // as `ok:` so the model reports it plainly instead of retrying or apologising
            // for a bug that did not happen. Same shape as the capture-privacy refusal.
            if err.hasPrefix("Recording needs your confirmation") {
                return """
                    ok: not recording. They were asked to confirm they will tell the other \
                    people on the call, and they declined or dismissed it. \
                    Do not retry. Just say recording did not start.
                    """
            }
            return "error: could not start meeting capture - \(err)"

        case "stop_meeting_capture":
            await MeetingCaptureService.shared.stop()
            guard let rec = await MeetingCaptureService.shared.activeMeeting else {
                return "error: no active meeting"
            }
            let mins = Int(rec.durationSeconds / 60)
            let secs = Int(rec.durationSeconds) % 60
            let summaryLine: String = {
                if let s = rec.summary, !s.isEmpty { return "\nsummary: \(s)" }
                return ""
            }()
            let actionsLine: String = {
                guard !rec.actionItems.isEmpty else { return "" }
                return "\naction_items:\n" + rec.actionItems.map { "- \($0)" }.joined(separator: "\n")
            }()
            return """
            ok: meeting_capture_stopped id=\(rec.id.uuidString) duration=\(mins)m\(secs)s utterances=\(rec.utterances.count)\(summaryLine)\(actionsLine)
            """

        case "list_meetings":
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 10))
            let since: Date? = {
                guard let s = input["since"] as? String, !s.isEmpty else { return nil }
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
                return f.date(from: s)
            }()
            let entries = await MainActor.run {
                MeetingStore.shared.list(limit: limit, since: since)
            }
            return formatEntries(entries)

        case "search_meetings":
            let query = (input["query"] as? String) ?? ""
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 10))
            let entries = await MainActor.run {
                MeetingStore.shared.search(query: query, limit: limit)
            }
            return formatEntries(entries)

        case "get_meeting_transcript":
            guard let idStr = input["meeting_id"] as? String, let id = UUID(uuidString: idStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            guard let rec = await MainActor.run(body: { MeetingStore.shared.loadRecord(id: id) }) else {
                return "error: meeting not found"
            }
            return formatRecord(rec)

        case "summarize_meeting":
            guard let idStr = input["meeting_id"] as? String, let id = UUID(uuidString: idStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            guard var rec = await MainActor.run(body: { MeetingStore.shared.loadRecord(id: id) }) else {
                return "error: meeting not found"
            }
            guard let summary = await MeetingSummarizer.summarize(rec) else {
                return "error: summarization failed (missing key or LLM error)"
            }
            rec.summary = summary.tldr
            rec.actionItems = summary.actionItems
            await MainActor.run { MeetingStore.shared.finalize(rec) }
            let actionsLine = rec.actionItems.isEmpty ? "" : "\naction_items:\n" + rec.actionItems.map { "- \($0)" }.joined(separator: "\n")
            return "ok: resummarized\nsummary: \(summary.tldr)\(actionsLine)"

        default:
            return "error: unknown meeting tool '\(name)'"
        }
    }

    private static func formatEntries(_ entries: [MeetingIndexEntry]) -> String {
        guard !entries.isEmpty else { return "(no meetings)" }
        let df = DateFormatter()
        df.dateFormat = "MMM d h:mm a"
        df.timeZone = TimeZone.current
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

    private static func formatRecord(_ rec: MeetingRecord) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = TimeZone.current
        var out: [String] = []
        out.append("id: \(rec.id.uuidString)")
        out.append("title: \(rec.displayTitle)")
        out.append("started_at: \(df.string(from: rec.startedAt))")
        if let ended = rec.endedAt { out.append("ended_at: \(df.string(from: ended))") }
        out.append("duration_sec: \(Int(rec.durationSeconds))")
        if let s = rec.sourceAppName { out.append("source_app: \(s)") }
        if let s = rec.summary, !s.isEmpty { out.append("summary: \(s)") }
        if !rec.actionItems.isEmpty {
            out.append("action_items:")
            for a in rec.actionItems { out.append("- \(a)") }
        }
        out.append("utterances (\(rec.utterances.count)):")
        out.append(rec.flatText())
        return out.joined(separator: "\n")
    }
}
