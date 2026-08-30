import Foundation

// Claude-tool adapter for the macOS Calendar (EventKit). Registered by
// ChatService.allTools() and dispatched by ChatService.dispatchTool().
// Thin switch that calls into CalendarService on the main actor.
//
// File access note (SECURITY.md): FilesystemTool is the general path from
// Claude to disk. import_ics / export_ics are a deliberately narrow carve-out
// scoped to a single file type: paths MUST end in .ics, imports are capped at
// 1 MB, and every touch is logged via WakeLog. No directory listing, no
// arbitrary reads.
enum CalendarTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "create_event",
                description: "Create an event in the user's macOS Calendar. Use when they say 'put X on my calendar', 'schedule a call Tuesday at 3', 'block an hour tomorrow'. Times are local to this Mac unless an offset is given. Returns the new event id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Event title, <120 chars."],
                        "start": ["type": "string", "description": "Start time, ISO 8601 ('2026-06-09T15:00:00' or with offset). Date-only ('2026-06-09') makes an all-day event."],
                        "end": ["type": "string", "description": "Optional end time, same format. Defaults to start + 1 hour (timed) or +1 day (all-day)."],
                        "location": ["type": "string", "description": "Optional location string."],
                        "notes": ["type": "string", "description": "Optional notes/description body."],
                        "calendar": ["type": "string", "description": "Optional calendar name or id. Defaults to their default calendar."]
                    ],
                    "required": ["title", "start"]
                ]
            ),
            ClaudeTool(
                name: "list_events",
                description: "List events from the user's macOS Calendar in a date range. Use for 'what's on my calendar today/this week', 'am I free Thursday afternoon', or to find an event id before editing/deleting. Defaults to today when no range given.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Range start, ISO 8601 or date-only. Default: start of today."],
                        "end": ["type": "string", "description": "Range end, ISO 8601 or date-only. Default: start + 1 day."],
                        "calendar": ["type": "string", "description": "Optional calendar name or id to filter to. Default: all calendars."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "import_ics",
                description: "Import a .ics file (iCalendar) into the user's macOS Calendar. Use when they download an invite or a calendar export and say 'add this to my calendar'. Path must end in .ics; max 1 MB.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path (or ~/...) to the .ics file."],
                        "calendar": ["type": "string", "description": "Optional destination calendar name or id. Defaults to their default calendar."]
                    ],
                    "required": ["path"]
                ]
            ),
            ClaudeTool(
                name: "export_ics",
                description: "Export a date range of the user's calendar events to a .ics file. Use for 'export my calendar', 'send my week to X as an ics'. Defaults to the next 30 days into ~/Downloads.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Range start, ISO 8601 or date-only. Default: start of today."],
                        "end": ["type": "string", "description": "Range end. Default: start + 30 days."],
                        "calendar": ["type": "string", "description": "Optional calendar name or id to filter to. Default: all calendars."],
                        "path": ["type": "string", "description": "Optional output path ending in .ics. Default: ~/Downloads/grux-calendar-<date>.ics."]
                    ]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = [
        "create_event", "list_events", "import_ics", "export_ics"
    ]

    static let maxICSImportBytes = 1_048_576

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "create_event":
            let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return "error: title is required" }
            guard let startRaw = input["start"] as? String,
                  let parsedStart = parseDateInput(startRaw) else {
                return "error: start must be ISO 8601 (e.g. 2026-06-09T15:00:00) or date-only (2026-06-09)"
            }
            let isAllDay = parsedStart.isDateOnly
            let end: Date = {
                if let endRaw = input["end"] as? String, let parsedEnd = parseDateInput(endRaw) {
                    return parsedEnd.date
                }
                return parsedStart.date.addingTimeInterval(isAllDay ? 86400 : 3600)
            }()
            let location = input["location"] as? String
            let notes = input["notes"] as? String
            let calendarHint = input["calendar"] as? String
            return await MainActor.run { () -> String in
                guard CalendarService.shared.hasAccess else { return noAccessMessage }
                do {
                    let summary = try CalendarService.shared.createEvent(
                        title: title,
                        start: parsedStart.date,
                        end: end,
                        isAllDay: isAllDay,
                        location: location,
                        notes: notes,
                        calendarHint: calendarHint
                    )
                    return "ok: created '\(summary.title)' \(formatRange(summary)) in calendar '\(summary.calendarName)' id=\(summary.id)"
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }

        case "list_events":
            let window = resolveWindow(
                startRaw: input["start"] as? String,
                endRaw: input["end"] as? String,
                defaultSpanDays: 1
            )
            let calendarHint = input["calendar"] as? String
            return await MainActor.run { () -> String in
                guard CalendarService.shared.hasAccess else { return noAccessMessage }
                let events = CalendarService.shared.events(from: window.start, to: window.end, calendarHint: calendarHint)
                if events.isEmpty {
                    return "(no events between \(formatDate(window.start)) and \(formatDate(window.end)))"
                }
                let rows = events.map { ev -> String in
                    var bits = ["- id=\(ev.id) · \(formatRange(ev)) · \(ev.title)"]
                    if let location = ev.location { bits.append("  @ \(location)") }
                    bits.append("  [\(ev.calendarName)]")
                    return bits.joined(separator: "\n")
                }
                return "events (\(events.count)):\n" + rows.joined(separator: "\n")
            }

        case "import_ics":
            guard let rawPath = input["path"] as? String, !rawPath.isEmpty else {
                return "error: path is required"
            }
            let path = (rawPath as NSString).expandingTildeInPath
            guard path.lowercased().hasSuffix(".ics") else {
                return "error: only .ics files can be imported"
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return "error: no file at \(path)"
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
               size > maxICSImportBytes {
                return "error: file exceeds the 1 MB import cap"
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return "error: couldn't read file as UTF-8"
            }
            let parsed = ICSImportExport.parse(text)
            guard !parsed.isEmpty else {
                return "error: no VEVENT blocks found in \(path)"
            }
            let calendarHint = input["calendar"] as? String
            return await MainActor.run { () -> String in
                guard CalendarService.shared.hasAccess else { return noAccessMessage }
                do {
                    let created = try CalendarService.shared.importICSEvents(parsed, calendarHint: calendarHint)
                    WakeLog.shared.log("calendarTool: imported \(created.count) event(s) from \(path)")
                    let preview = created.prefix(5).map { "- \($0.title) \(formatRange($0))" }.joined(separator: "\n")
                    let more = created.count > 5 ? "\n…and \(created.count - 5) more" : ""
                    return "ok: imported \(created.count) event(s)\n\(preview)\(more)"
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }

        case "export_ics":
            let window = resolveWindow(
                startRaw: input["start"] as? String,
                endRaw: input["end"] as? String,
                defaultSpanDays: 30
            )
            let calendarHint = input["calendar"] as? String
            let outPath: String = {
                if let p = input["path"] as? String, !p.isEmpty {
                    return (p as NSString).expandingTildeInPath
                }
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                let downloads = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first
                    ?? NSHomeDirectory() + "/Downloads"
                return downloads + "/grux-calendar-\(df.string(from: Date())).ics"
            }()
            guard outPath.lowercased().hasSuffix(".ics") else {
                return "error: output path must end in .ics"
            }
            return await MainActor.run { () -> String in
                guard CalendarService.shared.hasAccess else { return noAccessMessage }
                let icsEvents = CalendarService.shared.exportICSEvents(from: window.start, to: window.end, calendarHint: calendarHint)
                if icsEvents.isEmpty {
                    return "(no events between \(formatDate(window.start)) and \(formatDate(window.end)), nothing exported)"
                }
                let serialized = ICSImportExport.serialize(icsEvents)
                do {
                    try serialized.write(toFile: outPath, atomically: true, encoding: .utf8)
                } catch {
                    return "error: couldn't write \(outPath): \(error.localizedDescription)"
                }
                WakeLog.shared.log("calendarTool: exported \(icsEvents.count) event(s) to \(outPath)")
                return "ok: exported \(icsEvents.count) event(s) to \(outPath)"
            }

        default:
            return "error: unknown calendar tool '\(name)'"
        }
    }

    private static let noAccessMessage =
        "error: calendar access not granted. The user can enable it in System Settings > Privacy & Security > Calendars, or open the Calendar tab in Grux to trigger the prompt."

    // MARK: - Date input parsing

    struct ParsedInput {
        let date: Date
        let isDateOnly: Bool
    }

    // Accepts: full ISO 8601 with offset, ISO without offset (local to this Mac),
    // 'yyyy-MM-dd HH:mm', and date-only 'yyyy-MM-dd' (flagged all-day).
    static func parseDateInput(_ raw: String) -> ParsedInput? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return ParsedInput(date: d, isDateOnly: false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return ParsedInput(date: d, isDateOnly: false) }

        let tz = TimeZone.current
        for (format, dateOnly) in [
            ("yyyy-MM-dd'T'HH:mm:ss", false),
            ("yyyy-MM-dd'T'HH:mm", false),
            ("yyyy-MM-dd HH:mm:ss", false),
            ("yyyy-MM-dd HH:mm", false),
            ("yyyy-MM-dd", true)
        ] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz
            df.dateFormat = format
            if let d = df.date(from: s) { return ParsedInput(date: d, isDateOnly: dateOnly) }
        }
        return nil
    }

    private static func resolveWindow(startRaw: String?, endRaw: String?, defaultSpanDays: Int) -> (start: Date, end: Date) {
        let tz = TimeZone.current
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let start = startRaw.flatMap { parseDateInput($0)?.date } ?? calendar.startOfDay(for: Date())
        let end = endRaw.flatMap { parseDateInput($0)?.date } ?? start.addingTimeInterval(TimeInterval(defaultSpanDays) * 86400)
        return (start, max(end, start.addingTimeInterval(60)))
    }

    // MARK: - Formatting

    private static func formatRange(_ ev: CalendarService.EventSummary) -> String {
        if ev.isAllDay {
            return "\(formatDay(ev.start)) (all day)"
        }
        let sameDay = Foundation.Calendar.current.isDate(ev.start, inSameDayAs: ev.end)
        if sameDay {
            return "\(formatDay(ev.start)) \(formatTime(ev.start))-\(formatTime(ev.end))"
        }
        return "\(formatDate(ev.start)) → \(formatDate(ev.end))"
    }

    private static func formatDay(_ d: Date) -> String {
        localFormatter(format: "EEE MMM d").string(from: d)
    }

    private static func formatTime(_ d: Date) -> String {
        localFormatter(format: "h:mm a").string(from: d)
    }

    private static func formatDate(_ d: Date) -> String {
        localFormatter(format: "MMM d h:mm a").string(from: d)
    }

    private static func localFormatter(format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = format
        df.timeZone = .current
        return df
    }
}
