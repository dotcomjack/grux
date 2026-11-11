import Foundation

/// "How many days until Christmas?" (D195), counted on the Mac's own calendar.
/// Sense pass 27 (6:43 AM Sunday Nov 8) asked Grux Local 2B exactly that and
/// it answered "There are 41 days left until Christmas."; it was 47. The Mac
/// knows today's date, so a count of days is never left to a model's guess.
///
/// The grammar is closed like the math and time asks': the whole message must
/// be one "how many days until X" form, and X a named day this file knows or a
/// month and day (with an optional year). A weekday ("Friday", D181's lesson),
/// a bare "the 25th", a numeric date ("12/25", read either way round), a
/// season, Easter and anything personal ("my birthday") go to the model, so a
/// miss costs a model answer, never a wrong count.
enum DayCountAsk {
    private static let asks = #"(?:how many (?:more )?days (?:are )?(?:(?:is it|are there|left|remain|remaining) )?|how long (?:is it )?|days (?:left )?)"#
    private static let until = #"(?:until|till|til|'til|to|before)"#

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]
    private static let shortMonths: [String: Int] = {
        var out: [String: Int] = [:]
        for (i, m) in months.enumerated() { out[m] = i + 1; out[String(m.prefix(3))] = i + 1 }
        out["sept"] = 9
        return out
    }()

    /// A named day: its name as the reply leads, and its date in a given year.
    private struct Named { let name: String; let date: (Int, Calendar) -> DateComponents? }

    private static func fixed(_ name: String, _ month: Int, _ day: Int) -> Named {
        Named(name: name) { y, _ in DateComponents(year: y, month: month, day: day) }
    }

    /// Thanksgiving, the fourth Thursday of November, counted only where that
    /// is the day (the US); Canada keeps the second Monday of October, and
    /// other places none, so those ask the model.
    private static let thanksgiving = Named(name: "Thanksgiving") { y, cal in
        guard let first = cal.date(from: DateComponents(year: y, month: 11, day: 1)) else { return nil }
        let weekday = cal.component(.weekday, from: first)  // 1 is Sunday, 5 is Thursday
        let firstThursday = 1 + (5 - weekday + 7) % 7
        return DateComponents(year: y, month: 11, day: firstThursday + 21)
    }

    /// Many countries keep an Independence Day of their own; this name is the
    /// Fourth of July only where the region is US (wave 67 round 1).
    private static let usIndependenceDay = "independence day"

    private static let named: [String: Named] = {
        var out: [String: Named] = [:]
        let christmas = fixed("Christmas", 12, 25)
        for w in ["christmas", "christmas day", "xmas"] { out[w] = christmas }
        out["christmas eve"] = fixed("Christmas Eve", 12, 24)
        let newYear = fixed("New Year's Day", 1, 1)
        for w in ["new year's", "new years", "new year's day", "new years day", "new year", "the new year"] { out[w] = newYear }
        for w in ["new year's eve", "new years eve"] { out[w] = fixed("New Year's Eve", 12, 31) }
        for w in ["valentine's day", "valentines day", "valentine's", "valentines"] {
            out[w] = fixed("Valentine's Day", 2, 14)
        }
        out["halloween"] = fixed("Halloween", 10, 31)
        for w in ["the fourth of july", "fourth of july", "july 4th", "july fourth", "the 4th of july", "4th of july",
                  usIndependenceDay] {
            out[w] = fixed("The Fourth of July", 7, 4)
        }
        for w in ["st. patrick's day", "st patrick's day", "st patricks day", "st. patricks day", "saint patrick's day"] {
            out[w] = fixed("St. Patrick's Day", 3, 17)
        }
        out["thanksgiving"] = thanksgiving
        return out
    }()

    /// `calendar` gives only the time zone: the days asked about are Gregorian
    /// ones, so they are counted on a Gregorian calendar whatever the Mac's own
    /// calendar is (wave 67 round 1: a Mac on the Islamic calendar counted
    /// Christmas to "Dhu'l-Hijjah 25").
    static func reply(for text: String, now: Date = Date(), calendar mac: Calendar = .current,
                      region: String? = Locale.current.region?.identifier) -> String? {
        // Today's date is read in the Mac's time zone; every count after that is
        // between calendar dates, on a calendar with no clock changes (wave 67
        // round 2: where the clock jumps at midnight, that day starts at 1:00 AM
        // and a count from it to a midnight lost a day).
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
        guard let re = try? NSRegularExpression(pattern: "^\(asks)\(until) (.+)$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let target = String(s[r])
        guard let today = calendar.date(from: local.dateComponents([.year, .month, .day], from: now)) else { return nil }
        let year = calendar.component(.year, from: today)

        if let day = named[target] {
            if day.name == "Thanksgiving" || target == usIndependenceDay, region != "US" { return nil }
            guard let next = nextOccurrence(from: today, year: year, calendar: calendar, day.date) else { return nil }
            return line(day.name, next, today: today, calendar: calendar, showDate: true)
        }
        guard let said = monthDay(target) else { return nil }
        if let y = said.year {
            guard let date = valid(DateComponents(year: y, month: said.month, day: said.day), calendar) else { return nil }
            return line(label(said.month, said.day, year: y), date, today: today, calendar: calendar, showDate: false)
        }
        guard let next = nextOccurrence(from: today, year: year, calendar: calendar, { y, _ in
            DateComponents(year: y, month: said.month, day: said.day)
        }) else { return nil }
        let y = calendar.component(.year, from: next)
        return line(label(said.month, said.day, year: y == year ? nil : y), next, today: today, calendar: calendar,
                    showDate: false)
    }

    // MARK: - Dates

    /// "december 25", "dec 25th", "the 3rd of march", "march 3, 2028".
    private static func monthDay(_ s: String) -> (month: Int, day: Int, year: Int?)? {
        let ordinal = #"(\d{1,2})(?:st|nd|rd|th)?"#
        let year = #"(?:,? (\d{4}))?"#
        if let m = groups(#"^([a-z]+)\.? \#(ordinal)\#(year)$"#, s), let month = shortMonths[m[1]], let d = Int(m[2]) {
            return (month, d, m[3].isEmpty ? nil : Int(m[3]))
        }
        if let m = groups(#"^(?:the )?\#(ordinal) of ([a-z]+)\#(year)$"#, s), let month = shortMonths[m[2]], let d = Int(m[1]) {
            return (month, d, m[3].isEmpty ? nil : Int(m[3]))
        }
        return nil
    }

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    /// The date only when the calendar keeps every part as said, so February
    /// 30 or a February 29 outside a leap year is no date at all.
    private static func valid(_ c: DateComponents, _ cal: Calendar) -> Date? {
        guard let date = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == c.year && back.month == c.month && back.day == c.day ? date : nil
    }

    /// Today or the first one after it, looking as far as the next leap year.
    private static func nextOccurrence(from today: Date, year: Int, calendar: Calendar,
                                       _ date: (Int, Calendar) -> DateComponents?) -> Date? {
        for y in year...(year + 8) {
            if let c = date(y, calendar), let d = valid(c, calendar), d >= today { return d }
        }
        return nil
    }

    // MARK: - The reply

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func label(_ month: Int, _ day: Int, year: Int?) -> String {
        let name = months[month - 1].capitalized
        return year.map { "\(name) \(day), \($0)" } ?? "\(name) \(day)"
    }

    private static func line(_ name: String, _ date: Date, today: Date, calendar: Calendar, showDate: Bool) -> String {
        let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        let f = DateFormatter()
        f.locale = posix
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        let weekday = f.string(from: date)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        f.dateFormat = sameYear ? "EEEE, MMMM d" : "EEEE, MMMM d, yyyy"
        let when = showDate ? f.string(from: date) : weekday
        switch days {
        case 0: return "\(name) is today."
        case 1: return "\(name) is tomorrow, \(when)."
        case 2...: return "\(name) is in \(days) days, on \(when)."
        case -1: return "\(name) was yesterday."
        default: return "\(name) was \(-days) days ago."
        }
    }
}
