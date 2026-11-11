import Foundation

/// D140, live 2026-11-02 5:11 PM on qwen3.5:4b: "Is there anything going on
/// tonight?" came back "Nothing scheduled for tonight. Want me to block an hour
/// now for back-up work?" with no tool call, although `list_events` was
/// offered. CalendarAsk leaves that ask to the model (it is about the world as
/// often), and the model answered for the person's calendar without reading
/// it. True by luck that day; with a 7 PM dinner it says the evening is free.
/// A local reply that says what the calendar holds (empty, or naming an
/// entry), on a turn whose calendar read did not succeed, is replaced by what the calendar holds for the day asked
/// about, read here. The whole reply goes, as ActionClaimGuard's does, because
/// what follows a made-up free evening (an offer to fill it) rests on it.
@MainActor
enum CalendarClaimGuard {

    private static let time =
        "(?:today|tonight|tomorrow(?:\\s+(?:morning|afternoon|evening|night))?|this\\s+(?:morning|afternoon|evening|week|weekend)|the\\s+weekend|next\\s+week|(?:on\\s+|this\\s+)?(?:mon|tues|wednes|thurs|fri|satur|sun)day)"
    private static let calendarNoun = "(?:calendar|schedule|agenda|diary)"
    private static let dayNoun = "(?:day|evening|night|morning|afternoon|weekend|week)"
    private static let adverb = "(?:(?:totally|completely|pretty|all|entirely|wide)\\s+)?"
    private static let apostrophe = "['\u{2019}]"

    /// Ways a reply says the person's calendar holds nothing. Each needs a
    /// calendar word, a day, or "you're free", so "Nothing is waiting in
    /// Approvals" and "Your task stack is clear" are not claims.
    private static let patterns: [NSRegularExpression] = [
        // "Your calendar is clear", "your evening looks free", "the day's wide open"
        // ("the day is clear of urgent emails" is about mail)
        "\\b(?:your|the)\\s+(?:\(calendarNoun)|\(dayNoun))(?:\(apostrophe)s|\\s+is|\\s+looks|\\s+seems|\\s+appears)(?:\\s+to\\s+be)?(?:\\s+like)?\\s+\(adverb)(?:clear|empty|free|open|blank)\\b(?!\\s+of\\b)",
        // "a clear calendar"
        "\\b(?:clear|empty|free|open|blank)\\s+\(calendarNoun)\\b",
        // "You're free tonight", not "you're free to ask", "if you're free"
        "(?<!\\b(?:if|when|whether|once|until|unless)\\s)\\byou(?:\(apostrophe)re|\\s+are)\\s+\(adverb)(?:free|clear|open)\\b(?!\\s+to\\b)",
        // "You have no meetings", "you've got nothing planned"
        "\\byou(?:\(apostrophe)ve\\s+got|\\s+have\\s+got|\\s+have|\\s+got)\\s+(?:no\\s+(?:other\\s+)?(?:events?|meetings?|appointments?|plans)\\b|nothing\\s+(?:else\\s+)?(?:scheduled|planned|booked|on\\b|going\\s+on|\(time)))",
        // "Nothing scheduled", "nothing's planned for tomorrow", not "nothing scheduled to run"
        "\\bnothing(?:\\s+else)?(?:\(apostrophe)s|\\s+is)?\\s+(?:scheduled|planned|booked)\\b(?!\\s+to\\b)",
        // "Nothing on your calendar", "no events on your schedule"
        "\\b(?:nothing|no\\s+(?:events?|meetings?|appointments?))\\s+(?:\\w+\\s+)?(?:on|in)\\s+(?:your|the)\\s+\(calendarNoun)\\b",
        // "No meetings today", "no plans for tonight"
        "\\bno\\s+(?:events?|meetings?|appointments?|plans)\\s+(?:\\w+\\s+){0,2}?(?:(?:for|on)\\s+)?\(time)\\b",
        // "Nothing going on tonight", "nothing on tomorrow"
        "\\bnothing(?:\\s+else)?\\s+(?:going\\s+on|happening|coming\\s+up|on)\\s+(?:for\\s+)?\(time)\\b",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// A sentence that names the calendar as holding something ("Election Day
    /// is on your calendar", live 8:44 PM: a copy of an earlier turn's words
    /// about today, given for tomorrow) states it too, unless it offers,
    /// asks or points somewhere ("I'll block an hour on your calendar").
    private static let statesCalendar = try! NSRegularExpression(
        pattern: "(?i)\\b(?:on|in)\\s+(?:your|the)\\s+calendar\\b")
    private static let offerOrPointer = try! NSRegularExpression(
        pattern: "(?i)\\b(?:put|add|block|schedule|move|create|book|want|shall|should|can|cannot|can\(apostrophe)t|could|will|would|i\(apostrophe)ll|let\\s+me|check|look|open|connect|allow|read|turn|show|see|help|manage|keep|ask|tell)\\b")

    /// True when a sentence of the reply, not a question, says what the
    /// person's calendar holds: that it is empty, or that something is on it.
    static func claimsCalendar(_ reply: String) -> Bool {
        let ns = reply as NSString
        let sentence = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)
        for m in sentence.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if s.trimmingCharacters(in: .whitespaces).hasSuffix("?") { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            if patterns.contains(where: { $0.firstMatch(in: s, range: range) != nil }) { return true }
            if statesCalendar.firstMatch(in: s, range: range) != nil,
               offerOrPointer.firstMatch(in: s, range: range) == nil { return true }
        }
        return false
    }

    /// D206, live 2026-11-09 1:25 AM on Grux Local 2B: "When is my dentist
    /// appointment?" got "I don't have access to your schedule or appointments"
    /// while Grux could read the calendar. A local reply that says Grux cannot
    /// see the person's calendar is replaced by the calendar's own answer, or,
    /// when macOS does not allow the read, by why and what to do.
    /// Wave 72 round 1: Grux says it ("I can't", not "If you can't"), about the
    /// calendar as a whole ("your work calendar" may truly not be added).
    private static let denial = try! NSRegularExpression(pattern:
        "(?i)\\bI(?:\\s+(?:don\(apostrophe)?t|do\\s+not|can\(apostrophe)?t|cannot|can\\s+not|have\\s+no|lack)"
        + "|\(apostrophe)m\\s+(?:unable|not\\s+able)\\s+to|\\s+am\\s+(?:unable|not\\s+able)\\s+to)\\s+"
        + "(?:have\\s+)?(?:any\\s+)?(?:access\\s+to|access|see|read|view|check|look\\s+at)\\s+"
        + "(?:your|the\\s+user\(apostrophe)s)\\s+(?:(?:personal|own|full|whole|upcoming|current)\\s+)?"
        + "(?:calendars?|schedules?|appointments?|events|agenda|meetings)\\b")

    /// Wave 72 rounds 1 to 4: a denial is replaced only in answer to a
    /// question plainly about the person's own calendar ("When is my flight?",
    /// "Am I busy tomorrow?", "What's on tomorrow?", "Is my Friday free?"); the
    /// calendar's answer is then what they asked for. Any other ask keeps the
    /// model's words as written: "What should I do this weekend?" or "Can you
    /// plan my day?" answered after a denial loses the answer if replaced, and
    /// rewriting the model's sentences lost it too (round 4).
    private static let questionStart: Set<String> = [
        "when", "what", "what's", "whats", "which", "where", "who", "how", "do", "does", "did", "am", "is", "are",
        "have", "has", "any", "anything", "can", "could", "will", "would",
    ]
    /// Asks for something made, for advice or help with something, or why: a
    /// plan, a reminder, ideas for the weekend, the best day for a meeting
    /// (round 5), help with my plans (round 6). "Plan" counts as
    /// the verb ("Can you plan my day?"), not the noun ("What's the plan for my day?").
    private static let makes = try! NSRegularExpression(pattern:
        "(?i)(?:\\b(?:make|create|build|write|draft|design|organi[sz]e|remind|set\\s+up|come\\s+up\\s+with|why"
        + "|should\\s+(?:i|we)|how\\s+should|best|good\\s+(?:day|time|idea)|ideas?|suggest\\w*|recommend\\w*|tips?"
        + "|advice|advise|help\\s+(?:me\\s+)?with)\\b"
        + "|(?:^|\\b(?:you|me|to|please|i|we)\\s+)plan\\b)")
    private static let ownTime = try! NSRegularExpression(pattern:
        "(?i)(?:\\bmy\\s+(?:\\w+\\s+)?(?:calendars?|schedule|agenda|appointments?|meetings?|events?|day|week|evening"
        + "|morning|afternoon|weekend|night|(?:mon|tues|wednes|thurs|fri|satur|sun)day)\\b"
        // A bare "my plans" (round 6: "my study plan" is a document).
        + "|\\bmy\\s+plans?\\b"
        + "|^(?:when|what\\s+time|what\\s+day)\\b.*\\bmy\\b|^when\\s+(?:do|am|will)\\s+i\\b"
        + "|\\bam\\s+i\\s+(?:busy|free|seeing|meeting|booked|available|doing\\s+anything|supposed\\s+to\\s+be)\\b"
        + "|\\bwhat\\s+am\\s+i\\s+doing\\b|\\bhow\\s+busy\\b|\\bbusy\\s+am\\s+i\\b"
        + "|\\bany\\s+(?:meetings?|events?|appointments?|plans)\\b"
        + "|^(?:do\\s+i\\s+have|have\\s+i\\s+got|what\\s+do\\s+i\\s+have|is\\s+there\\s+anything|anything|what(?:'s|s|\\s+is)\\s+on)\\b)")
    private static let leadIn = try! NSRegularExpression(pattern: "(?i)^(?:(?:hey|hi|ok|okay)\\s+)?grux\\s*[,:]?\\s+")

    static func asksAboutTheirCalendar(_ ask: String) -> Bool {
        var text = ask.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        text = leadIn.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                               withTemplate: "")
        let first = text.lowercased().split { !$0.isLetter && $0 != "'" }.first.map(String.init) ?? ""
        guard text.hasSuffix("?") || questionStart.contains(first) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard makes.firstMatch(in: text, range: range) == nil else { return false }
        return CalendarSearchAsk.match(text) != nil || ownTime.firstMatch(in: text, range: range) != nil
    }

    /// True when the reply says Grux cannot see the person's calendar.
    static func deniesCalendar(_ reply: String) -> Bool {
        denial.firstMatch(in: reply, range: NSRange(location: 0, length: (reply as NSString).length)) != nil
    }

    /// Only an apology or "unfortunately" may come before the denial in its
    /// sentence: "While I don't have access to your calendar, Tuesday works
    /// best" and "Try walking at lunch, but I can't see your schedule" carry
    /// the answer in front (rounds 7 and 9).
    private static let bareLead = try! NSRegularExpression(pattern:
        "(?i)^(?:(?:(?:i\(apostrophe)m\\s+|i\\s+am\\s+)?sorry|i\\s+apologi[sz]e|unfortunately|well|hmm|oh(?:\\s+no)?"
        + "|as\\s+an\\s+ai(?:\\s+assistant)?|as\\s+a\\s+language\\s+model|but)[\\s,!.\u{2014}\u{2013}-]*)*$")
    /// Round 10: the rest of the denial's sentence says nothing more ("or
    /// appointments", "right now", "from here", "sorry"), or it opens a clause
    /// that is only a pointer; "I can't see your schedule; try a walk at
    /// lunch" carries the answer after it.
    private static let bareTail = try! NSRegularExpression(pattern:
        "(?i)^(?:\\s+(?:events|appointments|entries|app|data))?"
        + "(?:,?\\s+(?:or|and)\\s+(?:your\\s+)?(?:calendars?|schedules?|appointments?|events|agenda|meetings|plans))*"
        + "(?:\\s+(?:right\\s+now|at\\s+the\\s+moment|from\\s+here|directly|yet|on\\s+this\\s+device))?")
    private static let bareEnd = try! NSRegularExpression(pattern: "(?i)^(?:,?\\s+sorry)?[\\s.!]*$")
    /// The clause right after the denial ("..., but here are some ideas").
    private static let afterClause = try! NSRegularExpression(pattern:
        "(?is)^[\\s,]*(?:but|however|though|although|yet|so|and)\\b[\\s,]*(.*)$")
    /// A sentence or clause that only sends the person to look for themselves,
    /// apologizes, or offers more: no answer in it. Round 8: a pointer names
    /// where to look (their calendar, app, email or confirmation) or whom to
    /// ask (them, the office, their dentist), joined only by "or" and "and", so
    /// "You might want to look for 15 minute gaps" is advice, not a pointer.
    private static let pointer: NSRegularExpression = {
        let ask = "(?:you(?:\(apostrophe)ll|\\s+will)?\\s+(?:need|have|want|may\\s+want|might\\s+want)\\s+to\\s+"
            + "|you\\s+(?:can|could|may|might|should)\\s+|please\\s+"
            + "|i(?:\(apostrophe)d|\\s+would)?\\s+(?:recommend|suggest)\\s+(?:that\\s+)?(?:you\\s+)?|try\\s+)?"
        let source = "(?:check(?:ing)?|look(?:ing)?\\s+(?:at|in)|open(?:ing)?)\\s+(?:your|the)\\s+(?:\\w+\\s+)?"
            + "(?:calendar|schedule|agenda|app|email|inbox|confirmation)s?"
        let person = "(?:call(?:ing)?|contact(?:ing)?|messag(?:e|ing)|ask(?:ing)?|reach(?:ing)?\\s+out\\s+to)\\s+"
            + "(?:them|(?:the|your)\\s+(?:\\w+(?:\(apostrophe)s)?\\s+)?(?:dentist|doctor|office|clinic|provider|organizer))"
        let tail = "(?:\\s+(?:directly|instead|to\\s+confirm|for\\s+(?:details|that|the\\s+details|the\\s+time)))?"
        let piece = ask + "(?:" + source + "|" + person + ")" + tail
        let pattern = "(?i)^(?:" + piece + "(?:,?\\s+(?:or|and)\\s+" + piece + ")*"
            + "|(?:i\(apostrophe)m\\s+|i\\s+am\\s+)?sorry|i\\s+apologi[sz]e|unfortunately"
            + "|i\\s+understand(?:\\s+(?:that\\s+)?you(?:\(apostrophe)d|\\s+would)?\\s+(?:want|like)\\s+to\\s+know\\b[^,;:]*)?"
            + "|let\\s+me\\s+know\\b[^,;:]*|is\\s+there\\s+anything\\s+else\\b[^,;:]*)[.!?]*$"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Wave 72 round 7: whether the reply is only a denial, with at most an
    /// apology or a pointer to look for themselves. A reply that answers
    /// something after or around its denial (advice, a plan, a time read from
    /// a photo) is never replaced, whatever was asked; misjudged, it stays as
    /// the model wrote it, as before this guard.
    static func isBareDenial(_ reply: String) -> Bool {
        let ns = reply as NSString
        let sentence = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#)
        var denied = false
        for m in sentence.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            let sns = s as NSString
            let all = NSRange(location: 0, length: sns.length)
            if let d = denial.firstMatch(in: s, range: all) {
                denied = true
                let before = sns.substring(to: d.range.location).trimmingCharacters(in: .whitespaces)
                if bareLead.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil {
                    return false
                }
                var after = sns.substring(from: d.range.location + d.range.length)
                if let t = bareTail.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
                    after = (after as NSString).substring(from: t.range.length)
                }
                let ans = after as NSString
                let whole = NSRange(location: 0, length: ans.length)
                if bareEnd.firstMatch(in: after, range: whole) != nil { continue }
                guard let c = afterClause.firstMatch(in: after, range: whole) else { return false }
                let rest = ans.substring(with: c.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty,
                   pointer.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) == nil {
                    return false
                }
                continue
            }
            if pointer.firstMatch(in: s, range: all) == nil { return false }
        }
        return denied
    }

    private static let backingTools: Set<String> = ["list_events", "create_event", "import_ics"]

    /// The reply the person reads: the calendar's own answer when the reply
    /// claims what the calendar holds and no read this turn backs it, else the reply as is.
    /// Local route only: the cloud route streams sentences to speech as they
    /// arrive, so a replacement there would come after the person heard it.
    static func vet(reply: String, route: String, results: [ActionClaimGuard.ToolResult], ask: String,
                    hasImage: Bool = false, now: Date = Date(), calendar: Foundation.Calendar = .current,
                    locale: Locale = .current) -> (text: String, replaced: Bool) {
        guard route == "local",
              // A read this turn backs it, and so does an event written this
              // turn, for its own confirmation ("lunch is on your calendar").
              !results.contains(where: { Self.backingTools.contains($0.tool) && ActionClaimGuard.completed($0.result) }),
              claimsCalendar(reply)
                || (!hasImage && deniesCalendar(reply) && isBareDenial(reply) && asksAboutTheirCalendar(ask))
        else { return (reply, false) }
        // D206: "when is my dentist appointment" is answered by the search; on
        // a photo turn the reply may have read the answer from the photo.
        if !hasImage, let search = CalendarSearchAsk.match(ask) {
            return (CalendarSearchAsk.answer(search, now: now, calendar: calendar, locale: locale), true)
        }
        // A denial names no day of its own; the coming week shows what Grux can read.
        let denied = !claimsCalendar(reply)
        guard let window = CalendarAsk.mentionedWindow(in: ask, now: now, calendar: calendar)
                ?? (denied ? comingWeek(now: now, calendar: calendar) : nil)
                ?? CalendarAsk.mentionedWindow(in: reply, now: now, calendar: calendar)
                ?? CalendarAsk.mentionedWindow(in: "today", now: now, calendar: calendar)
        else { return (reply, false) }
        let events = CalendarAsk.events(window.start, window.end)
        return (CalendarAsk.reply(events: events, window: window, now: now, calendar: calendar, locale: locale), true)
    }

    /// Today and the six days after it.
    private static func comingWeek(now: Date, calendar: Foundation.Calendar) -> CalendarAsk.Window? {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: today) else { return nil }
        return CalendarAsk.Window(start: today, end: end, label: "the next 7 days")
    }
}
