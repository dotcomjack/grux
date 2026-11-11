import Foundation

/// D206, live 2026-11-09 1:25 AM on Grux Local 2B: "When is my dentist
/// appointment?" came back "I don't have access to your schedule or
/// appointments. You'll need to check your calendar" while Grux could read
/// the calendar. `list_events` lists one date range (today unless told), so a
/// small model had no way to find an appointment by its name and said it had
/// no access. A question that asks when the person's own appointment, meeting,
/// flight or the like is, is answered here by searching the names on the
/// calendar from now on, and the reply says what was searched. Anything else
/// (a day named, a second clause, no event word) goes to the model as before.
@MainActor
enum CalendarSearchAsk {

    struct Ask: Equatable {
        /// The thing asked about, as the person said it: "dentist appointment".
        let phrase: String
        /// The words an event's name must hold: "dentist". Empty when the
        /// phrase is only an event word ("my next meeting").
        let terms: [String]
        /// The event word: "appointment", "meeting", "flight".
        let noun: String
    }

    /// How far ahead the search reads.
    static let horizonDays = 365
    static let horizonWords = "the next 12 months"
    /// How many later matches follow the first.
    static let alsoListed = 2

    /// Words that name a calendar entry. "date", "test" and "birthday" are
    /// not here: they ask about other things as often.
    static let eventNouns: Set<String> = [
        "appointment", "appt", "meeting", "call", "flight", "reservation", "interview", "class", "lesson",
        "session", "checkup", "visit", "dinner", "lunch", "breakfast", "brunch", "party", "game", "event",
        "haircut", "exam", "practice", "rehearsal", "recital", "concert", "trip", "conference", "webinar",
        "standup", "presentation", "demo", "consultation", "surgery", "therapy", "cleaning",
    ]
    /// Event words that name any entry, so with nothing else said the next
    /// timed entry answers "when is my next meeting".
    private static let genericNouns: Set<String> = ["appointment", "appt", "meeting", "event"]
    /// Words in the phrase that name nothing to search for.
    private static let fillerWords: Set<String> = [
        "next", "upcoming", "the", "a", "an", "with", "at", "for", "of", "to", "my", "on", "in",
    ]

    private static let opener = try! NSRegularExpression(pattern:
        #"^(?:(?:when is|when's|whens|what time is|what day is|what date is) my|do i have (?:a|an|any)) (.+?)(?: coming up| scheduled| booked| soon)?$"#)

    /// The ask, or nil for anything else. Fails toward the model: a miss
    /// costs one model turn, a false match answers a question nobody asked.
    static func match(_ text: String) -> Ask? {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let last = s.last, "?.!".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(where: { ".!?;,\n".contains($0) }), !s.contains(" and ") else { return nil }
        for pattern in [#"^(?:(?:hey|ok|okay) )?grux:? "#, #" grux$"#, #" please$"#, #"^please "#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let ns = s as NSString
        guard let m = opener.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let phrase = ns.substring(with: m.range(at: 1))
        let words = phrase.split(separator: " ").map(String.init)
        guard (1...5).contains(words.count),
              words.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" } }),
              // A day named is CalendarAsk's or the model's.
              CalendarAsk.mentionedWindow(in: phrase) == nil,
              let noun = words.last(where: { eventNouns.contains(singular($0)) }).map(singular)
        else { return nil }
        let terms = words.filter { !fillerWords.contains($0) && singular($0) != noun }
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
        let shown = words.drop { $0 == "next" || $0 == "upcoming" }.joined(separator: " ")
        return Ask(phrase: shown, terms: terms, noun: noun)
    }

    private static func singular(_ w: String) -> String {
        w.count > 4 && w.hasSuffix("s") && eventNouns.contains(String(w.dropLast())) ? String(w.dropLast()) : w
    }

    /// Whether an event's name (or place) holds every word, each as a whole
    /// word or its plural or possessive: "sam" is in "Sam's lunch", never in
    /// "Samsung", and "call" is not in "Recall" (wave 72 round 1). Apostrophes
    /// go on both sides, so "o'brien" is in "Meeting with O'Brien".
    private static func named(_ ev: CalendarService.EventSummary, _ words: [String]) -> Bool {
        let text = folded((ev.title + " " + (ev.location ?? "")).lowercased())
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.map(folded).allSatisfy { w in
            tokens.contains { t in
                t == w || t == w + "s" || (takesEs(w) && t == w + "es")
                    || (t.count > 2 && (w == t + "s" || (takesEs(t) && w == t + "es")))
            }
        }
    }

    /// "es" makes a plural only after these ("classes", "lunches"), so "jones"
    /// is not "Jon" (wave 72 round 2).
    private static func takesEs(_ w: String) -> Bool {
        ["s", "x", "z", "ch", "sh"].contains { w.hasSuffix($0) }
    }

    private static func folded(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    }

    /// What the person reads, from the calendar alone. `events` is the seam
    /// CalendarAsk reads through; nil means Grux may not read the calendar.
    static func answer(_ ask: Ask, now: Date = Date(), calendar: Foundation.Calendar = .current,
                       locale: Locale = .current) -> String {
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: now),
              let all = CalendarAsk.events(now, end) else {
            return CalendarAsk.noAccessLine(CalendarAsk.access())
        }
        let upcoming = all.filter { $0.end > now }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let searched = "I searched the names on your calendar for \(horizonWords)"
        if !ask.terms.isEmpty {
            var found = upcoming.filter { named($0, ask.terms) }
            // "My call with Sam": a call with Sam before lunch with Sam.
            if !genericNouns.contains(ask.noun) {
                let both = found.filter { named($0, [ask.noun]) }
                if !both.isEmpty { found = both }
            }
            if !found.isEmpty { return listing(found, now: now, calendar: calendar, locale: locale) }
            let quoted = "\"\(ask.terms.joined(separator: " "))\""
            let byNoun = upcoming.filter { named($0, [ask.noun]) }
            if let next = byNoun.first {
                return "\(searched) and found nothing with \(quoted) in its name. The next \(ask.noun) on it: "
                    + line(next, now: now, calendar: calendar, locale: locale) + "."
            }
            return "\(searched) and found nothing with \(quoted) in its name. If it is there under another name, ask what is on that day."
        }
        let found = upcoming.filter { named($0, [ask.noun]) }
        if !found.isEmpty { return listing(found, now: now, calendar: calendar, locale: locale) }
        if genericNouns.contains(ask.noun), let next = upcoming.first(where: { !$0.isAllDay }) {
            return "Nothing on your calendar is named \"\(ask.noun)\". The next thing on it: "
                + line(next, now: now, calendar: calendar, locale: locale) + "."
        }
        return "\(searched) and found nothing with \"\(ask.noun)\" in its name. If it is there under another name, ask what is on that day."
    }

    private static func listing(_ found: [CalendarService.EventSummary], now: Date,
                                calendar: Foundation.Calendar, locale: Locale) -> String {
        let first = "From your calendar: " + line(found[0], now: now, calendar: calendar, locale: locale) + "."
        let later = found.dropFirst().prefix(alsoListed).map { line($0, now: now, calendar: calendar, locale: locale) }
        return later.isEmpty ? first : first + " After that: " + later.joined(separator: "; ") + "."
    }

    /// "Dentist, Thursday, Nov 12, 2:00 PM to 3:00 PM", "Dentist, now, until 3:00 PM".
    private static func line(_ ev: CalendarService.EventSummary, now: Date,
                             calendar: Foundation.Calendar, locale: Locale) -> String {
        let title = ev.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "An event with no title" : title
        if ev.start <= now {
            return ev.isAllDay ? "\(name), today, all day"
                : "\(name), now, until \(CalendarAsk.time(ev.end, calendar, locale))"
        }
        let day = calendar.isDate(ev.start, inSameDayAs: now) ? "today"
            : calendar.isDate(ev.start, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ? "tomorrow"
            : CalendarAsk.format(ev.start, otherYear(ev.start, now, calendar) ? "EEEE, MMM d, y" : "EEEE, MMM d", calendar, locale)
        if ev.isAllDay { return "\(name), \(day), all day" }
        let endTime = calendar.isDate(ev.end, inSameDayAs: ev.start) ? CalendarAsk.time(ev.end, calendar, locale)
            : CalendarAsk.format(ev.end, "EEE MMM d", calendar, locale) + " " + CalendarAsk.time(ev.end, calendar, locale)
        return "\(name), \(day), \(CalendarAsk.time(ev.start, calendar, locale)) to \(endTime)"
    }

    /// A date in another calendar year names its year.
    private static func otherYear(_ date: Date, _ now: Date, _ calendar: Foundation.Calendar) -> Bool {
        calendar.component(.year, from: date) != calendar.component(.year, from: now)
    }
}
