import EventKit
import Foundation

/// D136, live 2026-11-02 2:03 PM on qwen3.5:4b: "What is on my calendar
/// tomorrow?" came back "You've got a grocery run in the AM and a lunch with
/// Sarah at 1pm Friday." with no tool call, although `list_events` was offered;
/// the model answered from old lines in its memories, and the calendar held
/// Election Day. A question about what is on the person's calendar is answered
/// from the calendar, read here before any model sees the turn, the way D86's
/// upgrade-yourself ask takes the tool's own path. Only a plain listing
/// question matches; anything else ("am I free", "put lunch on my calendar",
/// the question inside a longer message) goes to the model as before.
@MainActor
enum CalendarAsk {

    /// The days a question asks about: `start` inclusive, `end` exclusive.
    struct Window: Equatable {
        let start: Date
        let end: Date
        /// How the reply names it: "today", "tomorrow", "on Thursday", "this week".
        let label: String
        /// More than one day, so each event names its day.
        var spansDays: Bool { end.timeIntervalSince(start) > 86_400 + 3_600 }
    }

    /// What the calendar holds in a window, or nil when Grux may not read it.
    /// A seam for tests: the live one reads Calendar through `CalendarService`.
    static var events: @MainActor (Date, Date) -> [CalendarService.EventSummary]? = { start, end in
        guard CalendarService.shared.hasAccess else { return nil }
        return CalendarService.shared.events(from: start, to: end)
    }

    /// What macOS allows Grux for Calendar, for the no-access line.
    static var access: @MainActor () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }

    /// Why Grux cannot read the calendar, in words that say what to do. Add-only
    /// access and a Mac whose manager restricts Calendar are not "turned off",
    /// and the second cannot be turned on (W41-P3 item 4).
    static func noAccessLine(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .writeOnly:
            return "I cannot read your calendar: Grux may add events to it but not read them. "
                + "To let Grux read it, set Grux AI to Full Access in System Settings, Privacy & Security, Calendars."
        case .restricted:
            return "I cannot read your calendar: whoever manages this Mac does not allow apps to read Calendar."
        case .denied:
            return "I cannot read your calendar: macOS has Calendar turned off for Grux, and it will not ask again. Turn on Grux AI in System Settings, Privacy & Security, Calendars."
        default:
            return "I cannot read your calendar yet: Grux needs your OK for Calendar. Open the Calendar tab to allow it, then ask again."
        }
    }

    // MARK: - The match

    /// The question's openers. One that names the calendar may stand alone
    /// (today); one that does not needs a day after it, so "what do I have"
    /// alone stays with the model.
    private static let namingOpeners = [
        "what's on my calendar", "what is on my calendar", "whats on my calendar",
        "what's on my schedule", "what is on my schedule", "whats on my schedule",
        "what's on my agenda", "what is on my agenda", "whats on my agenda",
        "what's on the calendar", "what is on the calendar",
        "what's in my calendar", "what is in my calendar",
        "anything on my calendar", "is there anything on my calendar",
        "do i have anything on my calendar", "what do i have on my calendar",
        "what's my schedule", "what is my schedule", "whats my schedule",
        "what's my agenda", "what is my agenda",
        "what meetings do i have", "what events do i have",
        "do i have any meetings", "do i have any events",
        "what are my meetings", "what are my events",
        "show me my calendar", "show my calendar", "check my calendar", "read me my calendar",
    ]
    private static let dayOpeners = [
        "what do i have", "what have i got", "do i have anything",
    ]
    /// W41-P3 item 5: "is there anything going on tonight" asks about the
    /// world as often as the calendar, so these need a calendar word too.
    private static let impersonalOpeners = ["is there anything", "anything"]
    // Not "what's happening today" or "what's going on": those ask for news as often.
    /// Words that may sit between the opener and the day.
    private static let fillers = ["on my calendar", "in my calendar", "on my schedule", "scheduled",
                                  "planned", "going on", "coming up", "on", "for"]
    /// The fillers that name the person's own calendar.
    private static let calendarFillers: Set<String> = ["on my calendar", "in my calendar", "on my schedule",
                                                       "scheduled", "planned"]

    /// The window a plain "what is on my calendar" question asks about, or nil
    /// for anything else. Fails toward the model: a miss costs one model turn,
    /// a false match answers a question nobody asked.
    static func window(for text: String, now: Date = Date(),
                       calendar: Foundation.Calendar = .current) -> Window? {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let last = s.last, "?.!".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        // One question: a second sentence or a clause after it goes to the model.
        guard !s.isEmpty, !s.contains(where: { ".!?;\n".contains($0) }), !s.contains(" and ") else { return nil }
        for pattern in [#"^(?:(?:hey|ok|okay) ?,? )?grux ?[,:]? ?"#, #" ?, ?grux$| grux$"#,
                        #" ?, ?please$| please$"#, #"^please ?,? "#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))

        func rest(after openers: [String]) -> String? {
            for opener in openers.sorted(by: { $0.count > $1.count }) where s == opener || s.hasPrefix(opener + " ") {
                return String(s.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        var named: Bool
        let impersonal: Bool
        var remainder: String
        if let r = rest(after: namingOpeners) {
            named = true; impersonal = false; remainder = r
        } else if let r = rest(after: dayOpeners) {
            named = false; impersonal = false; remainder = r
        } else if let r = rest(after: impersonalOpeners) {
            named = false; impersonal = true; remainder = r
        } else {
            return nil
        }
        var stripped = true
        while stripped {
            stripped = false
            for filler in fillers.sorted(by: { $0.count > $1.count })
            where remainder == filler || remainder.hasPrefix(filler + " ") {
                remainder = String(remainder.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
                if calendarFillers.contains(filler) { named = true }
                stripped = true
                break
            }
        }
        if impersonal && !named { return nil }
        if remainder.isEmpty { return named ? day(0, label: "today", now: now, calendar: calendar) : nil }
        return dayPhrase(remainder, now: now, calendar: calendar)
    }

    /// The day phrases `mentionedWindow` looks for, longest first so
    /// "tomorrow evening" wins over "tomorrow".
    private static let dayPhrases: [String] = {
        var p = ["today", "tonight", "this morning", "this afternoon", "this evening",
                 "tomorrow", "tomorrow morning", "tomorrow afternoon", "tomorrow evening",
                 "this week", "the rest of the week", "the rest of this week", "next week",
                 "this weekend", "the weekend"]
        for d in weekdays { p += [d, "on " + d, "this " + d] }
        return p.sorted { $0.count > $1.count }
    }()

    /// The first day a free-form message names ("anything going on tonight",
    /// "what about Friday"), or nil when it names none. D140 reads the
    /// calendar for this day when a reply claims it is empty.
    static func mentionedWindow(in text: String, now: Date = Date(),
                                calendar: Foundation.Calendar = .current) -> Window? {
        let s = text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var best: (at: String.Index, phrase: String)?
        for phrase in dayPhrases {
            guard let r = s.range(of: "\\b" + phrase + "\\b", options: .regularExpression) else { continue }
            // Longest first, so an equal start keeps the longer phrase.
            if best == nil || r.lowerBound < best!.at { best = (r.lowerBound, phrase) }
        }
        guard let best else { return nil }
        return dayPhrase(best.phrase, now: now, calendar: calendar)
    }

    private static func day(_ offset: Int, label: String, now: Date, calendar: Foundation.Calendar) -> Window? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: offset, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return Window(start: start, end: end, label: label)
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func dayPhrase(_ p: String, now: Date, calendar: Foundation.Calendar) -> Window? {
        let today = calendar.startOfDay(for: now)
        switch p {
        case "today", "tonight", "this morning", "this afternoon", "this evening":
            return day(0, label: "today", now: now, calendar: calendar)
        case "tomorrow", "tomorrow morning", "tomorrow afternoon", "tomorrow evening":
            return day(1, label: "tomorrow", now: now, calendar: calendar)
        case "this week", "the rest of the week", "the rest of this week":
            // From today to the start of next week, as this Mac counts weeks.
            guard let next = calendar.dateInterval(of: .weekOfYear, for: now)?.end else { return nil }
            return Window(start: today, end: next, label: "this week")
        case "next week":
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let end = calendar.date(byAdding: .day, value: 7, to: thisWeek.end) else { return nil }
            return Window(start: thisWeek.end, end: end, label: "next week")
        case "this weekend", "the weekend":
            // The coming Saturday and Sunday; today when it is one of them.
            let wd = calendar.component(.weekday, from: today)   // 1 Sunday ... 7 Saturday
            let toSaturday = wd == 1 ? -1 : 7 - wd
            guard let saturday = calendar.date(byAdding: .day, value: toSaturday, to: today),
                  let end = calendar.date(byAdding: .day, value: 2, to: saturday) else { return nil }
            return Window(start: max(saturday, today), end: end, label: "this weekend")
        default:
            break
        }
        // "monday", "on monday", "this monday": the next one after today;
        // "this monday" asked on a Monday is today (W41-P3 item 1).
        var name = p
        for prefix in ["on ", "this ", "next "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        guard p.hasPrefix("next ") == false, let index = weekdays.firstIndex(of: name) else { return nil }
        let wd = calendar.component(.weekday, from: today) - 1
        let ahead = (index - wd + 7) % 7
        if ahead == 0 && p.hasPrefix("this ") { return day(0, label: "today", now: now, calendar: calendar) }
        let offset = ahead == 0 ? 7 : ahead
        return day(offset, label: "on " + name.capitalized, now: now, calendar: calendar)
    }

    // MARK: - The reply

    /// More than this many events end with how many more Calendar holds.
    static let listed = 10

    /// What the person reads: every event in the window, in plain words, or
    /// that there is none. Built from the calendar alone, so nothing in it can
    /// be made up.
    static func reply(events: [CalendarService.EventSummary]?, window: Window, now: Date = Date(),
                      calendar: Foundation.Calendar = .current, locale: Locale = .current) -> String {
        guard let events else {
            return noAccessLine(access())
        }
        let when = heading(window, calendar: calendar, locale: locale)
        guard !events.isEmpty else { return "Nothing on your calendar \(when)." }
        let sorted = events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let lines = sorted.prefix(listed).map { line($0, window: window, calendar: calendar, locale: locale) }
        let more = sorted.count > listed ? " And \(sorted.count - listed) more, in Calendar." : ""
        let count = events.count == 1 ? "one thing" : "\(events.count) things"
        return "On your calendar \(when), \(count): " + lines.joined(separator: "; ") + "." + more
    }

    /// "tomorrow (Tuesday, Nov 3)", "this week (Nov 2 to Nov 8)".
    static func heading(_ window: Window, calendar: Foundation.Calendar, locale: Locale) -> String {
        if window.spansDays {
            let last = window.end.addingTimeInterval(-1)
            return "\(window.label) (\(format(window.start, "MMM d", calendar, locale)) to \(format(last, "MMM d", calendar, locale)))"
        }
        let date = format(window.start, "EEEE, MMM d", calendar, locale)
        return window.label.hasPrefix("on ") ? "on \(date)" : "\(window.label) (\(date))"
    }

    private static func line(_ ev: CalendarService.EventSummary, window: Window,
                             calendar: Foundation.Calendar, locale: Locale) -> String {
        let title = ev.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "An event with no title" : title
        // The day the line is about: inside the window, never before it.
        let lineDay = ev.start < window.start ? window.start : ev.start
        let dayPart = window.spansDays ? format(lineDay, "EEE MMM d", calendar, locale) + " " : ""
        if ev.isAllDay {
            // W41-P3 item 3: over several days, the days it covers in the window.
            let lastDay = min(ev.end, window.end).addingTimeInterval(-1)
            guard window.spansDays, !calendar.isDate(lastDay, inSameDayAs: lineDay) else {
                return "\(name), \(dayPart)all day"
            }
            return "\(name), all day \(format(lineDay, "EEE MMM d", calendar, locale)) to \(format(lastDay, "EEE MMM d", calendar, locale))"
        }
        let startTime = time(ev.start, calendar, locale)
        let endTime = time(ev.end, calendar, locale)
        // The end names its day only when it is not the day the line is about;
        // an end at that day's own midnight is "midnight" (W41-P3 item 6).
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lineDay))
        let endPart = ev.end == midnight ? "midnight"
            : calendar.isDate(ev.end, inSameDayAs: lineDay)
            ? endTime : format(ev.end, "EEE MMM d", calendar, locale) + " " + endTime
        let starts = ev.start < window.start
            ? "until \(endPart)"
            : "\(dayPart)\(startTime) to \(endPart)"
        return "\(name), \(starts)"
    }

    static func format(_ date: Date, _ template: String, _ calendar: Foundation.Calendar, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// "1:00 PM", or "13:00" where this Mac uses a 24-hour clock.
    static func time(_ date: Date, _ calendar: Foundation.Calendar, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
