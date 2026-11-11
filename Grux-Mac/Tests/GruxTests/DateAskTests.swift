import XCTest
@testable import Grux

/// D202: "What date is next Friday?" is answered from the Mac's own calendar,
/// with no model. Sense pass 29 (12:46 AM Monday Nov 9) asked Grux Local 2B
/// exactly that and it answered "It's November 15, 2026. Next Friday is
/// Monday, November 14."; the coming Friday was November 13.
final class DateAskTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0, minute: Int = 46) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    /// Monday, November 9, 2026, 12:46 AM, the sense pass's own moment.
    private func reply(_ text: String, on now: Date? = nil, region: String = "US") -> String? {
        DateAsk.reply(for: text, now: now ?? day(2026, 11, 9), calendar: cal, region: region)
    }

    func testTheSenseFailureGetsBothFridays() {
        XCTAssertEqual(reply("What date is next Friday?"),
                       "Next Friday is November 13, in 4 days. If you mean the Friday after that, it is November 20.")
    }

    func testAWeekdaySaidPlainOrWithThis() {
        let want = "Friday is November 13, in 4 days."
        for ask in ["what date is friday", "What date is this Friday?", "when is this coming friday",
                    "what's the date this friday", "Grux, what day is Friday?", "When's Friday?",
                    "what date is the coming friday"] {
            XCTAssertEqual(reply(ask), want, ask)
        }
        XCTAssertEqual(reply("what date is tuesday"), "Tuesday is November 10, tomorrow.")
        XCTAssertEqual(reply("what date is sunday"), "Sunday is November 15, in 6 days.")
    }

    func testTheWeekdayThatIsTodayAndLast() {
        // Monday asked on a Monday is today; next Monday is a week away.
        XCTAssertEqual(reply("what date is monday"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("what date is this monday"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("what date is next monday"),
                       "Next Monday is November 16, in 7 days. If you mean the Monday after that, it is November 23.")
        XCTAssertEqual(reply("what date was last friday"), "Last Friday was November 6, 3 days ago.")
        XCTAssertEqual(reply("what date was last sunday"), "Last Sunday was November 8, yesterday.")
        XCTAssertEqual(reply("what date was last monday"), "Last Monday was November 2, 7 days ago.")
        XCTAssertEqual(reply("what date is the friday after next"), "The Friday after next is November 20, in 11 days.")
    }

    func testTodayTomorrowYesterday() {
        for ask in ["what's today's date", "What is today's date?", "whats todays date", "what's the date",
                    "What is the date today?", "what day is it", "What day is it today?", "what date is it",
                    "what's the date today", "what day is today", "today's date", "Hey Grux, what's the date?"] {
            XCTAssertEqual(reply(ask), "Today is Monday, November 9, 2026.", ask)
        }
        XCTAssertEqual(reply("what's the date tomorrow"), "Tomorrow is Tuesday, November 10.")
        XCTAssertEqual(reply("what day is tomorrow"), "Tomorrow is Tuesday, November 10.")
        XCTAssertEqual(reply("what day will it be tomorrow"), "Tomorrow is Tuesday, November 10.")
        XCTAssertEqual(reply("what day was yesterday"), "Yesterday was Sunday, November 8.")
        XCTAssertEqual(reply("what date is the day after tomorrow"), "The day after tomorrow is Wednesday, November 11.")
        XCTAssertEqual(reply("what date was the day before yesterday"), "The day before yesterday was Saturday, November 7.")
    }

    func testDaysAndWeeksAhead() {
        XCTAssertEqual(reply("what's the date in 10 days"), "In 10 days it will be Thursday, November 19.")
        XCTAssertEqual(reply("What day will it be in 2 weeks?"), "In 2 weeks it will be Monday, November 23.")
        XCTAssertEqual(reply("what date is 3 weeks from today"), "In 3 weeks it will be Monday, November 30.")
        XCTAssertEqual(reply("what day is it in one week"), "In 1 week it will be Monday, November 16.")
        XCTAssertEqual(reply("what date is a week from now"), "In 1 week it will be Monday, November 16.")
        XCTAssertEqual(reply("what date is 1 day from now"), "In 1 day it will be Tuesday, November 10.")
        // Across a year the year is said.
        XCTAssertEqual(reply("what's the date in 60 days"), "In 60 days it will be Friday, January 8, 2027.")
    }

    func testTheBoundsOfACount() {
        // 3,650 days is the last count answered; one more, or zero, goes to the model.
        XCTAssertNotNil(reply("what's the date in 3650 days"))
        XCTAssertNil(reply("what's the date in 3651 days"))
        XCTAssertNil(reply("what's the date in 0 days"))
        XCTAssertNotNil(reply("what's the date in 521 weeks"))
        XCTAssertNil(reply("what's the date in 522 weeks"))
    }

    func testANamedDayOrDateReadsLikeTheDayCount() {
        XCTAssertEqual(reply("What day is Christmas?"), "Christmas is in 46 days, on Friday, December 25.")
        XCTAssertEqual(reply("when is thanksgiving"), "Thanksgiving is in 17 days, on Thursday, November 26.")
        XCTAssertEqual(reply("what day is december 25"), "December 25 is in 46 days, on Friday.")
        // Thanksgiving outside the US stays with the model, as the day count does.
        XCTAssertNil(reply("when is thanksgiving", region: "GB"))
    }

    func testTheWeekCrossesAYear() {
        // Wednesday, December 30, 2026: next Friday is January 1, 2027.
        XCTAssertEqual(reply("what date is next friday", on: day(2026, 12, 30)),
                       "Next Friday is January 1, 2027, in 2 days. If you mean the Friday after that, it is January 8, 2027.")
    }

    func testTheMacsTimeZoneDecidesToday() {
        // 11:30 PM Sunday in New York is already Monday in UTC; New York's
        // Sunday is the day asked from.
        let lateSunday = day(2026, 11, 8, hour: 23, minute: 30)
        XCTAssertEqual(reply("what date is tomorrow", on: lateSunday), "Tomorrow is Monday, November 9.")
    }

    /// Wave 71 round 1 P2: "When is it?" after "There's a Lakers game this
    /// week." answered today's date; "it" there is the game. Only "what day
    /// is it" means today.
    func testWhenIsItIsNotToday() {
        for ask in ["When is it?", "when was it", "When's it?", "when is it friday", "when is it tomorrow"] {
            XCTAssertNil(reply(ask), ask)
        }
        XCTAssertEqual(reply("what day is it"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("what date is it tomorrow"), "Tomorrow is Tuesday, November 10.")
        // Wave 71 round 3 P2: "the date on it" asks about a receipt or an event.
        for ask in ["What's the date on it?", "what's the date of it", "what is the date on it",
                    "whats the date of it today"] {
            XCTAssertNil(reply(ask), ask)
        }
        XCTAssertEqual(reply("what's the date"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("what's the date today"), "Today is Monday, November 9, 2026.")
        // Wave 71 round 2 P2: "which day is" is a what-form too.
        XCTAssertEqual(reply("Which day is it?"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("which day is it today"), "Today is Monday, November 9, 2026.")
        XCTAssertEqual(reply("which day is it tomorrow"), "Tomorrow is Tuesday, November 10.")
    }

    /// Wave 71 round 1 P2: a past-tense ask got the next one ("What date was
    /// Friday?" read November 13) or a count with no weekday ("What day was
    /// July 4, 1990?" read "was 13277 days ago"). Past asks are answered only
    /// for yesterday, the day before and "last" weekdays; the rest, and any
    /// date already gone, go to the model.
    func testAPastAskIsNeverAnsweredWithTheNextOne() {
        for ask in ["What date was Friday?", "What day was Halloween?", "What day was November 1?",
                    "What day was July 4, 1990?", "What day is December 25, 2025?", "when was christmas",
                    "what date was this friday", "what day was next friday", "what date was in 3 days",
                    "what date was today"] {
            XCTAssertNil(reply(ask), ask)
        }
        XCTAssertEqual(reply("what date was last friday"), "Last Friday was November 6, 3 days ago.")
        XCTAssertEqual(reply("what day was yesterday"), "Yesterday was Sunday, November 8.")
        XCTAssertNotNil(reply("what day was the day before yesterday"))
        XCTAssertEqual(reply("what day is christmas"), "Christmas is in 46 days, on Friday, December 25.")
    }

    /// Wave 71 round 1 P3: "this coming Monday" asked on a Monday is next week's.
    func testTheComingWeekdayIsNeverToday() {
        for ask in ["when is this coming monday", "what date is the coming monday", "when is coming monday"] {
            XCTAssertEqual(reply(ask), "Monday is November 16, in 7 days.", ask)
        }
    }

    /// Wave 71 round 4 P3: "What's the date now?" and "What day is it now?",
    /// the likeliest ways to ask, went to the model; "now", "right now" and
    /// "again" were read as the day asked about.
    func testNowAndAgainAskForToday() {
        for ask in ["What's the date now?", "What day is it now?", "What's the date right now?",
                    "What's the date again?", "what day is it right now", "what is the date currently",
                    "what day is it again", "What's today's date again?", "whats todays date now",
                    "what date is it now", "which day is it now", "what's the date today again",
                    "What day is it at the moment?"] {
            XCTAssertEqual(reply(ask), "Today is Monday, November 9, 2026.", ask)
        }
        // A "when" ask, a date of something, or a past ask is still not today.
        for ask in ["When is it now?", "what's the date on it now", "what day was it again", "when was it again",
                    "what day is it now in tokyo", "what's the date now and tomorrow"] {
            XCTAssertNil(reply(ask), ask)
        }
    }

    /// Wave 71 round 4 P3: a bare "What's the date?" right after a receipt
    /// photo asks the date on the receipt; only a said "today" or "now"
    /// still means today then.
    func testABareAskAfterAPhotoIsTheModels() {
        func after(_ text: String) -> String? {
            DateAsk.reply(for: text, afterImage: true, now: day(2026, 11, 9), calendar: cal, region: "US")
        }
        for ask in ["What's the date?", "What day is it?", "what date is it", "Which day is it?",
                    "What's the date again?"] {
            XCTAssertNil(after(ask), ask)
        }
        for ask in ["What's the date today?", "What's the date now?", "What's today's date?",
                    "What day is it right now?"] {
            XCTAssertEqual(after(ask), "Today is Monday, November 9, 2026.", ask)
        }
        let photo = ChatMessage(role: .user, content: "", imageData: Data([1]), imageMediaType: "image/png")
        let ask = ChatMessage(role: .user, content: "What's the date?")
        let answer = ChatMessage(role: .assistant, content: "A receipt from Joe's.")
        XCTAssertTrue(DateAsk.followsImage([photo, answer, ask]))
        XCTAssertFalse(DateAsk.followsImage([photo, answer, ChatMessage(role: .user, content: "Thanks"), answer, ask]))
        XCTAssertFalse(DateAsk.followsImage([ask]))
        XCTAssertEqual(after("What date is next Friday?"),
                       "Next Friday is November 13, in 4 days. If you mean the Friday after that, it is November 20.")
    }

    func testAnythingElseGoesToTheModel() {
        for ask in ["when is my meeting friday", "what day is trash day", "what date is my dentist appointment",
                    "what date is friday next week", "what's on my calendar friday", "when is easter",
                    "what day is it in tokyo", "what date is friday and saturday", "what's the date of the election",
                    "what day is good for a meeting", "when is the next full moon", "what's the date in a few days",
                    "remind me friday", "what date is friday at 3pm", "what day is the 25th", "what date is 12/25",
                    "what is the date in 10 years", "what time is it", "what date did I last call mom", ""] {
            XCTAssertNil(reply(ask), ask)
        }
    }
}
