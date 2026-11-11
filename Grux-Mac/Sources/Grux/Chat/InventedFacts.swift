import Foundation

/// D178, live on grux-local:2b (sense pass 22, and again 2026-11-06): writing
/// Grux was asked for about the person's own business ("a two sentence bio for
/// my coffee cart, starting with when I opened it") came back with a year, a
/// span of years and a street the person never gave: seven shops, each "in
/// 2024" and "on the corner of Elm and Main". A stranger pastes that onto
/// their site. An instruction line to use brackets left most years in place
/// and added refusals (`logs/d178/probe-v1.txt`, `-v2.txt`), and W53-FIX ruled
/// that a draft is never rewritten, so Grux names what it made up after the
/// writing, and the person, who knows the real year, puts it in.
enum InventedFacts {
    /// The numbers said as years, for counting spans: a 1600 to 2099 number
    /// that is not an order number, price, phone or house number ("#2041",
    /// "$2040", "555-2036", "2031 Elm Street"), judged by its neighbours and
    /// not its size. W59-FIX round 10: a five-year cap called "In twelve
    /// years" to 2038 made up; round 11: a hyphen rule dropped "1985-2020"
    /// and "mid-2019". Another year beside the hyphen makes a range.
    static func yearMarks(in raw: String) -> [Int] {
        // An en dash or a spaced hyphen between a year and a year or a
        // two-digit end is a range too (round 13 P3); beside a lone number
        // ("Founded 1985 - 3 generations") it is not, and the year stays.
        let text = raw.replacingOccurrences(
            of: #"(?<=\b\d{4})(?:\s*[\x{2013}\x{2014}]\s*|\s+-\s+)(?=(?:\d{2}|\d{4})\b)"#,
            with: "-", options: .regularExpression)
        let ns = text as NSString
        func isYear(_ s: String) -> Bool {
            s.count == 4 && year.firstMatch(in: s, range: NSRange(location: 0, length: 4)) != nil
        }
        func char(_ i: Int) -> String { i >= 0 && i < ns.length ? ns.substring(with: NSRange(location: i, length: 1)) : "" }
        func isDigit(_ i: Int) -> Bool { char(i).first?.isNumber ?? false }
        /// The run of digits ending at `i` (inclusive), or starting at `i`.
        func run(endingAt i: Int) -> String {
            var j = i
            while j >= 0, isDigit(j) { j -= 1 }
            return ns.substring(with: NSRange(location: j + 1, length: i - j))
        }
        func run(from i: Int) -> String {
            var j = i
            while j < ns.length, isDigit(j) { j += 1 }
            return ns.substring(with: NSRange(location: i, length: j - i))
        }
        return year.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { m -> [Int] in
            let start = m.range.location, end = m.range.location + m.range.length
            let before = char(start - 1), after = char(end)
            guard let value = Int(ns.substring(with: m.range)) else { return [] }
            if before == "#" || before == "$" { return [] }
            if [".", ",", "-"].contains(before) {
                let digits = run(endingAt: start - 2)
                if !digits.isEmpty && !(before == "-" && isYear(digits)) { return [] }
            }
            var also: [Int] = []
            if [".", ",", "-"].contains(after) {
                let digits = run(from: end + 1)
                // "1985-89", "2019-20", "2019-05-12": a range end or a date
                // (round 12); the end counts when later than the start.
                if after == "-", digits.count == 2, let yy = Int(digits) {
                    if yy > value % 100, char(end + 3) != "-" { also.append(value - value % 100 + yy) }
                } else if !digits.isEmpty && !(after == "-" && isYear(digits)) {
                    return []
                }
            }
            if ns.substring(from: end).range(of: #"^\s+(?:[A-Z][A-Za-z']*\s+)?(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr)\b"#,
                                            options: .regularExpression) != nil { return [] }
            return [value] + also
        }
    }

    /// A year a bio or a letter would state.
    private static let year = try! NSRegularExpression(pattern: "\\b(?:1[6-9]|20)\\d\\d\\b")
    /// "six years", "15 years": a span the model counts from a year it made up.
    private static let span = try! NSRegularExpression(pattern:
        "\\b(?:\\d{1,3}|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?|"
        + "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
        + "seventeen|eighteen|nineteen)\\s+years?\\b", options: [.caseInsensitive])
    private static let name = "[A-Z][A-Za-z']*"
    /// Words on one line: a line break never joins two names (W59-FIX P3).
    private static let gap = "[ \\t]+"
    /// "the corner of Elm and Main".
    private static let corner = try! NSRegularExpression(pattern:
        "\\b(?:the\(gap))?corner\(gap)of\(gap)\(name)(?:\(gap)\(name))?\(gap)and\(gap)\(name)(?:\(gap)\(name))?")
    /// "Maple Street", "12 Oak Street". Not "Way", "Court" or "Square": a
    /// slogan ("Coffee Your Way") reads as one (W59-FIX P3).
    private static let suffixes: Set<String> = ["street", "avenue", "road", "boulevard", "lane", "drive",
                                                "st", "ave", "rd", "blvd", "ln", "dr"]
    private static let street = try! NSRegularExpression(pattern:
        "\\b(?:\\d{1,5}\(gap))?\(name)(?:\(gap)\(name))?\(gap)(?:Street|Avenue|Road|Boulevard|Lane|Drive)\\b")
    /// Capitalized only because a sentence starts with them: "Now Main
    /// Street", "Our Maple Street cafe", "Visit us on Elm Street".
    private static let notPartOfAName: Set<String> = [
        "The", "On", "At", "In", "Now", "Near", "By", "From", "Off", "Just", "Our", "Your", "My", "Their", "Visit",
        "Find", "Come", "Welcome", "We", "I", "Stop", "Swing", "Located", "Join", "Here", "There",
    ]
    private static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                      "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                                      "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
                                      "nineteen": 19]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                               "eighty": 80, "ninety": 90]
    private static let ordinalWords = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                                       "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
                                       "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
                                       "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
                                       "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
                                       "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]

    /// Every number the text gives, in digits, words or ordinals ("40th",
    /// "ten", "fortieth", "10-year").
    static func numbers(in text: String) -> Set<Int> {
        var out: Set<Int> = []
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (i, t) in tokens.enumerated() {
            if let n = numberWords[t] ?? ordinalWords[t] ?? tens[t] { out.insert(n) }
            // "twenty-five", "twenty-fifth" (W59-FIX round 2).
            if let ten = tens[t], i + 1 < tokens.count, let one = numberWords[tokens[i + 1]] ?? ordinalWords[tokens[i + 1]],
               one < 10 {
                out.insert(ten + one)
            }
            let digits = t.prefix { $0.isNumber }
            let rest = t.dropFirst(digits.count)
            if !digits.isEmpty, rest.isEmpty || ["st", "nd", "rd", "th"].contains(String(rest)), let n = Int(digits) {
                out.insert(n)
            }
        }
        return out
    }

    /// A span's own number: "twenty-five years" is 25.
    static func value(ofSpan s: String) -> Int? { numbers(in: s).max() }

    /// The ask is about the person: their business, their landlord, in the first person.
    private static let aboutThePerson = try! NSRegularExpression(pattern:
        "\\b(?:my|our|i|we|me|us|mine|ours)\\b|\\bfirst\\s+person\\b", options: [.caseInsensitive])

    /// Whether the place was given as a place: its own name words next to a
    /// street word ("Elm St.", "12 Oak St", "Maple Street"), or a corner's two
    /// names joined ("Elm and Main"). A word given alone never is (W59-FIX
    /// round 2: "my farmers market stand" did not give "Market Street").
    private static func placeGiven(_ place: String, given: String) -> Bool {
        let words = place.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !notPartOfAName.contains($0) }.map { $0.lowercased() }
        if let corner = words.firstIndex(of: "corner") {
            // Both names, joined: "Elm & Main" and "Elm St. and Main St." give
            // "the corner of Elm and Main"; "the corner of Elm and Oak" does not
            // (W59-FIX round 3).
            let rest = Array(words[(corner + 1)...]).filter { $0 != "of" && !suffixes.contains($0) }
            guard let and = rest.firstIndex(of: "and") else { return false }
            let a = rest[..<and].joined(separator: " "), b = rest[(and + 1)...].joined(separator: " ")
            let plain = given.replacingOccurrences(of: "&", with: " and ")
                .replacingOccurrences(of: "\\b(?:" + suffixes.sorted().joined(separator: "|") + ")\\b\\.?", with: " ",
                                      options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return [a + " and " + b, b + " and " + a].contains { plain.contains($0) }
        }
        let core = words.filter { !suffixes.contains($0) && $0 != "the" }.joined(separator: " ")
        guard !core.isEmpty else { return false }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: core) + "\\s+(?:"
            + suffixes.sorted().joined(separator: "|") + ")\\b"
        return given.range(of: pattern, options: .regularExpression) != nil
    }

    /// The reply with one line after the writing naming each year, span of
    /// years or street that neither the ask nor the turn's context
    /// (`grounded`: the ask, the system prompt and the messages sent) gave, or
    /// nil when there is none or the ask is not for writing about the person.
    /// A span is named only when the ask gives no year: from "we opened in
    /// 1985", "40 years" is counted, not made up.
    ///
    /// Live 6:23 AM Nov 6: the 2B model copied this line from an earlier reply
    /// in the thread, naming 1985, which the ask gave; every copy is taken out
    /// first, and the reply comes back without it even when nothing is named.
    static func check(reply original: String, ask: String, grounded: String, personal: String? = nil,
                      now: Date = Date()) -> String? {
        let askRange = NSRange(location: 0, length: (ask as NSString).length)
        guard DraftAsk.asksForWriting(ask), aboutThePerson.firstMatch(in: ask, range: askRange) != nil else { return nil }
        let reply = withoutLine(original)
        // Only the writing: not a paragraph Grux added after it.
        let draft = ([ActionClaimGuard.approvalsPrefix, ActionClaimGuard.notDoneYet, ActionClaimGuard.writtenOnlyNote]
                     + ActionClaimGuard.olderWrittenOnlyNotes)
            .compactMap { reply.range(of: $0)?.lowerBound }.min().map { String(reply[..<$0]) } ?? reply
        let given = grounded.lowercased()
        let ns = draft as NSString
        let all = NSRange(location: 0, length: ns.length)
        var made: [String] = []
        func add(_ s: String) { if !made.contains(s) { made.append(s) } }
        // Only what the person and the tools gave: the prompt's own numbers
        // ("1 to 3 short sentences", the clock) give no span (W59-FIX round 2).
        let givenNumbers = numbers(in: personal ?? grounded)
        let givenMarks = Set(yearMarks(in: grounded))
        for m in year.matches(in: draft, range: all) {
            let y = ns.substring(with: m.range)
            // "since '85" gave 1985.
            let short = String(y.suffix(2))
            // A range end written out ("2010-15" gave 2015, round 13).
            if !given.contains(y), !given.contains("'" + short), !given.contains("\u{2019}" + short),
               !givenMarks.contains(Int(y) ?? 0) { add(y) }
        }
        // A span is given when its number was, or when it counts from a year
        // the person gave anywhere (this message, an earlier one, memory, a
        // tool result): now minus that year, one either side ("opened it in
        // 2019", then "for seven years"). W59-FIX round 7: a year anywhere
        // switching every span check off let "30 years" and a rent of "$1850"
        // through.
        let spoken = personal ?? ask
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let givenYears = yearMarks(in: spoken)
        for m in span.matches(in: draft, range: all) {
            let s = ns.substring(with: m.range)
            // Between any two of the given years and this one: back from now,
            // ahead to a year given, or between two given (round 8).
            let marks = Set(givenYears + [thisYear])
            guard let n = value(ofSpan: s), !givenNumbers.contains(n),
                  !marks.contains(where: { a in marks.contains { b in a > b && abs(a - b - n) <= 1 } }) else { continue }
            if !made.contains(where: { value(ofSpan: $0) == n && span.firstMatch(in: $0, range:
                NSRange(location: 0, length: ($0 as NSString).length)) != nil }) { add(s) }
        }
        for regex in [corner, street] {
            for m in regex.matches(in: draft, range: all) {
                var words = ns.substring(with: m.range).split(separator: " ").map(String.init)
                while let first = words.first, notPartOfAName.contains(first) { words.removeFirst() }
                let place = words.joined(separator: " ")
                guard !placeGiven(place, given: given),
                      !made.contains(where: { $0.contains(place) || place.contains($0) }) else { continue }
                add(place)
            }
        }
        guard !made.isEmpty else { return reply == original ? nil : reply }
        let list = made.count == 1 ? made[0]
            : made.dropLast().joined(separator: ", ") + " or " + made[made.count - 1]
        let line = linePrefix + "\(list), so I made "
            + (made.count == 1 ? "it" : "them") + " up."
        return ActionClaimGuard.appending(line, to: reply)
    }

    static let linePrefix = "Check this before you use it: you did not give "
    private static let copiedLine = try! NSRegularExpression(pattern:
        "\\s*" + NSRegularExpression.escapedPattern(for: linePrefix) + "[^\\n]*?, so I made (?:it|them) up\\.")

    /// The reply with every copy of the line taken out, paragraphs kept apart.
    static func withoutLine(_ reply: String) -> String {
        let ns = reply as NSString
        let out = copiedLine.stringByReplacingMatches(in: reply, range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "\n\n")
        guard out != reply else { return reply }
        return out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the person and the tools gave this turn, for numbers: the ask,
    /// the person's messages (what follows Grux's context label on the newest
    /// one) and tool results; never the system prompt or Grux's context block.
    static func personal(ask: String, messages: [[String: Any]], systemBlocks: [[String: Any]] = []) -> String {
        var out = [ask] + systemBlocks.compactMap { $0["text"] as? String }.map(memoryLines)
        for m in messages where (m["role"] as? String) == "user" {
            if let text = m["content"] as? String {
                out.append(text.components(separatedBy: userMessageMarker).last ?? text)
            } else if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks {
                    if (b["type"] as? String) == "tool_result" {
                        if let c = b["content"] as? String { out.append(c) }
                    } else if let t = b["text"] as? String {
                        out.append(t.components(separatedBy: userMessageMarker).last ?? t)
                    }
                }
            }
        }
        return out.joined(separator: "\n")
    }
    static let userMessageMarker = "THE USER'S MESSAGE:"

    /// The lines under a memory or profile header in a system block
    /// (RELEVANT_MEMORIES, RECENT_SPOKEN_MEMORIES, PENDING_MEMORIES,
    /// LONG_TERM_FACTS_ABOUT_USER, PERSON_CONTEXT): what the person told Grux,
    /// never the header itself ("last 20 min") or the prompt's own text
    /// (W59-FIX round 3: "I've been baking for 15 years" in memory gave 15 years).
    static func memoryLines(_ block: String) -> String {
        var keep = false
        var out: [String] = []
        for line in block.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = t.range(of: #"^[A-Z][A-Z_]{3,}(?=[\s(:])"#, options: .regularExpression), t.contains(":") {
                let header = String(t[m])
                keep = ["MEMORIES", "FACTS", "PERSON_CONTEXT"].contains { header.contains($0) }
                continue
            }
            // A row's own numbering and stamp are Grux's, not the person's
            // ("  1. [fact · Nov 3, 14:05] ...", "  • [Nov 4 7:12 PM] ...",
            // W59-FIX round 4).
            if keep {
                out.append(t.replacingOccurrences(of: #"^(?:\d+\.|[•\-*])?\s*(?:\[[^\]]*\]\s*)?"#, with: "",
                                                  options: .regularExpression)
                    // A person card's own count and date (round 5 P3).
                    .replacingOccurrences(of: #"\((?:mentioned|last)\b[^)]*\)"#, with: "", options: .regularExpression))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Every text the turn sent that is not the model's own: the ask, the
    /// system blocks and the person's messages with the tool results they
    /// carry, so a year Grux remembers or read for the person counts as given.
    /// Never an earlier assistant reply: the 2B model copies its own made-up
    /// "2024" from the thread, and that is not the person giving it.
    static func grounded(ask: String, systemBlocks: [[String: Any]], messages: [[String: Any]]) -> String {
        var out = [ask]
        func collect(_ value: Any) {
            if let s = value as? String { out.append(s) }
            else if let d = value as? [String: Any] { d.values.forEach(collect) }
            else if let a = value as? [Any] { a.forEach(collect) }
        }
        systemBlocks.forEach { collect($0) }
        messages.filter { ($0["role"] as? String) != "assistant" }.forEach { collect($0["content"] ?? "") }
        return out.joined(separator: "\n")
    }
}
