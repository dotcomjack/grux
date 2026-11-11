import Foundation

/// "What date is next Friday?" (D202), read from the Mac's own calendar.
/// Sense pass 29 (12:46 AM Monday Nov 9) asked Grux Local 2B exactly that and
/// it answered "It's November 15, 2026. Next Friday is Monday, November 14.";
/// the coming Friday was November 13. The Mac knows today's date, so which
/// date a weekday or "in 10 days" falls on is never left to a model's guess.
///
/// The grammar is closed like the day count's: the whole message must be one
/// "what date is X" form ("what day is", "when is", "what's the date"), and X
/// today, tomorrow, yesterday, a weekday ("friday", "this friday", "next
/// friday", "last friday", "the friday after next"), a count of days or weeks
/// ahead, or anything `DayCountAsk` knows (Christmas, December 25). "Next
/// Friday" means the coming one to some people and the one a week later to
/// others, so the reply names both. "Friday next week" (which depends on the
/// day a week starts), times, places and anything personal go to the model.
enum DateAsk {
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let numberWords: [String: Int] = [
        "a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10,
    ]
    /// The furthest count answered, about ten years.
    static let maxDaysAhead = 3650

    private static let asks = #"^(?:what(?:'s| is|s) the date(?: (?:of|on))?|what (?:date|day)(?:'s| is| was| will it be)|which day is|when(?:'s| is| was))(?: (.+))?$"#

    static func reply(for text: String, afterImage: Bool = false, now: Date = Date(), calendar mac: Calendar = .current,
                      region: String? = Locale.current.region?.identifier) -> String? {
        // As in the day count: today is read in the Mac's time zone, and every
        // step after that is between calendar dates on a calendar with no
        // clock changes.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = mac.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"[?.!\s]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:(?:hey|hi|ok|okay) )?(?:grux,? )?"#, with: "", options: .regularExpression)
        guard !s.isEmpty,
              let today = calendar.date(from: local.dateComponents([.year, .month, .day], from: now)) else { return nil }

        if s.range(of: #"^(?:what(?:'s| is|s) )?today'?s date(?: (?:again|now|right now|currently|at the moment))?$"#,
                   options: .regularExpression) != nil {
            return todayLine(today, calendar)
        }
        guard let m = groups(asks, s) else { return nil }
        var target = m[1]
        // "What's the date now?", "What day is it right now?", "What's the
        // date again?": the likeliest ways to ask, and none of them names a
        // day (wave 71 round 4 P3). Only the "now" words pin today after a
        // photo; "again" repeats the bare ask.
        if target == "again" { target = "" }
        if target.hasSuffix(" again") { target = String(target.dropLast(6)) }
        var saidNow = false
        for word in ["now", "right now", "currently", "at the moment"] where target == word || target == "it \(word)" {
            target = target.hasPrefix("it ") ? "it" : ""
            saidNow = true
        }
        // "What day was Friday?" asks about a day gone; the grammar reads only
        // the ones it can place behind today (wave 71 round 1 P2).
        let past = s.range(of: #"^(?:what (?:date|day) was|when was)( |$)"#, options: .regularExpression) != nil
        // Only "what day is it" or "which day is it" means today: "When is it?" after "There's a
        // game this week." asks about the game (wave 71 round 1 P2).
        // "What's the date on it?" asks about a receipt or an event, not today
        // (wave 71 round 3 P2).
        let ofSomething = s.range(of: #"the date (?:of|on)( |$)"#, options: .regularExpression) != nil
        let asksWhat = !s.hasPrefix("when") && !ofSomething
        if target.isEmpty || target == "it" {
            // A bare "What's the date?" right after a receipt photo asks the
            // date on the receipt (wave 71 round 4 P3).
            return asksWhat && !past && (saidNow || !afterImage) ? todayLine(today, calendar) : nil
        }
        if target.hasPrefix("it ") {
            guard asksWhat else { return nil }
            target = String(target.dropFirst(3))
        }

        if let line = relative(target, past: past, today: today, calendar: calendar) { return line }
        if let line = weekday(target, past: past, today: today, calendar: calendar) { return line }
        guard !past else { return nil }
        if let line = ahead(target, today: today, calendar: calendar) { return line }
        // The day count looks ahead and names no weekday for a date gone
        // ("July 4, 1990 was 13277 days ago."), so a date gone is the model's.
        guard let line = DayCountAsk.reply(for: "how many days until \(target)", now: now, calendar: mac, region: region),
              !line.contains(" was ") else { return nil }
        return line
    }

    /// Whether the person's turn before this one (the last message in the
    /// chat) carried a photo, so a bare "What's the date?" asks about it.
    static func followsImage(_ chat: [ChatMessage]) -> Bool {
        chat.dropLast().last(where: { $0.role == .user && !$0.isNotice })?.imageData != nil
    }

    // MARK: - Targets

    private static func relative(_ t: String, past: Bool, today: Date, calendar: Calendar) -> String? {
        let words: [String: (Int, String)] = [
            "today": (0, "Today is"), "tomorrow": (1, "Tomorrow is"), "yesterday": (-1, "Yesterday was"),
            "the day after tomorrow": (2, "The day after tomorrow is"),
            "the day before yesterday": (-2, "The day before yesterday was"),
        ]
        guard let (offset, lead) = words[t], !past || offset < 0 else { return nil }
        if offset == 0 { return todayLine(today, calendar) }
        guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
        return "\(lead) \(fullDate(date, today: today, calendar: calendar))."
    }

    private static func weekday(_ t: String, past: Bool, today: Date, calendar: Calendar) -> String? {
        let names = weekdays.joined(separator: "|")
        if !past, let m = groups("^the (\(names)) after next$", t), let w = weekdays.firstIndex(of: m[1]),
           let first = next(w, after: today, calendar: calendar),
           let date = calendar.date(byAdding: .day, value: 7, to: first) {
            return "The \(m[1].capitalized) after next is \(upcoming(date, today: today, calendar: calendar))."
        }
        guard let m = groups("^(?:(this|next|last|this coming|the coming|coming) )?(\(names))$", t),
              let w = weekdays.firstIndex(of: m[2]), !past || m[1] == "last" else { return nil }
        let name = m[2].capitalized
        switch m[1] {
        case "next":
            guard let first = next(w, after: today, calendar: calendar),
                  let second = calendar.date(byAdding: .day, value: 7, to: first) else { return nil }
            return "Next \(name) is \(upcoming(first, today: today, calendar: calendar)). "
                + "If you mean the \(name) after that, it is \(monthDay(second, today: today, calendar: calendar))."
        case "last":
            guard let before = calendar.date(byAdding: .day, value: -8, to: today),
                  let date = next(w, after: before, calendar: calendar) else { return nil }
            let days = calendar.dateComponents([.day], from: date, to: today).day ?? 0
            let when = days == 1 ? "yesterday" : "\(days) days ago"
            return "Last \(name) was \(monthDay(date, today: today, calendar: calendar)), \(when)."
        default:
            // "This coming Monday" asked on a Monday is next week's (wave 71 P3).
            if !m[1].contains("coming"), calendar.component(.weekday, from: today) == w + 1 {
                return todayLine(today, calendar)
            }
            guard let date = next(w, after: today, calendar: calendar) else { return nil }
            return "\(name) is \(upcoming(date, today: today, calendar: calendar))."
        }
    }

    /// "in 10 days", "2 weeks from now", "a week from today".
    private static func ahead(_ t: String, today: Date, calendar: Calendar) -> String? {
        let n = #"(\d{1,5}|a|one|two|three|four|five|six|seven|eight|nine|ten)"#
        let unit = #"(days?|weeks?)"#
        guard let m = groups("^in \(n) \(unit)$", t) ?? groups("^\(n) \(unit) from (?:now|today)$", t),
              let count = Int(m[1]) ?? numberWords[m[1]] else { return nil }
        let weeks = m[2].hasPrefix("week")
        let days = weeks ? count * 7 : count
        guard (1...maxDaysAhead).contains(days),
              let date = calendar.date(byAdding: .day, value: days, to: today) else { return nil }
        let said = "\(count) \(weeks ? "week" : "day")\(count == 1 ? "" : "s")"
        return "In \(said) it will be \(fullDate(date, today: today, calendar: calendar))."
    }

    /// The first given weekday (0 is Sunday) strictly after a date.
    private static func next(_ weekday: Int, after date: Date, calendar: Calendar) -> Date? {
        let from = calendar.component(.weekday, from: date) - 1
        let step = (weekday - from + 7) % 7
        return calendar.date(byAdding: .day, value: step == 0 ? 7 : step, to: date)
    }

    // MARK: - The reply

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func sameYear(_ a: Date, _ b: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: a) == calendar.component(.year, from: b)
    }

    private static func todayLine(_ today: Date, _ calendar: Calendar) -> String {
        "Today is \(format(today, "EEEE, MMMM d, yyyy", calendar))."
    }

    /// "Tuesday, November 10", with the year when it is not this one.
    private static func fullDate(_ date: Date, today: Date, calendar: Calendar) -> String {
        format(date, sameYear(date, today, calendar) ? "EEEE, MMMM d" : "EEEE, MMMM d, yyyy", calendar)
    }

    /// "November 13", with the year when it is not this one.
    private static func monthDay(_ date: Date, today: Date, calendar: Calendar) -> String {
        format(date, sameYear(date, today, calendar) ? "MMMM d" : "MMMM d, yyyy", calendar)
    }

    /// "November 13, in 4 days" or "November 10, tomorrow".
    private static func upcoming(_ date: Date, today: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        return "\(monthDay(date, today: today, calendar: calendar)), " + (days == 1 ? "tomorrow" : "in \(days) days")
    }

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}
