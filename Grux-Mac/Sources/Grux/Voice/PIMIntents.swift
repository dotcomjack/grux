import Foundation

// Voice-first PIM intents (Foundry batch 2, blueprint section 03).
//
// Maps spoken utterance patterns onto a deterministic tool-call plan that
// executes through the EXISTING Claude tools (CalendarTool create_event,
// NotesTool create_note, DocumentTools documents_list) via
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

    /// SF Symbol for the confirmation card.
    var symbolName: String {
        switch self {
        case .addToCalendar: return "calendar.badge.plus"
        case .takeNote:      return "note.text.badge.plus"
        case .draftEmail:    return "envelope"
        case .findDocument:  return "doc.text.magnifyingglass"
        }
    }

    /// Microcaps kind label on the card.
    var cardKindLabel: String {
        switch self {
        case .addToCalendar: return "CALENDAR"
        case .takeNote:      return "NOTE"
        case .draftEmail:    return "EMAIL DRAFT"
        case .findDocument:  return "DOC SEARCH"
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
