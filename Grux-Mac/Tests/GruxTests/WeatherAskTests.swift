import XCTest
@testable import Grux

/// D141, live 2026-11-02 5:09 PM on qwen3.5:4b: "What's the weather like where
/// I am today?" came back "I don't know your location, so I can't check the
/// weather for you." Grux had no weather path at all. A plain weather question
/// is now answered from Open-Meteo (free, no key, no account) before any model
/// sees it, sending only the place, and the place is remembered for next time.
@MainActor
final class WeatherAskTests: XCTestCase {

    // MARK: - The match

    func testPlainWeatherQuestionsMatchTheirPlaceAndDay() {
        let cases: [(String, String?, WeatherAsk.Day)] = [
            ("What's the weather like where I am today?", nil, .today),
            ("What is the weather?", nil, .today),
            ("whats the weather", nil, .today),
            ("what\u{2019}s the weather in Boston", "boston", .today),
            ("What's the weather like in Paris tomorrow?", "paris", .tomorrow),
            ("Grux, what's the weather going to be like tomorrow", nil, .tomorrow),
            ("Hey Grux, what's the forecast for Saturday?", nil, .weekday(7)),
            ("weather in new york city", "new york city", .today),
            ("Will it rain tomorrow?", nil, .tomorrow),
            ("Is it going to rain in Seattle today?", "seattle", .today),
            ("Do I need an umbrella today?", nil, .today),
            ("How's the weather outside right now", nil, .today),
            ("What's the weather for Boston, MA", "boston, ma", .today),
            ("Tell me the weather in Lyon on Friday please", "lyon", .weekday(6)),
            ("  What   is the  weather near me ?? ", nil, .today),
            ("what's the weather tonight", nil, .today),
            // W43-FIX round 3, live 12:35 AM: "at all" was taken as a place and
            // Open-Meteo has a village named exactly All, in Spain.
            ("Will it rain at all today?", nil, .today),
            ("Is it going to rain in an hour?", nil, .today),
            ("Will it rain at some point tomorrow?", nil, .tomorrow),
            ("Is it going to snow in a bit", nil, .today),
            // W43-FIX round 4: a day after the state still names the day.
            ("What's the weather in Boston, MA, tomorrow?", "boston, ma", .tomorrow),
            ("Will it rain in Springfield, IL, tomorrow?", "springfield, il", .tomorrow),
            ("What's the forecast for London, Friday?", "london", .weekday(6)),
            // W43-FIX round 5: a time span in words is not a place.
            ("Will it rain in two hours?", nil, .today),
            ("Is it going to snow in ten minutes", nil, .today),
            ("Will it rain in half an hour?", nil, .today),
            ("Will it rain in a couple of hours?", nil, .today),
            // A second comma ends the place on its usual stops.
            ("Weather in Portland, ME, on Friday?", "portland, me", .weekday(6)),
            // W43-P3 item 1: a time span in digits, or "the next few hours", is inside today.
            ("Will it rain in 2 hours?", nil, .today),
            ("Is it going to rain in 30 minutes", nil, .today),
            ("Will it snow in 1 hr", nil, .today),
            ("Will it rain in 45 mins?", nil, .today),
            ("Will it rain in 12 hours?", nil, .today),
            ("Will it rain in 120 minutes?", nil, .today),
            ("Will it rain in the next few hours?", nil, .today),
            ("What's the weather in the next 3 hours", nil, .today),
            ("Will it rain over the next couple of hours?", nil, .today),
            ("Is it going to rain in Seattle in 2 hours?", "seattle", .today),
            ("Will it rain in 2 hours in Boston?", "boston", .today),
            // "this" was taken off before "this evening" was looked for.
            ("What's the weather this evening?", nil, .today),
            ("Will it rain this afternoon in Boston?", "boston", .today),
            ("What's the forecast for this morning", nil, .today),
            ("Will it rain on this Friday?", nil, .weekday(6)),
            // W43-P3 item 2: a state or province code that is also a stop word
            // ("on", "or", "in") is the place's last word when nothing follows it.
            ("What's the weather in Toronto ON?", "toronto on", .today),
            ("Will it rain in London ON", "london on", .today),
            ("weather in Portland OR", "portland or", .today),
            ("What's the weather in Indianapolis IN?", "indianapolis in", .today),
            ("What's the weather in Toronto ON tomorrow?", "toronto", .tomorrow),
            // W45-P3 item 5: a leading "The" with the code in capitals is a name.
            ("What's the weather in The Dalles OR?", "the dalles or", .today),
            ("Will it rain in The Woodlands TX", "the woodlands tx", .today),
            ("Is it going to rain in Ottawa on Friday", "ottawa", .weekday(6)),
        ]
        for (text, place, day) in cases {
            // The place and the day; the hours inside it are WeatherWindowTests' (D146 item 1).
            let m = WeatherAsk.match(text)
            XCTAssertNotNil(m, text)
            XCTAssertEqual(m?.place, place, text)
            XCTAssertEqual(m?.day, day, text)
            XCTAssertFalse(m?.answering ?? true, text)
        }
    }

    /// Fails toward the model: anything that is not a plain weather question
    /// stays with it, so a miss costs one model turn and never a wrong answer.
    func testEverythingElseGoesToTheModel() {
        for text in [
            "I'm feeling under the weather",
            "Whether or not you can, tell me",
            "Write a poem about the weather",
            "What's the weather like in Paris in June?",
            "How does the weather API work",
            "weather app ideas for my startup",
            "What's the weather in Paris and what's on my calendar",
            "What was the weather yesterday?",
            "Will it rain on my parade",
            "What's the weather like in a place where it rains 300 days a year and everyone is sad",
            "",
            // W43-FIX P2-1: a time or a place that is not a place name after in, for or at.
            // ("for the weekend" and "for this week" are answered since D148: WeatherWeekendTests.)
            "Will it rain in the afternoon?",
            "Is it going to rain at night?",
            "What's the weather like at home",
            "What's the weather in the next few days",
            "What's the weather in June",
            "What's the weather like at my house",
            "What's the weather in the",
            // W43-FIX round 2 P2-3: a time or an event is never the place.
            "Will it rain in May?",
            "What's the weather in the fall?",
            "Will it rain tomorrow at noon?",
            "Will it rain at lunch?",
            "weather for christmas",
            "weather for the game tonight",
            "weather for all",
            "Will it rain at five?",
            "Will it rain at noon, please?",
            // W43-P3 item 1: a span past today, or one with no unit, stays with the model.
            "Will it rain in 2 days?",
            "Will it rain in 13 hours?",
            "Will it rain in 48 hours?",
            "Will it rain in 121 minutes?",
            "Will it rain in 0 hours?",
            "Will it rain in 5?",
            "What's the weather in the next 3 days",
            "Will it rain in 2 hours tomorrow?",
        ] {
            XCTAssertNil(WeatherAsk.match(text), text)
        }
    }

    /// W43-FIX round 2 P2-1 and P2-2: real places with a state code after the
    /// comma, or a word that is also an everyday word, are places.
    func testRealPlacesThatLookLikeOtherWordsArePlaces() {
        let places = ["tulsa, ok", "oklahoma city, ok", "honolulu, hi", "boise, id", "portland, me", "nice",
                      "silver spring", "spring hill", "winter park", "great falls", "can tho", "a coruña", "the hague",
                      "new york", "salt lake city, utah", "st. louis"]
        for place in places {
            XCTAssertEqual(WeatherAsk.match("What's the weather in \(place)?"), WeatherAsk.Ask(place: place, day: .today), place)
            XCTAssertEqual(WeatherAsk.cityAnswer(place, after: WeatherAsk.askForCity), place, place)
        }
        XCTAssertEqual(WeatherAsk.cityAnswer("I'm in Nice", after: WeatherAsk.askForCity), "nice")
        // W43-FIX round 3: a state code that is also a little word, and a town named like a time.
        for place in ["portland, or", "indianapolis, in", "toronto, on", "sunrise, fl", "spring, tx",
                      "christmas, fl", "holiday, fl", "new york, new york"] {
            XCTAssertEqual(WeatherAsk.match("What's the weather in \(place)?"), WeatherAsk.Ask(place: place, day: .today), place)
            XCTAssertEqual(WeatherAsk.cityAnswer(place, after: WeatherAsk.askForCity), place, place)
        }
        XCTAssertEqual(WeatherAsk.match("Will it rain in Portland, OR tomorrow?"),
                       WeatherAsk.Ask(place: "portland, or", day: .tomorrow))
    }

    /// The reply to Grux's own "which city" question is a place; anything else is not.
    func testACityAnswersGruxsOwnQuestionOnly() {
        XCTAssertEqual(WeatherAsk.cityAnswer("Boston", after: WeatherAsk.askForCity), "boston")
        XCTAssertEqual(WeatherAsk.cityAnswer("I'm in Lyon, France.", after: WeatherAsk.askForCity), "lyon, france")
        XCTAssertEqual(WeatherAsk.cityAnswer("in san francisco", after: WeatherAsk.askForCity), "san francisco")
        XCTAssertNil(WeatherAsk.cityAnswer("Boston", after: "Something else Grux said."))
        XCTAssertNil(WeatherAsk.cityAnswer("Boston", after: nil))
        for text in ["never mind", "no thanks", "Why do you need that?", "ok", "cancel",
                     "What is on my calendar tomorrow", "I would rather not say where I live right now honestly",
                     // W43-FIX P2-2: none of these is a city, and none may leave the Mac as one.
                     "tell me a joke", "remind me to call mom", "not now", "no, thanks", "later", "great",
                     "I'd rather not", "nah", "maybe later", "hello", "the weekend", "at home",
                     // W43-FIX round 3
                     "idk", "dunno", "whatever", "doesn't matter", "can't say", "anywhere", "pass", "the usual",
                     "same as before", "guess", "tomorrow, please", "hmm, idk"] {
            XCTAssertNil(WeatherAsk.cityAnswer(text, after: WeatherAsk.askForCity), text)
        }
    }

    /// W43-FIX P2-4: the city typed after "Which city?" answers the day first asked.
    func testTheCityAnswerKeepsTheDayFirstAskedFor() {
        XCTAssertEqual(WeatherAsk.followUp("Boston", previousReply: WeatherAsk.askForCity,
                                           previousAsk: "Will it rain tomorrow?"),
                       WeatherAsk.Ask(place: "boston", day: .tomorrow, answering: true))
        XCTAssertEqual(WeatherAsk.followUp("Boston", previousReply: WeatherAsk.askForCity,
                                           previousAsk: "What's the forecast for Saturday?"),
                       WeatherAsk.Ask(place: "boston", day: .weekday(7), answering: true))
        XCTAssertEqual(WeatherAsk.followUp("Boston", previousReply: WeatherAsk.askForCity, previousAsk: nil),
                       WeatherAsk.Ask(place: "boston", day: .today, answering: true))
        XCTAssertNil(WeatherAsk.followUp("Boston", previousReply: "Something else.", previousAsk: "Will it rain tomorrow?"))
    }

    // MARK: - What leaves the Mac

    /// Only the place goes out: the geocoding request names the city and the
    /// forecast request two rounded coordinates, with no cookies, no cache and
    /// no header that could say anything about the person.
    func testTheRequestsCarryOnlyThePlace() throws {
        let geo = WeatherAsk.geocodeRequest(name: "Boston")
        XCTAssertEqual(geo.httpMethod, "GET")
        XCTAssertFalse(geo.httpShouldHandleCookies)
        XCTAssertEqual(geo.url?.host, "geocoding-api.open-meteo.com")
        let geoItems = try XCTUnwrap(geo.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: geoItems.map { ($0.name, $0.value ?? "") }),
                       ["name": "Boston", "count": "10", "language": "en", "format": "json"])
        XCTAssertEqual(geo.allHTTPHeaderFields ?? [:], ["Accept-Language": "en"])

        let fc = WeatherAsk.forecastRequest(latitude: 42.358431, longitude: -71.059773, fahrenheit: true)
        XCTAssertEqual(fc.url?.host, "api.open-meteo.com")
        XCTAssertFalse(fc.httpShouldHandleCookies)
        XCTAssertEqual(fc.allHTTPHeaderFields ?? [:], ["Accept-Language": "en"])
        let fcItems = try XCTUnwrap(fc.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        let fcq = Dictionary(uniqueKeysWithValues: fcItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fcq["latitude"], "42.36")
        XCTAssertEqual(fcq["longitude"], "-71.06")
        XCTAssertEqual(fcq["temperature_unit"], "fahrenheit")
        XCTAssertEqual(fcq["wind_speed_unit"], "mph")
        XCTAssertEqual(fcq["timezone"], "auto")
        XCTAssertEqual(Set(fcq.keys), ["latitude", "longitude", "current", "daily", "timezone",
                                       "forecast_days", "temperature_unit", "wind_speed_unit"])
        let metric = WeatherAsk.forecastRequest(latitude: 48.85, longitude: 2.35, fahrenheit: false)
        let mq = metric.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        XCTAssertTrue(mq.contains(URLQueryItem(name: "temperature_unit", value: "celsius")))
        XCTAssertTrue(mq.contains(URLQueryItem(name: "wind_speed_unit", value: "kmh")))

        let session = WeatherAsk.sessionConfiguration()
        XCTAssertNil(session.httpCookieStorage)
        XCTAssertNil(session.urlCache)
        XCTAssertNil(session.urlCredentialStorage)
    }

    // MARK: - The answer

    private static let bostonGeo = Data("""
    {"results":[{"name":"Boston","latitude":42.35843,"longitude":-71.05977,"country_code":"US","country":"United States","admin1":"Massachusetts"},
    {"name":"Boston","latitude":52.97633,"longitude":-0.02664,"country_code":"GB","country":"United Kingdom","admin1":"England"}]}
    """.utf8)

    private static let forecast = Data("""
    {"current":{"temperature_2m":47.6,"apparent_temperature":43.2,"weather_code":2,"wind_speed_10m":9.4},
     "daily":{"time":["2026-11-02","2026-11-03","2026-11-04","2026-11-05","2026-11-06","2026-11-07","2026-11-08"],
      "weather_code":[61,3,0,95,71,45,1],
      "temperature_2m_max":[55.2,52.0,60.1,58.0,33.0,49.9,51.0],
      "temperature_2m_min":[41.0,38.6,44.0,47.0,28.0,40.0,39.0],
      "precipitation_probability_max":[60,20,0,80,90,null,5]}}
    """.utf8)

    private var asked: [URLRequest] = []

    private func stub(_ responses: [String: Data], failing: Bool = false) -> (URLRequest) async throws -> (Data, Int) {
        { [weak self] request in
            await MainActor.run { self?.asked.append(request) }
            if failing { throw URLError(.notConnectedToInternet) }
            let host = request.url?.host ?? ""
            return (responses[host] ?? Data("{}".utf8), 200)
        }
    }

    private var both: [String: Data] {
        ["geocoding-api.open-meteo.com": Self.bostonGeo, "api.open-meteo.com": Self.forecast]
    }

    func testANamedCityIsLookedUpAndRemembered() async {
        let out = await WeatherAsk.answer(.init(place: "boston, ma", day: .today), remembered: nil,
                                          fahrenheit: true, fetch: stub(both))
        XCTAssertEqual(asked.map { $0.url?.host ?? "" }, ["geocoding-api.open-meteo.com", "api.open-meteo.com"])
        let geoName = asked.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "name" }?.value
        XCTAssertEqual(geoName, "boston", "the hint after the comma picks a result, it is not sent")
        XCTAssertEqual(out.remember, WeatherPlace(name: "Boston, Massachusetts", latitude: 42.35843, longitude: -71.05977))
        XCTAssertEqual(out.reply, """
        Boston, Massachusetts, now: 48°F and partly cloudy, feels like 43°F, wind 9 mph. \
        Today: light rain at times, high 55°F, low 41°F, 60% chance of rain. \
        Only the place name went to Open-Meteo, a free weather service, and I'll use Boston, Massachusetts \
        when you ask again; name another city to change it.
        """)
    }

    /// A bare name takes the geocoder's first result, the best known place
    /// (live 2026-11-02 9:50 PM: preferring the person's own country made
    /// "Paris" Paris, Texas); a hint after a comma picks another.
    func testABareNameTakesTheBestKnownPlaceAndAHintPicksAnother() async {
        let paris = Data("""
        {"results":[{"name":"Paris","latitude":48.85341,"longitude":2.3488,"country_code":"FR","country":"France","admin1":"Île-de-France Region"},
        {"name":"Paris","latitude":33.66094,"longitude":-95.55551,"country_code":"US","country":"United States","admin1":"Texas"}]}
        """.utf8)
        let responses = ["geocoding-api.open-meteo.com": paris, "api.open-meteo.com": Self.forecast]
        let bare = await WeatherAsk.answer(.init(place: "paris", day: .today), remembered: nil,
                                           fahrenheit: true, fetch: stub(responses))
        XCTAssertEqual(bare.remember?.name, "Paris, France")
        for hint in ["paris, tx", "paris, texas", "paris, us"] {
            let named = await WeatherAsk.answer(.init(place: hint, day: .today), remembered: nil,
                                                fahrenheit: true, fetch: stub(responses))
            XCTAssertEqual(named.remember?.name, "Paris, Texas", hint)
        }
    }

    func testARememberedPlaceSendsOnlyItsCoordinates() async {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.35843, longitude: -71.05977)
        let tomorrow = await WeatherAsk.answer(.init(place: nil, day: .tomorrow), remembered: home,
                                               fahrenheit: true, fetch: stub(both))
        XCTAssertEqual(asked.map { $0.url?.host ?? "" }, ["api.open-meteo.com"])
        XCTAssertNil(tomorrow.remember)
        XCTAssertEqual(tomorrow.reply,
                       "Boston, Massachusetts, tomorrow: overcast, high 52°F, low 39°F, 20% chance of rain.")
        // Saturday is the 6th day the forecast holds; a missing chance of rain says nothing about rain.
        let saturday = await WeatherAsk.answer(.init(place: nil, day: .weekday(7)), remembered: home,
                                               fahrenheit: true, fetch: stub(both))
        XCTAssertEqual(saturday.reply, "Boston, Massachusetts, on Saturday: fog, high 50°F, low 40°F.")
        // The same city named again changes nothing and repeats no privacy line.
        let again = await WeatherAsk.answer(.init(place: "boston, ma", day: .tomorrow), remembered: home,
                                            fahrenheit: true, fetch: stub(both))
        XCTAssertNil(again.remember)
        XCTAssertEqual(again.reply, tomorrow.reply)
        // Another city is remembered with one short line; the privacy line was said the first time.
        let paris = WeatherPlace(name: "Paris, France", latitude: 48.85, longitude: 2.35)
        let moved = await WeatherAsk.answer(.init(place: "boston", day: .tomorrow), remembered: paris,
                                            fahrenheit: true, fetch: stub(both))
        XCTAssertEqual(moved.remember?.name, "Boston, Massachusetts")
        XCTAssertEqual(moved.reply, tomorrow.reply + " I'll use Boston, Massachusetts when you ask again.")
    }

    func testNoPlaceAndNoneRememberedAsksWhichCityAndSendsNothing() async {
        let out = await WeatherAsk.answer(.init(place: nil, day: .today), remembered: nil,
                                          fahrenheit: true, fetch: stub(both))
        XCTAssertTrue(asked.isEmpty)
        XCTAssertNil(out.remember)
        XCTAssertEqual(out.reply, WeatherAsk.askForCity)
        XCTAssertTrue(out.reply.contains("Open-Meteo"))
        XCTAssertFalse(out.reply.contains("\u{2014}") || out.reply.contains("\u{2013}"))
    }

    /// W43-FIX round 3: words after in, for or at that name no place exactly
    /// ("at all", "in an hour", "for the commute") are not a place: the
    /// remembered place answers, or Grux asks which city. Open-Meteo matches
    /// loosely, so only a result whose name is the typed name counts.
    func testWordsThatNameNoPlaceExactlyFallBack() async {
        let loose = Data("""
        {"results":[{"name":"Allentown","latitude":40.6,"longitude":-75.49,"country_code":"US","country":"United States","admin1":"Pennsylvania"}]}
        """.utf8)
        let responses = ["geocoding-api.open-meteo.com": loose, "api.open-meteo.com": Self.forecast]
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let withHome = await WeatherAsk.answer(.init(place: "a bit", day: .today), remembered: home,
                                               fahrenheit: true, fetch: stub(responses))
        XCTAssertNil(withHome.remember)
        XCTAssertTrue(withHome.reply.hasPrefix("Boston, Massachusetts, now: 48°F"), withHome.reply)
        let noHome = await WeatherAsk.answer(.init(place: "the commute", day: .today), remembered: nil,
                                             fahrenheit: true, fetch: stub(responses))
        XCTAssertNil(noHome.remember)
        XCTAssertEqual(noHome.reply, WeatherAsk.askForCity)
        // An exact name, written another way, still counts.
        let stl = Data("""
        {"results":[{"name":"St. Louis","latitude":38.63,"longitude":-90.2,"country_code":"US","country":"United States","admin1":"Missouri"}]}
        """.utf8)
        for typed in ["saint louis", "st. louis", "st louis"] {
            let out = await WeatherAsk.answer(.init(place: typed, day: .today), remembered: nil, fahrenheit: true,
                                              fetch: stub(["geocoding-api.open-meteo.com": stl, "api.open-meteo.com": Self.forecast]))
            XCTAssertEqual(out.remember?.name, "St. Louis, Missouri", typed)
        }
        let nyc = Data("""
        {"results":[{"name":"New York","latitude":40.71,"longitude":-74.0,"country_code":"US","country":"United States","admin1":"New York"}]}
        """.utf8)
        let city = await WeatherAsk.answer(.init(place: "new york city", day: .today), remembered: nil, fahrenheit: true,
                                           fetch: stub(["geocoding-api.open-meteo.com": nyc, "api.open-meteo.com": Self.forecast]))
        XCTAssertEqual(city.remember?.name, "New York")
    }

    /// W43-FIX round 4: a city written another way is still found, and one
    /// that is not found is said, never answered for the remembered city alone.
    func testANamedCityIsFoundOrSaidNotFound() async {
        let austin = Data("""
        {"results":[{"name":"Austin","latitude":30.27,"longitude":-97.74,"country_code":"US","country":"United States","admin1":"Texas"},
        {"name":"Austin","latitude":43.67,"longitude":-92.97,"country_code":"US","country":"United States","admin1":"Minnesota"}]}
        """.utf8)
        var names: [String] = []
        let byName: (URLRequest) async throws -> (Data, Int) = { request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value ?? ""
            if request.url?.host == "api.open-meteo.com" { return (Self.forecast, 200) }
            await MainActor.run { names.append(q) }
            return (q == "austin" ? austin : Data(#"{"generationtime_ms":0.1}"#.utf8), 200)
        }
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let texas = await WeatherAsk.answer(.init(place: "austin texas", day: .today), remembered: home,
                                            fahrenheit: true, fetch: byName)
        XCTAssertEqual(texas.remember?.name, "Austin, Texas")
        XCTAssertEqual(names, ["austin texas", "austin"], "the state at the end is tried as the hint")
        let mn = await WeatherAsk.answer(.init(place: "austin mn", day: .today), remembered: home,
                                         fahrenheit: true, fetch: byName)
        XCTAssertEqual(mn.remember?.name, "Austin, Minnesota")
        let typo = await WeatherAsk.answer(.init(place: "cincinatti", day: .today), remembered: home,
                                           fahrenheit: true, fetch: byName)
        XCTAssertNil(typo.remember)
        XCTAssertTrue(typo.reply.hasPrefix("I could not find a place called \u{201C}Cincinatti\u{201D}, so here is "
                                           + "Boston, Massachusetts. Boston, Massachusetts, now: 48°F"), typo.reply)
        // Words that are plainly not a name still fall back quietly.
        let commute = await WeatherAsk.answer(.init(place: "the commute", day: .today), remembered: home,
                                              fahrenheit: true, fetch: byName)
        XCTAssertTrue(commute.reply.hasPrefix("Boston, Massachusetts, now:"), commute.reply)
        // W45-P3 item 5: a name that starts with "The" and ends in a state
        // code ("The Dalles OR", "The Woodlands TX") tries the code as the hint.
        let dalles = Data("""
        {"results":[{"name":"The Dalles","latitude":45.59,"longitude":-121.18,"country_code":"US","country":"United States","admin1":"Oregon"},
        {"name":"The Dalles","latitude":45.6,"longitude":-121.1,"country_code":"US","country":"United States","admin1":"Washington"}]}
        """.utf8)
        var asked: [String] = []
        let theDalles: (URLRequest) async throws -> (Data, Int) = { request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value ?? ""
            if request.url?.host == "api.open-meteo.com" { return (Self.forecast, 200) }
            await MainActor.run { asked.append(q) }
            return (q == "the dalles" ? dalles : Data(#"{"generationtime_ms":0.1}"#.utf8), 200)
        }
        let oregon = await WeatherAsk.answer(.init(place: "the dalles or", day: .today), remembered: home,
                                             fahrenheit: true, fetch: theDalles)
        XCTAssertEqual(oregon.remember?.name, "The Dalles, Oregon", oregon.reply)
        XCTAssertEqual(asked, ["the dalles or", "the dalles"])
        let wa = await WeatherAsk.answer(.init(place: "the dalles wa", day: .today), remembered: home,
                                         fahrenheit: true, fetch: theDalles)
        XCTAssertEqual(wa.remember?.name, "The Dalles, Washington", wa.reply)
        let typoed = await WeatherAsk.answer(.init(place: "the dals or", day: .today), remembered: home,
                                             fahrenheit: true, fetch: theDalles)
        XCTAssertNil(typoed.remember)
        XCTAssertTrue(typoed.reply.hasPrefix("I could not find a place called \u{201C}The Dals Or\u{201D}, so here is "),
                      typoed.reply)
        // W46-P3 item 2: "the" plus a code that is not a stop word ("ok") was
        // never typed as a code by the rule in `match`; it falls back quietly,
        // or asks which city, as before.
        let beach = await WeatherAsk.answer(.init(place: "the beach ok", day: .today), remembered: home,
                                            fahrenheit: true, fetch: theDalles)
        XCTAssertTrue(beach.reply.hasPrefix("Boston, Massachusetts, now:"), beach.reply)
        let beachNoHome = await WeatherAsk.answer(.init(place: "the beach ok", day: .today), remembered: nil,
                                                  fahrenheit: true, fetch: theDalles)
        XCTAssertEqual(beachNoHome.reply, WeatherAsk.askForCity)
        // "the commute" ends in no code, so it still falls back quietly (above).
        XCTAssertEqual(WeatherAsk.alias("nyc"), "new york")
        XCTAssertEqual(WeatherAsk.alias("philly"), "philadelphia")
        XCTAssertEqual(WeatherAsk.comparable("Port Saint Lucie"), WeatherAsk.comparable("Port St. Lucie"))
        XCTAssertEqual(WeatherAsk.comparable("Ft Lauderdale"), WeatherAsk.comparable("Fort Lauderdale"))
        XCTAssertEqual(WeatherAsk.comparable("Lodz"), WeatherAsk.comparable("Łódź"))
    }

    /// W43-FIX round 4: "And tomorrow?" right after a forecast asks for the
    /// same place on that day (the local model copied today's numbers).
    /// W43-FIX round 5: a country, province or state code with no comma is a hint.
    func testACountryOrProvinceCodeIsAHint() async {
        let london = Data("""
        {"results":[{"name":"London","latitude":51.5,"longitude":-0.12,"country_code":"GB","country":"United Kingdom","admin1":"England"},
        {"name":"London","latitude":42.98,"longitude":-81.23,"country_code":"CA","country":"Canada","admin1":"Ontario"}]}
        """.utf8)
        let vancouver = Data("""
        {"results":[{"name":"Vancouver","latitude":49.25,"longitude":-123.12,"country_code":"CA","country":"Canada","admin1":"British Columbia"}]}
        """.utf8)
        let sydney = Data("""
        {"results":[{"name":"Sydney","latitude":-33.87,"longitude":151.21,"country_code":"AU","country":"Australia","admin1":"New South Wales"}]}
        """.utf8)
        let byName: (URLRequest) async throws -> (Data, Int) = { request in
            if request.url?.host == "api.open-meteo.com" { return (Self.forecast, 200) }
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value ?? ""
            return ([ "london": london, "vancouver": vancouver, "sydney": sydney][q] ?? Data("{}".utf8), 200)
        }
        for (typed, name) in [("london uk", "London, United Kingdom"), ("london on", "London, Canada"),
                              ("vancouver bc", "Vancouver, Canada"), ("sydney nsw", "Sydney, Australia"),
                              ("london england", "London, United Kingdom"), ("london, uk", "London, United Kingdom")] {
            let out = await WeatherAsk.answer(.init(place: typed, day: .today), remembered: nil, fahrenheit: true, fetch: byName)
            XCTAssertEqual(out.remember?.name, name, typed)
        }
        XCTAssertEqual(WeatherAsk.cityAnswer("Boston, please", after: WeatherAsk.askForCity), "boston")
        XCTAssertEqual(WeatherAsk.cityAnswer("boston please", after: WeatherAsk.askForCity), "boston")
    }

    func testADayFollowUpAfterAForecastIsAWeatherAsk() {
        let last = "Boston, Massachusetts, now: 48°F and partly cloudy. Today: overcast, high 52°F, low 40°F."
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let cases: [(String, WeatherAsk.Day, WeatherAsk.Window?)] = [
            ("And tomorrow?", .tomorrow, nil), ("what about tomorrow", .tomorrow, nil),
            ("How about Saturday?", .weekday(7), nil), ("and on friday?", .weekday(6), nil), ("And today?", .today, nil),
            // W43-P3 item 4: "later" asked as a question after a forecast is later today,
            // and since D146 item 1 the rest of today's hours.
            ("And later today?", .today, .restOfDay), ("and later?", .today, .restOfDay),
            ("What about later?", .today, .restOfDay),
            ("how about this evening", .today, .hours(from: 17, to: 21)),
        ]
        for (text, day, window) in cases {
            XCTAssertEqual(WeatherAsk.dayFollowUp(text, previousReply: last, remembered: home),
                           WeatherAsk.Ask(place: nil, day: day, window: window), text)
        }
        XCTAssertNil(WeatherAsk.dayFollowUp("And tomorrow?", previousReply: "Something else.", remembered: home))
        XCTAssertNil(WeatherAsk.dayFollowUp("And tomorrow?", previousReply: last, remembered: nil))
        XCTAssertNil(WeatherAsk.dayFollowUp("And tomorrow, remind me to call mom", previousReply: last, remembered: home))
        XCTAssertNil(WeatherAsk.dayFollowUp("Later!", previousReply: last, remembered: home), "a sign-off")
        XCTAssertNil(WeatherAsk.dayFollowUp("later", previousReply: last, remembered: home), "a sign-off")
        XCTAssertNil(WeatherAsk.dayFollowUp("Later, thanks", previousReply: last, remembered: home), "a sign-off")
    }

    func testAPlaceNobodyKnowsAndANetworkFailureSayWhatHappened() async {
        let unknown = await WeatherAsk.answer(.init(place: "zzqx", day: .today, answering: true), remembered: nil,
                                              fahrenheit: true,
                                              fetch: stub(["geocoding-api.open-meteo.com": Data(#"{"generationtime_ms":0.1}"#.utf8)]))
        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(unknown.remember)
        XCTAssertEqual(unknown.reply, "I could not find a place called \u{201C}Zzqx\u{201D}. Try a city name, for example \u{201C}Boston\u{201D}.")
        asked = []
        let down = await WeatherAsk.answer(.init(place: "boston", day: .today), remembered: nil,
                                           fahrenheit: true, fetch: stub(both, failing: true))
        XCTAssertNil(down.remember)
        XCTAssertTrue(down.reply.hasPrefix("I could not reach Open-Meteo, the weather service, just now"), down.reply)
    }

    /// W43-FIX P3s: a geocoder body that is not JSON is a failed request, not
    /// an unknown place; a forecast with nothing in it says so, never "today: .".
    func testABrokenAnswerSaysTheServiceFailed() async {
        let garbled = await WeatherAsk.answer(.init(place: "boston", day: .today), remembered: nil, fahrenheit: true,
                                              fetch: stub(["geocoding-api.open-meteo.com": Data("<html>".utf8)]))
        XCTAssertTrue(garbled.reply.hasPrefix("I could not reach Open-Meteo"), garbled.reply)
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let empty = Data(#"{"daily":{"time":["2026-11-02","2026-11-03"],"weather_code":[null,null]}}"#.utf8)
        for day in [WeatherAsk.Day.today, .tomorrow] {
            let out = await WeatherAsk.answer(.init(place: nil, day: day), remembered: home, fahrenheit: true,
                                              fetch: stub(["api.open-meteo.com": empty]))
            XCTAssertTrue(out.reply.hasPrefix("I could not reach Open-Meteo"), out.reply)
        }
    }

    func testMetricUnitsReadInCelsiusAndKilometres() async {
        let paris = WeatherPlace(name: "Paris, France", latitude: 48.85, longitude: 2.35)
        let metric = Data("""
        {"current":{"temperature_2m":8.4,"apparent_temperature":6.0,"weather_code":0,"wind_speed_10m":15.2},
         "daily":{"time":["2026-11-02"],"weather_code":[0],"temperature_2m_max":[12.0],
          "temperature_2m_min":[4.6],"precipitation_probability_max":[0]}}
        """.utf8)
        let out = await WeatherAsk.answer(.init(place: nil, day: .today), remembered: paris, fahrenheit: false, fetch: stub(["api.open-meteo.com": metric]))
        XCTAssertEqual(out.reply, "Paris, France, now: 8°C and clear, feels like 6°C, wind 15 km/h. "
                       + "Today: clear, high 12°C, low 5°C, 0% chance of rain.")
    }

    /// Words after "at" or "for" that name no place Open-Meteo knows ("at the
    /// beach") answered the remembered city with nothing saying so (D149 item
    /// 3, sense pass 18). The reply now ends naming the city it used; it still
    /// starts with the place, so "And tomorrow?" follows it.
    func testAPlaceGruxCannotFindSaysWhichCityItUsed() async {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.35843, longitude: -71.05977)
        let used = " I used Boston, Massachusetts, the city you gave me before; name a city to ask about another."
        let nowhere: [String: Data] = ["geocoding-api.open-meteo.com": Data("{}".utf8), "api.open-meteo.com": Self.forecast]
        for words in ["the beach", "the commute", "the beach ok"] {
            let out = await WeatherAsk.answer(.init(place: words, day: .today), remembered: home,
                                              fahrenheit: true, fetch: stub(nowhere))
            XCTAssertTrue(out.reply.hasPrefix("Boston, Massachusetts, now: 48°F"), out.reply)
            XCTAssertTrue(out.reply.hasSuffix(used), "\(words): \(out.reply)")
            XCTAssertNil(out.remember)
            XCTAssertNotNil(WeatherAsk.dayFollowUp("And tomorrow?", previousReply: out.reply, remembered: home),
                            "a follow-up still reads the reply as Boston's")
        }
        let weekend = await WeatherAsk.answer(.init(place: "the beach", day: .weekend), remembered: home,
                                              fahrenheit: true, now: Date(timeIntervalSince1970: 1_762_000_000),
                                              fetch: stub(nowhere))
        XCTAssertTrue(weekend.reply.hasSuffix("\n\n" + used.dropFirst()), weekend.reply)
        // No place words, a name Grux could not find, or a city it found: no line.
        let plain = await WeatherAsk.answer(.init(place: nil, day: .today), remembered: home,
                                            fahrenheit: true, fetch: stub(nowhere))
        XCTAssertFalse(plain.reply.contains("I used"), plain.reply)
        let typo = await WeatherAsk.answer(.init(place: "Cincinatti", day: .today), remembered: home,
                                           fahrenheit: true, fetch: stub(nowhere))
        XCTAssertTrue(typo.reply.hasPrefix("I could not find a place called"), typo.reply)
        XCTAssertFalse(typo.reply.contains("I used"), typo.reply)
        let found = await WeatherAsk.answer(.init(place: "boston", day: .today), remembered: home,
                                            fahrenheit: true, fetch: stub(both))
        XCTAssertFalse(found.reply.contains("I used"), found.reply)
    }

    /// Open-Meteo's daily code is the day's worst weather, so "now: clear"
    /// beside "Today: overcast" read as a contradiction (D149 item 2, sense
    /// pass 18). When the two differ, the day's weather is said "at times".
    func testTheDaysWeatherBesideADifferentNowSaysAtTimes() async {
        let paris = WeatherPlace(name: "Paris, France", latitude: 48.85, longitude: 2.35)
        func reply(now: Int?, day: Int?) async -> String {
            let current = now.map { ",\"weather_code\":\($0)" } ?? ""
            let daily = day.map { "\($0)" } ?? "null"
            let data = Data("""
            {"current":{"temperature_2m":8.4\(current)},
             "daily":{"time":["2026-11-02"],"weather_code":[\(daily)],"temperature_2m_max":[12.0]}}
            """.utf8)
            return await WeatherAsk.answer(.init(place: nil, day: .today), remembered: paris, fahrenheit: false,
                                           fetch: stub(["api.open-meteo.com": data])).reply
        }
        let clearThenOvercast = await reply(now: 0, day: 3)
        XCTAssertEqual(clearThenOvercast, "Paris, France, now: 8°C and clear. Today: overcast at times, high 12°C.")
        let rainThenStorms = await reply(now: 61, day: 95)
        XCTAssertEqual(rainThenStorms, "Paris, France, now: 8°C and light rain. Today: thunderstorms at times, high 12°C.")
        let same = await reply(now: 3, day: 3)
        XCTAssertEqual(same, "Paris, France, now: 8°C and overcast. Today: overcast, high 12°C.")
        let fogAndFog = await reply(now: 45, day: 48)
        XCTAssertEqual(fogAndFog, "Paris, France, now: 8°C and fog. Today: fog, high 12°C.",
                       "two codes with one name are one weather")
        let noNowCode = await reply(now: nil, day: 3)
        XCTAssertEqual(noNowCode, "Paris, France, now: 8°C. Today: overcast, high 12°C.",
                       "with no weather now there is nothing to contradict")
        let noDayCode = await reply(now: 0, day: nil)
        XCTAssertEqual(noDayCode, "Paris, France, now: 8°C and clear. Today: high 12°C.")
    }

    // MARK: - In chat

    private var savedOffline = false
    private var savedChat: [ChatMessage] = []
    private var savedFetch: ((URLRequest) async throws -> (Data, Int))!
    private var savedPlace: WeatherPlace?

    override func setUp() async throws {
        try await super.setUp()
        asked = []
        savedOffline = AppState.shared.offlineMode
        savedChat = AppState.shared.chat
        savedFetch = WeatherAsk.fetch
        savedPlace = AppState.shared.config.weatherPlace
    }

    override func tearDown() async throws {
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chat = savedChat
        WeatherAsk.fetch = savedFetch
        AppState.shared.config.weatherPlace = savedPlace
        try await super.tearDown()
    }

    /// The live question, then the city, with no model attached at all: Grux
    /// asks which city, takes the answer, and replies with the forecast. In
    /// offline mode, which first run turns on for everyone who picks Grux Local
    /// (live 2026-11-02 9:42 PM: the first build refused here and dead-ended
    /// exactly that person): a forecast is not a hosted model.
    func testTheAskThenTheCityAnswerInChatWithNoModel() async {
        AppState.shared.offlineMode = true
        AppState.shared.config.weatherPlace = nil
        AppState.shared.chat = []
        WeatherAsk.fetch = stub(both)

        await ChatService.shared.send(userText: "What's the weather like where I am today?")
        XCTAssertEqual(AppState.shared.chat.map(\.role), [.user, .assistant])
        XCTAssertEqual(AppState.shared.chat.last?.content, WeatherAsk.askForCity)
        XCTAssertTrue(asked.isEmpty)

        await ChatService.shared.send(userText: "Boston")
        XCTAssertEqual(AppState.shared.chat.map(\.role), [.user, .assistant, .user, .assistant])
        let reply = AppState.shared.chat.last?.content ?? ""
        XCTAssertTrue(reply.hasPrefix("Boston, Massachusetts, now: 48°F"), reply)
        XCTAssertEqual(AppState.shared.config.weatherPlace?.name, "Boston, Massachusetts")
    }

    /// Order in send(): after the calendar ask, before the PIM route and the
    /// readiness guard, so it needs no model.
    func testTheRouteSitsBeforeThePIMRouteAndTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let calendar = try XCTUnwrap(src.range(of: "CalendarAsk.window(for: trimmed)"))
        let route = try XCTUnwrap(src.range(of: "WeatherAsk.match(trimmed)"))
        let pim = try XCTUnwrap(src.range(of: "ChatIntentClassifier.pimRoute(utterance: trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(calendar.lowerBound < route.lowerBound && route.lowerBound < pim.lowerBound
                      && pim.lowerBound < readiness.lowerBound)
    }

    // MARK: - D154: a spot near you is your saved city

    /// D154, sense pass 19 (`s19-shots/chat-page1.png`): "Will it rain at the
    /// beach?" and "Should I bring an umbrella to the park?" went to the local
    /// model (a beach is not a city, and Beach, North Dakota is one), which
    /// said it could not check the weather, and the guard swapped in only a
    /// pointer. A spot people mean as "near me" is now the saved city, said
    /// so, the way "for the commute" is; with no saved city Grux asks which.
    func testASpotNearYouIsTheSavedCity() {
        let cases: [(String, WeatherAsk.Day, WeatherAsk.Window?)] = [
            ("Will it rain at the beach?", .today, nil),
            ("Should I bring an umbrella to the park?", .today, nil),
            ("Do I need an umbrella at the park?", .today, nil),
            ("What's the weather in town tomorrow?", .tomorrow, nil),
            ("Is it going to snow at the airport tonight?", .today, .hours(from: 18, to: 24)),
            ("How's the weather in the city", .today, nil),
            ("weather for the area this weekend", .weekend, nil),
            ("What's the weather like in the neighborhood?", .today, nil),
            ("Should I take an umbrella to the beach on Saturday?", .weekday(7), nil),
            ("Will it rain at beach", .today, nil),
            ("Will it rain at the beach, please?", .today, nil),
        ]
        for (text, day, window) in cases {
            XCTAssertEqual(WeatherAsk.match(text), WeatherAsk.Ask(place: nil, day: day, window: window, nearby: true), text)
        }
        // A real place stays a place; "to" leads only a spot; an event, or a
        // spot beside a city, stays with the model as before.
        XCTAssertEqual(WeatherAsk.match("Should I bring an umbrella in Boston?"), WeatherAsk.Ask(place: "boston", day: .today))
        XCTAssertEqual(WeatherAsk.match("Should I bring an umbrella?"), WeatherAsk.Ask(place: nil, day: .today))
        XCTAssertEqual(WeatherAsk.match("What's the weather in Beach, ND?"), WeatherAsk.Ask(place: "beach, nd", day: .today))
        for text in ["Should I bring an umbrella to Boston?", "Will it rain at the beach in Miami?",
                     "Will it rain in Miami at the beach?", "weather for the game tonight", "Will it rain for the wedding?",
                     "Should I bring an umbrella to the party?", "Will it rain at the beach near me?",
                     "Will it rain around here at the park?", "Should I bring an umbrella to", "Will it rain at the park and the beach?",
                     "Should I bring an umbrella to work?", "Should I bring my umbrella to the park?"] {
            XCTAssertNil(WeatherAsk.match(text), text)
        }
    }

    func testANearbyAskAnswersTheSavedCityAndSaysSo() async {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.35843, longitude: -71.05977)
        let used = " I used Boston, Massachusetts, the city you gave me before; name a city to ask about another."
        asked = []
        let out = await WeatherAsk.answer(.init(place: nil, day: .today, nearby: true), remembered: home,
                                          fahrenheit: true, fetch: stub(both))
        XCTAssertTrue(out.reply.hasPrefix("Boston, Massachusetts, now: 48°F"), out.reply)
        XCTAssertTrue(out.reply.hasSuffix(used), out.reply)
        XCTAssertNil(out.remember)
        XCTAssertEqual(asked.map { $0.url?.host ?? "" }, ["api.open-meteo.com"], "a spot is never sent to the geocoder")
        let none = await WeatherAsk.answer(.init(place: nil, day: .today, nearby: true), remembered: nil,
                                           fahrenheit: true, fetch: stub(both))
        XCTAssertEqual(none.reply, WeatherAsk.askForCity)
        // The city typed after "Which city" answers the day first asked.
        XCTAssertEqual(WeatherAsk.followUp("Boston", previousReply: WeatherAsk.askForCity,
                                           previousAsk: "Will it rain at the beach tomorrow?"),
                       WeatherAsk.Ask(place: "boston", day: .tomorrow, answering: true))
    }

    // MARK: - D154: a local turn about the weather is told Grux reads it

    /// The class fix: a weather ask the fast path leaves to a local model
    /// carries one line saying Grux reads the forecast and how to ask, so the
    /// model writes the right line itself instead of "I can't check the
    /// weather"; `WeatherClaimGuard` stays as the backstop.
    func testALocalWeatherTurnIsToldGruxReadsTheForecast() throws {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.35, longitude: -71.06)
        for ask in ["Any rain for my picnic this afternoon?", "Is it a good day for the beach, weather wise?",
                    "Will the snow stop by Friday next week?", "what's the weather looking like for my trip",
                    "Do I need an umbrella for the game in Chicago?", "is it RAINING"] {
            let note = try XCTUnwrap(WeatherAsk.localNote(ask: ask, remembered: home), ask)
            XCTAssertTrue(note.hasPrefix("WEATHER: "), note)
            XCTAssertTrue(note.contains("\u{201C}What's the weather?\u{201D}") && note.contains("Boston, Massachusetts"), note)
            XCTAssertTrue(note.contains("never say you cannot check the weather"), note)
            XCTAssertTrue(note.contains("never make up a forecast (one Grux gave above may be repeated)"), note)
        }
        let noHome = try XCTUnwrap(WeatherAsk.localNote(ask: "Any rain this afternoon?", remembered: nil))
        XCTAssertTrue(noHome.contains("\u{201C}What's the weather in\u{201D} and a city"), noHome)
        XCTAssertFalse(noHome.contains("Boston"), noHome)
        // Not about the weather: no line, so an everyday turn reads no more tokens.
        for ask in ["what is two plus two", "Is the cat outside?", "What's the brain made of?", "Read me the train times",
                    "the wind-up of the meeting", "Rainbow Road is my favorite track", "Show me my snowboard notes", "",
                    // W51-FIX P3 4: a business forecast and a prayer are not the weather.
                    "Draft the Q3 sales forecast", "what's our revenue forecast", "say a Hail Mary for me"] {
            XCTAssertNil(WeatherAsk.localNote(ask: ask, remembered: home), ask)
        }
        // The cost when it rides, measured in the per-turn block's own units.
        let note = try XCTUnwrap(WeatherAsk.localNote(ask: "any rain?", remembered: home))
        XCTAssertLessThanOrEqual(LocalTurn.tokens(chars: note.count), 90, "the weather line grew: \(note.count) chars")
    }

    func testTheWeatherLineRidesOnlyOnALocalWeatherTurn() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        func text(_ lean: Bool, _ ask: String) -> String {
            state.chat = [ChatMessage(role: .user, content: ask)]
            return ChatService.shared.assemblePendingContext(state: state, lean: lean, window: 16_384)
                .systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        XCTAssertTrue(text(true, "Any rain for my picnic this afternoon?").contains("WEATHER: "), "the local turn was not told")
        XCTAssertFalse(text(false, "Any rain for my picnic this afternoon?").contains("WEATHER: "), "a cloud turn carries it")
        XCTAssertFalse(text(true, "what is two plus two").contains("WEATHER: "), "an everyday turn carries it")
    }
}
