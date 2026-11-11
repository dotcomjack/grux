import XCTest
@testable import Grux

/// D146 item 1 with W44-P3 items 3 and 4 (sense pass 17, `logs/s17-shots/chat-page1.png`):
/// "Will it rain in 2 hours?", "this evening" and "the next few hours" were
/// answered with now plus the whole day, never the hours asked about; "in
/// twenty hours" skipped the 12-hour limit digits keep; and a span late in the
/// evening could not reach past midnight. The hours asked about are now read
/// from Open-Meteo's hourly forecast, across midnight when the span goes there.
@MainActor
final class WeatherWindowTests: XCTestCase {

    typealias W = WeatherAsk.Window

    // MARK: - The match

    func testASpanOrAPartOfTheDayIsTheWindowAsked() {
        let cases: [(String, String?, WeatherAsk.Day, W?)] = [
            ("Will it rain in 2 hours?", nil, .today, .next(hours: 2)),
            ("Is it going to rain in 30 minutes", nil, .today, .next(hours: 1)),
            ("Will it rain in 120 minutes?", nil, .today, .next(hours: 2)),
            ("Will it rain in 12 hours?", nil, .today, .next(hours: 12)),
            ("Will it rain in half an hour?", nil, .today, .next(hours: 1)),
            ("Is it going to rain in an hour?", nil, .today, .next(hours: 1)),
            ("Will it rain in the next hour?", nil, .today, .next(hours: 1)),
            ("Will it snow over the next hour", nil, .today, .next(hours: 1)),
            ("Will it rain in the next few hours?", nil, .today, .next(hours: 3)),
            ("Will it rain over the next couple of hours?", nil, .today, .next(hours: 2)),
            ("Is it going to snow in twenty minutes", nil, .today, .next(hours: 1)),
            ("Will it rain in twelve hours?", nil, .today, .next(hours: 12)),
            ("Is it going to rain in Seattle in 2 hours?", "seattle", .today, .next(hours: 2)),
            ("What's the weather this evening?", nil, .today, .hours(from: 17, to: 21)),
            ("Will it rain this afternoon in Boston?", "boston", .today, .hours(from: 12, to: 17)),
            ("What's the forecast for this morning", nil, .today, .hours(from: 6, to: 12)),
            ("what's the weather tonight", nil, .today, .hours(from: 18, to: 24)),
            ("Will it rain tomorrow morning?", nil, .tomorrow, .hours(from: 6, to: 12)),
            ("What's the weather tomorrow night in Paris", "paris", .tomorrow, .hours(from: 18, to: 24)),
            ("What's the weather later today?", nil, .today, .restOfDay),
            // W45-FIX P2: "later" narrowed by a part of the day is that part.
            ("Will it rain later tonight?", nil, .today, .hours(from: 18, to: 24)),
            ("What's the weather later this evening?", nil, .today, .hours(from: 17, to: 21)),
            ("Is it going to snow later this afternoon in Denver", "denver", .today, .hours(from: 12, to: 17)),
            // W45-P3 round 2 item 1: "later on" and "later in the" say the same.
            ("Will it rain later on tonight?", nil, .today, .hours(from: 18, to: 24)),
            ("What's the weather later on this evening?", nil, .today, .hours(from: 17, to: 21)),
            ("Is it going to rain later in the evening?", nil, .today, .hours(from: 17, to: 21)),
            ("Will it snow later in the afternoon in Denver", "denver", .today, .hours(from: 12, to: 17)),
            ("Will it rain later in the morning?", nil, .today, .hours(from: 6, to: 12)),
            ("Will it rain later in the night?", nil, .today, .hours(from: 18, to: 24)),
            ("Will it rain later on today?", nil, .today, .restOfDay),
            ("Will it rain later on?", nil, .today, .restOfDay),
            // No window: the whole day, as before.
            ("Will it rain today?", nil, .today, nil),
            ("Will it rain tomorrow?", nil, .tomorrow, nil),
            ("Is it going to snow in a bit", nil, .today, nil),
        ]
        for (text, place, day, window) in cases {
            XCTAssertEqual(WeatherAsk.match(text), WeatherAsk.Ask(place: place, day: day, window: window), text)
        }
    }

    /// Spelled out, as in digits: more than 12 hours ahead may be tomorrow or
    /// later, so it goes to the model (W44-P3 item 3).
    func testASpanPastTwelveHoursGoesToTheModel() {
        for text in ["Will it rain in twenty hours?", "Will it rain over the next thirty hours?",
                     "Is it going to rain in fifteen hours", "Will it snow in forty five hours",
                     "Will it rain in 13 hours?", "Will it rain this evening in 2 hours?"] {
            XCTAssertNil(WeatherAsk.match(text), text)
        }
    }

    /// W44-P3 item 5: a sentence cut off after "on", "or" or "in" read the
    /// stop as a province or state code and sent "the game on" to the
    /// geocoder. The code ends a place only after words that read as a name.
    func testATrailingStopAfterANonNameIsNoPlace() {
        for text in ["Will it rain for the game on", "Will it rain for the party in",
                     "Is it going to snow at the airport or"] {
            XCTAssertNil(WeatherAsk.match(text), text)
        }
        // W45-P3 item 5: "The" is a name's first word only when the code is
        // written as a code, in capitals; "for the game on" stays cut off.
        XCTAssertEqual(WeatherAsk.match("Will it rain in The Dalles OR")?.place, "the dalles or")
        XCTAssertNil(WeatherAsk.match("Will it rain in the dalles or"))
        XCTAssertEqual(WeatherAsk.match("What's the weather in Toronto ON?")?.place, "toronto on")
        XCTAssertEqual(WeatherAsk.match("weather in Portland OR")?.place, "portland or")
    }

    func testFollowUpsKeepTheWindow() {
        let city = WeatherAsk.followUp("Boston", previousReply: WeatherAsk.askForCity,
                                       previousAsk: "Will it rain this evening?")
        XCTAssertEqual(city, WeatherAsk.Ask(place: "boston", day: .today, window: .hours(from: 17, to: 21), answering: true))
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let previous = "Boston, Massachusetts, today: overcast, high 52°F, low 39°F."
        XCTAssertEqual(WeatherAsk.dayFollowUp("And tonight?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .hours(from: 18, to: 24)))
        XCTAssertEqual(WeatherAsk.dayFollowUp("And later?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .restOfDay))
        XCTAssertEqual(WeatherAsk.dayFollowUp("And later tonight?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .hours(from: 18, to: 24)))
        // W46-P3 item 1: "Later on!" is a goodbye, like "Later!"; asked, it is a question.
        XCTAssertNil(WeatherAsk.dayFollowUp("Later on!", previousReply: previous, remembered: home))
        XCTAssertEqual(WeatherAsk.dayFollowUp("And later on?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .restOfDay))
        XCTAssertEqual(WeatherAsk.dayFollowUp("And later on tonight?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .hours(from: 18, to: 24)))
        XCTAssertEqual(WeatherAsk.dayFollowUp("What about later in the evening?", previousReply: previous, remembered: home),
                       WeatherAsk.Ask(place: nil, day: .today, window: .hours(from: 17, to: 21)))
    }

    // MARK: - The request

    func testHourlyIsAskedOnlyForAWindow() throws {
        func keys(_ r: URLRequest) -> [String: String] {
            let items = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        let day = keys(WeatherAsk.forecastRequest(latitude: 42.36, longitude: -71.06, fahrenheit: true))
        XCTAssertNil(day["hourly"])
        let hours = keys(WeatherAsk.forecastRequest(latitude: 42.36, longitude: -71.06, fahrenheit: true, hourly: true))
        XCTAssertEqual(hours["hourly"], "weather_code,temperature_2m,precipitation_probability")
        XCTAssertEqual(Set(hours.keys), Set(day.keys).union(["hourly"]), "nothing else is added")
    }

    // MARK: - The answer

    private let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)

    /// Two days of hours. Hour h on Nov 2 has code `codes[h]`, temperature 40 + h,
    /// rain chance `rain[h]`; Nov 3 hour h has code 3, 30 + h and 10%.
    private func forecast(now: String, offset: Int?) -> Data {
        var times: [String] = [], codes: [Int] = [], temps: [Double] = [], rain: [Int] = []
        for h in 0..<24 {
            times.append(String(format: "2026-11-02T%02d:00", h))
            codes.append(h >= 21 ? 61 : (h >= 17 ? 2 : 0))
            temps.append(40 + Double(h))
            rain.append(h >= 21 ? 70 : (h >= 17 ? 20 : 0))
        }
        for h in 0..<24 {
            times.append(String(format: "2026-11-03T%02d:00", h))
            codes.append(3); temps.append(30 + Double(h)); rain.append(10)
        }
        func list<T>(_ a: [T]) -> String { a.map { "\($0)" }.joined(separator: ",") }
        return Data("""
        {\(offset.map { "\"utc_offset_seconds\":\($0)," } ?? "")"current":{"time":"\(now)","temperature_2m":47.6,"apparent_temperature":43.2,"weather_code":2,"wind_speed_10m":9.4},
         "daily":{"time":["2026-11-02","2026-11-03"],"weather_code":[61,3],"temperature_2m_max":[63.0,53.0],
          "temperature_2m_min":[40.0,30.0],"precipitation_probability_max":[70,10]},
         "hourly":{"time":[\(times.map { "\"\($0)\"" }.joined(separator: ","))],
          "weather_code":[\(list(codes))],"temperature_2m":[\(list(temps))],"precipitation_probability":[\(list(rain))]}}
        """.utf8)
    }

    private var asked: [URLRequest] = []

    /// `now` is the clock at the place. Open-Meteo's `current.time` steps by
    /// 15 minutes, so the fixture's is `now` rounded down to the quarter hour
    /// (W45-P3 round 2 item 2), and the Mac's clock is `now` at `offset`.
    private func answer(_ ask: WeatherAsk.Ask, now: String, offset: Int? = -5 * 3600) async -> String {
        let minute = Int(now.suffix(2))!
        let quarter = String(now.dropLast(2)) + String(format: "%02d", minute - minute % 15)
        let body = forecast(now: quarter, offset: offset)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let clock = f.date(from: now)!.addingTimeInterval(-Double(offset ?? 0))
        return await WeatherAsk.answer(ask, remembered: home, fahrenheit: true, now: clock, fetch: { [weak self] request in
            await MainActor.run { self?.asked.append(request) }
            return (body, 200)
        }).reply
    }

    func testTheNextHoursAreTheHoursAsked() async {
        let reply = await answer(.init(place: nil, day: .today, window: .next(hours: 2)), now: "2026-11-02T15:40")
        XCTAssertEqual(reply, "Boston, Massachusetts, the next 2 hours (until 6 PM): clear, then partly cloudy, "
                       + "55°F to 57°F, up to 20% chance of rain.")
        let hourly = asked.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "hourly" }?.value
        XCTAssertNotNil(hourly)
    }

    /// W45-P3 round 2 item 2: `current.time` reads 3:00 PM from 3:00 to 3:14,
    /// so "on the hour" fired for 15 minutes and a span asked at 3:10 ended at
    /// 5 PM, 10 minutes short. The minute is the clock's, at the place.
    func testOnlyTheHourItselfIsOnTheHour() async {
        let until6 = "Boston, Massachusetts, the next 2 hours (until 6 PM): clear, then partly cloudy, "
            + "55°F to 57°F, up to 20% chance of rain."
        let until5 = "Boston, Massachusetts, the next 2 hours (until 5 PM): clear, 55°F to 56°F, 0% chance of rain."
        let ask = WeatherAsk.Ask(place: nil, day: .today, window: .next(hours: 2))
        let at1501 = await answer(ask, now: "2026-11-02T15:01")
        XCTAssertEqual(at1501, until6, "one minute past")
        let at1510 = await answer(ask, now: "2026-11-02T15:10")
        XCTAssertEqual(at1510, until6)
        let at1514 = await answer(ask, now: "2026-11-02T15:14")
        XCTAssertEqual(at1514, until6, "the last minute the quarter reads 3:00")
        let at1500 = await answer(ask, now: "2026-11-02T15:00")
        XCTAssertEqual(at1500, until5, "on the hour")
        // A half-hour zone: 3:00 PM in Delhi is :30 past on the UTC clock.
        let delhi = await answer(ask, now: "2026-11-02T15:00", offset: 19800)
        XCTAssertEqual(delhi, until5, "on the hour at the place")
        let delhiLater = await answer(ask, now: "2026-11-02T15:05", offset: 19800)
        XCTAssertEqual(delhiLater, until6)
        // No offset in the answer: cover the hours rather than fall short.
        let unknown = await answer(ask, now: "2026-11-02T15:00", offset: nil)
        XCTAssertEqual(unknown, until6)
    }

    /// W45-FIX P3: asked on the hour, the next 2 hours are two slots, not three.
    func testOnTheHourTheSpanEndsWhenItSays() async {
        let reply = await answer(.init(place: nil, day: .today, window: .next(hours: 2)), now: "2026-11-02T15:00")
        XCTAssertEqual(reply, "Boston, Massachusetts, the next 2 hours (until 5 PM): clear, 55°F to 56°F, 0% chance of rain.")
        let one = await answer(.init(place: nil, day: .today, window: .next(hours: 1)), now: "2026-11-02T16:59")
        XCTAssertEqual(one, "Boston, Massachusetts, the next hour (until 6 PM): clear, then partly cloudy, "
                       + "56°F to 57°F, up to 20% chance of rain.")
    }

    /// W44-P3 item 4: late in the evening the span runs on past midnight.
    func testASpanLateInTheEveningCrossesMidnight() async {
        let reply = await answer(.init(place: nil, day: .today, window: .next(hours: 3)), now: "2026-11-02T22:40")
        XCTAssertEqual(reply, "Boston, Massachusetts, the next 3 hours (until 2 AM): light rain, then overcast, "
                       + "30°F to 63°F, up to 70% chance of rain.")
    }

    func testAPartOfTheDayIsItsClockHours() async {
        let evening = await answer(.init(place: nil, day: .today, window: .hours(from: 17, to: 21)), now: "2026-11-02T09:05")
        XCTAssertEqual(evening, "Boston, Massachusetts, this evening (5 PM to 9 PM): partly cloudy, 57°F to 60°F, 20% chance of rain.")
        // Started already: from the hour it is now.
        let tonight = await answer(.init(place: nil, day: .today, window: .hours(from: 18, to: 24)), now: "2026-11-02T22:10")
        XCTAssertEqual(tonight, "Boston, Massachusetts, tonight (10 PM to midnight): light rain, 62°F to 63°F, 70% chance of rain.")
        let morning = await answer(.init(place: nil, day: .tomorrow, window: .hours(from: 6, to: 12)), now: "2026-11-02T22:10")
        XCTAssertEqual(morning, "Boston, Massachusetts, tomorrow morning (6 AM to noon): overcast, 36°F to 41°F, 10% chance of rain.")
        let later = await answer(.init(place: nil, day: .today, window: .restOfDay), now: "2026-11-02T19:30")
        XCTAssertEqual(later, "Boston, Massachusetts, the rest of today (until midnight): partly cloudy, then light rain, "
                       + "59°F to 63°F, up to 70% chance of rain.")
    }

    /// A part of the day already over, or hours the answer lacks, answers the
    /// whole day as before rather than nothing.
    func testAWindowWithNoHoursLeftAnswersTheDay() async {
        let over = await answer(.init(place: nil, day: .today, window: .hours(from: 6, to: 12)), now: "2026-11-02T19:30")
        XCTAssertTrue(over.hasPrefix("Boston, Massachusetts, now: 48°F"), over)
        XCTAssertTrue(over.contains("Today: light rain at times, high 63°F, low 40°F, 70% chance of rain."), over)
    }
}
