import Foundation

// Voice-first PIM intents (Foundry batch 2, blueprint section 03).
//
// Maps spoken utterance patterns onto a deterministic tool-call plan that
// executes through the EXISTING Claude tools (CalendarTool create_event,
// NotesTool create_note, DocumentTools documents_list, add_task) via
// ChatService.dispatchTool, so there is exactly one implementation of each
// PIM action. No EventKit, no NotesStore, no network is touched here: this
// file is pure parsing + plan construction, which is what makes it unit
// testable without live services.
//
// Why deterministic and not an LLM hop? Same reasoning as
// ChatIntentClassifier and the Commands V2 fast path: "put lunch with Sarah
// on my calendar Friday 1pm" has one correct reading, and a round trip to
// Claude costs latency + tokens for zero added judgment. Anything this
// parser is not CONFIDENT about returns nil and falls through to the normal
// Claude tool path, which handles the fuzzy phrasings.
//
// Date parsing uses NSDataDetector (system-level, zero deps), mirroring
// CommitmentScheduler.parseTargetDate, plus the same "in N minutes/hours"
// fallback regex the detector sometimes misses.
//
// Email is the one intent that does NOT execute deterministically:
// compose_email SENDS immediately and the spoken recipient ("Sarah") still
// needs address resolution. So a draft-email plan delegates a synthesized
// instruction through ChatService.send, where Claude resolves the contact,
// drafts, and (per compose_email's own tool description) reads the draft
// back before sending. The confirmation card + undo window still front the
// whole flow.

// MARK: - Intent kinds

enum PIMIntentKind: String, CaseIterable, Sendable {
    case addToCalendar = "add_to_calendar"
    case takeNote = "take_note"
    case draftEmail = "draft_email"
    case findDocument = "find_document"
    case addTask = "add_task"
    case completeTask = "complete_task"
    case removeTask = "remove_task"
    case focusTask = "focus_on_task"
    case rememberFact = "remember_fact"

    /// SF Symbol for the confirmation card.
    var symbolName: String {
        switch self {
        case .addToCalendar: return "calendar.badge.plus"
        case .takeNote:      return "note.text.badge.plus"
        case .draftEmail:    return "envelope"
        case .findDocument:  return "doc.text.magnifyingglass"
        case .addTask:       return "checklist"
        case .completeTask:  return "checkmark.circle"
        case .removeTask:    return "trash"
        case .focusTask:     return "scope"
        case .rememberFact:  return "person.text.rectangle"
        }
    }

    /// The action in words, for the decision provider judging a matched plan.
    var judgeAction: String {
        switch self {
        case .addToCalendar: return "add a calendar event"
        case .takeNote:      return "save a note"
        case .draftEmail:    return "draft an email"
        case .findDocument:  return "search the document library"
        case .addTask:       return "add a task to the person's task list"
        case .completeTask:  return "mark a task on the person's task list as done"
        case .removeTask:    return "remove a task from the person's task list"
        case .focusTask:     return "make a task the person's current focus"
        case .rememberFact:  return "save, in the person's own words, what they just asked Grux to remember about themselves"
        }
    }

    /// Whether the decision provider may veto the fast path for this kind.
    /// Not for actions on an existing task: their tools change nothing
    /// without a matching task and the card carries the undo, so a wrong fire
    /// costs nothing while a veto turns a clear ask into an offer (live
    /// 2026-09-28: "focus on the task X" 0.49 to 0.62, "check off X" 0.59).
    /// Anything that creates keeps the judge: a false positive leaves junk.
    /// Except a note: the note matcher only fires on an explicit verb ("take
    /// a note", "note that", "write down"), a wrong note is harmless and
    /// undoable from the card, and the veto (0.16 to 0.56 live) turned every
    /// spoken note ask into an offer (A34, ruling 0v).
    /// And a first-person fact: the fact matcher only fires on the patterns
    /// ruling 0t lists ("remember that my X is Y", "remember that I ..."),
    /// which have one reading, and the card carries the undo.
    var isJudged: Bool {
        switch self {
        case .completeTask, .removeTask, .focusTask, .takeNote, .rememberFact: return false
        case .addToCalendar, .draftEmail, .findDocument, .addTask: return true
        }
    }

    /// Microcaps kind label on the card.
    var cardKindLabel: String {
        switch self {
        case .addToCalendar: return "CALENDAR"
        case .takeNote:      return "NOTE"
        case .draftEmail:    return "EMAIL DRAFT"
        case .findDocument:  return "DOC SEARCH"
        case .addTask, .completeTask, .removeTask, .focusTask: return "TASK"
        case .rememberFact:  return "MEMORY"
        }
    }
}

// MARK: - Slots

/// Extracted slots, exposed separately from the plan so tests can pin slot
/// extraction without caring about tool-input shapes.
struct PIMSlots: Equatable {
    /// Event title / note body / email topic / document query.
    var title: String = ""
    /// Resolved target date (calendar only).
    var date: Date? = nil
    /// True when the date expression carried no time of day ("tomorrow").
    var dateIsAllDay: Bool = false
    /// Spoken recipient name (email only). NOT an address.
    var recipient: String? = nil
    /// True when the words set the task off as a task: a colon, "called" or
    /// "named" after "add a task", or "add X to my tasks" (task only).
    var namedAsATask: Bool = false
}

// MARK: - Plan

/// A fully constructed, ready-to-run PIM action. Built on parse, displayed
/// on the confirmation card, executed after the undo window elapses.
struct PIMPlan {
    enum Execution {
        /// Deterministic: dispatch through ChatService.dispatchTool, which
        /// routes to CalendarTool / NotesTool / DocumentTools.
        case tool(name: String, input: [String: Any])
        /// Delegated: hand a synthesized instruction to ChatService.send so
        /// Claude finishes the job with its own tool calls (email drafting).
        case chat(prompt: String)
    }

    let kind: PIMIntentKind
    let slots: PIMSlots
    let execution: Execution
    /// Card headline, e.g. "Lunch with Sarah".
    let cardTitle: String
    /// Card second line, e.g. "Fri Jun 12 1:00 PM".
    let cardDetail: String
    /// Spoken acknowledgment, e.g. "Locked in: lunch with Sarah, Friday 1 PM".
    let spokenAck: String

    /// Grux's own reminder for a timed "remind me to" (D147), scheduled once
    /// the task lands; nil for everything else.
    var reminder: GruxReminder? = nil

    /// Whether the decision provider may veto this plan. Every gate asks the
    /// plan, never the kind: a task the person named as a task ("add a task:
    /// Email", "add a task called Email", "add Email to my tasks") has one
    /// reading and the card carries the undo, while the judge held "add a
    /// task: Email" back at 0.63 and the ask became an offer (D151).
    var isJudged: Bool { kind.isJudged && !slots.namedAsATask }

    /// Mutating actions get the 5s undo window; read-only doc search runs
    /// immediately.
    var requiresUndoWindow: Bool { kind != .findDocument }

    /// Convenience accessors for tests.
    var toolName: String? {
        if case .tool(let name, _) = execution { return name }
        return nil
    }
    var toolInput: [String: Any]? {
        if case .tool(_, let input) = execution { return input }
        return nil
    }
    var chatPrompt: String? {
        if case .chat(let prompt) = execution { return prompt }
        return nil
    }
}

// MARK: - Parser

enum PIMIntents {

    /// Seconds the confirmation card holds before executing a mutating plan.
    static let undoWindowSeconds: TimeInterval = 5
    /// How far ahead a "remind me to" time must be to become a reminder: the
    /// undo window and 30 s more, so the card never lands after the time it
    /// names (W47-P3 item 1). A nearer time stays in a plain task's title.
    static let reminderMinimumLead: TimeInterval = undoWindowSeconds + 30

    // MARK: Public entry points

    /// Parse an utterance into a runnable plan, or nil when this is not a
    /// confident PIM command (caller falls through to the Claude path).
    static func plan(for utterance: String, now: Date = Date()) -> PIMPlan? {
        guard let m = match(utterance, now: now) else { return nil }
        switch m.kind {
        case .addToCalendar: return calendarPlan(slots: m.slots, now: now)
        case .takeNote:      return notePlan(slots: m.slots)
        case .draftEmail:    return emailPlan(slots: m.slots)
        case .findDocument:  return documentPlan(slots: m.slots)
        case .addTask:       return taskPlan(slots: m.slots, now: now)
        case .completeTask, .removeTask, .focusTask:
            return taskActionPlan(kind: m.kind, slots: m.slots)
        case .rememberFact:  return factPlan(slots: m.slots)
        }
    }

    struct Match: Equatable {
        let kind: PIMIntentKind
        let slots: PIMSlots
    }

    /// Slot-level match, exposed for tests.
    static func match(_ utterance: String, now: Date = Date()) -> Match? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else { return nil }
        // PIM utterances are single spoken commands; an internal newline (from
        // multi-line dictation or pasted text) otherwise breaks the whole-string
        // ^...$ anchored regexes (default NSRegularExpression '.' does not cross
        // '\n'), silently dropping a confident note/calendar/email match to the
        // generic Claude path. Collapse internal newlines (and tabs) to spaces;
        // downstream firstLine() still recovers a multi-line note body.
        let flattened = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let stripped = stripPreamble(flattened)

        // Order matters: note and email triggers are start-anchored and more
        // specific; "note that I need to email Sarah" must stay a note.
        if let m = matchNote(stripped) { return m }
        if let m = matchEmail(stripped) { return m }
        if let m = matchTask(stripped, now: now) { return m }
        if let m = matchTaskAction(stripped) { return m }
        if let m = matchFact(stripped) { return m }
        if let m = matchCalendar(stripped, now: now) { return m }
        if let m = matchDocument(stripped) { return m }
        return nil
    }

    // MARK: Preamble

    // "hey grux, please can you put ..." → "put ..."
    private static let preambleRegex = regex(
        #"^(?:(?:hey|ok|okay|yo)[, ]+)?(?:grux[,!. ]+)?(?:please[,. ]+)?(?:can you |could you |would you |go ahead and )?"#
    )

    static func stripPreamble(_ s: String) -> String {
        let ns = s as NSString
        guard let m = preambleRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length > 0, m.range.length < ns.length else { return s }
        return ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Question shapes (never a confident mutation)

    // Questions and status lookups must reach Claude, not the mutation
    // fast path: "schedule lunch with Sarah Friday 1pm" is a command, but
    // "can I schedule X?", "when did I schedule X?", "did you email
    // Sarah?" are conversations. Trailing "?" or an interrogative lead
    // word (after the preamble strip) disqualifies calendar and email.
    private static let interrogativeLeadRegex = regex(
        #"^(?:what|when|why|where|who|whose|which|how|did|do|does|is|are|was|were|am|have|has|had|should|shall|would|will|can\s+i|could\s+i|may\s+i)\b"#
    )

    static func isQuestionShaped(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        return interrogativeLeadRegex.firstMatch(in: trimmed, range: fullRange(trimmed)) != nil
    }

    // MARK: Calendar

    private static let calendarPutRegex = regex(
        #"^(?:put|add|throw|stick|drop)\s+(.+?)\s+(?:on|to|onto)\s+(?:my\s+|the\s+)?calendar\b(.*)$"#
    )
    private static let calendarScheduleRegex = regex(
        #"^(?:schedule|book)\s+(?:me\s+)?(.+)$"#
    )

    // The bare schedule/book route is the loosest pattern in the file, so
    // it additionally needs an explicit event marker before it may mutate
    // the calendar: a "with <someone>" clause or an event noun. "Schedule
    // the foundry upgrade cycle for tonight at 11pm" is a task for Claude
    // (and its tools), not a calendar entry.
    private static let eventNounRegex = regex(
        #"\b(?:meeting|meet|call|appointment|appt|lunch|dinner|breakfast|brunch|coffee|demo|interview|session|sync|standup|stand-up|review|checkup|check-up|checkin|check-in|haircut|flight|workout|class|lesson|reservation|hangout|catchup|catch-up|one\s+on\s+one|1:1)\b"#
    )

    static func hasEventMarker(_ title: String) -> Bool {
        if regexHit(#"\bwith\s+\S"#, in: title) { return true }
        return eventNounRegex.firstMatch(in: title, range: fullRange(title)) != nil
    }

    private static func matchCalendar(_ s: String, now: Date) -> Match? {
        guard !isQuestionShaped(s) else { return nil }
        var titleCandidate: String?
        var needsEventMarker = false
        if let m = calendarPutRegex.firstMatch(in: s, range: fullRange(s)),
           let r = Range(m.range(at: 1), in: s) {
            // Date text may live in the title segment OR the tail after
            // "calendar"; detect over the whole utterance and excise below.
            titleCandidate = String(s[r])
        } else if let m = calendarScheduleRegex.firstMatch(in: s, range: fullRange(s)),
                  let r = Range(m.range(at: 1), in: s) {
            titleCandidate = String(s[r])
            needsEventMarker = true
        }
        guard var title = titleCandidate else { return nil }
        if needsEventMarker, !hasEventMarker(title) { return nil }

        // A calendar plan without a time anchor is not confident; let Claude
        // ask the follow-up question instead of inventing a slot.
        guard let detected = detectDate(in: s, now: now) else { return nil }

        // A date resolved into the past (NSDataDetector reading "Friday 1pm"
        // as the Friday just gone) is almost never what the user means for a
        // new event. Hand off to Claude to clarify rather than filing a stale
        // event. One hour of grace covers "lunch at noon" said at 12:05.
        guard detected.date.timeIntervalSince(now) > -3600 else { return nil }

        title = excise(detected.matchedText, from: title)
        title = cleanTitle(title)
        guard !title.isEmpty else { return nil }

        var slots = PIMSlots()
        slots.title = title
        slots.date = detected.date
        slots.dateIsAllDay = !detected.hasTime
        return Match(kind: .addToCalendar, slots: slots)
    }

    // MARK: Note

    private static let noteRegexes: [NSRegularExpression] = [
        regex(#"^take a (?:quick )?note[,:. ]\s*(?:that\s+)?(.+)$"#),
        regex(#"^make a (?:quick )?note(?: that| of| about)?[,:. ]\s*(.+)$"#),
        // "add a note to the invoice" attaches to something else: that stays
        // with the model.
        regex(#"^add a (?:quick )?note(?:\s*[,:]\s*|\s+that\s+|\s+(?!(?:to|of|on|in|for|about|at)\b))(.+)$"#),
        regex(#"^note that\s+(.+)$"#),
        regex(#"^note to self[,:. ]\s*(.+)$"#),
        regex(#"^write (?:this|that) down[,:. ]\s*(.+)$"#),
        regex(#"^write down\s+(.+)$"#),
        regex(#"^jot (?:this |that )?down[,:. ]\s*(.+)$"#),
        regex(#"^jot down\s+(.+)$"#)
    ]

    private static func matchNote(_ s: String) -> Match? {
        for re in noteRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let r = Range(m.range(at: 1), in: s) {
                let body = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                var slots = PIMSlots()
                slots.title = body
                return Match(kind: .takeNote, slots: slots)
            }
        }
        return nil
    }

    // MARK: Task

    // A task ask has one reading, so it does not wait on the model: on the
    // local route the model answered "add a task: X" with a made-up "added"
    // whenever the thread had any earlier turn (A28), and nothing was added.
    private static let remindRegex = regex(#"^remind me to\s+(.+)$"#)
    /// Words that name a day, a span or a repeat, a few short or misspelled
    /// ones too. A task holding one is not given a reminder: macOS read only
    /// the time out of "next week at 3pm" or "on Mondays at 8pm" and dated it
    /// today (W47-FIX). "This" and "next" alone name nothing ("finish this at
    /// 5pm"); "may" and "march" are verbs too, so only "in May" counts.
    private static let undatedDayWords: Set<String> = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "january", "february", "april", "june", "july", "august", "september", "october", "november", "december",
        "weekend", "week", "weekday", "weeknight", "day", "month", "year", "fortnight", "daily", "weekly",
        "monthly", "yearly", "nightly", "every", "each", "tomorrow", "christmas", "thanksgiving", "easter",
        "halloween", "birthday", "anniversary", "holiday", "quarter", "eod", "eow", "eom", "eoy",
        "tommorow", "tomorow", "tommorrow", "tmr", "tmrw", "tmw", "2moro", "2morrow", "xmas", "nye", "bday",
        // Not "sun", "sat", "wed" or "mon": everyday words ("put on sun cream at 3pm").
        "wk", "yr", "tue", "tues", "thu", "thur", "thurs", "fri",
        // Shorthands that are no day word written a letter or two off (rounds 6 and 7).
        "tmrrw", "tmrow", "tmorrow", "tomoro", "tomorow", "2morow", "wknd", "wkend", "wkd", "tmoro", "tomo", "tomoz",
        "morrow", "tommoro", "tommorw", "tommorow", "tommorrow", "2mrw", "2mro", "tmro", "tomrw",
        "tomor", "2mor", "2morro", "tomm", "tmorw", "2morw", "tmmrw", "2mrrw", "2moz", "tmrww", "satur", "overmorrow",
        "payday", "2mrow", "2mrrow", "2morroww", "biweekly", "bimonthly", "wkly", "wkday", "nextweek", "nextwk", "nxtwk",
        "thisweek", "thisweekend", "nextweekend", "nextmonth", "nextyear",
        // Months written short, the ones that are no everyday word or name (round 7).
        "feb", "apr", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mnth", "mth", "semester", "decade", "valentine", "hanukkah", "chanukah", "diwali", "eid", "passover",
        "ramadan", "kwanzaa", "nyd",
    ]
    /// Words that are a month or a season only after a word that ties them to
    /// a time ("in may", "by mar", "this summer", "in the fall"); alone they
    /// are a name or a verb ("email May", "call Jan", "fall asleep").
    private static let tiedDayWords: Set<String> = ["may", "march", "mar", "jan", "jun", "summer", "winter", "spring", "fall", "autumn"]
    private static let timeTies: Set<String> = ["in", "by", "this", "next", "last", "of", "until", "till", "before", "after",
                                                "during", "over", "early", "late", "mid", "end", "since", "from", "for"]

    /// The day words people misspell or shorten in typed chat (W47-FIX round 5).
    private static let looseDayWords = ["tomorrow", "weekend", "monday", "tuesday", "wednesday", "thursday",
                                        "friday", "saturday", "sunday", "fortnight"]

    /// Whether `word` is one of `looseDayWords` a letter off ("thursdy",
    /// "yomorrow"), or two off one of 8 letters or more with the same first
    /// letter ("tomrow", "satday", "wensday"). "Study", "Wendy" and "monkey"
    /// are words (round 6: a letters-in-order rule took "study" for "saturday").
    private static func nearADayWord(_ word: String) -> Bool {
        let w = Array(word)
        guard w.count >= 5, w.allSatisfy(\.isLetter) else { return false }
        // Edits with two swapped letters as one ("tuseday", "wekeend"; round 8).
        func distance(_ v: [Character]) -> Int {
            var d = Array(repeating: Array(repeating: 0, count: v.count + 1), count: w.count + 1)
            for i in 0...w.count { d[i][0] = i }
            for j in 0...v.count { d[0][j] = j }
            for i in stride(from: 1, through: w.count, by: 1) {
                for j in stride(from: 1, through: v.count, by: 1) {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (w[i - 1] == v[j - 1] ? 0 : 1))
                    if i > 1, j > 1, w[i - 1] == v[j - 2], w[i - 2] == v[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
                }
            }
            return d[w.count][v.count]
        }
        return looseDayWords.contains { day in
            let v = Array(day)
            let d = distance(v)
            // Two edits for the long day words, so "tomrow" and "satday" count while
            // "monkey" (two off "monday", a short day word) is a monkey (round 7).
            return d <= 1 || (v.count >= 8 && d <= 2 && v.first == w.first)
        }
    }

    /// Days macOS does not read: an ordinal ("the 15th", "on the first") and
    /// "on" a short weekday ("on sat", "on Wed.").
    private static let undatedDayShapes: String = {
        let ones = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        let words = ones + ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
                            "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth"]
            + ones.map { "twenty[- ]" + $0 } + ["thirty[- ]first"]
        return #"\b\d{1,2}(?:st|nd|rd|th)\b|\b(?:on|by|before|after|until)\s+the\s+(?:"#
            + words.joined(separator: "|") + #")\b|\bon\s+(?:sat|sun|mon|tue|tues|wed|thu|thur|thurs|fri)\b"#
            + #"|\b(?:on|by|until|before|after)\s+(?:the\s+)?\d{1,2}\b(?!\s*(?:%|[a-z]))"#
            // Month-day digits macOS does not read ("11-15", "11.15"; round 8), not a
            // dose or a range ("take 1-2 tablets"; round 9).
            + #"|\b\d{1,2}[-./]\d{1,2}\b(?!\s*[a-z%])"#
    }()

    /// Whether `task` names a day or a span of its own: a word above (or its
    /// plural), "in May", "in March", or a year.
    private static func namesAnUndatedDay(_ task: String) -> Bool {
        // "3days", "2wks": a number typed onto its unit is the unit too (round 9).
        let words = task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).flatMap { token -> [String] in
            var parts = [String(token)]
            if token.contains(where: \.isLetter), token.contains(where: \.isNumber) {
                var part = ""
                for c in token {
                    if let last = part.last, last.isNumber != c.isNumber { parts.append(part); part = "" }
                    part.append(c)
                }
                parts.append(part)
            }
            return parts
        }
        return words.indices.contains { i in
            let w = words[i]
            return undatedDayWords.contains(w) || (w.hasSuffix("s") && undatedDayWords.contains(String(w.dropLast())))
                || nearADayWord(w)
                // A unit of a day or more right after a number: "in 6mo", "in 3 mos", "in 2d"
                // (round 10); alone "Mo" is a name.
                // A one-letter unit only at the end ("in 2d"; "buy 2 d batteries" is a size).
                || (i > 0 && words[i - 1].allSatisfy(\.isNumber)
                    && (["mo", "mos", "dy", "dys"].contains(w) || (["d", "w", "y"].contains(w) && i == words.count - 1)))
                || (tiedDayWords.contains(w) && (i > 0 && timeTies.contains(words[i - 1])
                    || i > 1 && words[i - 1] == "the" && timeTies.contains(words[i - 2])))
                || (w.count == 4 && (w.hasPrefix("19") || w.hasPrefix("20")) && w.allSatisfy(\.isNumber))
        }
    }

    /// A "remind me to" that ends in a time Grux reads itself (W47-FIX round
    /// 3): "at 9 AM", "at 9:30 pm", "at noon", with today, tonight, tomorrow
    /// or "on Friday" before or after it, or "in 20 minutes". Anything else
    /// ("at 4pm about the trip", "before 5pm", "at about 5pm", "at 7") is a
    /// plain task with every word kept: a miss costs a reminder, never a
    /// wrong day or a broken title.
    private static let reminderTail: NSRegularExpression = {
        // Not "midnight": macOS reads it as the next day, so it never matches the day said (W47-FIX round 4).
        let clock = #"(?:\d{1,2}(?::\d{2})?\s?(?:am|pm|a\.m\.?|p\.m\.?)|noon)"#
        let day = #"(?:(?:later\s+)?(?:today|tonight|tomorrow)|on\s+(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday))"#
        // Digits only: macOS and `detectDate` read no spelled-out span ("in twenty minutes").
        let span = #"in\s+(?:\d{1,3}\s+(?:minutes?|mins?|hours?|hrs?)|an\s+hour(?:\s+and\s+a\s+half)?|half\s+an\s+hour|a\s+half\s+hour)"#
        return regex("^(.+?)\\s+((?:" + day + "\\s+)?at\\s+" + clock + "(?:\\s+" + day + ")?|" + span + ")[.!]?$")
    }()

    /// The spans people say out loud with one meaning, in the digits the date
    /// reader takes (W47-P3 item 4: "in an hour" got no reminder). "In a
    /// while" and "in an hour or two" are not here: they name no time.
    private static let spokenSpans: [String: String] = [
        "in an hour": "in 1 hour", "in an hour and a half": "in 90 minutes",
        "in half an hour": "in 30 minutes", "in a half hour": "in 30 minutes"
    ]

    /// The task and the time of a timed "remind me to", or nil. The day macOS
    /// reads for the time must be the one the words name, and the task must
    /// hold no date of its own.
    static func timedReminder(_ body: String, now: Date) -> (task: String, date: Date)? {
        guard let m = reminderTail.firstMatch(in: body, range: fullRange(body)),
              let taskRange = Range(m.range(at: 1), in: body), let whenRange = Range(m.range(at: 2), in: body)
        else { return nil }
        let task = String(body[taskRange]).trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
        let when = body[whenRange].lowercased()
        guard !task.isEmpty, let read = detectDate(in: spokenSpans[when] ?? String(body[whenRange]), now: now), read.hasTime,
              read.date.timeIntervalSince(now) >= reminderMinimumLead
        else { return nil }
        let cal = Foundation.Calendar.current
        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var date = read.date
        if when.contains("tomorrow") {
            guard let next = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(read.date, inSameDayAs: next) else { return nil }
        } else if let w = days.firstIndex(where: { when.contains($0) }) {
            guard let day = weekdayReminderDate(read: read.date, weekday: w + 1, now: now, calendar: cal) else { return nil }
            date = day
        } else if when.hasPrefix("in ") {
            guard read.date.timeIntervalSince(now) <= 24 * 3600 else { return nil }
        } else {
            guard cal.isDate(read.date, inSameDayAs: now) else { return nil }
        }
        // "tonight at 9am" is read as 9 PM; "12am", like midnight, is the next day's start.
        if when.contains("tonight"), when.range(of: #"\d\s?a\.?m"#, options: .regularExpression) != nil { return nil }
        if when.range(of: #"\b12(?::\d{2})?\s?a\.?m"#, options: .regularExpression) != nil { return nil }
        guard detectDate(in: task, now: now) == nil, !namesAnUndatedDay(task),
              task.range(of: undatedDayShapes, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        // With no day in the time phrase, a day macOS cannot read in the task would
        // be taken as today; the day words above refuse it, and so does a short
        // weekday (W47-FIX rounds 4 to 7).
        let saysDay = when.contains("today") || when.contains("tonight") || when.contains("tomorrow")
            || days.contains(where: { when.contains($0) })
        if !saysDay {
            let words = task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            // ... and no short weekday ("call mom Sat at 9pm"; "sun" is a word too, so this costs "sun cream").
            let short: Set<Substring> = ["sat", "sun", "mon", "wed", "weds", "tue", "tues", "thu", "thur", "thurs", "fri"]
            // Prepositions and numbers stay ("pick up the kids from school at 3pm",
            // "take 2 pills at 9pm"): round 6 refused every "in", "on", "for" and
            // number and cost the commonest reminders (round 7).
            guard !words.contains(where: short.contains) else { return nil }
        }
        return (task, date)
    }

    /// The day a "remind me ... on Friday at 3pm" falls on: the weekday the
    /// words name, inside the coming week. D181: macOS reads a weekday said on
    /// that same day as next week's, even while the time is still ahead
    /// today (measured 12:08 AM Friday Nov 6: "Friday at 3pm" read Friday Nov
    /// 13), so that read moves back to today when today's time is at least
    /// `reminderMinimumLead` away. nil when the read is another weekday or a
    /// week or more away.
    static func weekdayReminderDate(read: Date, weekday: Int, now: Date, calendar cal: Foundation.Calendar) -> Date? {
        guard cal.component(.weekday, from: read) == weekday else { return nil }
        if cal.component(.weekday, from: now) == weekday,
           let today = cal.date(byAdding: .day, value: -7, to: read), cal.isDate(today, inSameDayAs: now),
           today.timeIntervalSince(now) >= reminderMinimumLead {
            return today
        }
        return read.timeIntervalSince(now) < 7 * 86_400 ? read : nil
    }

    private static let taskRegexes: [NSRegularExpression] = [
        namedTaskRegex,
        // D180 item 1: "make a to-do list for the weekend" is a list to make,
        // not a task titled "list for the weekend"; it goes to the model.
        regex(#"^(?:add|create|make)\s+(?:a\s+)?(?:new\s+|another\s+)?(?:task|to-?do)\b(?!\s*lists?\b)[,:.]?\s*(?:to\s+|for\s+|called\s+|named\s+)?(.+)$"#),
        remindRegex,
        onTheListRegex
    ]
    /// The two shapes that name the task as a task, so the judge is not asked
    /// (`PIMPlan.isJudged`, D151). "add a task to ..." and "make a to-do list
    /// for my trip" are not among them: they read other ways too.
    private static let namedTaskRegex =
        regex(#"^(?:add|create|make)\s+(?:a\s+)?(?:new\s+|another\s+)?(?:task|to-?do)(?:\s*:\s*|\s+(?:called|named)\s+)(.+)$"#)
    private static let onTheListRegex =
        regex(#"^(?:add|put)\s+(.+?)\s+(?:to|on|onto)\s+(?:my\s+|the\s+)?(?:tasks|task\s+list|task\s+stack|to-?do\s+list|to-?dos|to-?do)$"#)

    private static func matchTask(_ s: String, now: Date) -> Match? {
        guard !isQuestionShaped(s) else { return nil }
        for re in taskRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let r = Range(m.range(at: 1), in: s) {
                var title = String(s[r])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!\""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                var slots = PIMSlots()
                // "Remind me to call the dentist tomorrow at 9 AM" names when:
                // the task is "call the dentist" and Grux reminds at 9 AM
                // (D147). Any other shape stays in the title: Grux does not
                // pick an hour or a day nobody said.
                // A "remind me to" inside a task the person names ("add a task:
                // remind me to call mom at 9pm") is the same ask (W48-P3 item 4).
                let named = re === namedTaskRegex || re === onTheListRegex
                var timedBody: String? = re === remindRegex ? title : nil
                if named, let inner = remindRegex.firstMatch(in: title, range: fullRange(title)),
                   let r = Range(inner.range(at: 1), in: title) {
                    timedBody = String(title[r])
                }
                if let body = timedBody, let timed = timedReminder(body, now: now) {
                    title = timed.task
                    slots.date = timed.date
                }
                slots.title = title
                slots.namedAsATask = named
                return Match(kind: .addTask, slots: slots)
            }
        }
        return nil
    }

    // A task action names one task and has one reading, so it does not wait
    // on the model either: with any thread history the local model answered
    // "mark X as done", "delete the task X" and "focus on the task X" with a
    // made-up "Marked as complete" 0 of 9 times calling the tool (A28b).
    // Every pattern names the task list or ends in a done word, so a bare
    // "focus on the release" or "remove lunch from my calendar" stays out.
    private static let taskListNoun = #"(?:my\s+|the\s+)?(?:tasks|task\s+list|task\s+stack|to-?do\s+list|to-?dos)"#
    private static let taskActionRegexes: [(PIMIntentKind, NSRegularExpression)] = [
        (.completeTask, regex(#"^(?:mark|set)\s+(?:the\s+task\s+)?(.+?)\s+(?:as\s+)?(?:done|complete|completed|finished)$"#)),
        (.completeTask, regex(#"^(?:check|tick|cross)\s+off\s+(?:the\s+task\s+)?(.+)$"#)),
        (.completeTask, regex(#"^(?:complete|finish|close)\s+(?:the\s+)?task\s+(.+)$"#)),
        (.removeTask, regex(#"^(?:delete|remove|drop|scratch)\s+(?:the\s+)?task\s+(.+)$"#)),
        (.removeTask, regex(#"^(?:delete|remove|drop|scratch|take)\s+(.+?)\s+(?:from|off)\s+(?:of\s+)?"# + taskListNoun + "$")),
        (.focusTask, regex(#"^focus\s+on\s+(?:the\s+)?task\s+(.+)$"#)),
        (.focusTask, regex(#"^(?:make|set)\s+(?:the\s+task\s+)?(.+?)\s+(?:my|the)\s+(?:current\s+focus|focus|top\s+priority)$"#))
    ]

    private static let pointerWords: Set<String> = ["as", "it", "that", "this", "that one", "this one", "them", "those", "these"]

    private static func matchTaskAction(_ s: String) -> Match? {
        guard !isQuestionShaped(s) else { return nil }
        for (kind, re) in taskActionRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let r = Range(m.range(at: 1), in: s) {
                let title = String(s[r])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!\"'"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // "mark it as done" points back into the conversation; only
                // the model can tell which task "it" is.
                guard !title.isEmpty, !pointerWords.contains(title.lowercased()) else { continue }
                var slots = PIMSlots()
                slots.title = title
                return Match(kind: kind, slots: slots)
            }
        }
        return nil
    }

    // A first-person fact has one reading, so it does not wait on the model:
    // with any thread history the local model answered "remember that X"
    // with text 3 of 3 times and saved nothing (A28c). Only "my <thing> is
    // <value>" and "I <verb> ..." count, "I am ..." and the contractions
    // ("I'm", "I've", "I'd", "I'll") included; "remember that trip" or
    // "remember that time we ..." is conversation and stays with the model.
    private static let factRegexes: [NSRegularExpression] = [
        regex(#"^remember\s+(?:that\s+)?(my\s+\S.*?\s+(?:is|are)\s+\S.*)$"#),
        regex(#"^remember\s+that\s+(i\s+\S+\s+\S.*)$"#),
        regex(#"^remember\s+that\s+(i['\x{2019}](?:m|ve|d|ll)\s+\S.*)$"#)
    ]

    private static func matchFact(_ s: String) -> Match? {
        guard !isQuestionShaped(s) else { return nil }
        for re in factRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let r = Range(m.range(at: 1), in: s) {
                let fact = String(s[r])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.;!\""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fact.isEmpty else { continue }
                var slots = PIMSlots()
                slots.title = capitalizedFirst(fact)
                return Match(kind: .rememberFact, slots: slots)
            }
        }
        return nil
    }

    // MARK: Email

    private static let emailRegexes: [NSRegularExpression] = [
        regex(#"^(?:draft|write|compose)\s+(?:an?\s+)?(?:quick\s+)?email\s+(?:to\s+)?(.+?)\s+(?:about|regarding|re|saying|that)\s+(.+)$"#),
        regex(#"^email\s+(.+?)\s+(?:about|regarding|re|saying|that)\s+(.+)$"#),
        regex(#"^(?:send|shoot)\s+(.+?)\s+(?:an?\s+)?(?:quick\s+)?email\s+(?:about|regarding|re|saying|that)\s+(.+)$"#),
        regex(#"^send\s+(?:an?\s+)?(?:quick\s+)?email\s+to\s+(.+?)\s+(?:about|regarding|re|saying|that)\s+(.+)$"#)
    ]

    // A recipient slot that swallowed a verb ("Sarah sent yesterday")
    // means the utterance was ABOUT mail, not a command to send mail:
    // fall through to Claude instead of drafting to a phantom address.
    private static let recipientVerbRegex = regex(
        #"\b(?:sent|said|says|wrote|writes|received|got|gets|emailed|emails|replied|replies|responded|mentioned|forwarded|asked|asks)\b"#
    )

    private static func matchEmail(_ s: String) -> Match? {
        guard !isQuestionShaped(s) else { return nil }
        for re in emailRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let rRecipient = Range(m.range(at: 1), in: s),
               let rTopic = Range(m.range(at: 2), in: s) {
                let recipient = String(s[rRecipient])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;"))
                let topic = String(s[rTopic])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!"))
                guard !recipient.isEmpty, !topic.isEmpty,
                      recipient.split(separator: " ").count <= 5 else { continue }
                guard recipientVerbRegex.firstMatch(in: recipient, range: fullRange(recipient)) == nil else {
                    continue
                }
                var slots = PIMSlots()
                slots.title = topic
                slots.recipient = recipient
                return Match(kind: .draftEmail, slots: slots)
            }
        }
        return nil
    }

    // MARK: Document

    private static let documentRegexes: [NSRegularExpression] = [
        regex(#"^(?:find|pull up|locate|dig up|search for)\s+(?:me\s+)?(?:the\s+|my\s+|that\s+|a\s+)?(?:doc|document|write[- ]?up)s?\s+(?:about|on|for|called|named|re)\s+(.+)$"#),
        regex(#"^(?:find|pull up|locate|dig up)\s+(?:me\s+)?(?:the\s+|my\s+|that\s+|a\s+)?(?:doc|document|write[- ]?up)s?\s+(.+)$"#),
        regex(#"^where(?:'s| is)\s+(?:the\s+|my\s+|that\s+)?(?:doc|document)s?\s+(?:about|on|for|called|named)\s+(.+)$"#),
        regex(#"^search\s+(?:my\s+|the\s+)?(?:docs|documents|library)\s+for\s+(.+)$"#)
    ]

    private static func matchDocument(_ s: String) -> Match? {
        for re in documentRegexes {
            if let m = re.firstMatch(in: s, range: fullRange(s)),
               let r = Range(m.range(at: 1), in: s) {
                var query = String(s[r])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;?!\""))
                query = stripLeadingWords(query, words: ["the", "my", "a", "an", "that"])
                guard !query.isEmpty else { continue }
                var slots = PIMSlots()
                slots.title = query
                return Match(kind: .findDocument, slots: slots)
            }
        }
        return nil
    }

    // MARK: - Plan construction

    private static func calendarPlan(slots: PIMSlots, now: Date) -> PIMPlan? {
        guard let date = slots.date, !slots.title.isEmpty else { return nil }
        let input: [String: Any] = [
            "title": slots.title,
            "start": isoString(for: date, allDay: slots.dateIsAllDay)
        ]
        return PIMPlan(
            kind: .addToCalendar,
            slots: slots,
            execution: .tool(name: "create_event", input: input),
            cardTitle: slots.title,
            cardDetail: cardWhen(date, allDay: slots.dateIsAllDay),
            spokenAck: "Locked in: \(spokenLowercased(slots.title)), \(spokenWhen(date, allDay: slots.dateIsAllDay, now: now))."
        )
    }

    private static func notePlan(slots: PIMSlots) -> PIMPlan? {
        let body = slots.title
        guard !body.isEmpty else { return nil }
        let noteTitle = noteTitleFrom(body)
        let input: [String: Any] = ["title": noteTitle, "body": body]
        return PIMPlan(
            kind: .takeNote,
            slots: slots,
            execution: .tool(name: "create_note", input: input),
            cardTitle: noteTitle,
            cardDetail: firstLine(of: body, cap: 90),
            spokenAck: "Noted: \(spokenLowercased(firstLine(of: body, cap: 70)))."
        )
    }

    private static func taskPlan(slots: PIMSlots, now: Date) -> PIMPlan? {
        guard !slots.title.isEmpty else { return nil }
        let title = capitalizedFirst(firstLine(of: slots.title, cap: 120))
        let input: [String: Any] = ["title": title, "priority": TaskPriority.next.rawValue]
        let spoken = spokenLowercased(firstLine(of: slots.title, cap: 70))
        guard let at = slots.date else {
            return PIMPlan(
                kind: .addTask,
                slots: slots,
                execution: .tool(name: "add_task", input: input),
                cardTitle: title,
                cardDetail: "task list, up next",
                spokenAck: "Added to your tasks: \(spoken)."
            )
        }
        let when = spokenWhen(at, allDay: false, now: now)
        return PIMPlan(
            kind: .addTask,
            slots: slots,
            execution: .tool(name: "add_task", input: input),
            cardTitle: title,
            cardDetail: "task list, reminder \(when)",
            spokenAck: "Added to your tasks: \(spoken). I'll remind you \(when).",
            reminder: GruxReminder(kind: .commitment, title: title,
                                   body: "You asked me to remind you: \(spoken).", scheduledFor: at)
        )
    }

    /// The task is matched by title when the card runs (fuzzy, like the
    /// model's own call), so an unknown title ends as a failed card saying
    /// no task matched, never as a claim that something changed.
    private static func taskActionPlan(kind: PIMIntentKind, slots: PIMSlots) -> PIMPlan? {
        guard !slots.title.isEmpty else { return nil }
        let match = firstLine(of: slots.title, cap: 120)
        let spoken = spokenLowercased(firstLine(of: slots.title, cap: 70))
        let (detail, ack): (String, String)
        switch kind {
        case .completeTask: (detail, ack) = ("task list, mark done", "Marking done: \(spoken).")
        case .removeTask:   (detail, ack) = ("task list, remove", "Removing from your tasks: \(spoken).")
        case .focusTask:    (detail, ack) = ("task list, make it NOW", "Focusing on: \(spoken).")
        default: return nil
        }
        return PIMPlan(
            kind: kind,
            slots: slots,
            execution: .tool(name: kind.rawValue, input: ["match": match]),
            cardTitle: capitalizedFirst(match),
            cardDetail: detail,
            spokenAck: ack
        )
    }

    private static func factPlan(slots: PIMSlots) -> PIMPlan? {
        guard !slots.title.isEmpty else { return nil }
        let fact = firstLine(of: slots.title, cap: 140)
        return PIMPlan(
            kind: .rememberFact,
            slots: slots,
            execution: .tool(name: "remember_fact", input: ["fact": fact]),
            cardTitle: fact,
            cardDetail: "Their words, kept as said.",
            spokenAck: "I'll remember that."
        )
    }

    private static func emailPlan(slots: PIMSlots) -> PIMPlan? {
        guard let recipient = slots.recipient, !slots.title.isEmpty else { return nil }
        // Phrased so it can NEVER re-match a PIM trigger when it round-trips
        // through ChatService.send (no leading "email"/"draft an email").
        // PIMIntentsTests pins that invariant.
        let prompt = """
        Prepare an outbound email for me. Recipient: \(recipient). Topic: \(slots.title). \
        Resolve the recipient's address from my contacts or recent inbox if you can. \
        Write a plain text draft and read it back to me. Do NOT call compose_email until I confirm the draft.
        """
        return PIMPlan(
            kind: .draftEmail,
            slots: slots,
            execution: .chat(prompt: prompt),
            cardTitle: "To \(recipient)",
            cardDetail: firstLine(of: slots.title, cap: 90),
            spokenAck: "Drafting an email to \(recipient) about \(spokenLowercased(slots.title))."
        )
    }

    private static func documentPlan(slots: PIMSlots) -> PIMPlan? {
        guard !slots.title.isEmpty else { return nil }
        let input: [String: Any] = ["query": slots.title, "limit": 8]
        return PIMPlan(
            kind: .findDocument,
            slots: slots,
            execution: .tool(name: "documents_list", input: input),
            cardTitle: "\"\(slots.title)\"",
            cardDetail: "searching the document library",
            spokenAck: "Searching your documents for \(spokenLowercased(slots.title))."
        )
    }

    // MARK: - Date detection (NSDataDetector, like CommitmentScheduler)

    struct DetectedDate: Equatable {
        let date: Date
        let matchedText: String
        let hasTime: Bool
    }

    static func detectDate(in text: String, now: Date = Date()) -> DetectedDate? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: text, options: [], range: fullRange(text))
            if let m = matches.first, let d = m.date, let r = Range(m.range, in: text) {
                let matched = String(text[r])
                return DetectedDate(date: d, matchedText: matched, hasTime: looksTimed(matched))
            }
        }
        // Fallback for "in N minutes/hours/days" the detector sometimes misses.
        let lower = text.lowercased()
        if let m = inNDurationRegex.firstMatch(in: lower, range: fullRange(lower)),
           m.numberOfRanges >= 3,
           let numRange = Range(m.range(at: 1), in: lower),
           let unitRange = Range(m.range(at: 2), in: lower),
           let fullMatch = Range(m.range, in: lower),
           let n = Int(lower[numRange]) {
            let unit = String(lower[unitRange])
            var seconds: TimeInterval = 0
            if unit.hasPrefix("sec") { seconds = Double(n) }
            else if unit.hasPrefix("min") { seconds = Double(n * 60) }
            else if unit.hasPrefix("hour") || unit == "hr" || unit == "hrs" { seconds = Double(n * 3600) }
            else if unit.hasPrefix("day") { seconds = Double(n * 86400) }
            if seconds > 0 {
                return DetectedDate(
                    date: now.addingTimeInterval(seconds),
                    matchedText: String(lower[fullMatch]),
                    hasTime: true
                )
            }
        }
        return nil
    }

    private static let inNDurationRegex = regex(
        #"\bin\s+(\d+)\s+(seconds?|minutes?|mins?|hours?|hrs?|days?)\b"#
    )

    /// Heuristic: did the matched date text carry a time of day? Drives the
    /// all-day flag on create_event (date-only start = all-day event).
    static func looksTimed(_ matched: String) -> Bool {
        let lower = matched.lowercased()
        if lower.contains(":") { return true }
        if lower.contains("noon") || lower.contains("midnight") { return true }
        if regexHit(#"\d\s*(?:am|pm|a\.m\.|p\.m\.)"#, in: lower) { return true }
        if regexHit(#"\bat\s+\d"#, in: lower) { return true }
        if regexHit(#"\bin\s+\d+\s+(?:sec|min|hour|hr)"#, in: lower) { return true }
        return false
    }

    // MARK: - Title / text cleanup

    /// Remove the date expression from a title candidate when the two overlap
    /// ("add lunch with Sarah Friday 1pm to my calendar").
    static func excise(_ fragment: String, from candidate: String) -> String {
        guard !fragment.isEmpty else { return candidate }
        guard let r = candidate.range(of: fragment, options: [.caseInsensitive]) else { return candidate }
        var out = candidate
        out.removeSubrange(r)
        return out
    }

    /// Trim filler edges and capitalize the first letter.
    static func cleanTitle(_ raw: String) -> String {
        var words = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!?"))
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let trailingFiller: Set<String> = ["on", "at", "for", "to", "from", "this", "next", "the", "a", "an", "my"]
        let leadingFiller: Set<String> = ["a", "an", "the", "my", "to"]
        while let last = words.last, trailingFiller.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, leadingFiller.contains(first.lowercased()) { words.removeFirst() }
        let joined = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!? "))
        return capitalizedFirst(joined)
    }

    static func noteTitleFrom(_ body: String) -> String {
        let line = firstLine(of: body, cap: 58)
        return capitalizedFirst(line)
    }

    static func firstLine(of text: String, cap: Int) -> String {
        let line = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= cap { return trimmed }
        return String(trimmed.prefix(cap)).trimmingCharacters(in: .whitespaces) + "..."
    }

    private static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Spoken text reads better lowercase unless it is an acronym-ish word.
    private static func spokenLowercased(_ s: String) -> String {
        guard let first = s.first, first.isUppercase,
              s.prefix(2).filter({ $0.isUppercase }).count < 2 else { return s }
        return String(first).lowercased() + s.dropFirst()
    }

    private static func stripLeadingWords(_ s: String, words: Set<String>) -> String {
        var parts = s.split(separator: " ").map(String.init)
        while let first = parts.first, words.contains(first.lowercased()), parts.count > 1 {
            parts.removeFirst()
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Date formatting (the machine's own zone, mirroring CalendarTool)

    // NSDataDetector resolves "Friday at 1pm" in the system zone, so formatting
    // has to read back in that same zone or a spoken time lands hours off.
    private static let localTZ = TimeZone.current

    /// CalendarTool.parseDateInput-compatible start string: date-only for
    /// all-day, local "yyyy-MM-dd'T'HH:mm:ss" otherwise.
    static func isoString(for date: Date, allDay: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = localTZ
        df.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss"
        return df.string(from: date)
    }

    /// Card line: "Fri Jun 12 1:00 PM" / "Fri Jun 12 (all day)".
    static func cardWhen(_ date: Date, allDay: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = localTZ
        df.dateFormat = allDay ? "EEE MMM d" : "EEE MMM d h:mm a"
        let base = df.string(from: date)
        return allDay ? "\(base) (all day)" : base
    }

    /// Spoken line: "today at 1 PM", "tomorrow at 9 AM", "Friday 1 PM",
    /// "June 20" for far-out all-day dates.
    static func spokenWhen(_ date: Date, allDay: Bool, now: Date = Date()) -> String {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.timeZone = localTZ

        let timeDf = DateFormatter()
        timeDf.locale = Locale(identifier: "en_US_POSIX")
        timeDf.timeZone = localTZ
        timeDf.dateFormat = cal.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
        let time = timeDf.string(from: date)

        let dayPhrase: String
        if cal.isDate(date, inSameDayAs: now) {
            dayPhrase = "today"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(date, inSameDayAs: tomorrow) {
            dayPhrase = "tomorrow"
        } else if date.timeIntervalSince(now) < 6 * 86400, date > now {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = localTZ
            df.dateFormat = "EEEE"
            dayPhrase = df.string(from: date)
        } else {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = localTZ
            df.dateFormat = "MMMM d"
            dayPhrase = df.string(from: date)
        }
        if allDay { return dayPhrase }
        return dayPhrase == "today" || dayPhrase == "tomorrow"
            ? "\(dayPhrase) at \(time)"
            : "\(dayPhrase) \(time)"
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a bad one is a programmer
        // error, surfaced immediately in tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..<s.endIndex, in: s)
    }

    private static func regexHit(_ pattern: String, in s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: s, range: fullRange(s)) != nil
    }
}
