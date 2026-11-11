import XCTest
@testable import Grux

/// D195: "How many days until Christmas?" is counted on the Mac's own
/// calendar, with no model. Sense pass 27 (6:43 AM Sunday Nov 8) asked Grux
/// Local 2B exactly that and it answered "There are 41 days left until
/// Christmas."; it was 47.
final class DayCountAskTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 6, minute: Int = 43) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func reply(_ text: String, on now: Date? = nil, region: String = "US") -> String? {
        DayCountAsk.reply(for: text, now: now ?? day(2026, 11, 8), calendar: cal, region: region)
    }

    func testTheSenseFailureIsCountedExactly() {
        XCTAssertEqual(reply("How many days until Christmas?"), "Christmas is in 47 days, on Friday, December 25.")
    }

    func testTheWaysPeopleAsk() {
        let want = "Christmas is in 47 days, on Friday, December 25."
        for ask in ["how many days till christmas", "How many days are left until Christmas?",
                    "how many days left until christmas", "How long until Christmas?", "days until christmas",
                    "Grux, how many days until Christmas Day?", "how many more days until christmas",
                    "How many days until Christmas.", "how many days to christmas", "How many days before Christmas?",
                    "How many days \u{2019}til Christmas?", "how many days is it until christmas"] {
            XCTAssertEqual(reply(ask), want, ask)
        }
    }

    func testEveryNamedDay() {
        let cases: [(String, String)] = [
            ("how many days until christmas eve", "Christmas Eve is in 46 days, on Thursday, December 24."),
            ("how many days until new year's eve", "New Year's Eve is in 53 days, on Thursday, December 31."),
            ("how many days until new year's", "New Year's Day is in 54 days, on Friday, January 1, 2027."),
            ("how many days until new years day", "New Year's Day is in 54 days, on Friday, January 1, 2027."),
            ("how many days until the new year", "New Year's Day is in 54 days, on Friday, January 1, 2027."),
            ("how many days until valentine's day", "Valentine's Day is in 98 days, on Sunday, February 14, 2027."),
            ("how many days until halloween", "Halloween is in 357 days, on Sunday, October 31, 2027."),
            ("how many days until the fourth of july", "The Fourth of July is in 238 days, on Sunday, July 4, 2027."),
            ("how many days until st. patrick's day", "St. Patrick's Day is in 129 days, on Wednesday, March 17, 2027."),
            // Thanksgiving, the fourth Thursday of November in the US.
            ("how many days until thanksgiving", "Thanksgiving is in 18 days, on Thursday, November 26."),
        ]
        for (ask, want) in cases { XCTAssertEqual(reply(ask), want, ask) }
    }

    func testADateSaidByMonthAndDay() {
        let cases: [(String, String)] = [
            ("how many days until december 25", "December 25 is in 47 days, on Friday."),
            ("How many days until Dec 25th?", "December 25 is in 47 days, on Friday."),
            ("how many days until March 3", "March 3, 2027 is in 115 days, on Wednesday."),
            ("how many days until the 3rd of march", "March 3, 2027 is in 115 days, on Wednesday."),
            ("how many days until march 3, 2028", "March 3, 2028 is in 481 days, on Friday."),
            ("how many days until november 8", "November 8 is today."),
            ("how many days until november 9", "November 9 is tomorrow, Monday."),
        ]
        for (ask, want) in cases { XCTAssertEqual(reply(ask), want, ask) }
    }

    func testTheDayItselfAndTheDayBefore() {
        XCTAssertEqual(reply("how many days until christmas", on: day(2026, 12, 25)), "Christmas is today.")
        XCTAssertEqual(reply("how many days until christmas", on: day(2026, 12, 24, hour: 23, minute: 59)),
                       "Christmas is tomorrow, Friday, December 25.")
        // Just after midnight on the 26th, the next one is a year away.
        XCTAssertEqual(reply("how many days until christmas", on: day(2026, 12, 26, hour: 0, minute: 1)),
                       "Christmas is in 364 days, on Saturday, December 25, 2027.")
    }

    func testTheCountIsByCalendarDayNotByHour() {
        // Late in the evening the count is the same as in the morning.
        XCTAssertEqual(reply("how many days until christmas", on: day(2026, 11, 8, hour: 23, minute: 59)),
                       "Christmas is in 47 days, on Friday, December 25.")
        XCTAssertEqual(reply("how many days until christmas", on: day(2026, 11, 8, hour: 0, minute: 0)),
                       "Christmas is in 47 days, on Friday, December 25.")
    }

    func testAcrossTheSpringClockChange() {
        // March 8, 2026 lost an hour in New York; the count stays whole days.
        XCTAssertEqual(reply("how many days until march 10", on: day(2026, 3, 7)),
                       "March 10 is in 3 days, on Tuesday.")
    }

    /// Wave 67 round 2 P2-1: where the clock jumps at midnight, that day starts
    /// at 1:00 AM and a count from it to a midnight lost a day ("May 1 is
    /// today." on April 30 in Cairo). Days are counted from calendar dates.
    func testWhereTheClockJumpsAtMidnight() {
        for (zone, y, m, d, ask, want) in [
            ("America/Santiago", 2026, 9, 6, "how many days until christmas", "Christmas is in 110 days, on Friday, December 25."),
            ("America/Havana", 2027, 3, 14, "how many days until march 15", "March 15 is tomorrow, Monday."),
            ("Asia/Beirut", 2027, 3, 28, "how many days until christmas", "Christmas is in 272 days, on Saturday, December 25."),
        ] {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: zone)!
            for hour in [1, 12, 23] {
                let now = c.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: 30))!
                XCTAssertEqual(DayCountAsk.reply(for: ask, now: now, calendar: c, region: "US"), want, "\(zone) \(hour)h")
            }
        }
    }

    func testAPastDateWithAYear() {
        XCTAssertEqual(reply("how many days until december 25, 2025"), "December 25, 2025 was 318 days ago.")
        XCTAssertEqual(reply("how many days until november 7, 2026"), "November 7, 2026 was yesterday.")
    }

    func testFebruary29() {
        XCTAssertEqual(reply("how many days until february 29"), "February 29, 2028 is in 478 days, on Tuesday.")
        XCTAssertNil(reply("how many days until february 29, 2027"))
        XCTAssertNil(reply("how many days until february 30"))
        XCTAssertNil(reply("how many days until april 31"))
    }

    func testThanksgivingIsCountedOnlyWhereItsDayIsKnown() {
        XCTAssertNil(reply("how many days until thanksgiving", region: "CA"))
        XCTAssertNil(reply("how many days until thanksgiving", region: "GB"))
        XCTAssertEqual(reply("how many days until thanksgiving", on: day(2026, 11, 27)),
                       "Thanksgiving is in 363 days, on Thursday, November 25, 2027.")
    }

    /// Wave 67 round 1 P2-1: a Mac whose calendar is not Gregorian counted
    /// Christmas as "Dhu'l-Hijjah 25" and New Year's as "January 1, 2570". The
    /// days asked about are Gregorian ones, in the Mac's own time zone.
    func testANonGregorianMacCountsTheSameDays() {
        let asks = ["how many days until christmas", "how many days until new year's", "how many days until march 3, 2028",
                    "how many days until december 25, 2025", "how many days until thanksgiving", "how many days until february 29"]
        let now = day(2026, 11, 8)
        for id: Calendar.Identifier in [.buddhist, .japanese, .islamicUmmAlQura, .hebrew, .persian, .chinese] {
            var other = Calendar(identifier: id)
            other.timeZone = cal.timeZone
            for ask in asks {
                XCTAssertEqual(DayCountAsk.reply(for: ask, now: now, calendar: other, region: "US"), reply(ask), "\(id) \(ask)")
            }
        }
    }

    /// Wave 67 round 1 P2-2: "Independence Day" is the Fourth of July only in the US.
    func testIndependenceDayIsTheFourthOfJulyOnlyInTheUS() {
        XCTAssertEqual(reply("how many days until independence day"), "The Fourth of July is in 238 days, on Sunday, July 4, 2027.")
        for region in ["IN", "MX", "GB", "CA"] { XCTAssertNil(reply("how many days until independence day", region: region), region) }
        XCTAssertEqual(reply("how many days until the fourth of july", region: "IN"),
                       "The Fourth of July is in 238 days, on Sunday, July 4, 2027.", "a date said by name is a date anywhere")
    }

    func testAnythingElseStaysWithTheModel() {
        for ask in ["how many days until my birthday", "how many days until friday", "how many days until 12/25",
                    "how many days until the meeting", "how many days until christmas and new year",
                    "how many days until christmas in 2030", "how many days until christmas if I leave today",
                    "how many days until spring", "how many days until easter", "how many days until the 25th",
                    "how many days until june", "why do people count days until christmas",
                    "how many days until december 25 1990 was a tuesday", "how many days until december 32",
                    "how many days until christmas? also what time is it", "how many days do I have left",
                    "write a poem about the days until christmas", "how many weeks until christmas", ""] {
            XCTAssertNil(reply(ask), ask)
        }
    }

    func testTheReplyCarriesNoDash() {
        for ask in ["how many days until christmas", "how many days until new year's", "how many days until march 3, 2028",
                    "how many days until december 25, 2025"] {
            let r = reply(ask) ?? ""
            XCTAssertFalse(r.contains("\u{2014}") || r.contains("\u{2013}"), ask)
        }
    }

    /// The count sits beside the other fast paths in `ChatService`, above the
    /// model, so a stranger's date question never reaches the model's guess.
    func testChatAnswersItBeforeTheModel() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/GruxTests/DayCountAskTests.swift",
                                                                              with: "Sources/Grux/ChatService.swift"),
                             encoding: .utf8)
        let count = try XCTUnwrap(src.range(of: "DayCountAsk.reply(for: trimmed"))
        let math = try XCTUnwrap(src.range(of: "MathAsk.reply(for: trimmed)"))
        let ready = try XCTUnwrap(src.range(of: "ChatReadiness"))
        XCTAssertLessThan(count.lowerBound, ready.lowerBound, "the day count must come before the readiness guard")
        XCTAssertLessThan(abs(src.distance(from: math.lowerBound, to: count.lowerBound)), 2_000,
                          "the day count sits with the math ask")
    }
}
