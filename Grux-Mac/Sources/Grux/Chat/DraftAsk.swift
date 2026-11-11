import Foundation
import NaturalLanguage

/// D157 item 17 and D159, live 2026-11-04 on grux-local:2b: "Write a short
/// email to my landlord saying the kitchen sink is leaking." came back "What's
/// your landlord's name?" instead of a draft, and "Draft a quick note to my boss
/// that I'll be late tomorrow." called `create_note` five times, queued five
/// notes in Approvals and answered "Okay.". A message the person asked Grux to
/// write for someone is text for them to send: on a local turn it carries one
/// line saying so, and no tool is offered. Withholding only the note tools was
/// tried first and the model reached for the next one (live 4:00 PM, two
/// `create_event` calls for "I will be late tomorrow"); a draft needs none.
enum DraftAsk {

    /// True when the message asks Grux to write a message to someone: a
    /// closed grammar, precision first (W50's lesson). The ask opens with
    /// "write", "draft" or "compose" (after "please", "can you", "Grux,"),
    /// names an email, message, note, letter, text or reply, and sends it
    /// "to" a recipient that is one of two closed phrases:
    /// - "my", "our", "the", "his", "her" or "their" (any case), at most one
    ///   word more, and a word in `people`;
    /// - a name in mixed case ("Sarah", "Sam Lee"), never a word in
    ///   `notAPerson`, that the on-device NaturalLanguage tagger reads as a
    ///   person's name, or a capitalized `people` word ("Mom");
    /// and the phrase ENDS there: at the end of the ask, at punctuation, or
    /// before a word in `connectors` ("about", "saying", "that"); a name only
    /// before such a word, since "Things: buy milk" is a note's title.
    /// So "the team doc", "My Desktop" and "my kids' chore chart" are places
    /// to keep a note (W52-FIX rounds 1 to 3). An ask that also says "and
    /// add", "then remind", "and send it", one that names an existing
    /// message after "to" (replying needs the tool that reads it), or one in
    /// all capitals, is left alone with its tools.
    ///
    /// D167: a message with no recipient whose kind is followed straight away
    /// by what it says ("a short, polite reply declining a meeting", "an email
    /// asking for a refund") is a draft too, by `saysShape`; never a note, and
    /// never one that names a message that exists after its kind.
    static func matches(_ ask: String) -> Bool {
        guard ask.contains(where: \.isLowercase) else { return false }
        let range = NSRange(location: 0, length: (ask as NSString).length)
        if let m = saysShape.firstMatch(in: ask, range: range), let r = Range(m.range(at: 1), in: ask) {
            let said = String(ask[r.lowerBound...])
            return alsoSaves.firstMatch(in: ask, range: range) == nil
                && namesAMessage.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)) == nil
        }
        guard let m = shape.firstMatch(in: ask, range: range),
              let r = Range(m.range(at: 1), in: ask) else { return false }
        if alsoSaves.firstMatch(in: ask, range: range) != nil { return false }
        let afterTo = String(ask[r.lowerBound...])
        if namesAMessage.firstMatch(in: afterTo, range: NSRange(afterTo.startIndex..., in: afterTo)) != nil {
            return false
        }
        let tokens = afterTo.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first.map(word) else { return false }
        if determiners.contains(first.text.lowercased()) {
            guard !first.closes else { return false }
            for at in 1...2 where at < tokens.count {
                let w = word(tokens[at])
                if people.contains(w.text.lowercased()) {
                    return !w.possessive && (w.closes || endsAt(tokens, at + 1, punctuationCounts: true))
                }
                if w.closes || w.possessive || notAPerson.contains(w.text.lowercased()) { return false }
            }
            return false
        }
        var at = 0
        var name: [String] = []
        while at < min(tokens.count, 2) {
            let w = word(tokens[at])
            guard w.text.first?.isUppercase == true, w.text.contains(where: \.isLowercase),
                  !w.possessive, !notAPerson.contains(w.text.lowercased()),
                  !determiners.contains(w.text.lowercased()) else { return false }
            if w.closes { return false }
            name.append(w.text)
            if endsAt(tokens, at + 1, punctuationCounts: false) {
                // A capitalized word before "about" is as often a notes app or
                // a folder ("Day One", "Ideas") as a person (W52-FIX round 4).
                return (name.count == 1 && people.contains(w.text.lowercased()))
                    || personalNames(in: ask).contains(name.joined(separator: " "))
            }
            at += 1
        }
        return false
    }

    /// The person's names the on-device NaturalLanguage tagger finds in the
    /// ask ("Sam", "Sam Lee"). It misses some ("Al", "Priya"), which costs a
    /// draft, and reads apps and folders as no name, which is the point.
    private static func personalNames(in ask: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = ask
        var names: Set<String> = []
        tagger.enumerateTags(in: ask.startIndex..<ask.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName { names.insert(String(ask[range])) }
            return true
        }
        return names
    }

    /// One token of the recipient: its letters, whether punctuation closes
    /// the phrase after it, and whether it is a possessive ("boss's", "kids'").
    private static func word(_ raw: String) -> (text: String, closes: Bool, possessive: Bool) {
        let closers: Set<Character> = [",", ":", ";", ".", "!", "?"]
        var t = Substring(raw)
        var closes = false
        while let c = t.last, closers.contains(c) { closes = true; t = t.dropLast() }
        let lower = t.lowercased()
        let possessive = lower.hasSuffix("'s") || lower.hasSuffix("\u{2019}s")
            || lower.hasSuffix("'") || lower.hasSuffix("\u{2019}")
        return (String(t).trimmingCharacters(in: .punctuationCharacters), closes, possessive)
    }

    /// Whether the recipient phrase ends before token `at`: a connector, or
    /// the end of the ask when `punctuationCounts` (a person word may end it).
    private static func endsAt(_ tokens: [String], _ at: Int, punctuationCounts: Bool) -> Bool {
        guard at < tokens.count else { return punctuationCounts }
        let next = word(tokens[at]).text.lowercased()
        // "my team to do list": "to do" names a list, never what the message says.
        if next == "to", at + 1 < tokens.count, word(tokens[at + 1]).text.lowercased() == "do" { return false }
        return connectors.contains(next)
    }

    private static let determiners: Set<String> = ["my", "our", "the", "his", "her", "their"]

    /// Words that end the recipient and start what the message says.
    private static let connectors: Set<String> = [
        "about", "saying", "that", "for", "to", "asking", "thanking", "telling", "letting", "explaining",
        "re", "regarding", "reminding", "inviting", "apologizing", "apologising", "congratulating", "wishing",
        "confirming", "requesting", "declining", "accepting", "welcoming", "announcing",
    ]

    /// Words in a name that make it oneself, a place notes are kept, or a
    /// message that already exists. Matched as whole words, any case.
    private static let notAPerson: Set<String> = [
        "self", "me", "myself", "us", "ourselves", "remind", "file", "files", "records", "list", "to-do",
        "journal", "diary", "notebook", "notes", "note", "notepad", "reminders", "calendar", "todo",
        "apple", "notion", "evernote", "obsidian", "onenote", "bear", "things", "todoist", "drafts", "keep",
        // Apps and assistants the NaturalLanguage tagger reads as a person's
        // name (measured, W52-FIX round 5): a note "to Joplin" is kept there.
        "joplin", "anytype", "jira", "asana", "alfred", "siri", "alexa", "gemini", "jarvis", "cortana",
        "copilot", "claude", "grux", "chatgpt", "trello", "slack", "discord", "linear", "logseq", "roam",
        "craft", "ulysses", "scrivener", "simplenote", "goodnotes", "notability", "basecamp", "clickup",
        "email", "e-mail", "emails", "message", "messages", "text", "texts", "thread", "post", "comment", "letter",
    ]

    /// Who a person writes to. Precision first: a word missing here sends the
    /// ask to the model with its tools, which costs a draft, never a note.
    private static let people: Set<String> = [
        "boss", "manager", "landlord", "landlady", "neighbor", "neighbors", "neighbour", "neighbours",
        "team", "teacher", "teachers", "aunt", "uncle", "mom", "mum", "mother", "dad", "father", "parents",
        "sister", "brother", "wife", "husband", "partner", "girlfriend", "boyfriend", "fiance", "fiancee",
        "friend", "friends", "colleague", "colleagues", "coworker", "coworkers", "co-worker", "co-workers",
        "client", "clients", "customer", "customers", "doctor", "dentist", "coach", "editor", "son", "daughter",
        "kids", "grandma", "grandmother", "grandpa", "grandfather", "cousin", "niece", "nephew", "roommate",
        "roommates", "tenant", "tenants", "employer", "employees", "staff", "professor", "principal",
        "assistant", "contractor", "plumber", "lawyer", "accountant", "therapist", "recruiter", "interviewer",
        "supervisor", "lead", "director", "ceo", "founder", "investors", "board", "council", "family", "in-laws",
        "babysitter", "nanny", "vet", "mentor", "hr",
    ]

    /// A message that already exists, named anywhere after "to".
    private static let namesAMessage = try! NSRegularExpression(pattern:
        "(?i)\\b(?:e-?mails?|messages?|texts?|threads?|inbox|mail|dms?|voicemails?|posts?|comments?)\\b")

    /// D167, live on grux-local:2b: with the DRAFT line and no tool, "Write a
    /// short, polite reply declining a meeting on Friday" still came back "I can
    /// draft that message for you." On the dumped wire the line drafted 5 of 8
    /// and a reply already opened with the greeting drafted 9 of 9
    /// (`logs/d167/probe-*.txt`). So a local draft reply starts with this, and
    /// the model writes the rest: "Dear" for a letter, the person's name when
    /// the ask gives one after "to" ("to Sarah", "to Mom"), a title and name or
    /// a family word after "thanking", "letting" and the like ("Dr. Patel",
    /// "Mom"), else "[Name]" as the DRAFT line asks. nil when the ask is not
    /// a draft.
    static func greeting(ask: String) -> String? {
        guard matches(ask) else { return nil }
        let ns = ask as NSString
        let range = NSRange(location: 0, length: ns.length)
        let opening = (saysShape.firstMatch(in: ask, range: range) ?? shape.firstMatch(in: ask, range: range))
            .map { ns.substring(to: $0.range(at: 1).location) } ?? ""
        let salutation = opening.range(of: "\\bletter\\b", options: [.regularExpression, .caseInsensitive]) != nil
            ? "Dear" : "Hi"
        var name: [String] = []
        if saysShape.firstMatch(in: ask, range: range) == nil,
           let m = shape.firstMatch(in: ask, range: range), let r = Range(m.range(at: 1), in: ask) {
            // `matches` accepted a capitalized recipient only as a name.
            for raw in ask[r.lowerBound...].split(whereSeparator: \.isWhitespace).prefix(2) {
                let w = word(String(raw))
                guard w.text.first?.isUppercase == true, !determiners.contains(w.text.lowercased()),
                      !connectors.contains(w.text.lowercased()) else { break }
                name.append(w.text)
                if w.closes { break }
            }
        }
        if name.isEmpty, let m = saysShape.firstMatch(in: ask, range: range), let r = Range(m.range(at: 1), in: ask),
           takesAPerson.contains(ask[r].lowercased()) {
            // After a connector only a title and a name ("thanking Dr. Patel")
            // or a family word standing alone ("letting Mom know") names the
            // person; "wishing Sam" keeps "[Name]".
            let after = ask[r.upperBound...].split(whereSeparator: \.isWhitespace).prefix(3).map { String($0) }
            var words: [String] = []
            for raw in after {
                let w = word(raw)
                if w.possessive { words = []; break }
                guard w.text.first?.isUppercase == true, w.text.contains(where: \.isLowercase),
                      w.text.allSatisfy(\.isLetter) else { break }
                words.append(w.text)
                // "Dr." closes on its own period; the name follows it.
                // A title takes up to two names after it, and greets with the last.
                let cap = titles.contains(words[0].lowercased()) ? 3 : 2
                if (w.closes && !titles.contains(w.text.lowercased())) || words.count == cap { break }
            }
            let tagged = personalNames(in: ask)
            if words.count >= 2, titles.contains(words[0].lowercased()) {
                // "Dr. Sarah Chen" greets the surname only when the tagger
                // joins all three; "Mrs. Jones Merry Christmas" greets Jones.
                let three = words.count == 3
                    && (tagged.contains("\(words[0]). \(words[1]) \(words[2])")
                        || tagged.contains(words.joined(separator: " "))
                        || tagged.contains("\(words[1]) \(words[2])"))
                name = [words[0] + ".", three ? words[2] : words[1]]
            } else if words.count == 1, let first = words.first, !titles.contains(first.lowercased()),
                      !Self.continuesCapitalized(after.dropFirst().first),
                      people.contains(first.lowercased()) {
                // Only a family word ("letting Mom know"): every rule that read
                // a tagged name here let a wish or a company through ("Eid
                // Mubarak", "Mazel tov", "Marriott"), and "[Name]" is never
                // wrong (W56-FIX rounds 8 and 9).
                name = [first]
            }
        }
        return "\(salutation) \(name.isEmpty ? "[Name]" : name.joined(separator: " ")),"
    }

    /// The marker on the greeting `ChatService` ends a local draft turn with:
    /// only a server that continues a trailing assistant message receives it
    /// (`OpenAICompatBackend.prefilled`); every other one never sees it.
    static let prefillKey = "grux_prefill"

    /// The greeting as the reply's start, for the end of a local draft turn.
    static func prefillMessage(ask: String) -> [String: Any]? {
        greeting(ask: ask).map { ["role": "assistant", "content": $0, prefillKey: true] }
    }

    /// The messages with the greeting removed, for a server that would not
    /// continue it (the Claude API, by `ChatService.wireMessages`).
    static func withoutPrefill(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.filter { $0[prefillKey] == nil }
    }

    /// The one line a local turn carries when `matches` is true. About 70
    /// tokens, after the cache point, only on such a turn.
    static func localNote(ask: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard matches(ask) else { return nil }
        let line = "DRAFT: The person asked you to write this message for them. Reply with the whole message now, "
            + "written as from them, ready to send. Where you do not know a name or detail, write a placeholder "
            + "such as [Name]. Do not ask for them first. It is text for them to send, not a note, task or memory to save."
        // D163: a 2B model counted "tomorrow" from Wednesday as Tuesday with the date in NOW.
        return daySentence(ask: ask, now: now, calendar: calendar).map { line + " " + $0 } ?? line
    }

    /// D163, live on grux-local:2b: "Write a short email to Sarah about lunch
    /// tomorrow" on a Wednesday came back "grabbing some food on Tuesday", with
    /// the day named in the DRAFT line. When the ask names exactly one day Grux
    /// can count ("today", "tonight" or "tomorrow") and no weekday, "yesterday"
    /// or "the day after", and the draft names another weekday, Grux says which
    /// day that is and which weekday the draft names, after the draft. nil when
    /// the draft names no other weekday.
    ///
    /// W53-FIX: it rewrote the weekday, and two review rounds found drafts that
    /// name another day on purpose ("back Monday", "How about Friday?" after
    /// "I can't make lunch tomorrow"), which a rewrite turned into the day being
    /// declined. Which weekday is meant cannot be read from the words, so the
    /// draft is left as written and the person, who knows, is told.
    static func checkingDays(reply: String, ask: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let calendar = gregorian(like: calendar)
        guard matches(ask), let day = meantDay(ask, now: now, calendar: calendar) else { return nil }
        let target = weekdays[calendar.component(.weekday, from: day.date) - 1]
        // Only the draft: not a paragraph Grux added after it.
        let draft = [ActionClaimGuard.approvalsPrefix, ActionClaimGuard.notDoneYet]
            .compactMap { reply.range(of: $0)?.lowerBound }.min().map { String(reply[..<$0]) } ?? reply
        let ns = draft as NSString
        var others: [String] = []
        for m in weekday.matches(in: draft, range: NSRange(location: 0, length: ns.length)) {
            let said = ns.substring(with: m.range).lowercased()
            guard let name = weekdays.first(where: { $0.lowercased() == said }),
                  name != target, !others.contains(name) else { continue }
            others.append(name)
        }
        guard !others.isEmpty else { return nil }
        let list = others.count == 1 ? others[0]
            : others.dropLast().joined(separator: ", ") + " and " + others[others.count - 1]
        let line = "\(sentence(for: day, calendar: calendar)) This draft names \(list): check that is the day you mean before you send it."
        return ActionClaimGuard.appending(line, to: reply)
    }

    /// The names below are Gregorian, so the day is counted on that calendar
    /// in the Mac's time zone. W53-FIX: a Mac set to the Hebrew calendar read
    /// Elul as month 13, past the end of `months`, and crashed; Islamic and
    /// Persian gave a false month.
    private static func gregorian(like calendar: Calendar) -> Calendar {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// The one day the ask names in words Grux can count, as days from today.
    private static func meantDay(_ ask: String, now: Date, calendar: Calendar) -> (offset: Int, date: Date)? {
        let range = NSRange(location: 0, length: (ask as NSString).length)
        if weekday.firstMatch(in: ask, range: range) != nil || uncounted.firstMatch(in: ask, range: range) != nil { return nil }
        let offsets = Set(relativeDay.matches(in: ask, range: range).map {
            (ask as NSString).substring(with: $0.range).lowercased() == "tomorrow" ? 1 : 0
        })
        guard offsets.count == 1, let offset = offsets.first,
              let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return nil }
        return (offset, date)
    }

    /// "Today is Wednesday, November 4." for the day the ask names, or nil.
    private static func daySentence(ask: String, now: Date, calendar: Calendar) -> String? {
        let calendar = gregorian(like: calendar)
        guard let day = meantDay(ask, now: now, calendar: calendar) else { return nil }
        return sentence(for: day, calendar: calendar)
    }

    /// "Tomorrow is Thursday, November 5." on a Gregorian `calendar`.
    private static func sentence(for day: (offset: Int, date: Date), calendar: Calendar) -> String {
        let name = weekdays[calendar.component(.weekday, from: day.date) - 1]
        let month = months[calendar.component(.month, from: day.date) - 1]
        return "\(day.offset == 1 ? "Tomorrow" : "Today") is \(name), \(month) \(calendar.component(.day, from: day.date))."
    }

    /// English names, since the draft is written in the words the person used.
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                                 "September", "October", "November", "December"]
    private static let weekday = try! NSRegularExpression(pattern:
        "(?i)\\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b")
    private static let relativeDay = try! NSRegularExpression(pattern: "(?i)\\b(?:today|tonight|tomorrow)\\b")
    private static let uncounted = try! NSRegularExpression(pattern:
        "(?i)\\b(?:yesterday|(?:after|before)\\s+tomorrow)\\b")

    private static let shape = try! NSRegularExpression(pattern:
        "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
        + "(?:write|draft|compose)\\s+(?:me\\s+)?(?:an?\\s+|the\\s+)?"
        + "(?:(?:short|quick|brief|polite|friendly|formal|nice|kind|firm),?\\s+)*"
        + "(?:e-?mail|message|note|letter|text|reply|thank[- ]you\\s+note)\\s+to\\s+"
        + "([a-z][a-z'\u{2019}\\-]*(?:\\s+[a-z][a-z'\u{2019}\\-]*){0,2})",
        options: [.caseInsensitive])
    /// D167: the opening `shape` reads, a message kind that is never a note,
    /// and a word from `connectors` that says what it says, with no "to" or
    /// "for" (a recipient, or a thing: "a message for the commit").
    private static let saysShape = try! NSRegularExpression(pattern:
        "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
        + "(?:write|draft|compose)\\s+(?:me\\s+)?(?:an?\\s+|the\\s+)?"
        + "(?:(?:short|quick|brief|polite|friendly|formal|nice|kind|firm),?\\s+)*"
        + "(?:(?:e-?mail|letter|reply)\\s+(?=(?:\(connectors.subtracting(["to", "for"]).sorted().joined(separator: "|")))\\b(?!-))"
        + "|(?:message|text)\\s+(?=(?:\(addressing.union(["saying"]).sorted().joined(separator: "|")))\\b(?!-)|that\\s+says?\\b)"
        + "|response\\s+(?=(?:\(addressing.sorted().joined(separator: "|")))\\b(?!-))"
        + ")((?:\(connectors.subtracting(["to", "for"]).sorted().joined(separator: "|")))\\b(?!-))",
        options: [.caseInsensitive])
    /// W56-FIX: a text or a response is as often a piece of writing as a
    /// message ("a text explaining photosynthesis", "a response saying why
    /// the author is wrong"), and seven review rounds found an essay behind
    /// every connector that names a topic. So after "message" or "text" only
    /// a connector that addresses someone, "saying" or "that says" drafts;
    /// after "response" only one that addresses someone. An email, a letter
    /// or a reply is a message whatever follows. "re-" starts a word.
    private static let addressing: Set<String> = [
        "asking", "thanking", "letting", "reminding", "inviting", "apologizing", "apologising", "congratulating",
        "wishing", "declining", "accepting", "welcoming",
    ]
    /// Connectors whose next word is the person the message is for
    /// ("wishing Sam", "thanking Sam", "letting Mom know"), so the greeting
    /// can use the name (W56-FIX).
    private static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "prof"]

    /// Whether the token after a would-be name carries on a capitalized
    /// phrase ("Team USA", "Eid Mubarak"); "I", "I'm" and "I'll" do not.
    private static func continuesCapitalized(_ token: String?) -> Bool {
        guard let token, let c = token.first, c.isUppercase else { return false }
        let w = word(token).text
        return !(w == "I" || token.hasPrefix("I'") || token.hasPrefix("I\u{2019}"))
    }
    private static let takesAPerson: Set<String> = [
        "asking", "thanking", "telling", "letting", "reminding", "inviting", "congratulating", "wishing", "welcoming",
    ]
    /// D171, live on grux-local:2b: "Write a text that tells our story for the
    /// bakery website" came back as the copy ("We started as a small family
    /// business in 1985") and the action-claim guard took it for Grux saying it
    /// had started something. True when the ask is for words to read, not a
    /// thing Grux keeps: every `matches` draft, or an ask that opens with
    /// "write", "draft", "compose" or "rewrite" and names a piece of writing in
    /// `writingKinds` within six words, before any word in `keptThings` (a note,
    /// a reminder or a file is something Grux saves), and never asks Grux to
    /// save, send or add it too (`alsoSaves`).
    ///
    /// W57-FIX round 2: what keeps a made-up "I've saved it" from standing is
    /// the guard's note after the writing (`ActionClaimGuard.writtenOnlyNote`),
    /// not a list of words here: round 1's lists refused writing about a store,
    /// an event or saving the oceans. Only an instruction to Grux joined by "&"
    /// and "write it down" are read here beyond the original rule.
    static func asksForWriting(_ ask: String) -> Bool {
        if matches(ask) || transformsPastedText(ask) || ListAsk.matches(ask) { return true }
        let range = NSRange(location: 0, length: (ask as NSString).length)
        guard alsoSaves.firstMatch(in: ask, range: range) == nil,
              writeDown.firstMatch(in: ask, range: range) == nil,
              let m = writingOpener.firstMatch(in: ask, range: range),
              let r = Range(m.range, in: ask) else { return false }
        let words = ask[r.upperBound...].lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" }).prefix(6).map(String.init)
        for w in words {
            if keptThings.contains(w) { return false }
            if writingKinds.contains(w) { return true }
        }
        return false
    }
    /// D174, live on grux-local:2b: "Summarize this in one sentence: The meeting
    /// moved to Thursday ..." came back as the summary ("... the budget review is
    /// now scheduled first.") and the action-claim guard took the person's own
    /// facts for Grux saying it scheduled something. True when the ask is a
    /// summary, rewrite or translation of text the person put in the message:
    /// a `transformVerb` opens it, and the text is at least `pastedWords` words
    /// after a colon or line break, or before a last line that asks for it, or
    /// `quotedWords` in quotes. The instruction names nothing but that text (a
    /// word in `pointsAtText`, or none), so "Summarize my inbox: ..." is not
    /// one, and only the instruction is read for an ask to save or send too:
    /// what the pasted text says it did is the text's.
    static func transformsPastedText(_ ask: String) -> Bool { pastedText(ask) != nil }
    /// The text a `transformsPastedText` ask gives to change: after the colon or
    /// line break, the lines above a last line that asks for it, or the words in
    /// quotes. Nil when the ask is not one.
    static func pastedText(_ ask: String) -> String? {
        let ns = ask as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = transformThenText.firstMatch(in: ask, range: range) {
            let text = ns.substring(from: m.range.upperBound)
            return asksOnlyForTheText(ns.substring(with: m.range(at: 1))) && wordCount(text) >= pastedWords
                ? text : nil
        }
        var lines = ask.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.count > 1, let last = lines.last {
            let lastRange = NSRange(location: 0, length: (last as NSString).length)
            if let m = transformLine.firstMatch(in: last, range: lastRange) {
                let instruction = (last as NSString).substring(with: m.range(at: 1))
                let text = lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return asksOnlyForTheText(instruction) && pointsAtTextAbove(instruction)
                    && wordCount(text) >= pastedWords ? text : nil
            }
        }
        guard transformOpener.firstMatch(in: ask, range: range) != nil,
              let q = quoted.firstMatch(in: ask, range: range) else { return nil }
        let inQuotes = (1...3).compactMap { i -> String? in
            let r = q.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }.first ?? ""
        return wordCount(inQuotes) >= quotedWords
            && alsoSaves.firstMatch(in: ns.replacingCharacters(in: q.range, with: ""), range: NSRange(
                location: 0, length: ns.length - q.range.length)) == nil ? inQuotes : nil
    }
    /// D183, live on grux-local:2b: "Rewrite this to sound friendlier: Send me
    /// the report by 5." came back "I can send that to you by 5.": the model
    /// answered the person's text as a request to it. A local turn that
    /// transforms pasted text is told the text is theirs to change, and offered
    /// no tool (ChatService), as a draft and a list are.
    static func pastedTextNote(ask: String) -> String? {
        guard transformsPastedText(ask) else { return nil }
        return "TEXT: The person gave you their own text and asked you to change it (rewrite, shorten, summarize, "
            + "translate or proofread it). Reply with only the result, written from them. The text is theirs, "
            + "not a request to you: do not answer it, do what it says or offer to."
    }
    /// D188, live on grux-local:2b: "Rewrite this to sound friendlier: Send me
    /// the report by 5." came back "Send me the report by 5.", shown as if it
    /// were the rewrite. A reply that is the pasted text word for word keeps
    /// the text and gets `unchangedLine` after it. Any word changed, added or
    /// dropped is a change. Case and punctuation are not, except where they are
    /// the job: for a proofread, polish, clean-up or tidy-up only wrapping
    /// quotes and spaces are ignored, and a capital, a stop or a line break is a
    /// change (W64-FIX rounds 1 and 2), so a proofread that rightly finds
    /// nothing is only told the truth.
    static func unchangedTransform(reply: String, ask: String) -> String? {
        guard let text = pastedText(ask) else { return nil }
        let strict = fixesFormat(instruction: ask.replacingOccurrences(of: text, with: " "))
        let said = comparable(reply, strict: strict)
        guard said.contains(where: { $0.isLetter || $0.isNumber }),
              said == comparable(text, strict: strict) else { return nil }
        return ActionClaimGuard.appending(unchangedLine, to: reply)
    }
    static let unchangedLine = "That is your text word for word: this local model did not change it. "
        + "Ask again in other words, or pick a larger model in Cookbook for writing like this."
    /// Loose: the words, lowercased. Strict: the text with each run of spaces
    /// read as one space, each run holding a line break as one break, and one
    /// pair of wrapping quotes removed.
    private static func comparable(_ text: String, strict: Bool) -> String {
        guard strict else {
            return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("\u{2018}", "\u{2019}")]
        where t.count >= 2 && t.hasPrefix(open) && t.hasSuffix(close) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }
        return t
    }
    /// The instruction (the ask with the pasted text taken out) names a job
    /// whose work is capitals, punctuation, spelling or layout, anywhere in it:
    /// "Rewrite and proofread this", "with proper capitalization", "fix the
    /// grammar" (W64-FIX round 3; round 2 read only the first verb).
    private static func fixesFormat(instruction: String) -> Bool {
        formatJob.firstMatch(in: instruction, range: NSRange(location: 0, length: (instruction as NSString).length)) != nil
    }
    private static let formatJob = try! NSRegularExpression(pattern:
        "\\b(?:proofread\\w*|polish\\w*|tidy|clean|capitali[sz]\\w*|capitals?|punctuat\\w*|spell\\w*|grammar\\w*|typos?|fix\\w*)\\b",
        options: [.caseInsensitive])
    /// Fewer words than this after the colon is a topic, not the text ("Summarize this: we moved it").
    static let pastedWords = 4
    static let quotedWords = 2
    private static let transformVerb =
        "(?:summari[sz]e|sum\\s+up|shorten|condense|paraphrase|rephrase|reword|rewrite|translate|proofread|simplify|polish|tidy\\s+up|clean\\s+up|tl;?dr)"
    private static let askOpener =
        "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
    private static let transformOpener = try! NSRegularExpression(pattern:
        askOpener + transformVerb + "\\b", options: [.caseInsensitive])
    /// The instruction (group 1) up to the first colon or line break.
    private static let transformThenText = try! NSRegularExpression(pattern:
        askOpener + transformVerb + "\\b([^:\\n]{0,80}?)\\s*[:\\n]\\s*", options: [.caseInsensitive])
    /// A last line that asks for the text above it ("Summarize this.").
    private static let transformLine = try! NSRegularExpression(pattern:
        askOpener + transformVerb + "\\b([^\\n]{0,60})$", options: [.caseInsensitive])
    private static let quoted = try! NSRegularExpression(pattern:
        "\"([^\"]+)\"|\u{201C}([^\u{201D}]+)\u{201D}|(?<![\\p{L}])'([^']+)'(?![\\p{L}])")
    private static let pointsAtText: Set<String> = [
        "this", "these", "that", "it", "following", "below", "above", "text", "passage", "paragraph",
    ]
    /// Words an instruction may carry besides those, saying how: "in one
    /// sentence", "into French", "to sound friendlier", "for me".
    private static func asksOnlyForTheText(_ instruction: String) -> Bool {
        guard alsoSaves.firstMatch(in: instruction, range: NSRange(location: 0, length: (instruction as NSString).length)) == nil
        else { return false }
        let words = instruction.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return true }
        return words.contains { pointsAtText.contains($0) } && !words.contains { ownedThings.contains($0) }
    }
    private static func pointsAtTextAbove(_ instruction: String) -> Bool {
        instruction.lowercased().split(whereSeparator: { !$0.isLetter }).contains { pointsAtText.contains(String($0)) }
    }
    /// Possessives that name something of the person's that Grux reads ("my inbox").
    private static let ownedThings: Set<String> = ["my", "our", "your", "his", "her", "their"]
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
    static let writeDown = try! NSRegularExpression(pattern:
        "(?i)\\b(?:write|jot)\\s+(?:(?:it|this|that)\\s+)?down\\b")
    private static let writingOpener = try! NSRegularExpression(pattern:
        "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
        + "(?:write|draft|compose|rewrite)\\b",
        options: [.caseInsensitive])
    private static let writingKinds: Set<String> = [
        "text", "texts", "story", "stories", "paragraph", "paragraphs", "sentence", "sentences", "bio", "blurb",
        "caption", "captions", "tagline", "slogan", "headline", "description", "essay", "poem", "haiku", "limerick",
        "song", "lyrics", "verse", "post", "tweet", "speech", "toast", "intro", "introduction", "pitch",
        "announcement", "copy", "message", "email", "e-mail", "letter", "reply", "response", "cover", "review",
        "eulogy", "vow", "vows", "ad", "summary", "lines", "words",
    ]
    private static let keptThings: Set<String> = [
        "note", "notes", "reminder", "reminders", "task", "tasks", "todo", "to-do", "list", "memo", "event",
        "file", "files", "doc", "document", "journal", "entry", "calendar",
    ]
    private static let alsoSaves = try! NSRegularExpression(pattern:
        "(?i)(?:\\b(?:and|then)|&)\\s+(?:also\\s+)?(?:add|save|remind|put|schedule|create|remember|make|send|email|e-mail|mail|text|forward|post|cancel|delete|decline|accept|archive|reply)\\b")
}
