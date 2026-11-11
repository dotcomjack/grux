import Foundation

/// D164, sense pass 20 on grux-local:2b: "Write a note to Day One about today"
/// got "I have not done that. Want me to?" and "Write a note to Joplin about the
/// recipe" got "I can't write notes directly to your specific app like Joplin.
/// You'll have to..." with no note at all. Grux writes to no notes app but its
/// own (Notion only through its push tools, so Notion is not named here). A line
/// telling the model to write the note out was tried first: measured on this
/// Mini, grux-local:2b refused in 12 of 12 calls across two wordings, with and
/// without the thread's history, and where it wrote anything for "about today"
/// it made up the weather. So Grux answers the ask itself, with no model: the
/// words the person gave are written out to paste in, with the offer to keep
/// them in Grux's Notes; an ask with no words ("about the recipe") is told how
/// to send them (W53-FIX: never by reading the next message as the note).
enum ForeignNoteAsk {

    struct Ask: Equatable {
        /// The app as it spells itself ("Day One").
        let app: String
        /// What the note is about ("the recipe"), when the ask says.
        let topic: String?
        /// The note's own words, when the ask gives them.
        let words: String?
    }

    /// The ask, when it puts a note in a notes app Grux cannot write to. A
    /// closed grammar, precision first (iteration 104's lesson): it opens with
    /// "write", "make", "add", "jot down" and the like (after "please", "can
    /// you", "Grux,"), names a note, entry, page or memo, puts it "to", "in",
    /// "into" or "on" an app in `apps` (after "my" or "the"), and the app's name
    /// ends there: at the end, at punctuation, after "app", or before a word in
    /// `connectors`. An app whose name is an everyday word ("Bear", "Day One",
    /// "Reflect") counts only when capitalized, so "a note to bear in mind" is
    /// not one. A message to a person (`DraftAsk`), a compound ask ("and remind
    /// me") is left to the model.
    static func match(_ ask: String) -> Ask? {
        let ns = ask as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = shape.firstMatch(in: ask, range: range) else { return nil }
        // Only the ask before the words is read for a second ask: the note's
        // own words may say "and make dinner" (wave 53 review round 3).
        let colon = wordsColon.firstMatch(in: ask, range: NSRange(location: m.range.upperBound,
                                                                   length: ns.length - m.range.upperBound))
        let head = colon.map { ns.substring(to: $0.range.location) } ?? ask
        if alsoDoes.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) != nil
            || DraftAsk.matches(head) { return nil }
        let said = ns.substring(with: m.range(at: 1))
        let key = said.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let app = apps[key] else { return nil }
        if commonWords.contains(key), said.first?.isUppercase != true { return nil }
        var rest = ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespaces)
        var topic: String?
        if let t = topicOpener.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            let after = (rest as NSString).substring(from: t.range.upperBound)
            // The colon that opens the words is followed by a space, a tab, a
            // new line or the end, so "the 3:30 call" stays whole (wave 53
            // review, P3) and a list typed on the lines below is the words.
            let trimmed = after.trimmingCharacters(in: .whitespaces)
            let tns = trimmed as NSString
            if let colon = wordsColon.firstMatch(in: trimmed, range: NSRange(location: 0, length: tns.length)) {
                topic = clean(tns.substring(to: colon.range.location))
                rest = ":" + tns.substring(from: colon.range.location + colon.range.length)
            } else {
                topic = clean(trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : trimmed)
                rest = ""
            }
        }
        var words: String?
        if let w = wordsOpener.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            words = clean((rest as NSString).substring(from: w.range.upperBound))
        }
        return Ask(app: app, topic: topic, words: words)
    }

    /// The whole reply for `ask`, or nil when it is not one.
    ///
    /// W53-FIX: an ask with no words used to make the NEXT message the note,
    /// and two review rounds found commands and changes of mind it took
    /// ("Remind me to call the vet at 5", "Mark the dentist task as done",
    /// "nvm"), plus a saved thread's first message days later. No word list
    /// tells a note from an ask, so nothing after the ask is read as a note:
    /// Grux says how to send the words, in the one shape `match` reads.
    static func reply(for ask: String) -> String? {
        guard let m = match(ask) else { return nil }
        guard let words = m.words else { return askForWords(app: m.app, topic: m.topic) }
        return note(app: m.app, topic: m.topic, words: words)
    }

    /// The note written out, and what a yes would do.
    static func note(app: String, topic: String?, words: String) -> String {
        let title = topic.map { "\(capitalized($0))\n" } ?? ""
        return "Here is your note for \(app), to paste in:\n\n\(title)\(words)\n\n\(offer(app: app))"
    }

    static func offer(app: String) -> String {
        "Grux can't write to \(app). Want me to keep this note in Grux's Notes too?"
    }

    /// The words go after a colon in the same ask, which `match` reads, so
    /// the example is one that matches.
    static func askForWords(app: String, topic: String?) -> String {
        let about = topic.map { " about \($0)" } ?? ""
        return "Grux can't write to \(app), but it can write the note out for you to paste in, or keep it in Grux's Notes. "
            + "Send the words after a colon, like \"Write a note to \(app)\(about): your words\"."
    }

    private static func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = t.last, c == "." || c == "!" || c == "?" { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Lowercased, single-spaced name to the app's own spelling.
    private static let apps: [String: String] = Dictionary(uniqueKeysWithValues: [
        "Day One", "Joplin", "Apple Notes", "Obsidian", "Evernote", "Bear", "OneNote", "Simplenote", "Logseq",
        "Roam", "Roam Research", "Craft", "Anytype", "Ulysses", "Drafts", "Google Keep", "Standard Notes",
        "UpNote", "NotePlan", "Agenda", "Reflect", "Capacities", "Heptabase", "GoodNotes", "Notability",
    ].map { ($0.lowercased(), $0) })

    /// Apps named by an everyday word: only an app when capitalized.
    private static let commonWords: Set<String> = ["day one", "bear", "roam", "craft", "drafts", "agenda", "reflect", "capacities"]

    /// Words that end the app's name and start what the note is about or says.
    private static let connectors = [
        "about", "on", "for", "saying", "that", "with", "re", "regarding", "of", "listing", "to", "called", "titled", "named",
    ]

    private static let shape: NSRegularExpression = {
        let names = apps.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        return try! NSRegularExpression(pattern:
            "^\\s*(?:(?:hey\\s+)?grux[,:]?\\s+)?(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?)?"
            + "(?:write|make|take|jot(?:\\s+down)?|add|save|put|create|start|keep)\\s+(?:me\\s+)?(?:an?\\s+|the\\s+)?"
            + "(?:(?:short|quick|brief|new|little),?\\s+)*(?:note|journal\\s+entry|entry|page|memo)\\s+"
            + "(?:to|in|into|on)\\s+(?:my\\s+|the\\s+)?(\(names))(?:\\s+app)?"
            + "(?=\\s*$|\\s*[,:;.!?]|\\s+(?:\(connectors.joined(separator: "|")))\\b)",
            options: [.caseInsensitive])
    }()

    /// The colon between what a note is about and its words: followed by
    /// white space (a new line too) or the end.
    private static let wordsColon = try! NSRegularExpression(pattern: ":(?=\\s|$)")

    /// Opens what the note is about: up to a colon, the rest is its words.
    private static let topicOpener = try! NSRegularExpression(pattern:
        "^,?\\s*(?:about|on|for|re|regarding|of|called|titled|named)\\s+", options: [.caseInsensitive])
    /// Opens the note's own words.
    private static let wordsOpener = try! NSRegularExpression(pattern:
        "^,?\\s*(?::|(?:saying|that|with|listing|to\\s+say)\\b:?)\\s*", options: [.caseInsensitive])

    /// The ask also wants something else done, which needs the model's tools.
    private static let alsoDoes = try! NSRegularExpression(pattern:
        "(?i)\\b(?:and|then)\\s+(?:also\\s+)?(?:add|save|remind|put|schedule|create|remember|make|send|email|e-mail|mail|text|forward|post|open)\\b")
}
