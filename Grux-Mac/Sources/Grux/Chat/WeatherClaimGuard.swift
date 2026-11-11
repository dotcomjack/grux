import Foundation

/// W43-FIX round 2, live 2026-11-02 11:53 PM on qwen3.5:4b: "Will it rain in
/// May?" rightly went to the model (a month is not a place), and the model
/// answered "May, France, tomorrow: overcast with a 0% chance of rain. I'll
/// use May, France when you ask again.", copying the weather fast path's
/// replies earlier in the thread. The model has no weather tool, so a forecast
/// in its reply is made up. A local reply that states the weather, on a turn
/// whose web read did not succeed, is replaced by a line saying how to get the
/// real one, the way CalendarClaimGuard replaces a calendar it did not read.
@MainActor
enum WeatherClaimGuard {

    /// Tools whose result can carry a real forecast. Not `search_web`: it
    /// opens a browser tab and reads nothing (W43-FIX round 3).
    private static let backingTools: Set<String> = ["research_web"]

    /// A chance of rain however it is worded: "40% chance of rain", "30
    /// percent chance of snow", "14% rain chance", "0% rain", "rain chance is
    /// 20%", "chance of rain at 40%" (D148 live: a made-up week in the second
    /// wording passed); "a 40% chance of light rain", "a 40% chance it will
    /// rain", "a 40% probability of rain", "Chance of rain: 40%", "Rain: 40%"
    /// (W47-FIX). The odds word or the colon is what makes it a forecast:
    /// "14% done and the rain sounds app" is not one.
    private static let chance = "\\b" + percent + "\\s+" + odds + "\\s+(?:of\\s+|for\\s+|that\\s+)?" + someWords + precipitation
        + "|\\b" + percent + "\\s+" + precipitation
        + "|\\b(?:rain|snow|precipitation|precip)\\s+" + odds + "\\s*" + before + percent
        + "|\\b" + odds + "\\s+of\\s+" + someWords + precipitation + "\\s*" + before + percent
        + "|\\b(?:rain|snow|precipitation|precip)\\s*:\\s*" + percent
        // A word or two between the rain and the number ("Rain chance tomorrow
        // is 40%", "the chance of rain on Friday is 60%", "Odds of rain Friday:
        // 60%"), and a bare "60% chance" ending a clause after a rainy word
        // (W47-FIX round 3). Rain must be there: "the odds of a rate cut at
        // 70%" is not a forecast (round 4).
        + "|\\b" + rainWords + "\\b[^.!?\\n]{0,40}?(?:" + odds + "|:)[^.!?\\n]{0,20}?" + percent
        + "|\\b" + odds + "\\s+(?:of|for)\\s+[^.!?\\n]{0,30}?\\b" + rainWords + "\\b[^.!?\\n]{0,30}?" + percent
        + "|\\b(?:rain|snow|shower|storm|drizzl|wet)\\w*[^.!?\\n]{0,40}?" + percent + "\\s+chances?\\b(?=\\s*(?:[.,;!?]|$))"
    private static let rainWords = "(?:rain|rainfall|snow|snowfall|showers?|precipitation|precip|flurries|drizzle|sleet"
        + "|storms?|thunderstorms?)"
    private static let percent = "\\d{1,3}\\s?(?:%|\\s+percent\\b)"
    private static let odds = "(?:chances?|probability|odds|likelihood|risk)"
    private static let before = "(?:of\\s+|is\\s+|at\\s+|around\\s+|about\\s+|near\\s+|:\\s*)?"
    private static let someWords = "(?:[a-z'-]+\\s+){0,4}?"
    private static let precipitation = "(?:rain|rainfall|snow|snowfall|showers?|precipitation|precip|storms?|thunderstorms?"
        + "|drizzle|sleet|flurries)\\b"
    /// A temperature band: "highs in the mid 70s", "temperatures in the low to
    /// mid 60s", "highs in the 70's" (W43-P3 item 6, W47-FIX). Only after a
    /// temperature word: "born in the 70s" is not one.
    private static let band = "\\b(?:highs?|lows?|temperatures?|temps?)\\s+(?:in\\s+the\\s+|around\\s+the\\s+|near\\s+the\\s+)?"
        + "(?:(?:low|mid|high|upper|lower)(?:[- ]to[- ](?:low|mid|high|upper|lower))?[- ]?)?\\d0['\u{2019}]?s\\b"
    /// A reading: a temperature, a chance of rain, or a high or low.
    private static let reading = try! NSRegularExpression(pattern: "(?i)"
        + "(?:-?\\d{1,3}\\s?°\\s?[FC]\\b"
        + "|\\b-?\\d{1,3}\\s+degrees\\b"
        + "|" + chance + "|" + band
        + "|\\b(?:high|low)s?\\s+(?:of\\s+|around\\s+|near\\s+)?-?\\d{1,3}\\b)")
    /// And a word that makes the reading about the weather, so "Preheat the
    /// oven to 350°F" and "your CPU is at 85°C" are not forecasts.
    private static let weatherWord = try! NSRegularExpression(pattern: "(?i)\\b(?:weather|forecast|rain|raining|rainy"
        + "|snow|snowing|showers?|storms?|thunderstorms?|sunny|sun(?!-)|cloudy|clouds|overcast|fog|foggy|wind|windy"
        + "|humid|drizzle|sleet|hail|precip\\w*|rainfall|snowfall|flurries|clear\\s+skies|outside|umbrella)\\b")

    /// True when the reply gives a weather reading.
    static func claimsWeather(_ reply: String) -> Bool {
        let range = NSRange(location: 0, length: (reply as NSString).length)
        return reading.firstMatch(in: reply, range: range) != nil
            && weatherWord.firstMatch(in: reply, range: range) != nil
    }

    /// What replaces a made-up forecast: how to get the real one.
    static func howToAsk(remembered: WeatherPlace?) -> String {
        if let place = remembered {
            return "I didn't look that up, so I won't guess the weather. Ask \u{201C}What's the weather?\u{201D} "
                + "and I'll check Open-Meteo, a free weather service, for \(place.name), or name another city."
        }
        return "I didn't look that up, so I won't guess the weather. Ask \u{201C}What's the weather in\u{201D} "
            + "and your city, and I'll check Open-Meteo, a free weather service."
    }

    /// D153, live 2026-11-04 on grux-local:2b: "Will it rain at the beach?"
    /// got "I don't have access to real-time weather for your specific
    /// location. You'll need to check a weather app or website for that."
    /// Grux reads Open-Meteo with no model, so that reply is false. A reply
    /// is replaced only when it is ALL refusal (W50-FIX rounds 1 to 4 found a
    /// word rule either eats advice or misses a wording): every sentence is
    /// Grux saying it cannot get the weather, an apology, a pointer to a
    /// weather app or an offer of other help, and one says it cannot get the
    /// weather. Any other sentence (advice, a hedge, a refusal of something
    /// else) keeps the reply as the model wrote it.
    private static let apostrophe = "['\u{2019}]"
    private static let no = "(?:do\\s+not|don" + apostrophe + "t|does\\s+not|doesn" + apostrophe + "t|can" + apostrophe
        + "t|cannot|can\\s+not|couldn" + apostrophe + "t|could\\s+not|won" + apostrophe + "t|will\\s+not)"
        + "(?:\\s+be\\s+able\\s+to)?|ha(?:ve|s)\\s+no|lacks?"
    /// Grux saying it cannot: "I can't", "I'm unable to", "I've no", "I'm an
    /// AI and don't", "I'm offline and can't".
    private static let iCannot = "(?:\\b(?:I|we|Grux)\\s+(?:(?:really|currently|actually|just|unfortunately)\\s+)?(?:" + no + ")"
        + "|\\bI(?:" + apostrophe + "m|\\s+am)\\s+(?:not\\s+able|unable)\\s+to"
        + "|\\bI" + apostrophe + "ve\\s+no"
        + "|\\bI(?:" + apostrophe + "m|\\s+am)\\s+[^.!?;\\n]{0,40}?\\b(?:and|so)\\s+(?:I\\s+)?(?:" + no + "))\\b"
        + "(?:\\s+(?:really|currently|actually|just))?"
    private static let weatherNoun = "(?:weather|forecasts?)\\b"
        + "(?!\\s*(?:apps?|api|apis|sdk|library|libraries|code|models?|delays?|alerts?|warnings?|radar|maps?)\\b)"
    /// Words that may stand between "check" and "the weather".
    private static let describing = "(?:\\s+(?:the|current|live|real[- ]?time|local|today" + apostrophe + "s|tomorrow"
        + apostrophe + "s|latest|any|you|up[- ]to[- ]date|accurate|exact|information|info|data)"
        + "|,?\\s+(?:like|including|such\\s+as)){0,5}"
    /// Words that may stand between "the ability to" and "weather".
    private static let reaching = "(?:,?\\s+(?:the|internet|web|or|and|real[- ]?time|live|current|up[- ]to[- ]date|data"
        + "|information|info|like|any|to|check|checking|look\\s+up|access|accessing|get|see|know|knowing|browse|search"
        + "|provide|providing|fetch|fetching|retrieve|retrieving|give|offer|pull|read|including"
        + "|latest|local|such\\s+as)){0,8}"
    private static let refusalShapes: [NSRegularExpression] = [
        // "I can't check the weather", "I can't bring up the forecast".
        "\\s+(?:access|check|look\\s+up|bring\\s+up|pull\\s+up|get|fetch|retrieve|provide|give\\s+you|pull|read)"
            + describing + "\\s+" + weatherNoun,
        // "I can't see the weather.", "I don't know the weather there." ("I
        // don't see rain in the forecast" is reassurance: see only after a can't.)
        "(?<=n" + apostrophe + "t|not|unable\\s{1,3}to|able\\s{1,3}to)(?<!don" + apostrophe + "t|do\\s{1,3}not|doesn"
            + apostrophe + "t|does\\s{1,3}not)\\s+see(?:\\s+what)?" + describing + "\\s+(?:weather(?:\\s+forecasts?)?|forecasts?)\\b"
            + "(?=\\s*(?:[.,;!?]|$|(?:is|there|here|right\\s+now|for|at|in|from|outside)\\b))",
        "\\s+know(?:\\s+what)?" + describing + "\\s+(?:weather(?:\\s+forecasts?)?|forecasts?)\\b"
            + "(?=\\s*(?:[.,;!?]|$|(?:is|there|here|right\\s+now|for|at|in|from|outside)\\b))",
        // "I don't have the capability to check the weather", "I do not have real-time access to weather data".
        "(?:\\s+ha(?:ve|s))?(?:\\s+(?:the|any|a))?(?:\\s+(?:real[- ]?time|live|current|direct))?"
            + "\\s+(?:capability|ability|means|way|tools?|access)\\s+(?:to|of|for)" + reaching + "\\s+" + weatherNoun,
        // "I have no real-time weather data", "I'm unable to provide current weather forecasts".
        "(?:\\s+(?:have|has|get|access|provide|pull|fetch|retrieve))?(?:\\s+(?:any|the))?"
            + "\\s+(?:real[- ]?time|live|current|up[- ]to[- ]date)\\s+" + weatherNoun,
        // "I don't have weather data", "I do not have information about the weather".
        "(?:\\s+have)?(?:\\s+(?:any|the))?\\s+(?:" + weatherNoun + "|(?:information|info|data)\\s+(?:about|on|for)\\s+(?:the\\s+)?(?:(?:current|live|real[- ]?time|today"
            + apostrophe + "s)\\s+)?weather\\b)",
        // "I can't browse the web for the forecast".
        "\\s+(?:browse|search|go\\s+online|access\\s+the\\s+(?:internet|web))\\b[^.!?;\\n]{0,40}?\\b" + weatherNoun,
    ].map { try! NSRegularExpression(pattern: "(?i)" + iCannot + $0) }
    /// "I'm not able to access real-time information." with nothing after
    /// it: a refusal of the weather only beside a pointer to a weather app.
    private static let bareRealTime = try! NSRegularExpression(pattern: "(?i)" + iCannot
        + "(?:\\s+(?:have|has|get|access|provide|pull|fetch|retrieve))?(?:\\s+(?:any|the))?(?:\\s+access\\s+to)?"
        + "\\s+(?:real[- ]?time|live|current|up[- ]to[- ]date)\\s+(?:information|info|data|updates)\\s*[.!]?\\s*$")
    /// What may come before "I can't" in its sentence: an apology, "as an AI".
    private static let lead = try! NSRegularExpression(pattern: "(?i)^(?:[\\s,;:!-]*(?:(?:I" + apostrophe
        + "m|I\\s+am)\\s+sorry|sorry|unfortunately|apologies|I\\s+apologize|but|however|so|and|well|oh|hmm|hi|hello|hey"
        + "|as\\s+an?\\s+(?:(?:large|language|virtual|digital|local|helpful|text[- ]based|AI)\\s+){0,3}"
        + "(?:AI|assistant|model|chatbot|bot)"
        + "|right\\s+now|currently|at\\s+the\\s+moment|(?:I" + apostrophe + "m|I\\s+am)\\s+(?:not\\s+connected\\s+to\\s+the"
        + "\\s+internet|offline|not\\s+online)|I\\s+(?:don" + apostrophe + "t|do\\s+not)\\s+have\\s+(?:real[- ]?time\\s+capabilities|(?:access\\s+to\\s+)?real[- ]?time\\s+(?:information|info|data)|internet\\s+access"
        + "|access\\s+to\\s+the\\s+(?:internet|web))))*[\\s,;:!-]*$")
    /// After "so" or "but", a refusal goes on only to point to a weather app
    /// or offer other help ("but I recommend checking a weather app", "but I
    /// can help you plan a beach day"); anything else ("so I'd bring one",
    /// "but you can bring an umbrella", "but I can tell you it is usually
    /// cool") is advice the reply keeps (W50-FIX round 5).
    private static let contrast = try! NSRegularExpression(pattern: "(?i)\\b(?:so|but|though|although|however)\\b")
    /// A pointer: "you can check a weather app", "I recommend checking the forecast", after
    /// an opening such as "However," "To check the weather," "For the most accurate forecast,".
    private static let pointer = try! NSRegularExpression(pattern: "(?i)^[\\s,]*(?:(?:however|instead|alternatively|for\\s+now"
        + "|for\\s+(?:the\\s+)?(?:most\\s+)?(?:accurate|latest|up[- ]to[- ]date|current|best)\\s+(?:forecast|information|info|weather|results?)"
        + "|to\\s+(?:check|get|find\\s+out|see|know)[^,.!?]{0,60}),\\s*){0,2}"
        + "(?:please\\s+|you(?:" + apostrophe + "ll|\\s+will)?\\s+(?:need|want|have)\\s+to\\s+"
        + "|you\\s+(?:can|could|might|may|should)\\s+(?:(?:easily|also|always|simply)\\s+)?(?:(?:want|need)\\s+to\\s+)?"
        + "|I(?:" + apostrophe + "d|\\s+would)?\\s+(?:recommend|suggest)(?:\\s+that\\s+you)?\\s+|try\\s+)?"
        + "(?:check|checking|use|using|consult|consulting|look\\s+at|looking\\s+at|visit|visiting|find|open|try)\\b[^.!?]*"
        + "\\b(?:weather|forecast)")
    /// An offer of other help or a closing line ("Let me know if there's
    /// anything else I can help with!"); `advice` keeps one with a tip in it.
    private static let offer = try! NSRegularExpression(pattern: "(?i)^[\\s,]*(?:(?:however|but|instead)[\\s,]+)?(?:I\\s+can"
        + "(?:\\s+also)?\\s+(?:help|assist)|I(?:" + apostrophe + "m|\\s+am|" + apostrophe + "d\\s+be|\\s+would\\s+be)\\s+"
        + "(?:happy|glad)\\s+to\\s+help|is\\s+there\\s+anything\\s+else|let\\s+me\\s+know|(?:I\\s+)?hope\\s+(?:that|this)"
        + "\\s+helps|feel\\s+free\\s+to\\s+(?:ask|let\\s+me\\s+know|reach\\s+out)|if\\s+you\\s+have\\s+(?:any\\s+)?"
        + "(?:other|more)\\s+questions)\\b[^.!?:]*[.!?]*\\s*$")
    /// Advice: what to bring or do, what the weather usually is. Read after
    /// `pointerTail` is taken out, so "check a weather app before you go" is
    /// a pointer and "check a weather app and take a raincoat" is advice.
    private static let advice = try! NSRegularExpression(pattern: "(?i)\\b(?:bring(?:s|ing)?|pack(?:s|ing)?|wear(?:s|ing)?"
        + "|tak(?:e|es|ing)|carr(?:y|ies|ying)|go(?:es|ing)?|leav(?:e|es|ing)|avoid(?:s|ing)?|stay(?:s|ing)?|head(?:s|ing)?"
        + "|grab(?:s|bing)?|dress(?:es|ing)?|apply(?:ing)?|keep(?:s|ing)?|expect(?:s|ing)?|usually|often|typically|tends?|generally|normally|sunscreen|umbrella"
        + "|jacket|raincoat|tell\\s+you)\\b|\\d")
    private static let pointerTail = try! NSRegularExpression(pattern: "(?i)\\b(?:before\\s+(?:you\\s+)?(?:go(?:ing)?"
        + "|head(?:ing)?(?:\\s+out|\\s+to\\s+(?:the\\s+)?[a-z]+)?|leav(?:e|ing)|set(?:ting)?\\s+out)|to\\s+stay\\s+"
        + "(?:up[- ]to[- ]date|informed|updated)|(?:to\\s+see\\s+)?what\\s+to\\s+expect|take\\s+a\\s+(?:quick\\s+)?look"
        + "|(?:packing|travel|planning|trip)\\s+(?:tips|ideas|lists?))\\b")
    /// A pointer to the source of something else: closures, delays, roads.
    private static let otherTopic = try! NSRegularExpression(pattern: "(?i)\\b(?:closures?|closed|closings?|delays?|delayed"
        + "|cancell?ations?|cancell?ed|flights?|airlines?|roads?|traffic|DOT|ferry|ferries|schools?|district|games?"
        + "|match|status|outages?|events?)\\b")
    /// What may follow a refusal in its sentence: where, when, for whom, and
    /// a reason that says nothing about the weather ("since I'm busy
    /// backing up the Mini").
    /// One to three words of a place or a thing ("the beach", "your area"),
    /// none of them a word that starts another filler, so the filler reads in
    /// one way only (no backtracking on "on on on ...").
    private static let placeWords = "(?:\\s+(?:(?:the|your)\\s+)?(?!" + fillerWords + "\\b)(?![a-z'\u{2019}-]*ing\\b)"
        + "[a-z'\u{2019}-]+\\b){1,2}"
    private static let fillerWords = "(?:at|in|near|on|for|the|your|this|that|today|tonight|tomorrow|there|here|again"
        + "|specifically|itself|directly|online|now|right|currently|it" + apostrophe + "s|since|because|as|and|or|but|so"
        + "|you|me|moment"
        + "|which|who|where|when|what|is|are|was|be|being|been)"
    private static let restFiller = try! NSRegularExpression(pattern: "(?i)^(?:,?\\s+(?:(?:or|and)\\s+)?(?:forecasts?|data|information"
        + "|info|updates|conditions|reports?)\\b)*"
        + "(?:[\\s,]++(?:for(?:\\s+(?:you|that|now|this|me|today|tomorrow)|" + placeWords + ")"
        + "|right\\s+now|at\\s+(?:the|this)\\s+moment|at\\s+this\\s+time|currently|there|here|today|tonight|tomorrow"
        + "|again|specifically|itself|directly|near\\s+(?:me|you)"
        + "|online|(?:at|in|near|on)" + placeWords + "|it" + apostrophe + "s\\s+beyond\\s+my\\s+(?:capabilities"
        + "|abilities))\\b)*+[\\s,]*+(?:(?:since|because|as)\\s+" + reason + "[\\s,]*+)?[.!?]*$")
    /// Why Grux cannot, from a closed list (W50-FIX round 12: an open
    /// reason carried statements, "because I'm offline and fog rolls in most
    /// evenings"): offline, no internet or real-time access, no weather tool,
    /// an AI or local model, busy, or focused on a backup or another task
    /// (D148's "since I'm currently focused on backing up the Mini and in
    /// loginwindow mode"; round 13: no open words, they carried statements).
    private static let reason = "(?:I(?:" + apostrophe + "m|\\s+am)\\s+(?:currently\\s+)?(?:offline|not\\s+online"
        + "|not\\s+connected(?:\\s+to\\s+the\\s+(?:internet|web))?|an?\\s+(?:AI|local\\s+model|language\\s+model"
        + "|AI\\s+(?:assistant|language\\s+model))|running\\s+(?:locally|offline|on\\s+this\\s+Mac)"
        + "|(?:busy|focused\\s+on\\s+(?:backing\\s+up|a\\s+backup|the\\s+backup|something\\s+else|another\\s+task"
        + "|other\\s+tasks)(?:\\s+(?:the|your|this)\\s+(?:Mac|Mini|computer))?))"
        + "|I\\s+(?:don" + apostrophe + "t|do\\s+not)\\s+have\\s+(?:internet\\s+access|access\\s+to\\s+the\\s+(?:internet|web)"
        + "|web\\s+access|a\\s+weather\\s+tool|real[- ]?time\\s+(?:access|data|information))"
        + "|I\\s+(?:can" + apostrophe + "t|cannot)\\s+(?:go\\s+online|access\\s+the\\s+(?:internet|web)|browse(?:\\s+the\\s+web)?)"
        + "|there" + apostrophe + "s\\s+no\\s+internet(?:\\s+connection)?)"
        + "(?:\\s+and\\s+in\\s+[a-z]+\\s+mode)?"
    /// What follows "but" or "so" in a refusal, or a sentence beside one:
    /// a pointer to a weather app or an offer, about the weather only, and
    /// no advice.
    private static func pointsElsewhere(_ text: String) -> Bool {
        let ns = text as NSString
        let stripped = pointerTail.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                            withTemplate: " ")
        return (matches(pointer, text) || matches(offer, text)) && !matches(advice, stripped) && !matches(otherTopic, text)
    }
    /// An apology on its own, or "That's beyond what I can do."
    private static let fillerSentence = try! NSRegularExpression(pattern: "(?i)^[\\s,]*(?:(?:(?:I" + apostrophe
        + "m|I\\s+am)\\s+sorry|sorry|unfortunately|apologies|I\\s+apologize)[\\s,!.]*$"
        + "|(?:that|this)(?:" + apostrophe + "s|\\s+is)\\s+(?:beyond|outside|not\\s+something)\\b[^.!?]*[.!?]*$)")
    /// How far a forecast reaches: "that far out", "beyond 16 days", "next
    /// month", "yet", "closer to the date" in the reply, or a month, holiday
    /// or date asked about ("Will it snow on Christmas?"). Grux's forecast is
    /// seven days, so a refusal of those is true.
    private static let range = try! NSRegularExpression(pattern: "(?i)\\b(?:that\\s+far|far\\s+(?:out|ahead|off)"
        + "|beyond\\s+(?:\\d+|a|one|two|seven|the\\s+next|that|this)|until\\s+closer|closer\\s+to|next\\s+(?:month|year)"
        + "|months?|weeks?\\s+(?:out|ahead|away|from\\s+now)|\\d+\\s+days|week\\s+ahead|yet|that\\s+(?:date|day)"
        + "|yesterday|last\\s+(?:night|week|weekend|month|year|time)|ago|past|history|historical)\\b")
    private static let monthAsked = try! NSRegularExpression(pattern: "(?i)\\b(?:january|february|march|april|june"
        + "|july|august|september|october|november|december|next\\s+(?:month|year)|in\\s+\\d+\\s+(?:weeks|months)"
        + "|christmas|xmas|thanksgiving|easter|halloween|new\\s+year" + apostrophe + "?s?|hanukkah|valentine"
        + apostrophe + "?s?|\\d{1,2}(?:st|nd|rd|th)|yesterday|last\\s+(?:night|week|weekend|month|year)|ago)\\b|\\b(?:in|this|next|during|for|by)\\s+May\\b")

    private static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: "(?<=[.!?])\\s+|\\n+", with: "\u{0}", options: .regularExpression)
            .split(separator: "\u{0}").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A sentence that says Grux cannot get the weather, after nothing but an
    /// apology, and going on only to point elsewhere.
    private static func refusalSentence(_ sentence: String) -> Bool {
        let ns = sentence as NSString
        for shape in refusalShapes {
            for m in shape.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
                guard matches(lead, ns.substring(to: m.range.location)) else { continue }
                let rest = ns.substring(from: m.range.location + m.range.length)
                let restNS = rest as NSString
                // What follows the refusal in its sentence is only filler ("for
                // you right now", "at the beach", a reason with no weather in
                // it), or a contrast then a pointer or offer. Anything else, a
                // statement or advice however joined, keeps the reply (W50-FIX
                // rounds 8 and 9).
                let bare = pointerTail.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: restNS.length),
                                                                withTemplate: " ")
                guard !matches(advice, bare) else { return false }
                if let c = contrast.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)) {
                    guard matches(restFiller, restNS.substring(to: c.range.location)),
                          pointsElsewhere(restNS.substring(from: c.range.location + c.range.length)) else { return false }
                } else {
                    guard matches(restFiller, rest) else { return false }
                }
                return true
            }
        }
        return false
    }

    /// True when the reply only says Grux cannot get the weather.
    static func refusesWeather(_ reply: String, ask: String = "") -> Bool {
        // A reply that names closures, delays, roads or flights refuses (or
        // points to) something besides the weather (W50-FIX round 8).
        guard !claimsWeather(reply), !matches(range, reply), !matches(monthAsked, ask), !matches(otherTopic, reply)
        else { return false }
        let all = sentences(reply)
        let refusals = all.filter(refusalSentence)
        let bare = all.filter { matches(bareRealTime, $0) }
        let pointers = all.filter(pointsElsewhere)
        guard !refusals.isEmpty || (!bare.isEmpty && !pointers.isEmpty) else { return false }
        return all.allSatisfy { s in
            refusals.contains(s) || bare.contains(s) || pointers.contains(s) || matches(fillerSentence, s)
        }
    }

    /// What replaces a refusal to check the weather: what Grux can do.
    static func canCheck(remembered: WeatherPlace?) -> String {
        if let place = remembered {
            return "I can check the weather: ask \u{201C}What's the weather?\u{201D} and I'll read Open-Meteo, "
                + "a free weather service, for \(place.name), or name a city."
        }
        // D157 item 16: a stranger has never heard of Open-Meteo.
        return "I can check the weather: ask \u{201C}What's the weather in\u{201D} and a city, "
            + "and I'll read Open-Meteo, a free weather service."
    }

    private static let number = try! NSRegularExpression(pattern: "\\d{1,3}")
    /// Readings that say what the day will bring (a high, a low, a chance of
    /// rain): only Grux's own forecast just before can back these, never the
    /// person's question ("below 60?" is not "today's high is 60").
    private static let forecastReading = try! NSRegularExpression(pattern: "(?i)"
        + "(?:\\b(?:high|low)s?\\s+(?:is\\s+|will\\s+be\\s+|of\\s+|around\\s+|near\\s+|at\\s+)?-?\\d{1,3}\\b"
        + "|\\b\\d{1,3}\\s?(?:%|\\s+percent)\\s+chance\\b"
        + "|" + chance + "|" + band + ")")
    private static let dayWord = try! NSRegularExpression(pattern: "(?i)\\b(today|tonight|tomorrow|"
        + "sunday|monday|tuesday|wednesday|thursday|friday|saturday)\\b")

    private static func numbers(_ text: String, _ regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { m -> [String] in
            let part = ns.substring(with: m.range)
            return number.matches(in: part, range: NSRange(location: 0, length: (part as NSString).length))
                .map { (part as NSString).substring(with: $0.range) }
        }
    }

    /// The days a text names, with tonight as today.
    private static func days(_ text: String) -> Set<String> {
        let ns = text as NSString
        return Set(dayWord.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            let d = ns.substring(with: $0.range).lowercased()
            return d == "tonight" ? "today" : d
        })
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// What Grux's own forecast reply just before can back: one entry per day
    /// it gave, the names that day goes by and the numbers said for it. A
    /// one-day reply ("X, now: ... Today:", "X, tomorrow:", "X, on Saturday:")
    /// is one entry with all its numbers; a list ("X, this weekend:" then "-
    /// Saturday: ...") is one per line with that line's numbers only, so
    /// Sunday's high never backs Saturday (W47-FIX). Today and Tomorrow go by
    /// their weekdays too, read from a named line after them, or Saturday and
    /// Sunday in a two-line weekend. Empty when it is not a forecast.
    private static func forecastEntries(_ previous: String) -> [(days: Set<String>, numbers: Set<String>)] {
        let isWeekend = previous.contains(", this weekend:\n")
        if isWeekend || previous.range(of: #", the next (?:\d+ days|day):\n"#, options: .regularExpression) != nil {
            let lines = previous.split(separator: "\n").filter { $0.hasPrefix("- ") && $0.contains(":") }
            let labels = lines.map { line -> String in
                line[line.index(line.startIndex, offsetBy: 2)..<line.firstIndex(of: ":")!].lowercased()
            }
            let named = labels.indices.first { weekdays.contains(labels[$0]) }
            return lines.indices.map { i in
                var names: Set<String> = [labels[i]]
                if let j = named, let w = weekdays.firstIndex(of: labels[j]) {
                    names.insert(weekdays[((w - (j - i)) % 7 + 7) % 7])
                } else if isWeekend, lines.count == 2 {
                    names.insert(i == 0 ? "saturday" : "sunday")
                }
                return (names, Set(numbers(String(lines[i]), number)))
            }
        }
        let all = Set(numbers(previous, number))
        if previous.contains(", now: ") || previous.contains(", today: ") { return [(["today"], all)] }
        if previous.contains(", tomorrow: ") { return [(["tomorrow"], all)] }
        for d in weekdays where previous.lowercased().contains(", on \(d): ") { return [([d], all)] }
        return []
    }

    /// Every reading in the reply is one the person gave (a temperature) or
    /// one Grux's own forecast just before gave, for the same day: advice
    /// about a temperature the person named, or about the forecast Grux just
    /// looked up, is not made up; today's numbers given as tomorrow's are.
    static func readingsBacked(_ reply: String, ask: String, previous: String) -> Bool {
        let fromAsk = Set(numbers(ask, number))
        let all = numbers(reply, reading)
        guard !all.isEmpty else { return false }
        func backedBy(_ fromForecast: Set<String>) -> Bool {
            numbers(reply, forecastReading).allSatisfy { fromForecast.contains($0) }
                && all.allSatisfy { fromAsk.contains($0) || fromForecast.contains($0) }
        }
        let entries = forecastEntries(previous)
        let named = days(reply)
        // No day named: one day's numbers must hold them all.
        guard !named.isEmpty else { return entries.contains { backedBy($0.numbers) } || backedBy([]) }
        // Every day named must be one Grux gave, and only those days' numbers back the reply.
        let used = entries.filter { !$0.days.isDisjoint(with: named) }
        guard named.allSatisfy({ d in used.contains { $0.days.contains(d) } }) else { return backedBy([]) }
        return backedBy(used.reduce(into: Set<String>()) { $0.formUnion($1.numbers) })
    }

    /// `ask`: the person's message; `previous`: Grux's reply just before this one.
    static func vet(reply: String, route: String, results: [ActionClaimGuard.ToolResult],
                    remembered: WeatherPlace?, ask: String, previous: String) -> (text: String, replaced: Bool) {
        guard route == "local",
              !results.contains(where: { backingTools.contains($0.tool) && ActionClaimGuard.completed($0.result) })
        else { return (reply, false) }
        let askRange = NSRange(location: 0, length: (ask as NSString).length)
        if weatherWord.firstMatch(in: ask, range: askRange) != nil, refusesWeather(reply, ask: ask) {
            return (canCheck(remembered: remembered), true)
        }
        guard claimsWeather(reply), !readingsBacked(reply, ask: ask, previous: previous) else { return (reply, false) }
        return (howToAsk(remembered: remembered), true)
    }
}
