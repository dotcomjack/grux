import Foundation

/// A place a weather question is answered for: the name shown in the reply
/// and the coordinates the forecast is asked for.
struct WeatherPlace: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
}

/// D141, live 2026-11-02 5:09 PM on qwen3.5:4b: "What's the weather like where
/// I am today?" came back "I don't know your location, so I can't check the
/// weather for you." Grux had no weather path at all, web research needs a key,
/// and Location is a permission a first run does not ask for. A plain weather
/// question is answered here, before any model sees the turn, the way the
/// calendar ask is: from Open-Meteo, which needs no key and no account. Only the
/// place leaves the Mac (the name the person typed, then two rounded
/// coordinates), and the place is remembered, so "the weather" asks for it
/// again; every reply names it, so a wrong one is seen and changed by naming
/// another. Anything that is not a plain weather question stays with the model.
/// Offline mode does not stop it: that switch keeps chat off hosted models (the
/// first run turns it on for everyone who picks Grux Local), and a forecast is
/// not a model, the same as the update check, which also runs under it.
@MainActor
enum WeatherAsk {

    enum Day: Equatable {
        case today, tomorrow
        /// `Calendar` numbering: 1 is Sunday, 7 is Saturday.
        case weekday(Int)
        /// The coming Saturday and Sunday, or what is left of them (D148).
        case weekend
        /// Every day the forecast holds (D148).
        case week
    }

    /// The hours asked about inside the day, answered from the hourly
    /// forecast rather than the whole day (D146 item 1).
    enum Window: Equatable {
        /// From the hour it is now through `hours` more; a span in minutes is one hour.
        case next(hours: Int)
        /// Clock hours at the place on the day asked, `from` up to `to` (24 is midnight).
        case hours(from: Int, to: Int)
        /// From the hour it is now to midnight.
        case restOfDay
    }

    struct Ask: Equatable {
        /// The place as the person wrote it, lowercased; nil means "where I am".
        let place: String?
        let day: Day
        var window: Window? = nil
        /// The place answers Grux's own "Which city are you in?".
        var answering: Bool = false
        /// A spot people mean as "near me" ("at the beach", "to the park"):
        /// the saved city answers, and the reply says so (D154).
        var nearby: Bool = false
    }

    struct Outcome {
        let reply: String
        /// A place to remember, when the person named one that is not the remembered one.
        let remember: WeatherPlace?
    }

    /// D154, the class fix for D153: a weather ask the fast path leaves to a
    /// local model ("Any rain for my picnic?") carries this one line in the
    /// turn's own block, so the model says how to ask instead of "I can't
    /// check the weather"; `WeatherClaimGuard` stays as the backstop. Only on
    /// a turn whose words name the weather, so an everyday turn reads no more
    /// tokens (about 75 when it rides, after the cache point, D114).
    static func localNote(ask: String, remembered: WeatherPlace?) -> String? {
        let range = NSRange(location: 0, length: (ask as NSString).length)
        guard weatherAsked.firstMatch(in: ask, range: range) != nil else { return nil }
        let how = remembered.map { "\u{201C}What's the weather?\u{201D} (for \($0.name), their saved city)" }
            ?? "\u{201C}What's the weather in\u{201D} and a city"
        return "WEATHER: Grux reads the 7-day forecast from Open-Meteo itself when the person asks "
            + how + ". You cannot read it: never make up a forecast (one Grux gave above may be repeated) "
            + "and never say you cannot check the weather; tell them to ask that way."
    }
    /// Not "forecast" alone ("the Q3 sales forecast") nor "hail" ("a Hail
    /// Mary"): "the weather forecast" still names the weather (W51-FIX).
    private static let weatherAsked = try! NSRegularExpression(pattern: "(?i)\\b(?:weather|rain|raining|rainy"
        + "|snow|snowing|snowy|umbrella|storms?|stormy|thunderstorms?|drizzle|sleet)\\b")

    static let askForCity = "Which city are you in? Tell me and I'll look up the weather on Open-Meteo, "
        + "a free weather service. Only the city name leaves your Mac, and I'll remember it for next time."

    /// The network, a seam for tests. The live one keeps nothing (no cookies,
    /// no cache, no saved credentials) and answers with the body and status.
    static var fetch: (URLRequest) async throws -> (Data, Int) = { request in
        let session = URLSession(configuration: WeatherAsk.sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - The match

    private static let leadIns = [
        "hey grux", "ok grux", "okay grux", "grux", "please", "can you tell me", "could you tell me",
        "can you check", "could you check", "tell me", "check", "show me", "give me",
    ]
    private static let openers = [
        "what's the weather forecast", "what is the weather forecast", "whats the weather forecast",
        "what's the weather", "what is the weather", "whats the weather",
        "how's the weather", "how is the weather", "hows the weather",
        "what's the forecast", "what is the forecast", "whats the forecast",
        "the weather forecast", "weather forecast", "the weather", "the forecast", "weather", "forecast",
        "will it rain", "is it going to rain", "is it gonna rain", "is it raining",
        "will it snow", "is it going to snow", "is it gonna snow", "is it snowing",
        "do i need an umbrella", "do i need a jacket", "do i need a coat",
        // D154: "Should I bring an umbrella to the park?"
        "should i bring an umbrella", "should i take an umbrella", "should i bring a jacket",
        "should i take a jacket", "should i bring a coat", "should i take a coat",
    ].sorted { $0.count > $1.count }
    /// Words that change nothing about the answer.
    private static let fillers = [
        "going to be like", "gonna be like", "going to be", "gonna be", "be like", "like", "looking",
        "right now", "at the moment", "now", "outside", "out", "please",
        // Times inside the day asked about (W43-FIX round 3: "at all" named a
        // village in Spain).
        "at all", "at some point", "in a bit", "in a while",
        "any time soon", "anytime soon", "soon",
    ]
    /// "in two hours", "in half an hour", "over the next few hours": inside
    /// today, never a place (W43-FIX round 5, W43-P3 item 1). Each with its
    /// length in minutes.
    private static let timeSpans: [(phrase: String, minutes: Double)] = {
        let counts: [(String, Double)] = [
            ("a couple of", 2), ("a couple", 2), ("a few", 3), ("half an", 0.5), ("half a", 0.5), ("couple of", 2),
            ("few", 3), ("a", 1), ("an", 1), ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5),
            ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10), ("eleven", 11), ("twelve", 12),
            ("fifteen", 15), ("twenty", 20), ("thirty", 30), ("forty five", 45), ("forty-five", 45),
        ]
        let units: [(String, Double)] = [("minute", 1), ("minutes", 1), ("hour", 60), ("hours", 60)]
        let leads = ["in", "in the next", "over the next", "within the next"]
        let counted = leads.flatMap { lead in
            counts.flatMap { n, count in units.map { u, size in ("\(lead) \(n) \(u)", count * size) } }
        }
        // "in the next hour", with no count.
        let one = leads.dropFirst().flatMap { lead in
            units.filter { !$0.0.hasSuffix("s") }.map { u, size in ("\(lead) \(u)", size) }
        }
        return (counted + one).sorted { $0.phrase.count > $1.phrase.count }
    }()
    /// The same in digits ("in 2 hours", "in 30 mins", "in the next 3 hrs"), up
    /// to 12 hours or 120 minutes. Longer goes to the model: 13 hours from now
    /// may be tomorrow.
    private static let digitSpan = try! NSRegularExpression(
        pattern: #"^(?:in|in the next|over the next|within the next) (\d{1,3}) ?(minutes?|mins?|hours?|hrs?)(?=$|[ ,])"#)
    /// The longest span answered here, spelled out or in digits (W44-P3 item 3).
    private static let longestSpanMinutes: Double = 12 * 60

    private enum SpanRead { case none, hours(Int), tooFar }

    /// A time span at the front of `s`, consumed, as whole hours from now.
    private static func consumeTimeSpan(from s: inout String) -> SpanRead {
        func read(_ minutes: Double) -> SpanRead {
            minutes > longestSpanMinutes ? .tooFar : .hours(max(1, Int((minutes / 60).rounded(.up))))
        }
        for span in timeSpans where consume(span.phrase, from: &s) { return read(span.minutes) }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = digitSpan.firstMatch(in: s, range: range),
              let countRange = Range(m.range(at: 1), in: s), let unitRange = Range(m.range(at: 2), in: s),
              let count = Int(s[countRange]), count > 0,
              count <= (s[unitRange].hasPrefix("m") ? 120 : 12),
              let whole = Range(m.range, in: s) else { return .none }
        let minutes = Double(count) * (s[unitRange].hasPrefix("m") ? 1 : 60)
        s = String(s[whole.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return read(minutes)
    }
    /// Ways of saying "where I am".
    private static let heres = [
        "where i am", "where i'm at", "where i live", "around here", "near me", "around me",
        "in my area", "for my area", "at my location", "in my city", "here",
    ]
    /// The parts of a day, by the clock at the place.
    private static let partsOfDay: [(word: String, from: Int, to: Int)] = [
        ("morning", 6, 12), ("afternoon", 12, 17), ("evening", 17, 21), ("night", 18, 24),
    ]
    private static func todayWord(_ part: String) -> String { part == "night" ? "tonight" : "this \(part)" }
    private typealias DayPhrase = (phrase: String, window: Window?)
    // Built in typed steps, the same phrases in the same order as before: one
    // expression of maps and concatenations took Swift 6.1 (Xcode 16) past its
    // type-check limit (public CI run 43027688522).
    private static let todays: [DayPhrase] = {
        var phrases: [DayPhrase] = []
        for part in partsOfDay {
            phrases.append((todayWord(part.word), Window.hours(from: part.from, to: part.to)))
        }
        // "later tonight" narrows "later" to the part named (W45-FIX), and
        // so do "later on tonight" and "later in the evening" (W45-P3).
        for part in partsOfDay {
            let window: Window? = Window.hours(from: part.from, to: part.to)
            for prefix in ["later ", "later on "] {
                phrases.append((prefix + todayWord(part.word), window))
            }
            phrases.append(("later in the " + part.word, window))
        }
        let rest: [DayPhrase] = [("later today", .restOfDay), ("later on today", .restOfDay), ("today", nil),
                                 ("later on", .restOfDay), ("later", .restOfDay)]
        phrases += rest
        return phrases.sorted { $0.0.count > $1.0.count }
    }()
    private static let tomorrows: [(phrase: String, window: Window?)] = (
        partsOfDay.map { ("tomorrow \($0.word)", Window.hours(from: $0.from, to: $0.to)) } + [("tomorrow", nil)]
    ).sorted { $0.0.count > $1.0.count }
    /// Days the seven-day forecast holds whole: "this weekend", "the rest of
    /// the week" (D148). "Next weekend" and "next week" may lie past it, so
    /// they stay with the model.
    private static let spans: [(phrase: String, day: Day)] = [
        ("this coming weekend", .weekend), ("over the weekend", .weekend), ("this weekend", .weekend),
        ("the weekend", .weekend), ("the rest of this week", .week), ("the rest of the week", .week),
        ("the week ahead", .week), ("this week", .week),
    ].sorted { $0.0.count > $1.0.count }
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    /// Words after a comma that are never a state or country.
    private static let dayTokens: Set<String> = ["today", "tonight", "tomorrow", "later", "please", "this", "next"]
    /// Words that end a place: a day, a filler, or another clause.
    private static let placeStops: Set<String> = [
        "today", "tonight", "tomorrow", "this", "later", "like", "right", "now", "on", "for", "in", "at",
        "and", "or", "but", "going", "gonna", "be", "please", "next", "during", "over",
    ]

    private static func normalized(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let last = s.last, "?.!".contains(last) { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// Drops `prefix` and the space or comma after it, when `s` starts with it as whole words.
    private static func consume(_ prefix: String, from s: inout String) -> Bool {
        guard s.hasPrefix(prefix) else { return false }
        let rest = s.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "," else { return false }
        s = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return true
    }

    private static func consumeAny(_ options: [String], from s: inout String) -> String? {
        for o in options where consume(o, from: &s) { return o }
        return nil
    }

    /// A day named at the front of `s` ("tomorrow", "on friday", "for today"), consumed.
    /// Each lead is tried, and none, so "this evening" is not read as "evening"
    /// after "this" (W43-P3).
    private static func consumeDay(from s: inout String) -> (day: Day, window: Window?)? {
        for lead in ["", "on this", "for this", "on", "for", "this"] {
            var t = s
            guard lead.isEmpty || consume(lead, from: &t) else { continue }
            for d in tomorrows where consume(d.phrase, from: &t) { s = t; return (.tomorrow, d.window) }
            for d in todays where consume(d.phrase, from: &t) { s = t; return (.today, d.window) }
            for d in spans where consume(d.phrase, from: &t) { s = t; return (d.day, nil) }
            if let name = consumeAny(weekdayNames, from: &t), let i = weekdayNames.firstIndex(of: name) {
                s = t
                return (.weekday(i + 1), nil)
            }
        }
        return nil
    }

    /// The place a weather question is about and the day, or nil for anything
    /// that is not a plain weather question. Fails toward the model: a miss
    /// costs one model turn, a false match answers a question nobody asked.
    static func match(_ text: String) -> Ask? {
        var s = normalized(text)
        let lastTyped = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
            .split(separator: " ").last.map(String.init)
        while consumeAny(leadIns, from: &s) != nil {}
        guard consumeAny(openers, from: &s) != nil else { return nil }
        var place: String?
        var day: Day?
        var window: Window?
        var sawHere = false
        var sawSpan = false
        var nearby = false
        while !s.isEmpty {
            if consumeAny(heres, from: &s) != nil {
                guard place == nil else { return nil }
                sawHere = true
                continue
            }
            if let d = consumeDay(from: &s) {
                guard day == nil || day == d.day else { return nil }
                day = d.day
                if let w = d.window {
                    // "this evening in 2 hours" asks two things at once.
                    guard window == nil || window == w else { return nil }
                    window = w
                }
                continue
            }
            switch consumeTimeSpan(from: &s) {
            case .tooFar: return nil
            case .hours(let n):
                guard window == nil else { return nil }
                window = .next(hours: n)
                sawSpan = true
                continue
            case .none: break
            }
            if consumeAny(fillers, from: &s) != nil { continue }
            if let lead = consumeAny(["in", "for", "at", "to"], from: &s) {
                guard place == nil, !sawHere, !nearby else { return nil }
                var words: [String] = []
                let all = s.split(separator: " ").map(String.init)
                for (i, word) in all.enumerated() {
                    let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    // The word right after a comma is a state or country,
                    // whatever else it is ("Portland, OR", "Toronto, ON").
                    // Only the first comma's word is forced in ("Portland, ME, on Friday").
                    let afterComma = (words.last?.hasSuffix(",") ?? false)
                        && words.filter { $0.hasSuffix(",") }.count == 1
                    // A code that is also a stop ("Toronto ON", "Portland OR") is the
                    // place's last word when nothing follows it (W43-P3 item 2);
                    // "Ottawa on Friday" still ends the place at "on". Only after
                    // words that read as a name: "for the game on" is cut off,
                    // not in Ontario (W44-P3 item 5).
                    // A name may start with "The" ("The Dalles OR") when the code
                    // is typed as a code, in capitals (W45-P3 item 5).
                    let lastCode = i == all.count - 1 && !words.isEmpty
                        && (usStates[bare] != nil || regionCodes[bare] != nil)
                        && (readsAsAName(words.joined(separator: " "))
                            || (lastTyped == bare.uppercased() && readsAsTheName(words)))
                    if !afterComma, !lastCode, placeStops.contains(bare) || weekdayNames.contains(bare) { break }
                    // ... unless it is a day or "please" ("Boston, MA, tomorrow").
                    if afterComma, dayTokens.contains(bare) || weekdayNames.contains(bare) { break }
                    words.append(word)
                }
                let typed = words.joined(separator: " ")
                let bare = typed.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
                let spot = bare.hasPrefix("the ") ? String(bare.dropFirst(4)) : bare
                if nearbySpots.contains(spot) {
                    nearby = true
                } else {
                    // "to" leads only a spot: "an umbrella to work" is not a place.
                    guard lead != "to", let found = plausiblePlace(typed) else { return nil }
                    place = found
                }
                s = String(s.dropFirst(typed.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                continue
            }
            return nil
        }
        // "in 2 hours tomorrow" asks two things at once.
        guard !sawSpan || (day ?? .today) == .today else { return nil }
        return Ask(place: place, day: day ?? .today, window: window, nearby: nearby)
    }

    /// Spots people mean as "near me", never sent to the geocoder (Beach,
    /// North Dakota is a city): the saved city answers, and says so (D154).
    /// Events ("the game", "the wedding") may be anywhere, so they stay with
    /// the model.
    private static let nearbySpots: Set<String> = ["beach", "park", "airport", "area", "neighborhood", "city", "town"]

    /// Words that are never part of a city's name: pronouns, verbs and reply
    /// words ("tell me a joke", "remind me to call mom", "not now", "at my
    /// house"). Checked before the comma only, so a state or country after it
    /// ("Tulsa, OK", "Boise, ID", "Portland, ME") is never refused (W43-FIX).
    private static let neverInAName: Set<String> = [
        "i", "i'd", "i'm", "im", "me", "my", "you", "your", "our", "we", "they", "it", "his", "her", "their",
        "to", "not", "no", "yes", "now", "later", "thanks", "thank", "please", "rather", "would", "could",
        "should", "will", "do", "don't", "dont", "tell", "remind", "call", "what", "why", "how", "when", "who",
        "joke", "sure", "nah", "nope", "never", "mind", "just", "maybe", "hello", "hey", "stop", "cancel", "skip",
        "forget", "weather", "forecast", "rain", "snow", "lol", "home", "house", "work", "office", "school",
        "here", "there", "outside", "inside", "next", "last", "few", "rest",
        "idk", "dunno", "whatever", "anywhere", "nowhere", "somewhere", "everywhere", "pass", "guess", "usual",
        "same", "matter", "doesn't", "doesnt", "can't", "cant", "won't", "wont", "nothing", "something",
    ]
    /// A whole "place" that is a time, an event or a reply ("May", "the fall",
    /// "noon", "lunch", "the game", "the weekend", "great"). Only the whole
    /// place: "Silver Spring", "Great Falls" and "Nice" are cities (W43-FIX).
    private static let neverTheWholePlace: Set<String> = [
        "weekend", "week", "weeks", "morning", "mornings", "afternoon", "evening", "night", "nights", "tonight",
        "today", "tomorrow", "yesterday", "day", "days", "hour", "hours", "moment", "future", "past", "time",
        "noon", "midnight", "dawn", "dusk", "sunrise", "sunset", "breakfast", "brunch", "lunch", "dinner",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "spring", "summer", "fall", "autumn", "winter", "season", "year", "month",
        "christmas", "thanksgiving", "easter", "halloween", "new year", "new year's", "new years", "holidays",
        "holiday", "game", "match", "party", "wedding", "trip", "concert", "race", "parade", "festival",
        "beach", "park", "airport", "area", "neighborhood", "city", "town",
        "a", "an", "ok", "okay", "great", "good", "fine", "cool", "thanks", "hi", "hello",
        // Everyday words that are also the exact name of a real place (All, in Spain).
        "all", "some", "any", "least", "most", "once", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve",
    ]

    /// A place name as typed: letters, spaces and a few marks, one to five
    /// words, no word that is never in a city's name before the comma, and not
    /// a time, an event or a reply as a whole.
    private static func plausiblePlace(_ raw: String) -> String? {
        let p = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        let words = p.split(separator: " ")
        guard (1...5).contains(words.count), p.count <= 60 else { return nil }
        let name = p.split(separator: ",", maxSplits: 1).first.map(String.init) ?? p
        var nameWords = name.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard !nameWords.contains(where: { neverInAName.contains($0) }) else { return nil }
        if nameWords.first == "the" { nameWords.removeFirst() }
        // A state or country after a comma says it is a place ("Sunrise, FL");
        // "tomorrow, please" and "hmm, idk" carry no state or country.
        let hintWords = p.split(separator: ",", maxSplits: 1).dropFirst().first?
            .split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? []
        guard !hintWords.contains(where: { (neverInAName.contains($0) && usStates[$0] == nil) || dayTokens.contains($0) })
        else { return nil }
        let hinted = !hintWords.isEmpty
        guard !nameWords.isEmpty,
              hinted || !neverTheWholePlace.contains(nameWords.joined(separator: " ")) else { return nil }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " ,.'-"))
        guard p.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return p
    }

    private static let notPlaces: Set<String> = [
        "no", "nope", "no thanks", "no thank you", "never mind", "nevermind", "cancel", "stop", "skip",
        "forget it", "thanks", "thank you", "ok", "okay", "yes", "yeah", "sure", "nowhere", "not telling",
    ]
    private static let questionWords: Set<String> = ["what", "why", "how", "who", "when", "where", "which", "do", "does",
                                                     "is", "are", "could", "will", "would", "should", "i"]

    /// The city typed straight after Grux's "Which city are you in?", asking
    /// for the day the person first asked about ("Will it rain tomorrow?").
    static func followUp(_ text: String, previousReply: String?, previousAsk: String?) -> Ask? {
        guard let city = cityAnswer(text, after: previousReply) else { return nil }
        let first = previousAsk.flatMap { match($0) }
        return Ask(place: city, day: first?.day ?? .today, window: first?.window, answering: true)
    }

    /// "And tomorrow?" right after Grux's own forecast for the remembered
    /// place asks for that place on that day (W43-FIX round 4: the local model
    /// gave today's numbers as tomorrow's).
    static func dayFollowUp(_ text: String, previousReply: String?, remembered: WeatherPlace?) -> Ask? {
        guard let place = remembered, let previous = previousReply, previous.hasPrefix(place.name + ", ") else {
            return nil
        }
        var s = normalized(text)
        let asked = consumeAny(["and what about", "and how about", "what about", "how about", "and"], from: &s) != nil
        // "Later!" alone after a forecast is a sign-off; "And later?" and
        // "later today" ask about the rest of today (W43-P3 item 4).
        // "Later on!" too (W46-P3).
        guard asked || (s != "later" && s != "later on"), let asked = consumeDay(from: &s), s.isEmpty else { return nil }
        return Ask(place: nil, day: asked.day, window: asked.window)
    }

    /// Short names people use for a few big cities, as Open-Meteo names them.
    private static let aliases: [String: String] = [
        "nyc": "new york", "la": "los angeles", "sf": "san francisco", "philly": "philadelphia",
        "dc": "washington, dc", "vegas": "las vegas", "nola": "new orleans",
    ]
    static func alias(_ name: String) -> String? { aliases[comparable(name)] }

    /// Whether a phrase reads as a name rather than a thing ("the commute",
    /// "a walk", "tonight's dinner"), for saying a name was not found.
    /// "the dalles", "the woodlands": "The" and then words that read as a name.
    private static func readsAsTheName(_ words: [String]) -> Bool {
        words.count >= 2 && words[0] == "the" && readsAsAName(words.dropFirst().joined(separator: " "))
    }

    private static func readsAsAName(_ typed: String) -> Bool {
        let words = typed.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        return !["the", "a", "an", "my", "your", "our", "this", "that", "some", "any", "every"].contains(first)
            && !words.contains { $0.hasSuffix("'s") || $0.hasSuffix("\u{2019}s") }
    }

    /// The person's answer to Grux's own "which city" question, or nil when the
    /// message after it is not a place.
    static func cityAnswer(_ text: String, after previous: String?) -> String? {
        guard previous == askForCity else { return nil }
        var s = normalized(text)
        _ = consumeAny(["please"], from: &s)
        for tail in [", please", " please"] where s.hasSuffix(tail) { s = String(s.dropLast(tail.count)) }
        _ = consumeAny(["i'm in", "i am in", "im in", "i live in", "it's", "its", "in"], from: &s)
        guard !notPlaces.contains(s), let first = s.split(separator: " ").first,
              !questionWords.contains(String(first)) else { return nil }
        return plausiblePlace(s)
    }

    // MARK: - What leaves the Mac

    /// Asks Open-Meteo's geocoder for a place by name. Ten results, so a hint
    /// after a comma ("boston, ma") can pick one without being sent.
    static func geocodeRequest(name: String) -> URLRequest {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json"),
        ]
        return request(c.url!)
    }

    /// Asks for the current weather and seven days at a place, rounded to two
    /// decimals (about a kilometre), in the person's own units; and each hour
    /// when the question names some.
    static func forecastRequest(latitude: Double, longitude: Double, fahrenheit: Bool, hourly: Bool = false) -> URLRequest {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily",
                         value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
        ]
        if hourly {
            c.queryItems?.append(URLQueryItem(name: "hourly", value: "weather_code,temperature_2m,precipitation_probability"))
        }
        return request(c.url!)
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        // The same for everyone: an explicit value wins over the one CFNetwork adds.
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    /// The update check's session: keeps nothing, sends no extra header.
    static func sessionConfiguration() -> URLSessionConfiguration {
        UpdateCheck.sessionConfiguration()
    }

    /// Whether the person reads temperatures in Fahrenheit.
    static var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }

    // MARK: - The answer

    private struct WeatherFailure: Error { let error: Error? }

    /// Open-Meteo geocoder results; also read by the time ask (D156).
    struct GeoResults: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country_code: String?
            let country: String?
            let admin1: String?
            let timezone: String?
            let feature_code: String?
        }
        let results: [Result]?
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            /// Local time at the place, "2026-11-02T22:40".
            let time: String?
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let weather_code: Int?
            let wind_speed_10m: Double?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]?
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
            let precipitation_probability_max: [Int?]?
        }
        struct Hourly: Decodable {
            let time: [String]
            let weather_code: [Int?]?
            let temperature_2m: [Double?]?
            let precipitation_probability: [Int?]?
        }
        let current: Current?
        let daily: Daily?
        let hourly: Hourly?
        let utc_offset_seconds: Int?
    }

    static let usStates: [String: String] = [
        "al": "alabama", "ak": "alaska", "az": "arizona", "ar": "arkansas", "ca": "california",
        "co": "colorado", "ct": "connecticut", "de": "delaware", "fl": "florida", "ga": "georgia",
        "hi": "hawaii", "id": "idaho", "il": "illinois", "in": "indiana", "ia": "iowa", "ks": "kansas",
        "ky": "kentucky", "la": "louisiana", "me": "maine", "md": "maryland", "ma": "massachusetts",
        "mi": "michigan", "mn": "minnesota", "ms": "mississippi", "mo": "missouri", "mt": "montana",
        "ne": "nebraska", "nv": "nevada", "nh": "new hampshire", "nj": "new jersey", "nm": "new mexico",
        "ny": "new york", "nc": "north carolina", "nd": "north dakota", "oh": "ohio", "ok": "oklahoma",
        "or": "oregon", "pa": "pennsylvania", "ri": "rhode island", "sc": "south carolina",
        "sd": "south dakota", "tn": "tennessee", "tx": "texas", "ut": "utah", "vt": "vermont",
        "va": "virginia", "wa": "washington", "wv": "west virginia", "wi": "wisconsin", "wy": "wyoming",
        "dc": "district of columbia",
    ]

    /// A place name for comparing: no case, accents, dots, hyphens or
    /// apostrophes, "saint" as "st", and no "city" at the end.
    static func comparable(_ name: String) -> String {
        var n = name.lowercased().folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        n = n.replacingOccurrences(of: "\u{0142}", with: "l")
        let short = ["saint": "st", "sainte": "ste", "ft": "fort", "mt": "mount"]
        n = n.split(separator: " ").map { short[String($0)] ?? String($0) }.joined(separator: " ")
        if n.hasSuffix(" city") { n = String(n.dropLast(5)) }
        return n
    }

    /// Country, province and state codes people write after a city outside
    /// the US ("London UK", "Vancouver BC", "Sydney NSW"), as Open-Meteo
    /// codes and names them (W43-FIX round 5).
    private static let regionCodes: [String: (country: String, admin: String?)] = [
        "uk": ("GB", nil), "gb": ("GB", nil), "usa": ("US", nil), "us": ("US", nil),
        "scotland": ("GB", "scotland"), "wales": ("GB", "wales"),
        "bc": ("CA", "british columbia"), "on": ("CA", "ontario"), "qc": ("CA", "quebec"), "ab": ("CA", "alberta"),
        "mb": ("CA", "manitoba"), "sk": ("CA", "saskatchewan"), "ns": ("CA", "nova scotia"),
        "nb": ("CA", "new brunswick"), "nl": ("CA", "newfoundland and labrador"),
        "nsw": ("AU", "new south wales"), "vic": ("AU", "victoria"), "qld": ("AU", "queensland"),
    ]

    /// The result a hint names ("ma", "massachusetts", "france", "us"), else the
    /// first, among the results whose name IS the typed name (W43-FIX round 3:
    /// Open-Meteo matches loosely, so "all" in "Will it rain at all today?"
    /// came back as a town). The best known place comes first (Paris is in
    /// France, Boston in Massachusetts), and the reply names it.
    static func pick(_ all: [GeoResults.Result], typed: String, hint: String?,
                             hintRequired: Bool = false) -> GeoResults.Result? {
        let want = comparable(typed)
        let results = all.filter { comparable($0.name) == want }
        guard let hint, !hint.isEmpty else { return results.first }
        let state = usStates[hint]
        let region = regionCodes[hint]
        let named = results.first { r in
            let admin = r.admin1?.lowercased() ?? ""
            if let state, r.country_code == "US", admin == state { return true }
            if let region, r.country_code == region.country, region.admin == nil || admin == region.admin { return true }
            return admin == hint || r.country?.lowercased() == hint || r.country_code?.lowercased() == hint
                || (hint.count > 2 && (admin.hasPrefix(hint) || (r.country?.lowercased().hasPrefix(hint) ?? false)))
        }
        return named ?? (hintRequired ? nil : results.first)
    }

    static func displayName(_ r: GeoResults.Result) -> String {
        let region = r.country_code == "US" ? r.admin1 : r.country
        guard let region, !region.isEmpty, region != r.name else { return r.name }
        return "\(r.name), \(region)"
    }

    private static func titled(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// WMO weather interpretation codes, as Open-Meteo returns them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "heavy rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed weather"
        }
    }

    private static func unreachable(_ error: Error?) -> String {
        let why = (error as? URLError).map { e -> String in
            switch e.code {
            case .notConnectedToInternet: return "this Mac is not connected to the internet"
            case .timedOut: return "it did not answer in time"
            default: return "the request failed"
            }
        } ?? "it gave no forecast"
        return "I could not reach Open-Meteo, the weather service, just now (\(why)). Ask again in a moment."
    }

    /// The reply to a weather question, fetching only what it needs.
    static func answer(_ ask: Ask, remembered: WeatherPlace?, fahrenheit: Bool, now: Date = Date(),
                       fetch: (URLRequest) async throws -> (Data, Int)) async -> Outcome {
        var place = remembered
        var learned = false
        var notFound: String?
        // A spot near the person ("at the beach") is the saved city, said so (D154).
        var usedRemembered = ask.nearby && remembered != nil
        if let typed = ask.place {
            let parts = typed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            var name = parts[0]
            var hint = parts.count > 1 ? parts[1].lowercased() : nil
            if let a = alias(name) {
                let ap = a.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                name = ap[0]
                if hint == nil, ap.count > 1 { hint = ap[1] }
            }
            // Each try asks for a name and keeps only a result with exactly that name.
            func lookUp(_ name: String, _ hint: String?, hintRequired: Bool) async -> Result<GeoResults.Result?, WeatherFailure> {
                do {
                    let (data, status) = try await fetch(geocodeRequest(name: name))
                    guard status == 200,
                          let decoded = try? JSONDecoder().decode(GeoResults.self, from: data) else { return .failure(.init(error: nil)) }
                    return .success(pick(decoded.results ?? [], typed: name, hint: hint, hintRequired: hintRequired))
                } catch {
                    return .failure(.init(error: error))
                }
            }
            var found: GeoResults.Result?
            switch await lookUp(name, hint, hintRequired: false) {
            case .failure(let f): return Outcome(reply: unreachable(f.error), remember: nil)
            case .success(let r): found = r
            }
            // "Austin Texas", "Lyon France": the last word is the state or country;
            // "The Dalles OR" too, when that word is a code (W45-P3 item 5).
            let words = name.split(separator: " ").map(String.init)
            let theAndACode = readsAsTheName(Array(words.dropLast()))
                && (usStates[words.last ?? ""] != nil || regionCodes[words.last ?? ""] != nil)
            // Said not found only for a code `match` lets end a "The" name, a stop
            // word typed in capitals; "the beach ok" falls back as before (W46-P3).
            let typedAsACode = theAndACode && placeStops.contains(words.last ?? "")
            if found == nil, hint == nil, words.count >= 2, readsAsAName(name) || theAndACode {
                switch await lookUp(words.dropLast().joined(separator: " "), words.last, hintRequired: true) {
                case .failure(let f): return Outcome(reply: unreachable(f.error), remember: nil)
                case .success(let r): found = r
                }
            }
            if let found {
                let resolved = WeatherPlace(name: displayName(found), latitude: found.latitude, longitude: found.longitude)
                learned = resolved != remembered
                place = resolved
            } else if ask.answering || ((readsAsAName(typed) || typedAsACode) && remembered == nil) {
                return Outcome(reply: "I could not find a place called \u{201C}\(titled(typed))\u{201D}. "
                               + "Try a city name, for example \u{201C}Boston\u{201D}.", remember: nil)
            } else if readsAsAName(typed) || typedAsACode, let home = remembered {
                notFound = "I could not find a place called \u{201C}\(titled(typed))\u{201D}, so here is \(home.name). "
            } else {
                // Words that name no place ("at the beach", "for the commute")
                // are not a place: the remembered one answers, and the reply
                // ends saying so (D149 item 3), or Grux asks which city.
                usedRemembered = remembered != nil
            }
        }
        guard let place else { return Outcome(reply: askForCity, remember: nil) }

        let forecast: Forecast
        do {
            let (data, status) = try await fetch(forecastRequest(latitude: place.latitude, longitude: place.longitude,
                                                                 fahrenheit: fahrenheit, hourly: ask.window != nil))
            guard status == 200, let f = try? JSONDecoder().decode(Forecast.self, from: data), let daily = f.daily,
                  !daily.time.isEmpty else {
                return Outcome(reply: unreachable(nil), remember: nil)
            }
            forecast = f
        } catch {
            return Outcome(reply: unreachable(error), remember: nil)
        }
        let daily = forecast.daily!
        let unit = fahrenheit ? "°F" : "°C"
        let speed = fahrenheit ? "mph" : "km/h"
        func deg(_ v: Double) -> String { "\(Int(v.rounded()))\(unit)" }

        var reply: String
        if ask.day == .weekend || ask.day == .week {
            let indices = spanDays(ask.day, daily.time)
            guard !indices.isEmpty else {
                let days = daily.time.count == 1 ? "day" : "\(daily.time.count) days"
                return Outcome(reply: "I only have a forecast for the next \(days) at \(place.name).", remember: nil)
            }
            let lines = indices.compactMap { i -> String? in
                let parts = dayParts(daily, i, deg: deg)
                guard !parts.isEmpty else { return nil }
                let name = i == 0 ? "Today" : i == 1 ? "Tomorrow" : weekdayNames[weekday(daily.time[i])! - 1].capitalized
                return "- \(name): " + parts.joined(separator: ", ")
            }
            guard !lines.isEmpty else { return Outcome(reply: unreachable(nil), remember: nil) }
            let label = ask.day == .weekend ? "this weekend"
                : daily.time.count == 1 ? "the next day" : "the next \(daily.time.count) days"
            reply = "\(place.name), \(label):\n" + lines.joined(separator: "\n")
        } else if let window = ask.window, let hours = hoursLine(window, day: ask.day, forecast, at: now, deg: deg) {
            reply = "\(place.name), \(hours)."
        } else {
            let index: Int?
            let label: String
            switch ask.day {
            case .today: index = 0; label = "Today"
            case .tomorrow: index = daily.time.count > 1 ? 1 : nil; label = "tomorrow"
            case .weekday(let w):
                index = daily.time.firstIndex { weekday($0) == w }
                label = "on " + weekdayNames[w - 1].capitalized
            case .weekend, .week: return Outcome(reply: unreachable(nil), remember: nil)
            }
            guard let i = index else {
                return Outcome(reply: "I only have a forecast for the next 7 days at \(place.name).", remember: nil)
            }
            // Beside the weather now, the day's own code (its worst weather)
            // is said "at times" when it names other weather (D149 item 2).
            let nowWeather = ask.day == .today ? forecast.current?.weather_code.map(describe) : nil
            let dayLine = dayParts(daily, i, deg: deg, besideNow: nowWeather).joined(separator: ", ")
            let nowKnown = ask.day == .today && forecast.current?.temperature_2m != nil
            guard !dayLine.isEmpty || nowKnown else { return Outcome(reply: unreachable(nil), remember: nil) }

            if ask.day == .today, let now = forecast.current, let t = now.temperature_2m {
                var nowLine = "\(place.name), now: \(deg(t))"
                if let code = now.weather_code { nowLine += " and \(describe(code))" }
                if let feels = now.apparent_temperature, Int(feels.rounded()) != Int(t.rounded()) {
                    nowLine += ", feels like \(deg(feels))"
                }
                if let wind = now.wind_speed_10m { nowLine += ", wind \(Int(wind.rounded())) \(speed)" }
                reply = nowLine + ". " + (dayLine.isEmpty ? "" : "Today: \(dayLine).")
            } else {
                reply = "\(place.name), \(label == "Today" ? "today" : label): \(dayLine)."
            }
        }
        reply = (notFound ?? "") + reply.trimmingCharacters(in: .whitespaces)
        // After a list of days, the line about the place is its own paragraph (D148).
        let gap = reply.contains("\n") ? "\n\n" : " "
        if learned, remembered == nil {
            reply += gap + "Only the place name went to Open-Meteo, a free weather service, and I'll use "
                + "\(place.name) when you ask again; name another city to change it."
        } else if learned {
            reply += gap + "I'll use \(place.name) when you ask again."
        } else if usedRemembered {
            reply += gap + "I used \(place.name), the city you gave me before; name a city to ask about another."
        }
        return Outcome(reply: reply, remember: learned ? place : nil)
    }
}

extension WeatherAsk {
    /// One day of the daily forecast: "overcast, high 52°F, low 39°F, 20% chance of rain".
    /// Open-Meteo's daily code is the day's worst weather, so beside different
    /// weather now (`besideNow`) it reads "overcast at times".
    private static func dayParts(_ daily: Forecast.Daily, _ i: Int, deg: (Double) -> String,
                                 besideNow: String? = nil) -> [String] {
        var parts: [String] = []
        if let code = daily.weather_code?[safe: i] ?? nil {
            let weather = describe(code)
            parts.append(besideNow.map { $0 == weather ? weather : weather + " at times" } ?? weather)
        }
        if let hi = daily.temperature_2m_max?[safe: i] ?? nil { parts.append("high \(deg(hi))") }
        if let lo = daily.temperature_2m_min?[safe: i] ?? nil { parts.append("low \(deg(lo))") }
        if let p = daily.precipitation_probability_max?[safe: i] ?? nil { parts.append("\(p)% chance of rain") }
        return parts
    }

    /// The weekday of a forecast day, "2026-11-07", in `Calendar` numbering
    /// (1 is Sunday). The date is the place's own, so it is read as UTC.
    private static func weekday(_ day: String) -> Int? {
        var utc = Foundation.Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parse = DateFormatter()
        parse.calendar = utc
        parse.timeZone = utc.timeZone
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        return parse.date(from: day).map { utc.component(.weekday, from: $0) }
    }

    /// The forecast days a span covers: every day for the week; for the
    /// weekend the first Saturday and the Sunday after it, or only Sunday when
    /// the forecast starts on one (on a Sunday this weekend is today).
    private static func spanDays(_ day: Day, _ days: [String]) -> [Int] {
        guard day == .weekend else { return Array(days.indices) }
        guard let first = days.indices.first(where: { [7, 1].contains(weekday(days[$0])) }) else { return [] }
        if weekday(days[first]) == 7, days.indices.contains(first + 1), weekday(days[first + 1]) == 1 {
            return [first, first + 1]
        }
        return [first]
    }

    /// The hours a window covers, said as "the next 2 hours (until 6 PM): clear,
    /// then partly cloudy, 55°F to 57°F, up to 20% chance of rain". Nil when the
    /// answer holds no such hours (a morning already over, no hourly block), so
    /// the whole day answers instead of nothing.
    private static func hoursLine(_ window: Window, day: Day, _ forecast: Forecast, at macClock: Date,
                                  deg: (Double) -> String) -> String? {
        guard let hourly = forecast.hourly, let reported = forecast.current?.time else { return nil }
        // The time at the place by the Mac's clock: `current.time` steps by 15
        // minutes, so it reads 3:00 until 3:15 (W45-P3). Without the place's
        // offset, Open-Meteo's own time, and never "on the hour".
        let now = forecast.utc_offset_seconds.map { placeTime(macClock, offset: $0) } ?? reported
        let onTheHour = forecast.utc_offset_seconds != nil && now.dropFirst(14).prefix(2) == "00"
        guard now.count >= 13,
              let k = hourly.time.firstIndex(where: { $0.hasPrefix(String(now.prefix(13))) }) else { return nil }
        func hour(_ i: Int) -> Int? { Int(hourly.time[i].dropFirst(11).prefix(2)) }
        func date(_ i: Int) -> Substring { hourly.time[i].prefix(10) }
        let today = now.prefix(10)
        let slots: [Int]
        let label: String
        let until: Bool
        switch window {
        case .next(let n):
            // From 3:40 the next 2 hours reach into the 5 PM slot; from 3:00 they end at 5 PM.
            slots = Array(k...min(k + n - (onTheHour ? 1 : 0), hourly.time.count - 1))
            label = n == 1 ? "the next hour" : "the next \(n) hours"
            until = true
        case .restOfDay:
            slots = (k..<hourly.time.count).filter { date($0) == today }
            label = "the rest of today"
            until = true
        case .hours(let from, let to):
            let on: Substring
            switch day {
            case .today: on = today
            case .tomorrow:
                guard let next = forecast.daily?.time[safe: 1] else { return nil }
                on = Substring(next)
            case .weekday, .weekend, .week: return nil
            }
            slots = hourly.time.indices.filter { i in
                guard date(i) == on, let h = hour(i), h >= from, h < to else { return false }
                return day != .today || i >= k
            }
            guard let part = partsOfDay.first(where: { $0.from == from && $0.to == to })?.word else { return nil }
            label = day == .today ? todayWord(part) : "tomorrow \(part)"
            until = false
        }
        guard let first = slots.first, let last = slots.last, let start = hour(first), let end = hour(last) else {
            return nil
        }
        var parts: [String] = []
        var said: [String] = []
        for i in slots {
            guard let code = hourly.weather_code?[safe: i] ?? nil else { continue }
            let words = describe(code)
            if !said.contains(words) { said.append(words) }
        }
        if !said.isEmpty { parts.append(said.prefix(3).joined(separator: ", then ")) }
        let temps = slots.compactMap { hourly.temperature_2m?[safe: $0] ?? nil }.map { $0.rounded() }
        if let lo = temps.min(), let hi = temps.max() {
            parts.append(lo == hi ? deg(lo) : "\(deg(lo)) to \(deg(hi))")
        }
        let rain = slots.compactMap { hourly.precipitation_probability?[safe: $0] ?? nil }
        if let most = rain.max() {
            parts.append((rain.min() == most ? "" : "up to ") + "\(most)% chance of rain")
        }
        guard !parts.isEmpty else { return nil }
        let span = until ? "until \(clock(end + 1))" : "\(clock(start)) to \(clock(end + 1))"
        return "\(label) (\(span)): " + parts.joined(separator: ", ")
    }

    /// "6 PM", "noon", "midnight".
    /// "2026-11-02T15:10", the time at a place `offset` seconds from UTC.
    private static func placeTime(_ date: Date, offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date.addingTimeInterval(Double(offset)))
    }

    private static func clock(_ h: Int) -> String {
        switch h % 24 {
        case 0: return "midnight"
        case 12: return "noon"
        case let x where x < 12: return "\(x) AM"
        case let x: return "\(x - 12) PM"
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
