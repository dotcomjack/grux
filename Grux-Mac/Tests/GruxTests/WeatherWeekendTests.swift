import XCTest
@testable import Grux

/// D148 (sense pass 18, `logs/s18-chat/replies.txt`): "What's the weather this
/// weekend?" went to the local model, which answered "I can't check the
/// weather for you right now since I'm currently focused on backing up the
/// Mini and in loginwindow mode." Grux already fetches seven days, so the
/// weekend and the week are answered from them, one line per day, with no model.
@MainActor
final class WeatherWeekendTests: XCTestCase {

    // MARK: - The match

    func testTheWeekendAndTheWeekAreWeatherAsks() {
        let cases: [(String, String?, WeatherAsk.Day)] = [
            ("What's the weather this weekend?", nil, .weekend),
            ("What's the weather for the weekend?", nil, .weekend),
            ("Will it rain this weekend?", nil, .weekend),
            ("Will it rain over the weekend in Boston?", "boston", .weekend),
            ("Is it going to snow in Denver this weekend", "denver", .weekend),
            ("What's the forecast for this weekend", nil, .weekend),
            ("How's the weather this coming weekend?", nil, .weekend),
            ("What's the weather on the weekend in Paris, France", "paris, france", .weekend),
            ("weather for this week", nil, .week),
            ("What's the weather this week?", nil, .week),
            ("What's the forecast for the rest of the week?", nil, .week),
            ("What's the weather in Chicago for the week ahead", "chicago", .week),
        ]
        for (text, place, day) in cases {
            XCTAssertEqual(WeatherAsk.match(text), WeatherAsk.Ask(place: place, day: day), text)
        }
    }

    /// Fails toward the model: a weekend past the seven days, or the weekend
    /// asked with another day or hours, is not answered here.
    func testAWeekendItCannotAnswerGoesToTheModel() {
        for text in ["What's the weather next weekend?", "What's the weather this weekend on Saturday",
                     "Will it rain in 2 hours this weekend?", "weather for the week of December 5",
                     "What's the weather this weekend evening", "What's the weather next week?",
                     "Will it rain tomorrow this week?"] {
            XCTAssertNil(WeatherAsk.match(text), text)
        }
    }

    func testTheWeekendAfterAForecastIsAFollowUp() {
        let last = "Boston, Massachusetts, now: 48°F and partly cloudy. Today: overcast, high 52°F, low 40°F."
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        XCTAssertEqual(WeatherAsk.dayFollowUp("And this weekend?", previousReply: last, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .weekend))
        XCTAssertEqual(WeatherAsk.dayFollowUp("What about the rest of the week?", previousReply: last, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .week))
    }

    // MARK: - The answer

    private let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
    private var asked: [URLRequest] = []

    /// Seven days from `first` (a "yyyy-MM-dd" at the place). Day i has code
    /// `codes[i]`, high 50 + i, low 40 + i and a rain chance of 10 * i, except
    /// that day 5 has no chance of rain.
    private func forecast(from first: String) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let start = f.date(from: first)!
        let days = (0..<7).map { "\"\(f.string(from: start.addingTimeInterval(Double($0) * 86_400)))\"" }
        return Data("""
        {"current":{"temperature_2m":47.6,"apparent_temperature":43.2,"weather_code":2,"wind_speed_10m":9.4},
         "daily":{"time":[\(days.joined(separator: ","))],
          "weather_code":[61,3,0,95,71,45,1],
          "temperature_2m_max":[50.0,51.0,52.0,53.0,54.0,55.0,56.0],
          "temperature_2m_min":[40.0,41.0,42.0,43.0,44.0,45.0,46.0],
          "precipitation_probability_max":[0,10,20,30,40,null,60]}}
        """.utf8)
    }

    private func answer(_ ask: WeatherAsk.Ask, from first: String) async -> String {
        let body = forecast(from: first)
        return await WeatherAsk.answer(ask, remembered: home, fahrenheit: true, fetch: { [weak self] request in
            await MainActor.run { self?.asked.append(request) }
            return (body, 200)
        }).reply
    }

    func testTheWeekendIsSaturdayAndSundayOneLineEach() async {
        // Monday Nov 2, 2026: Saturday is day 5, Sunday day 6.
        let reply = await answer(.init(place: nil, day: .weekend), from: "2026-11-02")
        XCTAssertEqual(reply, "Boston, Massachusetts, this weekend:\n"
                       + "- Saturday: fog, high 55°F, low 45°F\n"
                       + "- Sunday: mostly clear, high 56°F, low 46°F, 60% chance of rain")
        // The days only: no hourly block is asked for.
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(asked[0].url?.query?.contains("hourly") ?? true)
    }

    func testOnTheWeekendItselfTheWeekendStartsToday() async {
        // Saturday Nov 7: today and tomorrow.
        let saturday = await answer(.init(place: nil, day: .weekend), from: "2026-11-07")
        XCTAssertEqual(saturday, "Boston, Massachusetts, this weekend:\n"
                       + "- Today: light rain, high 50°F, low 40°F, 0% chance of rain\n"
                       + "- Tomorrow: overcast, high 51°F, low 41°F, 10% chance of rain")
        // Sunday Nov 8: what is left of it is today; next Saturday is not this weekend.
        let sunday = await answer(.init(place: nil, day: .weekend), from: "2026-11-08")
        XCTAssertEqual(sunday, "Boston, Massachusetts, this weekend:\n"
                       + "- Today: light rain, high 50°F, low 40°F, 0% chance of rain")
        // Friday Nov 6: Saturday is tomorrow.
        let friday = await answer(.init(place: nil, day: .weekend), from: "2026-11-06")
        XCTAssertEqual(friday, "Boston, Massachusetts, this weekend:\n"
                       + "- Tomorrow: overcast, high 51°F, low 41°F, 10% chance of rain\n"
                       + "- Sunday: clear, high 52°F, low 42°F, 20% chance of rain")
    }

    func testTheWeekIsEveryDayTheForecastHolds() async {
        let reply = await answer(.init(place: nil, day: .week), from: "2026-11-02")
        XCTAssertEqual(reply, "Boston, Massachusetts, the next 7 days:\n"
                       + "- Today: light rain, high 50°F, low 40°F, 0% chance of rain\n"
                       + "- Tomorrow: overcast, high 51°F, low 41°F, 10% chance of rain\n"
                       + "- Wednesday: clear, high 52°F, low 42°F, 20% chance of rain\n"
                       + "- Thursday: thunderstorms, high 53°F, low 43°F, 30% chance of rain\n"
                       + "- Friday: light snow, high 54°F, low 44°F, 40% chance of rain\n"
                       + "- Saturday: fog, high 55°F, low 45°F\n"
                       + "- Sunday: mostly clear, high 56°F, low 46°F, 60% chance of rain")
    }

    /// The line about what left the Mac starts its own paragraph after the
    /// days, never on the last day's line (live, 11:21 AM: "7% chance of rain
    /// Only the place name went to Open-Meteo").
    func testANewPlaceIsSaidAfterTheDays() async {
        let geo = Data("""
        {"results":[{"name":"Chicago","latitude":41.85,"longitude":-87.65,"country_code":"US","country":"United States","admin1":"Illinois"}]}
        """.utf8)
        let days = forecast(from: "2026-11-02")
        let out = await WeatherAsk.answer(.init(place: "chicago", day: .weekend), remembered: nil, fahrenheit: true,
                                          fetch: { r in (r.url?.host == "geocoding-api.open-meteo.com" ? geo : days, 200) })
        XCTAssertEqual(out.reply, "Chicago, Illinois, this weekend:\n"
                       + "- Saturday: fog, high 55°F, low 45°F\n"
                       + "- Sunday: mostly clear, high 56°F, low 46°F, 60% chance of rain\n\n"
                       + "Only the place name went to Open-Meteo, a free weather service, and I'll use "
                       + "Chicago, Illinois when you ask again; name another city to change it.")
        let moved = await WeatherAsk.answer(.init(place: "chicago", day: .week), remembered: home, fahrenheit: true,
                                            fetch: { r in (r.url?.host == "geocoding-api.open-meteo.com" ? geo : days, 200) })
        XCTAssertTrue(moved.reply.hasSuffix("60% chance of rain\n\nI'll use Chicago, Illinois when you ask again."), moved.reply)
    }

    /// A forecast that ends before the weekend says so, as a day past it does.
    func testAShortForecastSaysWhatItHas() async {
        let body = Data("""
        {"daily":{"time":["2026-11-02","2026-11-03"],"weather_code":[61,3],"temperature_2m_max":[50.0,51.0],
          "temperature_2m_min":[40.0,41.0],"precipitation_probability_max":[0,10]}}
        """.utf8)
        let out = await WeatherAsk.answer(.init(place: nil, day: .weekend), remembered: home, fahrenheit: true,
                                          fetch: { _ in (body, 200) })
        XCTAssertEqual(out.reply, "I only have a forecast for the next 2 days at Boston, Massachusetts.")
    }
    // MARK: - The guard (D148 live, 11:21 AM)

    private let none: [ActionClaimGuard.ToolResult] = []

    /// "And the rest of the week?" after Grux's "Which city are you in?" went
    /// to the model, which wrote "Thursday overcast with 14% rain chance,
    /// Friday partly cloudy with 0% rain"; the guard read only "N% chance of
    /// rain" and let it through. Every way of giving a chance of rain, and a
    /// temperature band, is a reading (W43-P3 item 6's "30 percent", "mid 70s").
    func testAMadeUpWeekInOtherWordsIsReplaced() {
        for reply in [
            "Boston, Massachusetts, the rest of the week (Thursday through Sunday): Thursday overcast with 14% rain "
                + "chance, Friday partly cloudy with 0% rain, Saturday overcast with 9% rain.",
            "There's a 30 percent chance of rain tomorrow.",
            "Expect highs in the mid 70s and sunny skies.",
            "Sunny all week, temperatures in the 60s.",
            "The rain chance is 20% on Friday.",
            "Chance of rain at 40% Saturday, so bring an umbrella.",
            "Snow likely, 80% snow chance Sunday.",
        ] {
            let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                            ask: "And the rest of the week?", previous: WeatherAsk.askForCity)
            XCTAssertTrue(out.replaced, reply)
        }
        for reply in ["Your download is 14% done and the rain sounds app is open.",
                      "Battery at 30 percent; the forecast app needs an update.",
                      "Born in the 70s, she loves rainy days."] {
            XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil,
                                                 ask: "", previous: "").replaced, reply)
        }
    }

    /// Grux's own list of days backs a reply about one of them, as its
    /// one-day forecast does; a day it did not list is still made up.
    func testGruxsOwnListOfDaysBacksAReplyAboutThem() {
        let weekend = "Boston, Massachusetts, this weekend:\n- Saturday: overcast, high 54°F, low 43°F, 14% chance of rain\n"
            + "- Sunday: overcast, high 60°F, low 48°F, 7% chance of rain"
        let backed = WeatherClaimGuard.vet(reply: "Saturday looks dry, only a 14% chance of rain and a high of 54°F.",
                                           route: "local", results: none, remembered: home,
                                           ask: "Should I bring an umbrella Saturday?", previous: weekend)
        XCTAssertFalse(backed.replaced)
        let otherDay = WeatherClaimGuard.vet(reply: "Monday has a 14% chance of rain.", route: "local", results: none,
                                             remembered: home, ask: "And Monday?", previous: weekend)
        XCTAssertTrue(otherDay.replaced)
        let week = "Boston, Massachusetts, the next 7 days:\n- Today: clear, high 52°F, low 42°F, 0% chance of rain\n"
            + "- Tomorrow: rain, high 50°F, low 44°F, 90% chance of rain"
        XCTAssertFalse(WeatherClaimGuard.vet(reply: "Tomorrow has a 90% chance of rain, so take an umbrella.",
                                             route: "local", results: none, remembered: home,
                                             ask: "umbrella tomorrow?", previous: week).replaced)
    }

    /// W47-FIX P2 3: after a list, every number in it backed every listed
    /// day (and the "7" of "the next 7 days"). Each day is backed by its own
    /// line now; a reply naming no day, by one line holding all its numbers.
    func testEachListedDayIsBackedByItsOwnLine() {
        let weekend = "Boston, Massachusetts, this weekend:\n- Saturday: overcast, high 54°F, low 43°F, 14% chance of rain\n"
            + "- Sunday: overcast, high 60°F, low 48°F, 7% chance of rain"
        func vet(_ reply: String, _ previous: String) -> Bool {
            WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                  ask: "And the weekend?", previous: previous).replaced
        }
        XCTAssertTrue(vet("Saturday will be warmest at 60°F with a 7% chance of rain.", weekend), "Sunday's numbers as Saturday's")
        XCTAssertFalse(vet("Sunday will be warmest at 60°F with a 7% chance of rain.", weekend))
        XCTAssertFalse(vet("Only a 14% chance of rain and a high of 54°F, so no umbrella.", weekend), "one line holds both")
        XCTAssertTrue(vet("A high of 60°F and a 14% chance of rain, so no umbrella.", weekend), "two lines mixed")
        XCTAssertFalse(vet("Saturday is 54°F with a 14% chance, Sunday 60°F with 7%.", weekend))
        let week = "Boston, Massachusetts, the next 7 days:\n- Today: clear, high 52°F, low 42°F, 0% chance of rain\n"
            + "- Tomorrow: rain, high 50°F, low 44°F, 90% chance of rain\n- Wednesday: clear, high 51°F, low 40°F, 10% chance of rain"
        XCTAssertTrue(vet("Tomorrow has a 7% chance of rain.", week), "the header's 7 backs nothing")
        // W47-P3 item 5: Today and Tomorrow are known by their weekdays too.
        XCTAssertFalse(vet("Tuesday has a 90% chance of rain, so take an umbrella.", week))
        XCTAssertFalse(vet("Monday stays dry at 0% chance of rain.", week))
        XCTAssertTrue(vet("Tuesday has a 10% chance of rain.", week), "Wednesday's number as Tuesday's")
        let fromSaturday = "Boston, Massachusetts, this weekend:\n- Today: rain, high 50°F, low 40°F, 70% chance of rain\n"
            + "- Tomorrow: clear, high 55°F, low 41°F, 5% chance of rain"
        XCTAssertFalse(vet("Sunday is the better day, only a 5% chance of rain.", fromSaturday))
        XCTAssertTrue(vet("Saturday is the better day, only a 5% chance of rain.", fromSaturday))
    }

    /// W47-FIX P2 4: more wordings of a chance of rain and a band.
    func testMoreWordingsAreReadings() {
        for reply in ["Thursday has a 40% chance of light rain.", "Expect a 20% chance of scattered showers Friday.",
                      "A 60% chance of afternoon thunderstorms tomorrow.", "There's a 40% chance of a shower later.",
                      "Sunny, temperatures in the low to mid 60s.", "Highs in the 70's all week, clear skies.",
                      "Highs in the 70\u{2019}s and sunny."] {
            XCTAssertTrue(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                ask: "And the week?", previous: WeatherAsk.askForCity).replaced, reply)
        }
        for reply in ["There's a 40% chance of my flight being delayed by the storms.",
                      "A 30% chance of the deal closing by Friday."] {
            XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil,
                                                 ask: "", previous: "").replaced, reply)
        }
    }

    /// Round 2 P2 5: more ways of saying a chance of rain.
    func testEvenMoreWordingsAreReadings() {
        for reply in ["Tomorrow looks cloudy and there's a 40% chance it will rain, so bring an umbrella.",
                      "Chance of rain: 40% tomorrow.", "Rain chance: 20% on Friday.", "Chance of rain around 40% Saturday.",
                      "Chance of rain about 40% Saturday.", "Rain chances of 40% on Sunday.", "A 40% chance for rain tomorrow.",
                      "A 40% probability of rain tomorrow.", "Rain: 40% on Friday.", "A 40% chance of precip Thursday."] {
            XCTAssertTrue(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                ask: "And the week?", previous: WeatherAsk.askForCity).replaced, reply)
        }
        for reply in ["There's a 40% chance of my flight being delayed by the storms.",
                      "A 30% chance of the deal closing by Friday.",
                      "Your download is 14% done and the rain sounds app is open.",
                      "There's a 40% chance the package arrives today."] {
            XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil,
                                                 ask: "", previous: "").replaced, reply)
        }
    }

    /// Round 2 P3: one day of forecast is "the next day", not "1 days".
    func testOneDayIsNotOneDays() async {
        let body = Data("""
        {"daily":{"time":["2026-11-02"],"weather_code":[61],"temperature_2m_max":[50.0],
          "temperature_2m_min":[40.0],"precipitation_probability_max":[0]}}
        """.utf8)
        let out = await WeatherAsk.answer(.init(place: nil, day: .weekend), remembered: home, fahrenheit: true,
                                          fetch: { _ in (body, 200) })
        XCTAssertEqual(out.reply, "I only have a forecast for the next day at Boston, Massachusetts.")
    }

    /// Round 3 P2 3: a word between the rain and the number, a bare "60%
    /// chance", and "precipitation" as the only weather word.
    func testTheWordingsRoundThreeFound() {
        for reply in ["Friday: high of 55°F with a 40% chance of precipitation.", "A 40% chance of precipitation on Friday.",
                      "Friday has a 40% chance of rainfall.", "Friday brings a 30% chance of flurries.",
                      "Snowfall chance 30% Friday.", "The chance of rain on Friday is 60%.",
                      "The chance of showers Friday is 60%.", "Rain chance tomorrow is 40%.", "Odds of rain Friday: 60%.",
                      "Rain chances are around 40% on Friday.", "Friday looks rainy, 60% chance."] {
            XCTAssertTrue(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                ask: "And the week?", previous: WeatherAsk.askForCity).replaced, reply)
        }
    }

    /// Round 3 P3 1: a one-day week is "the next day".
    func testAOneDayWeekIsTheNextDay() async {
        let body = Data("""
        {"daily":{"time":["2026-11-02"],"weather_code":[61],"temperature_2m_max":[50.0],
          "temperature_2m_min":[40.0],"precipitation_probability_max":[0]}}
        """.utf8)
        let out = await WeatherAsk.answer(.init(place: nil, day: .week), remembered: home, fahrenheit: true,
                                          fetch: { _ in (body, 200) })
        XCTAssertTrue(out.reply.hasPrefix("Boston, Massachusetts, the next day:\n- Today:"), out.reply)
    }

    /// Round 4 P2 2: an odds word and a percent are not a forecast without
    /// rain; these replies were replaced with the weather refusal.
    func testOddsWithoutRainAreNotAForecast() {
        for reply in ["The forecast puts the odds of a rate cut at 70%.",
                      "Your Q3 sales forecast: the likelihood of hitting target is about 80%.",
                      "The odds of getting in are about 10% for applicants from outside the state.",
                      "The risk of a crash is about 30%, so wind down open apps first.",
                      "Snow Leopard had about a 5% share by then.",
                      "The sales forecast says there's a 70% chance."] {
            XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil,
                                                 ask: "", previous: "").replaced, reply)
        }
    }

    /// Round 4 P3: a one-day list is read back like a longer one.
    func testAOneDayListBacksItsDay() {
        let one = "Boston, Massachusetts, the next day:\n- Today: rain, high 50°F, low 40°F, 70% chance of rain"
        XCTAssertFalse(WeatherClaimGuard.vet(reply: "Today has a 70% chance of rain.", route: "local", results: none,
                                             remembered: home, ask: "rain?", previous: one).replaced)
    }
}
