import Foundation

/// "What time is it in Tokyo right now?" (D156), answered with the time.
/// Sense pass 19 (11:09 AM Nov 4) got "I don't have access to real-time
/// location data like your city's timezone. You'll need to check a weather app
/// or website for that." from Grux Local 2B, about a question the Mac answers
/// exactly by itself.
///
/// The zone comes from what this Mac knows first: its own time zone list
/// (Tokyo, London, New York, Kolkata), a few zone words (UTC, Pacific Time) and
/// the US states. Only another place is looked up, on Open-Meteo's geocoder
/// (the weather ask's, free, no key), and only its name is sent. A country with
/// more than one zone is not guessed. The grammar is closed like the weather
/// ask's: anything that is not plainly "what time is it (in X)" stays with the
/// model.
@MainActor
enum TimeAsk {
    struct Ask: Equatable { let place: String? }

    // MARK: - The match

    private static let asks = #"(?:what time is it|what time's it|what's the time|whats the time|what is the time|what's the current time|whats the current time|what is the current time)"#
    private static let now = #"(?: (?:right )?now)"#

    /// Words that say the rest is not a place ("in the morning", "in my
    /// calendar", "in tokyo tomorrow", "in tokyo and london").
    private static let notInAPlace: Set<String> = [
        "my", "your", "our", "his", "her", "their", "a", "an", "this", "that", "when", "if", "where", "what",
        "how", "and", "or", "vs", "versus", "compared", "than", "from", "to", "at", "for", "with",
        "today", "tonight", "tomorrow", "yesterday", "morning", "afternoon", "evening", "night", "week", "weekend",
        "month", "year", "hour", "hours", "minute", "minutes", "world", "calendar", "meeting", "life",
    ]

    static func match(_ text: String) -> Ask? {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"[?.!\s]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:(?:hey|hi|ok|okay) )?(?:grux,? )?"#, with: "", options: .regularExpression)
        guard !s.isEmpty else { return nil }
        if s.range(of: "^\(asks)(?:\(now)| here)?$", options: .regularExpression) != nil { return Ask(place: nil) }
        let forms = ["^\(asks)\(now)? in (.+?)\(now)?$",
                     "^(?:the )?(?:current |local )?time\(now)? in (.+?)\(now)?$"]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            let place = String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if place == "here" { return Ask(place: nil) }
            return plausible(place) ? Ask(place: place) : nil
        }
        return nil
    }

    private static func plausible(_ place: String) -> Bool {
        let allowed = CharacterSet.lowercaseLetters.union(CharacterSet(charactersIn: " ,.'-"))
        let words = place.split { $0 == " " || $0 == "," }.map(String.init)
        return !place.isEmpty && place.count <= 60 && (1...5).contains(words.count)
            && place.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !words.contains { notInAPlace.contains($0) }
    }

    // MARK: - What this Mac knows

    /// The Mac's own zone list by city ("Asia/Tokyo" as "tokyo"): two-part
    /// names only, so a county like "America/North_Dakota/Center" is not a
    /// city, plus the three big cities filed one level down and two cities
    /// Foundation lists under an older name.
    private static let cityZones: [String: String] = {
        var out: [String: String] = [:]
        let regions: Set<String> = ["Africa", "America", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"]
        let deeper = ["America/Argentina/Buenos_Aires", "America/Indiana/Indianapolis", "America/Kentucky/Louisville"]
        // Today's names Foundation files under the old ones (Asia/Calcutta).
        let renamed = ["Asia/Kolkata", "Asia/Saigon"]
        for id in TimeZone.knownTimeZoneIdentifiers + deeper + renamed {
            let parts = id.split(separator: "/")
            guard parts.count == 2 || deeper.contains(id), regions.contains(String(parts[0])) else { continue }
            let city = WeatherAsk.comparable(parts.last!.replacingOccurrences(of: "_", with: " "))
            if out[city] == nil { out[city] = id }
        }
        return out
    }()

    /// Zone words people say instead of a place, and how the reply leads.
    private static let zoneWords: [String: (lead: String, id: String)] = {
        var out: [String: (String, String)] = ["utc": ("In UTC", "UTC"), "gmt": ("In GMT", "GMT")]
        for (name, id, words) in [("Eastern", "America/New_York", ["eastern", "est", "edt"]),
                                  ("Central", "America/Chicago", ["central", "cst", "cdt"]),
                                  ("Mountain", "America/Denver", ["mountain", "mst", "mdt"]),
                                  ("Pacific", "America/Los_Angeles", ["pacific", "pst", "pdt"])] {
            for w in words + words.map({ "\($0) time" }) { out[w] = ("On \(name) Time", id) }
        }
        // The abbreviations people type for other zones (W51-FIX P2 1: "IST"
        // could reach the geocoder and match a village named Ist).
        for (lead, id, words) in [("On Central European Time", "Europe/Paris", ["cet", "cest", "central european time"]),
                                  ("In the UK", "Europe/London", ["bst", "british time"]),
                                  ("On Japan Time", "Asia/Tokyo", ["jst", "japan time"]),
                                  ("On Korea Time", "Asia/Seoul", ["kst", "korea time"]),
                                  ("On Australian Eastern Time", "Australia/Sydney", ["aest", "aedt"]),
                                  ("On Hawaii Time", "Pacific/Honolulu", ["hst", "hawaii time"]),
                                  ("On Alaska Time", "America/Anchorage", ["akst", "akdt", "alaska time"])] {
            for w in words { out[w] = (lead, id) }
        }
        return out
    }()

    /// Countries people name by a short or everyday name, settled before any
    /// lookup (W51-FIX P2 1): the geocoder keeps an exact name, so "usa" was
    /// Usa, Oita, Japan, and "mexico" read as Mexico City in the zone list.
    private enum Country { case many(String), zone(lead: String, id: String) }
    private static let countries: [String: Country] = {
        var out: [String: Country] = [:]
        for w in ["usa", "us", "america", "united states", "united states of america"] {
            out[w] = .many("The United States")
        }
        for name in ["Mexico", "Canada", "Russia", "Australia", "Brazil", "Indonesia"] {
            out[name.lowercased()] = .many(name)
        }
        for w in ["uk", "united kingdom", "britain", "great britain", "england", "scotland", "wales"] {
            out[w] = .zone(lead: "In the UK", id: "Europe/London")
        }
        return out
    }()
    /// One abbreviation, three zones: never guessed.
    private static let ambiguousZones = [
        "ist": "IST names more than one time zone (India, Israel and Ireland). Name a city and I'll tell you its time.",
    ]

    /// Each state's zone; `most` where part of the state keeps another one.
    /// Washington goes to the geocoder (people often mean DC), Georgia has its
    /// own two-line answer, and New York the state is New York the city.
    private static let stateZones: [String: (id: String, most: Bool)] = {
        let ny = "America/New_York", chi = "America/Chicago", den = "America/Denver", la = "America/Los_Angeles"
        return [
            "alabama": (chi, false), "alaska": ("America/Anchorage", true), "arizona": ("America/Phoenix", true),
            "arkansas": (chi, false), "california": (la, false), "colorado": (den, false),
            "connecticut": (ny, false), "delaware": (ny, false), "florida": (ny, true),
            "hawaii": ("Pacific/Honolulu", false), "idaho": ("America/Boise", true), "illinois": (chi, false),
            "indiana": ("America/Indiana/Indianapolis", true), "iowa": (chi, false), "kansas": (chi, true),
            "kentucky": (ny, true), "louisiana": (chi, false), "maine": (ny, false), "maryland": (ny, false),
            "massachusetts": (ny, false), "michigan": (ny, true), "minnesota": (chi, false),
            "mississippi": (chi, false), "missouri": (chi, false), "montana": (den, false),
            "nebraska": (chi, true), "nevada": (la, true), "new hampshire": (ny, false), "new jersey": (ny, false),
            "new mexico": (den, false), "north carolina": (ny, false), "north dakota": (chi, true),
            "ohio": (ny, false), "oklahoma": (chi, false), "oregon": (la, true), "pennsylvania": (ny, false),
            "rhode island": (ny, false), "south carolina": (ny, false), "south dakota": (chi, true),
            "tennessee": (chi, true), "texas": (chi, true), "utah": (den, false), "vermont": (ny, false),
            "virginia": (ny, false), "west virginia": (ny, false), "wisconsin": (chi, false), "wyoming": (den, false),
        ]
    }()

    /// Countries whose land spans more than one zone, as Open-Meteo codes them.
    private static let manyZones: Set<String> = [
        "US", "CA", "RU", "AU", "BR", "MX", "ID", "KZ", "MN", "CD", "CL", "EC", "ES", "PT", "KI", "FM", "GL", "PF",
    ]

    // MARK: - The answer

    static func answer(_ ask: Ask, now: Date = Date(), here: TimeZone = .current,
                       fetch: (URLRequest) async throws -> (Data, Int)) async -> String {
        guard let place = ask.place else { return "It's \(clock(now, here)) on \(day(now, here))." }
        func line(_ lead: String, _ zone: TimeZone) -> String {
            "\(lead) it's \(clock(now, zone)) on \(day(now, zone)), \(relation(now, zone, here))."
        }
        let parts = place.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        var name = parts[0]
        var hint = parts.count > 1 ? parts[1] : nil
        // `comparable` drops a trailing " city", so "Jersey City" keys as
        // "jersey" (Europe/Jersey) and "Mexico City" as "mexico". A name that
        // ends in "city" is matched here only by a zone that is itself a city
        // (Mexico_City); every other one is looked up by name (W51-FIX rounds 2, 3).
        let namesACity = name.lowercased().replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces).hasSuffix(" city")
        if hint == nil, !namesACity {
            let key = WeatherAsk.comparable(name)
            let bare = key.hasPrefix("the ") ? String(key.dropFirst(4)) : key
            switch countries[bare] {
            case .many(let country)?:
                return "\(country) has more than one time zone. Name a city there and I'll tell you its time."
            case .zone(let lead, let id)?:
                if let zone = TimeZone(identifier: id) { return line(lead, zone) }
            case nil: break
            }
            if let ambiguous = ambiguousZones[key] { return ambiguous }
            if let z = zoneWords[key], let zone = TimeZone(identifier: z.id) { return line(z.lead, zone) }
            if let a = WeatherAsk.alias(name) {
                let ap = a.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                name = ap[0]
                if ap.count > 1 { hint = ap[1] }
            }
        }
        if hint == nil {
            let key = WeatherAsk.comparable(name)
            if let id = cityZones[key], !namesACity || id.hasSuffix("_City"), let zone = TimeZone(identifier: id) {
                let city = id.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ")
                return line("In \(city)", zone)
            }
            if !namesACity, key == "georgia", let state = TimeZone(identifier: "America/New_York"),
               let country = TimeZone(identifier: "Asia/Tbilisi") {
                return line("In Georgia, the US state,", state) + " " + line("In Georgia, the country,", country)
            }
            if !namesACity, let s = stateZones[key], let zone = TimeZone(identifier: s.id) {
                return line("In \(s.most ? "most of " : "")\(titled(key))", zone)
            }
        }
        // Anywhere else: the geocoder, sent the name and never the hint.
        let found: WeatherAsk.GeoResults.Result?
        do {
            let (data, status) = try await fetch(WeatherAsk.geocodeRequest(name: name))
            guard status == 200, let decoded = try? JSONDecoder().decode(WeatherAsk.GeoResults.self, from: data) else {
                return unreachable(place: name, nil)
            }
            found = WeatherAsk.pick(decoded.results ?? [], typed: name, hint: hint?.lowercased())
        } catch {
            return unreachable(place: name, error)
        }
        // A country: one with several zones is never guessed, and Open-Meteo
        // gives those (and some one-zone countries, China) no zone at all.
        if let found, found.feature_code?.hasPrefix("PCL") == true {
            if let code = found.country_code, manyZones.contains(code) {
                return "\(found.name) has more than one time zone. Name a city there and I'll tell you its time."
            }
            if found.timezone.flatMap(TimeZone.init(identifier:)) == nil {
                return "Name a city in \(found.name) and I'll tell you its time."
            }
        }
        guard let found, let id = found.timezone, let zone = TimeZone(identifier: id) else {
            return "I could not find a place called \u{201C}\(titled(name))\u{201D}. "
                + "Try a city name, for example \u{201C}Tokyo\u{201D}."
        }
        let shown = WeatherAsk.displayName(found)
        return line("In \(shown)\(shown.contains(",") ? "," : "")", zone)
            + " Only the name went to Open-Meteo, a free weather service, to find where it is."
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func clock(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "h:mm a") }
    private static func day(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "EEEE, MMMM d") }

    private static func format(_ date: Date, _ zone: TimeZone, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// "14 hours ahead of you", "10 and a half hours ahead", "the same time as here".
    private static func relation(_ date: Date, _ zone: TimeZone, _ here: TimeZone) -> String {
        let minutes = (zone.secondsFromGMT(for: date) - here.secondsFromGMT(for: date)) / 60
        guard minutes != 0 else { return "the same time as here" }
        let h = abs(minutes) / 60, m = abs(minutes) % 60
        let amount: String
        switch m {
        case 0: amount = h == 1 ? "1 hour" : "\(h) hours"
        case 30: amount = h == 0 ? "half an hour" : "\(h) and a half hours"
        default: amount = (h == 0 ? "" : h == 1 ? "1 hour " : "\(h) hours ") + "\(m) minutes"
        }
        return amount + (minutes > 0 ? " ahead of you" : " behind you")
    }

    private static func unreachable(place: String, _ error: Error?) -> String {
        let why = (error as? URLError).map { e -> String in
            switch e.code {
            case .notConnectedToInternet: return "this Mac is not connected to the internet"
            case .timedOut: return "it did not answer in time"
            default: return "the request failed"
            }
        } ?? "the lookup gave no answer"
        return "I could not look up where \u{201C}\(titled(place))\u{201D} is just now (\(why)). "
            + "Big cities like Tokyo or London I know without looking up."
    }

    private static func titled(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
