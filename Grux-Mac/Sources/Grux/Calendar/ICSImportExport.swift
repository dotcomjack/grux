import Foundation

// Pure-Swift iCalendar (.ics, RFC 5545) VEVENT parser + serializer.
// Zero dependencies, no EventKit import, fully unit-testable (ICSTests.swift).
//
// Scope (deliberate): SUMMARY / DTSTART / DTEND / LOCATION / DESCRIPTION /
// UID / RRULE on VEVENT blocks. That covers the real-world cases Grux needs
// (Google Calendar exports, Outlook invites, Calendly attachments). VTODO,
// VALARM, VTIMEZONE definitions, and exotic RRULE refinements are skipped,
// not errored on, so a messy feed still imports its events.
//
// Parsing rules honored from the RFC:
//   - Line unfolding: CRLF (or bare LF) followed by SPACE or HTAB continues
//     the previous line.
//   - Text escaping: \\n and \\N -> newline, \\, -> comma, \\; -> semicolon,
//     \\\\ -> backslash.
//   - DTSTART/DTEND forms: UTC (...Z), floating local, TZID=... param, and
//     VALUE=DATE all-day dates.
enum ICSImportExport {

    // MARK: - Value type

    struct ICSEvent: Codable, Equatable, Hashable, Sendable {
        var uid: String
        var summary: String
        var start: Date
        var end: Date?
        var isAllDay: Bool
        var location: String?
        var description: String?
        var rrule: String?

        init(
            uid: String = UUID().uuidString,
            summary: String,
            start: Date,
            end: Date? = nil,
            isAllDay: Bool = false,
            location: String? = nil,
            description: String? = nil,
            rrule: String? = nil
        ) {
            self.uid = uid
            self.summary = summary
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.location = location
            self.description = description
            self.rrule = rrule
        }

        // DTEND is optional in the wild. Default: all-day events span one day,
        // timed events span one hour.
        var effectiveEnd: Date {
            if let end = end, end > start { return end }
            return start.addingTimeInterval(isAllDay ? 86400 : 3600)
        }
    }

    // MARK: - Parse

    static func parse(_ text: String) -> [ICSEvent] {
        let lines = unfoldLines(text)
        var events: [ICSEvent] = []

        var inEvent = false
        var props: [(name: String, params: [String: String], value: String)] = []

        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" {
                inEvent = true
                props = []
                continue
            }
            if upper == "END:VEVENT" {
                if inEvent, let event = buildEvent(from: props) {
                    events.append(event)
                }
                inEvent = false
                continue
            }
            guard inEvent else { continue }
            if let prop = parseContentLine(line) {
                props.append(prop)
            }
        }
        return events
    }

    // MARK: - Serialize

    static func serialize(_ events: [ICSEvent], calendarName: String = "Grux") -> String {
        var out: [String] = []
        out.append("BEGIN:VCALENDAR")
        out.append("VERSION:2.0")
        out.append("PRODID:-//Grux//Grux Calendar//EN")
        out.append("CALSCALE:GREGORIAN")
        out.append(fold("X-WR-CALNAME:" + escapeText(calendarName)))

        let stampString = utcDateTimeString(from: Date())
        for event in events {
            out.append("BEGIN:VEVENT")
            out.append(fold("UID:" + (event.uid.isEmpty ? UUID().uuidString : event.uid)))
            out.append("DTSTAMP:" + stampString)
            if event.isAllDay {
                out.append("DTSTART;VALUE=DATE:" + dateOnlyString(from: event.start))
                out.append("DTEND;VALUE=DATE:" + dateOnlyString(from: event.effectiveEnd))
            } else {
                out.append("DTSTART:" + utcDateTimeString(from: event.start))
                out.append("DTEND:" + utcDateTimeString(from: event.effectiveEnd))
            }
            out.append(fold("SUMMARY:" + escapeText(event.summary)))
            if let location = event.location, !location.isEmpty {
                out.append(fold("LOCATION:" + escapeText(location)))
            }
            if let description = event.description, !description.isEmpty {
                out.append(fold("DESCRIPTION:" + escapeText(description)))
            }
            if let rrule = event.rrule, !rrule.isEmpty {
                out.append(fold("RRULE:" + rrule))
            }
            out.append("END:VEVENT")
        }
        out.append("END:VCALENDAR")
        return out.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Content line plumbing

    // Unfold per RFC 5545 3.1: a CRLF immediately followed by SPACE or HTAB
    // is a continuation. Tolerates bare LF and bare CR line endings too.
    static func unfoldLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var unfolded: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                unfolded.append(line)
            }
        }
        return unfolded
    }

    // "DTSTART;TZID=America/Chicago:20260609T140000" ->
    //   (name: "DTSTART", params: ["TZID": "America/Chicago"], value: "20260609T140000")
    // Honors quoted parameter values so a colon inside quotes doesn't split.
    static func parseContentLine(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var nameAndParams = ""
        var value = ""
        var inQuotes = false
        var foundColon = false
        for ch in line {
            if foundColon {
                value.append(ch)
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ":" && !inQuotes {
                foundColon = true
                continue
            }
            nameAndParams.append(ch)
        }
        guard foundColon, !nameAndParams.isEmpty else { return nil }

        var params: [String: String] = [:]
        let segments = splitRespectingQuotes(nameAndParams, separator: ";")
        guard let first = segments.first else { return nil }
        let name = first.uppercased()
        for segment in segments.dropFirst() {
            let kv = segment.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).uppercased()
            var val = String(kv[1])
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return (name, params, value)
    }

    private static func splitRespectingQuotes(_ s: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle() }
            if ch == separator && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func buildEvent(
        from props: [(name: String, params: [String: String], value: String)]
    ) -> ICSEvent? {
        var uid = ""
        var summary = ""
        var location: String?
        var description: String?
        var rrule: String?
        var start: Date?
        var end: Date?
        var isAllDay = false

        for prop in props {
            switch prop.name {
            case "UID":
                uid = prop.value
            case "SUMMARY":
                summary = unescapeText(prop.value)
            case "LOCATION":
                let s = unescapeText(prop.value)
                location = s.isEmpty ? nil : s
            case "DESCRIPTION":
                let s = unescapeText(prop.value)
                description = s.isEmpty ? nil : s
            case "RRULE":
                rrule = prop.value.isEmpty ? nil : prop.value
            case "DTSTART":
                if let parsed = parseICSDate(prop.value, tzid: prop.params["TZID"], valueParam: prop.params["VALUE"]) {
                    start = parsed.date
                    isAllDay = parsed.isDateOnly
                }
            case "DTEND":
                if let parsed = parseICSDate(prop.value, tzid: prop.params["TZID"], valueParam: prop.params["VALUE"]) {
                    end = parsed.date
                }
            default:
                break
            }
        }

        guard let startDate = start else { return nil }
        return ICSEvent(
            uid: uid.isEmpty ? UUID().uuidString : uid,
            summary: summary.isEmpty ? "(untitled event)" : summary,
            start: startDate,
            end: end,
            isAllDay: isAllDay,
            location: location,
            description: description,
            rrule: rrule
        )
    }

    // MARK: - Date handling

    struct ParsedDate: Equatable {
        let date: Date
        let isDateOnly: Bool
    }

    // Accepts: 20260609T140000Z (UTC) | 20260609T140000 (floating, TZID or
    // local) | 20260609 (date-only / all-day).
    static func parseICSDate(_ raw: String, tzid: String?, valueParam: String? = nil) -> ParsedDate? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let isDateOnly = (valueParam?.uppercased() == "DATE") || (value.count == 8 && !value.contains("T"))

        if isDateOnly {
            guard let date = dateFromComponents(value, time: nil, timeZone: zone(for: tzid) ?? .current) else { return nil }
            return ParsedDate(date: date, isDateOnly: true)
        }

        let isUTC = value.hasSuffix("Z") || value.hasSuffix("z")
        let trimmed = isUTC ? String(value.dropLast()) : value
        let pieces = trimmed.split(separator: "T", maxSplits: 1)
        guard pieces.count == 2 else { return nil }
        let tz: TimeZone = isUTC ? TimeZone(identifier: "UTC")! : (zone(for: tzid) ?? .current)
        guard let date = dateFromComponents(String(pieces[0]), time: String(pieces[1]), timeZone: tz) else { return nil }
        return ParsedDate(date: date, isDateOnly: false)
    }

    private static func zone(for tzid: String?) -> TimeZone? {
        guard let tzid = tzid, !tzid.isEmpty else { return nil }
        return TimeZone(identifier: tzid)
    }

    private static func dateFromComponents(_ yyyymmdd: String, time hhmmss: String?, timeZone: TimeZone) -> Date? {
        guard yyyymmdd.count == 8,
              let year = Int(yyyymmdd.prefix(4)),
              let month = Int(yyyymmdd.dropFirst(4).prefix(2)),
              let day = Int(yyyymmdd.dropFirst(6).prefix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        if let t = hhmmss {
            guard t.count >= 4 else { return nil }
            components.hour = Int(t.prefix(2))
            components.minute = Int(t.dropFirst(2).prefix(2))
            components.second = t.count >= 6 ? Int(t.dropFirst(4).prefix(2)) : 0
        } else {
            components.hour = 0
            components.minute = 0
            components.second = 0
        }
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    static func utcDateTimeString(from date: Date) -> String {
        formatter(format: "yyyyMMdd'T'HHmmss'Z'", utc: true).string(from: date)
    }

    static func dateOnlyString(from date: Date) -> String {
        formatter(format: "yyyyMMdd", utc: false).string(from: date)
    }

    private static func formatter(format: String, utc: Bool) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = format
        df.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        return df
    }

    // MARK: - Text escaping (RFC 5545 3.3.11)

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescapeText(_ s: String) -> String {
        var result = ""
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else {
                result.append(ch)
                continue
            }
            guard let next = iterator.next() else {
                result.append(ch)
                break
            }
            switch next {
            case "n", "N": result.append("\n")
            case ",": result.append(",")
            case ";": result.append(";")
            case "\\": result.append("\\")
            default:
                result.append(ch)
                result.append(next)
            }
        }
        return result
    }

    // MARK: - Line folding (RFC 5545 3.1: max 75 octets per line)

    // Folds on character boundaries at a conservative 73-character width so
    // multi-byte UTF-8 stays under the 75-octet ceiling in typical content.
    static func fold(_ line: String, width: Int = 73) -> String {
        guard line.count > width else { return line }
        var pieces: [String] = []
        var remaining = Substring(line)
        var first = true
        while !remaining.isEmpty {
            let take = first ? width : width - 1
            let chunk = remaining.prefix(take)
            pieces.append(first ? String(chunk) : " " + String(chunk))
            remaining = remaining.dropFirst(take)
            first = false
        }
        return pieces.joined(separator: "\r\n")
    }
}
