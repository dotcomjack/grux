import Foundation

/// D175, live on grux-local:2b (sense pass 22, 9:25 PM Nov 5): "Make a packing
/// list for a weekend in Chicago" came back "I can't create a physical packing
/// list for you to print out. I can draft a digital checklist instead if you'd
/// like". A list the person asks Grux to write is text for them to read, like
/// a draft (`DraftAsk`): on a local turn it carries one line saying so, no
/// tool is offered, and the reply starts "Here is <the list asked for>:".
/// Measured on that turn's own prompt (`logs/d175/probe-*.txt`, five asks):
/// no line and no tool 6 of 15 lists, the line 11 of 15, the line and the
/// start 20 of 20.
enum ListAsk {

    /// True when the message asks Grux to write a list: a closed grammar,
    /// precision first (W50's lesson). The ask opens with "make", "create",
    /// "write", "draft", "compose", "build", "give me", "put together", "come
    /// up with" or "draw up" (after "please", "can you", "Grux,"), then "a" or
    /// "an", up to three words, and "list" or "checklist", and the list is one
    /// `span` names as writing, the whole message. Never one in all capitals
    /// or one that says "write it down".
    static func matches(_ ask: String) -> Bool { span(ask) != nil }

    /// "Here is a packing list for a weekend in Chicago:", the list said back
    /// up to the end of its first sentence with "for my" as "for your"; "Here is your
    /// list:" when that runs past `longestNamed` characters. nil when the ask
    /// is not a list.
    static func replyStart(ask: String) -> String? {
        guard let named = span(ask) else { return nil }
        let list = named.split(whereSeparator: \.isWhitespace).map { said($0) }.joined(separator: " ")
        return list.count > longestNamed ? "Here is your list:" : "Here is \(list):"
    }

    /// The reply's start as `ChatService` ends a local list turn with
    /// (`OpenAICompatBackend.prefilled` sends it only to an Ollama server).
    static func prefillMessage(ask: String) -> [String: Any]? {
        replyStart(ask: ask).map { ["role": "assistant", "content": $0, DraftAsk.prefillKey: true] }
    }

    /// The one line a local list turn carries. About 60 tokens, after the
    /// cache point, only on such a turn.
    static func localNote(ask: String) -> String? {
        guard matches(ask) else { return nil }
        return "LIST: The person asked you to write this list. Reply with the whole list now, one item per line, "
            + "as text for them to read or copy. Do not say you cannot, and do not offer to make it: write it. "
            + "It is not a task, note or reminder to save."
    }

    static let longestNamed = 80

    /// The list as the ask names it, from "a" or "an" to the end of the
    /// message, or nil when the ask is not a list.
    ///
    /// Wave 58 rounds 1 to 5 each found a list of the person's own things, or
    /// a list with an instruction beside it ("... and slack it to Sam", "...
    /// Slack Sam."), that word lists missed, and the turn lost the tool it
    /// needed. So both halves are closed. The list ask is the WHOLE message,
    /// one clause: no second sentence (a closing "please" or "thanks" aside),
    /// no comma, and no "and", "then", "so", "also", "plus", "&", "+" or "/"
    /// ("pros and cons" is one thing), so no instruction can sit beside it;
    /// a longer message goes to the model with its tools, which costs only
    /// the LIST line. And the list is named by a closed grammar: a kind before
    /// "list" (`kinds`: packing, shopping, moving); or a plain "list of" whose
    /// head (the words after "of" up to `headStops`) names a general thing
    /// (`heads`: ideas, names, tips, things) with no word in `now` (due, today,
    /// upcoming, installed) and not a set that exists (`ofASetThatExists`:
    /// "of the ...", "items in Sam's proposal"), which holds after a kind too;
    /// or a plain "list" or "checklist for" an occasion
    /// (`occasions`: trip, weekend, move, job). The words call for no tool
    /// group but the core (`ToolRelevance.groups`). On top of that, a person word
    /// (`theirOwn`) refuses, except "my", "our", "me" or "us" straight after
    /// "for" ("gift ideas for my dad"); so does a word in `readsData`, one in
    /// `acts` ("a shopping list to send to Sam") or one in `namesASource`
    /// ("tips from the PDF").
    private static func span(_ ask: String) -> String? {
        guard ask.contains(where: \.isLowercase) else { return nil }
        let ns = ask as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard DraftAsk.writeDown.firstMatch(in: ask, range: range) == nil,
              let m = shape.firstMatch(in: ask, range: range) else { return nil }
        let modifiers = tokens(ns.substring(with: m.range(at: 2)))
        let preposition = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3)).lowercased()
        var rest = ns.substring(from: m.range(at: 1).location)
        if let close = rest.range(of: closing, options: [.regularExpression, .caseInsensitive]) {
            rest.removeSubrange(close)
        }
        let one = rest.replacingOccurrences(of: "pros and cons", with: "prosconsphrase", options: .caseInsensitive)
        guard firstSentence(one) == one, !one.contains(where: { ",&+/\n".contains($0) }),
              joiner.firstMatch(in: one, range: NSRange(location: 0, length: (one as NSString).length)) == nil
        else { return nil }
        // Wave 58 round 6: the words pick no tool group beyond the core, by the
        // same rule that picks the turn's tools, so a list "from the standup",
        // "in the video" or "on the screen" keeps the tool that reads it.
        guard ToolRelevance.groups(for: .init(utterance: ask)) == [.core] else { return nil }
        let named = rest.trimmingCharacters(in: .whitespaces)
        let words = tokens(named)
        if words.contains(where: { readsData.contains($0) || acts.contains($0) || namesASource.contains($0) }) { return nil }
        for (i, w) in words.enumerated() where theirOwn.contains(w) {
            if forOnly.contains(w), i > 0, words[i - 1] == "for" { continue }
            return nil
        }
        let topic = preposition.flatMap { p in words.firstIndex(of: p).map { Array(words[($0 + 1)...]) } } ?? []
        let head = Array(topic.prefix { !headStops.contains($0) })
        // "with" and "about" name the list's contents as "of" does (wave 58 round 10).
        if ["of", "with", "about"].contains(preposition ?? ""), ofASetThatExists(topic, head: head) { return nil }
        if !modifiers.isEmpty {
            return modifiers.contains(where: { kinds.contains($0) }) ? named : nil
        }
        guard let preposition else { return nil }
        switch preposition {
        case "of":
            return head.contains(where: { heads.contains($0) }) ? named : nil
        case "for":
            return topic.contains(where: { occasions.contains($0) }) ? named : nil
        default:
            return nil
        }
    }

    /// A closing "please" or "thanks", and the punctuation that ends the ask.
    /// Never after "say" or "saying": "ways to say thanks" is the list.
    private static let closing =
        "(?:(?:\\s*[,.!?]\\s*|(?<!\\bsay)(?<!\\bsaying)\\s+)(?:please|thanks|thank you|thx)\\b)?[\\s.!?]*$"
    /// Wave 58 round 7: a list to write comes from nothing the person holds,
    /// so one that names a source ("tips from the PDF", "based on the
    /// forecast", "using the guide", "the following items") keeps its tools,
    /// whatever the source is called.
    private static let namesASource: Set<String> = [
        "from", "based", "using", "according", "attached", "above", "below", "following", "pasted", "uploaded",
        "shared", "sent", "received", "saved",
    ]
    /// Joins a second clause; "andSlack" too, typed with no space.
    private static let joiner = try! NSRegularExpression(pattern: "(?i)\\b(?:and|then|so|also|plus)(?:\\b|(?=[A-Z]))")

    /// Lowercased words, an apostrophe kept inside one ("i've").
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" })
            .map { String($0).trimmingCharacters(in: .init(charactersIn: "'")) }
    }

    /// Up to the first "?", "!", ";", line break, or "." that ends a sentence:
    /// followed by a space or the end, after a word that is not a title or a
    /// short form ("St. Louis", "Mr. Smith", "9 a.m.").
    private static func firstSentence(_ text: String) -> String {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if "?!;\n".contains(c) { return String(chars[..<i]) }
            if c == ".", i + 1 == chars.count || chars[i + 1].isWhitespace {
                var j = i
                while j > 0, chars[j - 1].isLetter || chars[j - 1] == "." { j -= 1 }
                let before = String(chars[j..<i]).lowercased()
                if !(before.contains(".") || shortForms.contains(before)) {
                    return String(chars[..<i])
                }
            }
            i += 1
        }
        return text
    }

    /// "my" said back as "your" (only after "for", see `span`).
    private static func said(_ raw: Substring) -> String {
        let w = String(raw).trimmingCharacters(in: .init(charactersIn: ","))
        switch w.lowercased() {
        case "my", "our": return "your"
        case "me", "us": return "you"
        default: return w
        }
    }

    private static let shape = try! NSRegularExpression(pattern:
        "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
        + "(?:make|create|write|draft|compose|build|give|put\\s+together|come\\s+up\\s+with|draw\\s+up)"
        + "(?:\\s+(?:me|us))?\\s+"
        + "((?:an?\\s+)((?:[\\w'\u{2019}\\-]+\\s+){0,3}?)(?:check)?list(?:\\s+(for|of|to|with|about)\\b|\\s*(?=[.?!,;]|$)))",
        options: [.caseInsensitive])

    private static let shortForms: Set<String> = [
        "st", "mr", "mrs", "ms", "dr", "mt", "ft", "jr", "sr", "vs", "etc", "no", "ave", "blvd", "rd", "prof", "approx",
    ]

    /// Words in the list that make it the person's own (Grux would have to
    /// read it), or Grux's ("things you can do"); `forOnly` of them are fine
    /// straight after "for".
    private static let theirOwn: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "we", "we're", "we've", "we'd", "we'll", "you", "your", "you're",
        "yours", "you've", "my", "our", "me", "us", "mine", "ours", "myself", "ourselves",
    ]
    private static let forOnly: Set<String> = ["my", "our", "me", "us"]

    /// Words after the list that ask Grux to do something with it.
    private static let acts: Set<String> = [
        "add", "save", "store", "put", "send", "email", "e-mail", "mail", "text", "remind", "schedule", "share",
        "post", "upload", "export", "forward", "attach", "sync", "pin", "remember", "create", "make", "capture",
        "keep", "push", "message", "imessage", "dm", "texting", "sending", "saving", "adding", "emailing", "doc",
    ]

    /// Kinds of list that are writing whatever follows ("a packing list for
    /// Chicago"). A word before "list" not here ("a to-do list", "a deadline
    /// list") leaves the ask with its tools.
    private static let kinds: Set<String> = [
        "packing", "shopping", "grocery", "groceries", "moving", "reading", "gift", "bucket", "wedding",
        "itinerary", "camping", "travel", "baby", "party", "holiday", "christmas", "honeymoon", "hiking", "beach",
        "ski", "dorm", "college", "back-to-school", "emergency", "cleaning", "chore", "chores", "picnic", "potluck",
        "vacation", "road-trip",
    ]
    /// What a "list of" names when it is writing ("a list of 10 dinner ideas").
    private static let heads: Set<String> = [
        "ideas", "idea", "names", "tips", "questions", "steps", "ways", "reasons", "pros", "cons", "places",
        "recipes", "activities", "games", "words", "synonyms", "examples", "facts", "things", "items", "essentials",
        "supplies", "ingredients", "snacks", "gifts", "chores", "goals", "books", "movies", "films", "shows",
        "podcasts", "destinations", "restaurants", "exercises", "habits", "hobbies", "jokes", "prompts", "topics",
        "options", "alternatives", "mistakes", "rules", "foods", "meals", "dishes", "outfits", "colors",
        "plants", "sights", "attractions", "dos", "don'ts", "suggestions", "slogans", "titles", "themes",
    ]
    /// Wave 58 rounds 8 to 10: a list to write is of things in general. A
    /// "list of", "with" or "about" (after a kind too: "a gift list of ...",
    /// "a grocery list with the ingredients in the recipe") that starts with
    /// "the", "this" or a possessive ("of the action items", "of Sam's
    /// ideas"), whose head sits straight "in" or "on" one ("action items in
    /// Sam's proposal", "names in that chat"), or that names a time or a
    /// state in `now`, is a set that exists, read by a tool. "Things to do in
    /// the city" is placed in the world, after "to do", and stays a list.
    private static func ofASetThatExists(_ topic: [String], head: [String]) -> Bool {
        if topic.contains(where: { now.contains($0) }) { return true }
        if let first = topic.first, ownedOrDefinite(first) { return true }
        guard head.count + 1 < topic.count, ["in", "on", "inside", "within"].contains(topic[head.count]) else { return false }
        return ownedOrDefinite(topic[head.count + 1])
    }
    private static func ownedOrDefinite(_ word: String) -> Bool {
        definite.contains(word) || word.hasSuffix("'s") || word.hasSuffix("s'")
    }
    private static let definite: Set<String> = [
        "the", "this", "that", "these", "those", "his", "her", "their", "its", "my", "our", "your",
    ]
    /// Where a "list of" head ends: "things | to do in Paris".
    private static let headStops: Set<String> = [
        "to", "for", "in", "at", "with", "that", "which", "from", "about", "on", "near", "by", "when", "while",
    ]
    /// Words that make a "list of" the state of something Grux reads.
    private static let now: Set<String> = [
        "due", "today", "today's", "tomorrow", "tomorrow's", "tonight", "tonight's", "yesterday", "yesterday's",
        "upcoming", "overdue", "pending", "open", "recent", "latest", "installed", "running", "scheduled", "unread",
        "current", "this", "next", "last", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "week's", "month's", "everything", "what", "what's", "who", "whom", "all",
    ]
    /// Occasions a plain "list for" or "checklist for" is written for.
    private static let occasions: Set<String> = [
        "trip", "weekend", "vacation", "holiday", "move", "moving", "wedding", "party", "camping", "hike", "hiking",
        "picnic", "day", "job", "interview", "baby", "newborn", "school", "college", "dorm", "flight", "travel",
        "birthday", "christmas", "thanksgiving", "visit", "apartment", "house", "home", "puppy", "garden", "race",
        "marathon", "honeymoon", "road", "beach", "cruise", "festival", "concert", "potluck", "barbecue", "bbq",
    ]

    /// Words naming something a tool reads, kept or plays: the list is the
    /// person's own, so it stays with the model and its tools.
    private static let readsData: Set<String> = [
        "meeting", "meetings", "task", "tasks", "todos", "event", "events", "calendar", "schedule",
        "appointment", "appointments", "email", "emails", "e-mail", "e-mails", "inbox", "mail", "messages",
        "texts", "note", "notes", "contact", "contacts", "reminder", "reminders", "file", "files",
        "document", "documents", "docs", "song", "songs", "track", "tracks", "playlist", "album", "albums",
        "memories", "photos", "bookmarks", "tabs", "slack", "whatsapp", "telegram", "imessage", "drive", "dropbox",
        "notion", "clipboard", "desktop", "icloud", "airdrop", "discord", "gmail", "outlook", "pdf", "pdfs", "resume",
        "contract", "contracts", "manual", "memo", "memos", "spreadsheet", "spreadsheets", "sheet", "sheets",
        "attachment", "attachments", "ebook", "slides", "slide", "deck", "doc", "page", "pages", "link", "links",
        "chapter", "chapters", "csv", "excel", "guide",
    ]
}
