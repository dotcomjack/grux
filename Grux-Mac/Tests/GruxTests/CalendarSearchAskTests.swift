import XCTest
@testable import Grux

/// D206, live 2026-11-09 1:25 AM on Grux Local 2B: "When is my dentist
/// appointment?" came back "I don't have access to your schedule or
/// appointments" while Grux could read the calendar. The ask is now answered
/// by searching the names on the calendar, and a local reply that denies the
/// calendar Grux can read is replaced by the calendar's answer.
@MainActor
final class CalendarSearchAskTests: XCTestCase {

    private var cal: Foundation.Calendar = {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return c
    }()
    private let us = Locale(identifier: "en_US")

    /// Monday Nov 9, 2026, 1:25 AM in New York: the live turn.
    private var now: Date { date(2026, 11, 9, 1, 25) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false,
                       location: String? = nil) -> CalendarService.EventSummary {
        CalendarService.EventSummary(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: allDay,
                                     location: location, notes: nil, calendarName: "Home", calendarId: "home")
    }

    private var savedEvents: (@MainActor (Date, Date) -> [CalendarService.EventSummary]?)!

    override func setUp() async throws {
        try await super.setUp()
        savedEvents = CalendarAsk.events
    }

    override func tearDown() async throws {
        CalendarAsk.events = savedEvents
        try await super.tearDown()
    }

    private func answer(_ text: String) throws -> String {
        let ask = try XCTUnwrap(CalendarSearchAsk.match(text), text)
        return CalendarSearchAsk.answer(ask, now: now, calendar: cal, locale: us)
    }

    // MARK: - The match

    func testWhenIsMyThingAsksMatch() {
        let cases: [(String, [String], String)] = [
            ("When is my dentist appointment?", ["dentist"], "appointment"),
            ("when\u{2019}s my dentist appointment", ["dentist"], "appointment"),
            ("When is my next dentist appointment?", ["dentist"], "appointment"),
            ("What time is my call with Sam?", ["sam"], "call"),
            ("What day is my flight to Denver?", ["denver"], "flight"),
            ("When is my flight?", [], "flight"),
            ("When is my next meeting?", [], "meeting"),
            ("Grux when is my haircut", [], "haircut"),
            ("Do I have a dentist appointment coming up?", ["dentist"], "appointment"),
            ("Do I have any piano lessons scheduled?", ["piano"], "lesson"),
            ("When is my mom's surgery?", ["mom"], "surgery"),
        ]
        for (text, terms, noun) in cases {
            let ask = CalendarSearchAsk.match(text)
            XCTAssertEqual(ask?.terms, terms, text)
            XCTAssertEqual(ask?.noun, noun, text)
        }
    }

    /// Fails toward the model: no event word, a day named, a second clause,
    /// or someone else's thing.
    func testOtherAsksGoToTheModel() {
        let others = [
            "When is my birthday?",
            "When is my due date?",
            "When is my dentist?",
            "When is my dentist appointment tomorrow?",
            "When is my meeting on Friday?",
            "When is my dentist appointment and can you move it?",
            "When is my flight, and what gate?",
            "When is the meeting?",
            "When is Thanksgiving?",
            "What's on my calendar tomorrow?",
            "When is my next meeting with the whole product design team?",
            "Do I have time for lunch?",
            "When is my call. Also remind me",
            "",
        ]
        for text in others {
            XCTAssertNil(CalendarSearchAsk.match(text), text)
        }
    }

    /// The earlier fast paths leave these asks alone, so the search answers them.
    func testNoEarlierFastPathTakesTheAsk() {
        for text in ["When is my dentist appointment?", "When's my next meeting?", "What day is my flight to Denver?",
                     "Do I have a dentist appointment coming up?"] {
            XCTAssertNil(DateAsk.reply(for: text, now: now, calendar: cal), text)
            XCTAssertNil(DayCountAsk.reply(for: text, now: now, calendar: cal), text)
            XCTAssertNil(CalendarAsk.window(for: text, now: now, calendar: cal), text)
        }
    }

    // MARK: - The answer

    /// The live ask with a dentist on Thursday: the person reads the day and time.
    func testTheLiveAskFindsTheAppointment() throws {
        var asked: [(Date, Date)] = []
        CalendarAsk.events = { start, end in
            asked.append((start, end))
            return [self.event("Team sync", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 10)),
                    self.event("Dentist", self.date(2026, 11, 12, 14), self.date(2026, 11, 12, 15))]
        }
        XCTAssertEqual(try answer("When is my dentist appointment?"),
                       "From your calendar: Dentist, Thursday, Nov 12, 2:00 PM to 3:00 PM.")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, now, "the search starts now")
        XCTAssertEqual(asked.first?.1, cal.date(byAdding: .day, value: 365, to: now), "and reads 12 months ahead")
    }

    func testMatchingIgnoresCaseAndReadsThePlaceAndListsLaterOnes() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Cleaning", self.date(2026, 11, 20, 8), self.date(2026, 11, 20, 9), location: "Bright Smile DENTIST"),
             self.event("DENTIST follow-up", self.date(2026, 12, 1, 9), self.date(2026, 12, 1, 9, 30)),
             self.event("dentist again", self.date(2027, 2, 3, 11), self.date(2027, 2, 3, 12)),
             self.event("Dentist, last", self.date(2027, 5, 3, 11), self.date(2027, 5, 3, 12))]
        }
        XCTAssertEqual(try answer("When is my dentist appointment?"),
                       "From your calendar: Cleaning, Friday, Nov 20, 8:00 AM to 9:00 AM. After that: "
                       + "DENTIST follow-up, Tuesday, Dec 1, 9:00 AM to 9:30 AM; dentist again, Wednesday, Feb 3, 2027, 11:00 AM to 12:00 PM.")
    }

    func testTodayTomorrowNowAndAllDay() throws {
        CalendarAsk.events = { _, _ in [self.event("Flight UA 12", self.date(2026, 11, 9, 1), self.date(2026, 11, 9, 4))] }
        XCTAssertEqual(try answer("When is my flight?"), "From your calendar: Flight UA 12, now, until 4:00 AM.")
        CalendarAsk.events = { _, _ in [self.event("Flight UA 12", self.date(2026, 11, 10, 6), self.date(2026, 11, 10, 9))] }
        XCTAssertEqual(try answer("When is my flight?"), "From your calendar: Flight UA 12, tomorrow, 6:00 AM to 9:00 AM.")
        CalendarAsk.events = { _, _ in [self.event("Ski trip", self.date(2026, 12, 19), self.date(2026, 12, 21), allDay: true)] }
        XCTAssertEqual(try answer("When is my ski trip?"), "From your calendar: Ski trip, Saturday, Dec 19, all day.")
    }

    /// An event already over is not "when": the search reads what is ahead.
    func testAnEventAlreadyOverIsSkipped() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Dentist", self.date(2026, 11, 8, 14), self.date(2026, 11, 9, 1, 25)),
             self.event("Dentist", self.date(2026, 11, 30, 10), self.date(2026, 11, 30, 11))]
        }
        XCTAssertEqual(try answer("When is my dentist appointment?"),
                       "From your calendar: Dentist, Monday, Nov 30, 10:00 AM to 11:00 AM.")
    }

    /// Nothing found says what was searched, never "no access" or a guess.
    func testNothingFoundSaysWhatWasSearched() throws {
        CalendarAsk.events = { _, _ in [self.event("Team sync", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 10))] }
        XCTAssertEqual(try answer("When is my dentist appointment?"),
                       "I searched the names on your calendar for the next 12 months and found nothing with \"dentist\" in its name. "
                       + "If it is there under another name, ask what is on that day.")
        XCTAssertEqual(try answer("When is my flight?"),
                       "I searched the names on your calendar for the next 12 months and found nothing with \"flight\" in its name. "
                       + "If it is there under another name, ask what is on that day.")
    }

    /// The specific words miss, the event word finds one: both are said.
    func testATermMissNamesTheNextOfItsKind() throws {
        CalendarAsk.events = { _, _ in [self.event("Flight UA 12 to DEN", self.date(2026, 11, 14, 6), self.date(2026, 11, 14, 9))] }
        XCTAssertEqual(try answer("What day is my flight to Denver?"),
                       "I searched the names on your calendar for the next 12 months and found nothing with \"denver\" in its name. "
                       + "The next flight on it: Flight UA 12 to DEN, Saturday, Nov 14, 6:00 AM to 9:00 AM.")
    }

    /// "My next meeting" with nothing named meeting: the next timed entry, said as such.
    func testNextMeetingFallsBackToTheNextTimedEntry() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Veterans Day", self.date(2026, 11, 11), self.date(2026, 11, 12), allDay: true),
             self.event("Standup with Ana", self.date(2026, 11, 11, 9), self.date(2026, 11, 11, 9, 15))]
        }
        XCTAssertEqual(try answer("When is my next meeting?"),
                       "Nothing on your calendar is named \"meeting\". The next thing on it: Standup with Ana, Wednesday, Nov 11, 9:00 AM to 9:15 AM.")
    }

    /// Wave 72 round 1 P2-2: a name matches whole words, with a plural or
    /// possessive, never a word's start ("sam" is not "Samsung", "call" is
    /// not "California"); with words named, an entry that also holds the event
    /// word comes first.
    func testNamesMatchWholeWordsAndTheEventWordRanksFirst() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Samsung TV delivery", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 12)),
             self.event("Lunch with Sam", self.date(2026, 11, 11, 12), self.date(2026, 11, 11, 13)),
             self.event("Call with Sam", self.date(2026, 11, 13, 15), self.date(2026, 11, 13, 15, 30))]
        }
        XCTAssertEqual(try answer("When is my call with Sam?"),
                       "From your calendar: Call with Sam, Friday, Nov 13, 3:00 PM to 3:30 PM.")
        CalendarAsk.events = { _, _ in
            [self.event("Samsung TV delivery", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 12)),
             self.event("Lunch with Sam", self.date(2026, 11, 11, 12), self.date(2026, 11, 11, 13))]
        }
        XCTAssertEqual(try answer("When is my call with Sam?"),
                       "From your calendar: Lunch with Sam, Wednesday, Nov 11, 12:00 PM to 1:00 PM.")
        CalendarAsk.events = { _, _ in
            [self.event("California trip", self.date(2026, 11, 10), self.date(2026, 11, 12), allDay: true),
             self.event("Call with Ana", self.date(2026, 11, 12, 10), self.date(2026, 11, 12, 10, 30)),
             self.event("Recall notice pickup", self.date(2026, 11, 13, 10), self.date(2026, 11, 13, 11))]
        }
        XCTAssertEqual(try answer("When is my next call?"),
                       "From your calendar: Call with Ana, Thursday, Nov 12, 10:00 AM to 10:30 AM.")
        CalendarAsk.events = { _, _ in
            [self.event("Classic rock night", self.date(2026, 11, 10, 20), self.date(2026, 11, 10, 23)),
             self.event("Moment of silence", self.date(2026, 11, 11, 11), self.date(2026, 11, 11, 11, 5))]
        }
        XCTAssertEqual(try answer("Do I have a class coming up?"),
                       "I searched the names on your calendar for the next 12 months and found nothing with \"class\" in its name. "
                       + "If it is there under another name, ask what is on that day.")
        XCTAssertTrue(try answer("When is my mom's surgery?").hasPrefix("I searched"), "Moment is not mom")
        CalendarAsk.events = { _, _ in
            [self.event("Mom's surgery", self.date(2026, 11, 20, 7), self.date(2026, 11, 20, 9)),
             self.event("Yoga classes", self.date(2026, 11, 21, 9), self.date(2026, 11, 21, 10))]
        }
        XCTAssertEqual(try answer("When is my mom's surgery?"),
                       "From your calendar: Mom's surgery, Friday, Nov 20, 7:00 AM to 9:00 AM.")
        XCTAssertEqual(try answer("When is my yoga class?"),
                       "From your calendar: Yoga classes, Saturday, Nov 21, 9:00 AM to 10:00 AM.")
    }

    /// Wave 72 round 1 P2-3: a word with an apostrophe matches the same name
    /// ("O'Brien", "kids'"), so the reply never says it found nothing and then
    /// names the entry.
    func testApostropheWordsMatch() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Meeting with O\u{2019}Brien", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 10)),
             self.event("Kids recital", self.date(2026, 11, 14, 18), self.date(2026, 11, 14, 19))]
        }
        XCTAssertEqual(try answer("When is my meeting with O'Brien?"),
                       "From your calendar: Meeting with O\u{2019}Brien, tomorrow, 9:00 AM to 10:00 AM.")
        XCTAssertEqual(try answer("When is my kids' recital?"),
                       "From your calendar: Kids recital, Saturday, Nov 14, 6:00 PM to 7:00 PM.")
    }

    func testNoAccessSaysWhyAndWhatToDo() throws {
        CalendarAsk.events = { _, _ in nil }
        XCTAssertTrue(try answer("When is my dentist appointment?").hasPrefix("I cannot read your calendar"))
    }

    // MARK: - The denial guard

    private func vet(_ reply: String, ask: String, route: String = "local", hasImage: Bool = false,
                     results: [ActionClaimGuard.ToolResult] = []) -> (text: String, replaced: Bool) {
        CalendarClaimGuard.vet(reply: reply, route: route, results: results, ask: ask, hasImage: hasImage,
                               now: now, calendar: cal, locale: us)
    }

    /// The live reply: replaced by the search's answer.
    func testTheLiveDenialIsReplacedByTheSearch() {
        CalendarAsk.events = { _, _ in [self.event("Dentist", self.date(2026, 11, 12, 14), self.date(2026, 11, 12, 15))] }
        let out = vet("I don't have access to your schedule or appointments. You'll need to check your calendar or message them directly.",
                      ask: "When is my dentist appointment?")
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(out.text, "From your calendar: Dentist, Thursday, Nov 12, 2:00 PM to 3:00 PM.")
    }

    /// A denial on an ask the search does not take reads the coming week.
    func testADenialWithNoSearchReadsTheComingWeek() {
        var asked: [(Date, Date)] = []
        CalendarAsk.events = { s, e in
            asked.append((s, e))
            return [self.event("Dentist", self.date(2026, 11, 12, 14), self.date(2026, 11, 12, 15))]
        }
        let out = vet("I can't see your calendar, sorry.", ask: "Am I seeing the dentist soon?")
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(asked.first?.0, date(2026, 11, 9))
        XCTAssertEqual(asked.first?.1, date(2026, 11, 16))
        XCTAssertEqual(out.text, "On your calendar the next 7 days (Nov 9 to Nov 15), one thing: Dentist, Thu, Nov 12 2:00 PM to 3:00 PM.")
    }

    /// A denial that names a day reads that day.
    func testADenialOnADayReadsThatDay() {
        CalendarAsk.events = { _, _ in [] }
        let out = vet("I do not have access to your calendar.", ask: "Am I busy tomorrow?")
        XCTAssertEqual(out.text, "Nothing on your calendar tomorrow (Tuesday, Nov 10).")
    }

    func testEveryDenialWordingIsCaught() {
        let denials = [
            "I don't have access to your schedule or appointments.",
            "I don\u{2019}t have access to your calendar.",
            "I do not have access to your calendar events.",
            "Sorry, I can't see your calendar.",
            "I cannot read your schedule.",
            "I'm unable to view your appointments.",
            "I have no access to your calendar.",
            "I can't check your personal calendar from here.",
            "I don't have any access to the user's schedule.",
            "I can not look at your meetings.",
        ]
        for reply in denials { XCTAssertTrue(CalendarClaimGuard.deniesCalendar(reply), reply) }
        let others = [
            "I don't have access to your email.",
            "I can't see your screen right now.",
            "Want me to check your calendar?",
            "I can check your calendar for that.",
            "I don't have access to real-time weather.",
        ]
        for reply in others { XCTAssertFalse(CalendarClaimGuard.deniesCalendar(reply), reply) }
    }

    /// Wave 72 rounds 1 to 4: a denial is replaced, whole, only in answer to
    /// a question plainly about the person's own calendar, on a turn with no
    /// photo; the calendar's answer is then what they asked for. Any other ask
    /// keeps the model's words as written (rewriting its sentences lost the
    /// answer in round 4). "If you can't" and "your work calendar" are not Grux
    /// denying the calendar it reads.
    func testADenialIsReplacedOnlyForAQuestionAboutTheirOwnCalendar() {
        CalendarAsk.events = { _, _ in [] }
        let kept: [(reply: String, ask: String, image: Bool)] = [
            ("I don't have access to your schedule, but here is a plan: Monday math, Tuesday history.",
             "Help me make a study schedule for finals", false),
            ("I don't have access to your schedule to set reminders, but you can set one in Reminders.",
             "Remind me to call mom at 5", false),
            ("I can't see your work calendar because it isn't added in Calendar.", "What's on my work calendar?", false),
            ("I don't have access to your calendar, but this confirmation shows your flight is Nov 12 at 3:40 PM.",
             "When is my flight?", true),
            ("If you can't see your calendar events in Grux, check System Settings, Privacy.",
             "Why can't I see my calendar events in Grux?", false),
            ("I don't have access to your schedule, but most people study best in the morning.",
             "What's a good study schedule for me?", false),
            ("I don't have access to your schedule, but here are some ideas: a hike, a museum, brunch with friends.",
             "What should I do this weekend?", false),
            ("I don't have access to your calendar, but here's a suggested plan:\n1. Workout\n2. Deep work",
             "Can you plan my day tomorrow?", false),
            ("I can't see your calendar, but try blocking two hours.", "Could you plan out my week?", false),
            ("I can't check your calendar, but Nov 11 is Veterans Day, a federal holiday.",
             "Am I right that Friday is a holiday?", false),
            ("I can't see your calendar. Working past 9 PM most nights is a sign to slow down.",
             "Am I overworking myself?", false),
            ("I can't see your calendar. Probably yes.", "Is Friday a good day to ask for a raise?", false),
            ("While I don't have access to your calendar, Tuesday or Wednesday mornings usually work best.",
             "What's the best day for a team meeting?", false),
            ("I don't have access to your schedule.", "Remind me to call mom at 5", false),
            ("I don't have access to your calendar.", "When is my flight?", true),
            // Round 5: asking for advice about their own time keeps the advice.
            ("I don't have access to your schedule, but here are some ideas: a hike, a museum, brunch with friends.",
             "What should I do with my weekend?", false),
            ("While I don't have access to your calendar, Tuesday or Wednesday mornings usually work best.",
             "What's the best day for my team meeting?", false),
            ("I can't see your calendar, but start with your hardest task.", "How should I structure my day?", false),
            ("I can't see your calendar, but rest and see friends.", "What should I do on my day off?", false),
            ("I don't have access to your calendar, but after a big win is a good time.",
             "When should I ask my boss for a raise?", false),
            ("I can't see your calendar, but block mornings for deep work.", "Any tips for my week?", false),
            // Round 6: a plan of some kind is a document, not the calendar.
            ("I don't have access to your calendar, but here's a study plan for this week: Monday, chapter 1.",
             "Can you help me with my study plan for this week?", false),
            ("I can't see your calendar, but your workout plan looks balanced.",
             "Can you look over my workout plan for this week?", false),
            ("I don't have access to your calendar, but leg day is a good start.", "What's my workout plan for today?", false),
            ("I can't see your calendar, but the Louvre opens at 9.", "Can you help with my travel plans for Paris?", false),
            ("I can't see your calendar, but a picnic could be fun.", "Can you help me with my plans for Saturday?", false),
            ("I can't see your calendar, but it has enough protein.", "Can you check my meal plan for the week?", false),
            // Round 7: a reply that answers is never replaced, whatever the ask.
            ("I don't have access to your schedule, but here are a few ways to fit exercise in: 1. Walk at lunch. 2. Stretch.",
             "How can I fit exercise into my schedule?", false),
            ("I can't see your calendar. Try two 45 minute blocks after dinner.", "How do I fit studying into my week?", false),
            ("While I don't have access to your schedule, moving meetings to the morning helps.",
             "What can I do to free up my afternoon?", false),
            ("I don't have access to your calendar, so batch your errands into one trip.",
             "How can I get more done in my day?", false),
            // Round 8: advice that opens like a pointer is still advice.
            ("I don't have access to your schedule, but you might want to look for 15 minute gaps for a quick walk after lunch.",
             "How can I fit exercise into my schedule?", false),
            ("I don't have access to your schedule. You could look at moving one meeting so you can fit in a 20 minute workout.",
             "How can I fit exercise into my schedule?", false),
            ("I can't see your calendar. I understand it's hard to find time, but batching errands into one trip helps.",
             "How can I get more done in my day?", false),
            ("I can't see your calendar, but you can ask your manager to move the standup.",
             "What can I do to free up my afternoon?", false),
            ("I can't see your calendar. Sorry, your dentist usually books six months out.",
             "What do I have this week?", false),
            // Round 9: advice before the denial in the same sentence.
            ("A good approach is to block 20 minutes each morning, but I don't have access to your schedule to find specific times.",
             "How can I fit exercise into my schedule?", false),
            ("Morning workouts are easiest to protect, but I can't see your calendar to pick exact times.",
             "How can I fit exercise into my schedule?", false),
            ("Try walking at lunch, but I can't see your schedule.", "How can I fit exercise into my schedule?", false),
            // Round 10: an answer after the denial with no linking word.
            ("I can't see your schedule \u{2014} try a 15 minute walk after lunch or a short workout before bed.",
             "How can I fit exercise into my schedule?", false),
            ("I can't see your calendar: moving your meetings to the morning usually helps.",
             "What can I do to free up my afternoon?", false),
            ("I don't have access to your schedule; mornings before work are easiest to protect, so check your calendar.",
             "How can I fit exercise into my schedule?", false),
        ]
        for c in kept {
            let out = vet(c.reply, ask: c.ask, hasImage: c.image)
            XCTAssertFalse(out.replaced, c.ask)
            XCTAssertEqual(out.text, c.reply, c.ask)
        }
        for reply in ["If you can't see your calendar events in Grux, check System Settings.",
                      "I can't see your work calendar because it isn't added in Calendar.",
                      "You don't have access to your calendar from the lock screen."] {
            XCTAssertFalse(CalendarClaimGuard.deniesCalendar(reply), reply)
        }
        let asks = ["When is my dentist appointment?", "Am I seeing the dentist soon?", "Am I busy tomorrow?",
                    "Do I have anything on Friday?", "What's on my schedule this week?", "Can you check my calendar?",
                    "Is there anything going on tonight?", "What time is my dentist tomorrow?", "What's on tomorrow?",
                    "Are there any meetings today?", "When am I seeing the dentist?", "Is my Friday free?",
                    "Grux, anything tonight?", "What's the plan for my day?", "Hey Grux, what's on for the weekend?",
                    "Can you help me check my calendar for tomorrow?", "Am I free Thursday afternoon?",
                    "What do I have this week?",
                    // Round 5: own-calendar wordings the gate missed.
                    "What are my plans for tomorrow?", "What am I doing this weekend?", "How busy am I tomorrow?",
                    "When do I see the dentist?", "What's my plan for today?"]
        // Bare denials: nothing but the denial and pointers to look for themselves.
        let replies = ["I don't have access to your calendar.",
                       "I'm sorry, I can't see your calendar. You'll need to check your calendar app.",
                       "I don't have access to your schedule or appointments, but you can check your calendar or call the office directly.",
                       "I understand you want to know. Unfortunately, I don't have access to your schedule.",
                       "I'm sorry, but I don't have access to your calendar. I recommend checking your calendar app.",
                       "I can't see your calendar. Please check your Calendar app or call the office for details. Is there anything else I can help with?",
                       // Round 9 P3: pointer shapes the dentist case uses.
                       "Unfortunately, I can't see your calendar. Please check your calendar or contact your dentist's office.",
                       "Sorry, I don't have access to your schedule. Contact the dentist directly.",
                       "I don't have access to your calendar. I'd recommend checking your calendar app.",
                       "I can't see your schedule. I recommend you check your calendar.",
                       // Round 10: tails and leads that say nothing more.
                       "As an AI, I don't have access to your calendar.",
                       "I'm sorry, but as an AI, I can't see your schedule.",
                       "Sorry \u{2014} I can't see your calendar right now.",
                       "I can't see your calendar, sorry.",
                       "I don't have access to your calendar events from here."]
        for ask in asks {
            for reply in replies {
                let out = vet(reply, ask: ask)
                XCTAssertTrue(out.replaced, ask + " / " + reply)
                XCTAssertTrue(out.text.hasPrefix("Nothing on your calendar") || out.text.hasPrefix("I searched")
                              || out.text.hasPrefix("Nothing on your calendar is named"), ask + " -> " + out.text)
            }
        }
    }

    /// Wave 72 round 2 P3: "es" is a plural only after s, x, z, ch or sh
    /// ("classes", "lunches"), so "jones" is not "Jon" and "jam" is not "James".
    func testTheEsPluralFollowsOnlyItsEndings() throws {
        CalendarAsk.events = { _, _ in
            [self.event("Lunch with Jon", self.date(2026, 11, 10, 12), self.date(2026, 11, 10, 13)),
             self.event("Team lunches", self.date(2026, 11, 11, 12), self.date(2026, 11, 11, 13))]
        }
        XCTAssertTrue(try answer("When is my meeting with Jones?").hasPrefix("I searched"))
        XCTAssertEqual(try answer("When is my team lunch?"),
                       "From your calendar: Team lunches, Wednesday, Nov 11, 12:00 PM to 1:00 PM.")
        CalendarAsk.events = { _, _ in [self.event("Coffee with James", self.date(2026, 11, 10, 9), self.date(2026, 11, 10, 10))] }
        XCTAssertTrue(try answer("When is my jam session?").hasPrefix("I searched"))
    }

    /// The guard is local only, and a read this turn backs the reply.
    func testCloudAndABackedTurnKeepTheirReply() {
        CalendarAsk.events = { _, _ in [] }
        let denial = "I don't have access to your calendar."
        XCTAssertFalse(vet(denial, ask: "When is my dentist appointment?", route: "anthropic").replaced)
        XCTAssertFalse(vet(denial, ask: "When is my dentist appointment?",
                           results: [(tool: "list_events", input: [:], result: "[]")]).replaced)
    }

    // MARK: - The wiring

    /// Order in send(): right after the calendar ask, before the readiness guard, so it needs no model.
    func testTheSearchSitsAfterTheCalendarAskAndBeforeTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let calendar = try XCTUnwrap(src.range(of: "CalendarAsk.window(for: trimmed)"))
        let search = try XCTUnwrap(src.range(of: "CalendarSearchAsk.match(trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(calendar.lowerBound < search.lowerBound && search.lowerBound < readiness.lowerBound)
        // Wave 72 round 1 P2-1: a photo turn's answer is never swapped for a search.
        XCTAssertNotNil(src.range(of: "ask: userText, hasImage: imageData != nil)"))
    }
}
