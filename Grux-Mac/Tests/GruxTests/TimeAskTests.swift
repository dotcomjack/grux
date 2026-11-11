import XCTest
@testable import Grux

/// D156: "What time is it in Tokyo right now?" is answered with the time.
/// Sense pass 19 (11:09 AM Nov 4) got "I don't have access to real-time
/// location data like your city's timezone. You'll need to check a weather app
/// or website for that." from Grux Local 2B.
@MainActor
final class TimeAskTests: XCTestCase {
    /// 11:09 AM in New York on Wednesday, November 4, 2026 (Eastern Standard Time).
    private let now = Date(timeIntervalSince1970: 1_793_808_540)
    private let here = TimeZone(identifier: "America/New_York")!

    func testTheClockIsWhatTheTestsSayItIs() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = here
        f.dateFormat = "yyyy-MM-dd HH:mm"
        XCTAssertEqual(f.string(from: now), "2026-11-04 11:09")
    }

    // MARK: - The match

    func testPlainTimeQuestionsMatchTheirPlace() {
        let cases: [(String, String?)] = [
            ("What time is it in Tokyo right now?", "tokyo"),
            ("what's the time in London", "london"),
            ("time in new york", "new york"),
            ("Grux, what time is it?", nil),
            ("what time is it now", nil),
            ("what time is it here", nil),
            ("current time in Paris, TX", "paris, tx"),
            ("What's the current time in Sydney?", "sydney"),
            ("what\u{2019}s the time right now in Rio de Janeiro", "rio de janeiro"),
            ("Hey Grux what time is it in Texas", "texas"),
        ]
        for (text, place) in cases {
            XCTAssertEqual(TimeAsk.match(text), TimeAsk.Ask(place: place), text)
        }
    }

    func testWhatIsNotATimeQuestionStaysWithTheModel() {
        for text in ["what time is it in the morning", "what time is it in tokyo when it's 9am here",
                     "what's the time difference between tokyo and london", "what time does the store close",
                     "what time is my meeting", "time in a bottle", "what time is it in my calendar",
                     "what time is it in 2 hours", "how much time is left", "", "time",
                     "what time is it in tokyo and london", "what time is it in tokyo compared to here",
                     "is it time to go", "what time is it in your world", "what time is it in tokyo tomorrow"] {
            XCTAssertNil(TimeAsk.match(text), text)
        }
    }

    // MARK: - The answer

    private var asked: [URLRequest] = []

    private func stub(_ body: String = "{}", failing: Bool = false) -> (URLRequest) async throws -> (Data, Int) {
        { [weak self] request in
            await MainActor.run { self?.asked.append(request) }
            if failing { throw URLError(.notConnectedToInternet) }
            return (Data(body.utf8), 200)
        }
    }

    private func answer(_ place: String?, _ body: String = "{}", failing: Bool = false) async -> String {
        await TimeAsk.answer(.init(place: place), now: now, here: here, fetch: stub(body, failing: failing))
    }

    func testACityThisMacKnowsNeedsNoLookUp() async {
        let cases: [(String?, String)] = [
            ("tokyo", "In Tokyo it's 1:09 AM on Thursday, November 5, 14 hours ahead of you."),
            ("nyc", "In New York it's 11:09 AM on Wednesday, November 4, the same time as here."),
            ("los angeles", "In Los Angeles it's 8:09 AM on Wednesday, November 4, 3 hours behind you."),
            ("kolkata", "In Kolkata it's 9:39 PM on Wednesday, November 4, 10 and a half hours ahead of you."),
            ("kathmandu", "In Kathmandu it's 9:54 PM on Wednesday, November 4, 10 hours 45 minutes ahead of you."),
            ("st johns", "In St Johns it's 12:39 PM on Wednesday, November 4, 1 and a half hours ahead of you."),
            ("utc", "In UTC it's 4:09 PM on Wednesday, November 4, 5 hours ahead of you."),
            ("pst", "On Pacific Time it's 8:09 AM on Wednesday, November 4, 3 hours behind you."),
            ("eastern time", "On Eastern Time it's 11:09 AM on Wednesday, November 4, the same time as here."),
            ("texas", "In most of Texas it's 10:09 AM on Wednesday, November 4, 1 hour behind you."),
            ("california", "In California it's 8:09 AM on Wednesday, November 4, 3 hours behind you."),
            ("arizona", "In most of Arizona it's 9:09 AM on Wednesday, November 4, 2 hours behind you."),
            ("georgia", "In Georgia, the US state, it's 11:09 AM on Wednesday, November 4, the same time as here. "
                + "In Georgia, the country, it's 8:09 PM on Wednesday, November 4, 9 hours ahead of you."),
            (nil, "It's 11:09 AM on Wednesday, November 4."),
        ]
        for (place, want) in cases {
            let got = await answer(place)
            XCTAssertEqual(got, want, place ?? "here")
        }
        XCTAssertTrue(asked.isEmpty, "nothing left the Mac")
    }

    /// W51-FIX P2 1: "usa" went to the geocoder, which keeps an exact name
    /// (Usa, Oita, Japan) and answered that town's time; "mexico" answered
    /// Mexico City's. A country people name by a short name, and the zone
    /// abbreviations people type, are settled here before any lookup.
    func testCountryNamesAndZoneAbbreviationsNeedNoLookUp() async {
        let many = "has more than one time zone. Name a city there and I'll tell you its time."
        for place in ["usa", "us", "u.s.", "u.s.a.", "america", "united states", "the united states",
                      "united states of america", "the us", "the usa"] {
            let got = await answer(place)
            XCTAssertEqual(got, "The United States " + many, place)
        }
        for (place, name) in [("mexico", "Mexico"), ("canada", "Canada"), ("russia", "Russia"),
                              ("australia", "Australia"), ("brazil", "Brazil"), ("indonesia", "Indonesia")] {
            let got = await answer(place)
            XCTAssertEqual(got, "\(name) " + many, place)
        }
        for place in ["uk", "the uk", "u.k.", "united kingdom", "the united kingdom", "britain", "great britain",
                      "england", "scotland", "wales"] {
            let got = await answer(place)
            XCTAssertEqual(got, "In the UK it's 4:09 PM on Wednesday, November 4, 5 hours ahead of you.", place)
        }
        let cases: [(String, String)] = [
            ("cet", "On Central European Time it's 5:09 PM on Wednesday, November 4, 6 hours ahead of you."),
            ("bst", "In the UK it's 4:09 PM on Wednesday, November 4, 5 hours ahead of you."),
            ("jst", "On Japan Time it's 1:09 AM on Thursday, November 5, 14 hours ahead of you."),
            ("aest", "On Australian Eastern Time it's 3:09 AM on Thursday, November 5, 16 hours ahead of you."),
            ("hst", "On Hawaii Time it's 6:09 AM on Wednesday, November 4, 5 hours behind you."),
            ("ist", "IST names more than one time zone (India, Israel and Ireland). Name a city and I'll tell you its time."),
        ]
        for (place, want) in cases {
            let got = await answer(place)
            XCTAssertEqual(got, want, place)
        }
        // W51-FIX round 2 P2: "comparable" drops " city", so the country
        // table must not take "Mexico City" for Mexico.
        for place in ["mexico city", "Mexico City"] {
            let got = await answer(place)
            XCTAssertEqual(got, "In Mexico City it's 10:09 AM on Wednesday, November 4, 1 hour behind you.", place)
        }
        XCTAssertTrue(asked.isEmpty, "a country or a zone name left the Mac")
    }

    /// W51-FIX round 3 P2: `comparable` drops " city", so "Jersey City" read
    /// as Europe/Jersey (5 hours off), "Michigan City" as Michigan, "Central
    /// City" as Central Time. A name ending in "city" is matched locally only
    /// by a zone that is itself a city ("Mexico City"); the rest are looked up.
    func testANameEndingInCityIsThatCity() async throws {
        let jersey = #"{"results":[{"name":"Jersey City","latitude":40.73,"longitude":-74.08,"feature_code":"PPLA2","country_code":"US","country":"United States","admin1":"New Jersey","timezone":"America/New_York"}]}"#
        let got = await answer("jersey city", jersey)
        XCTAssertTrue(got.hasPrefix("In Jersey City, New Jersey, it's 11:09 AM on Wednesday, November 4, the same time as here."), got)
        for place in ["michigan city", "central city", "virginia city", "colorado city", "kansas city", "panama city"] {
            asked = []
            _ = await answer(place)
            XCTAssertEqual(asked.count, 1, "\(place) was answered from a table for another place")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(asked.first?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "name" }?.value, place)
        }
        asked = []
        let mexico = await answer("mexico city")
        XCTAssertEqual(mexico, "In Mexico City it's 10:09 AM on Wednesday, November 4, 1 hour behind you.")
        XCTAssertTrue(asked.isEmpty)
    }

    private static let mumbai = #"{"results":[{"name":"Mumbai","latitude":19.07,"longitude":72.88,"feature_code":"PPLA","country_code":"IN","country":"India","admin1":"Maharashtra","timezone":"Asia/Kolkata"}]}"#

    func testAnyOtherPlaceIsLookedUpByNameOnly() async throws {
        let got = await answer("mumbai", Self.mumbai)
        XCTAssertEqual(got, "In Mumbai, India, it's 9:39 PM on Wednesday, November 4, 10 and a half hours ahead of you. "
            + "Only the name went to Open-Meteo, a free weather service, to find where it is.")
        XCTAssertEqual(asked.count, 1)
        let request = try XCTUnwrap(asked.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(request.url?.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "mumbai")
        XCTAssertEqual(Set(items.map(\.name)), ["name", "count", "language", "format"])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testAHintAfterACommaPicksThePlace() async throws {
        let paris = #"{"results":[{"name":"Paris","latitude":48.85,"longitude":2.35,"feature_code":"PPLC","country_code":"FR","country":"France","admin1":"Île-de-France","timezone":"Europe/Paris"},{"name":"Paris","latitude":33.66,"longitude":-95.56,"feature_code":"PPLA2","country_code":"US","country":"United States","admin1":"Texas","timezone":"America/Chicago"}]}"#
        let got = await answer("paris, tx", paris)
        XCTAssertEqual(got, "In Paris, Texas, it's 10:09 AM on Wednesday, November 4, 1 hour behind you. "
            + "Only the name went to Open-Meteo, a free weather service, to find where it is.")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(asked.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "name" }?.value, "paris", "the hint is not sent")
    }

    func testACountryWithOneZoneIsAnsweredAndOneWithManyIsNot() async {
        let japan = #"{"results":[{"name":"Japan","latitude":35.69,"longitude":139.69,"feature_code":"PCLI","country_code":"JP","country":"Japan","timezone":"Asia/Tokyo"}]}"#
        let one = await answer("japan", japan)
        XCTAssertEqual(one, "In Japan it's 1:09 AM on Thursday, November 5, 14 hours ahead of you. "
            + "Only the name went to Open-Meteo, a free weather service, to find where it is.")
        // Open-Meteo gives a country with several zones no zone at all (read
        // live 12:23 PM Nov 4: Australia, Canada, Russia, United States), and
        // some one-zone countries none either (China).
        let australia = #"{"results":[{"name":"Australia","latitude":-25,"longitude":135,"feature_code":"PCLI","country_code":"AU","country":"Australia"},{"name":"Australia","latitude":21.9,"longitude":-80.5,"feature_code":"PPL","country_code":"CU","country":"Cuba","timezone":"America/Havana"}]}"#
        let many = await answer("australia", australia)
        XCTAssertEqual(many, "Australia has more than one time zone. Name a city there and I'll tell you its time.")
        let china = #"{"results":[{"name":"China","latitude":35,"longitude":105,"feature_code":"PCLI","country_code":"CN","country":"China"}]}"#
        let none = await answer("china", china)
        XCTAssertEqual(none, "Name a city in China and I'll tell you its time.")
    }

    func testNotFoundAndUnreachableSayWhatIsTrue() async {
        let none = await answer("atlantis", #"{"generationtime_ms":0.5}"#)
        XCTAssertEqual(none, "I could not find a place called \u{201C}Atlantis\u{201D}. "
            + "Try a city name, for example \u{201C}Tokyo\u{201D}.")
        // A result with another name, or no time zone, is not the place.
        let other = await answer("atlantis", #"{"results":[{"name":"Atlanta","latitude":33.7,"longitude":-84.4,"country_code":"US","admin1":"Georgia","timezone":"America/New_York"}]}"#)
        XCTAssertEqual(other, none)
        let noZone = await answer("mumbai", #"{"results":[{"name":"Mumbai","latitude":19.07,"longitude":72.88,"country_code":"IN","country":"India"}]}"#)
        XCTAssertEqual(noZone, "I could not find a place called \u{201C}Mumbai\u{201D}. "
            + "Try a city name, for example \u{201C}Tokyo\u{201D}.")
        let offline = await answer("mumbai", failing: true)
        XCTAssertEqual(offline, "I could not look up where \u{201C}Mumbai\u{201D} is just now "
            + "(this Mac is not connected to the internet). Big cities like Tokyo or London I know without looking up.")
    }
}
