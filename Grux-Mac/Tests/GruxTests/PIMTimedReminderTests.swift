import XCTest
@testable import Grux

/// D147 (sense pass 18, `logs/s18-chat/replies.txt`): "Remind me to call the
/// dentist tomorrow at 9 AM" answered "Added \"Call the dentist tomorrow at 9
/// AM\" to your tasks." The time stayed in the title and nothing reminded
/// anyone at 9 AM. A "remind me to" that names a time now adds the task under
/// its own name and schedules Grux's own reminder for that time, and says so.
@MainActor
final class PIMTimedReminderTests: XCTestCase {

    private func tomorrowAt(_ hour: Int) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)!
    }

    func testATimeInTheAskIsTheReminderAndLeavesTheTitle() throws {
        let m = try XCTUnwrap(PIMIntents.match("Remind me to call the dentist tomorrow at 9 AM"))
        XCTAssertEqual(m.kind, .addTask)
        XCTAssertEqual(m.slots.title, "call the dentist")
        XCTAssertEqual(m.slots.date, tomorrowAt(9))

        let soon = try XCTUnwrap(PIMIntents.match("remind me to stretch in 20 minutes"))
        XCTAssertEqual(soon.slots.title, "stretch")
        let gap = try XCTUnwrap(soon.slots.date).timeIntervalSince(Date())
        XCTAssertTrue((19 * 60...21 * 60).contains(gap), "\(gap)")
    }

    /// No time, or a day with no time, is a task as before: Grux does not
    /// pick an hour nobody said.
    func testNoTimeIsATaskAsBefore() throws {
        for (ask, title) in [("remind me to call the plumber", "call the plumber"),
                             ("remind me to call mom tomorrow", "call mom tomorrow"),
                             ("remind me to call the dentist at three", "call the dentist at three")] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertEqual(m.kind, .addTask, ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertNil(PIMIntents.plan(for: ask)?.reminder, ask)
        }
        // Other ways of adding a task never schedule anything.
        XCTAssertNil(PIMIntents.plan(for: "add a task: call the dentist tomorrow at 9 AM")?.reminder)
    }

    /// W48-P3 item 4: "add a task: remind me to call mom at 9pm" was a plain
    /// task titled "Remind me to call mom at 9pm" with no reminder. A
    /// "remind me to" inside a task the person names is the same ask: the
    /// task under its own name, the reminder at its time. A task named with
    /// no "remind me to" still schedules nothing (the test above), and one
    /// with no time it reads keeps every word.
    func testARemindMeToNamedAsATaskReminds() throws {
        let ten = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let ninePM = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: ten)!
        for ask in ["add a task: remind me to call mom at 9pm",
                    "Add a task called remind me to call mom at 9 PM",
                    "add remind me to call mom at 9pm to my tasks"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: ten), ask)
            XCTAssertEqual(m.kind, .addTask, ask)
            XCTAssertEqual(m.slots.title, "call mom", ask)
            XCTAssertEqual(m.slots.date, ninePM, ask)
            XCTAssertTrue(m.slots.namedAsATask, ask)
        }
        for (ask, title) in [("add a task: remind me to call mom", "remind me to call mom"),
                             ("add a task: remind me to call mom at three", "remind me to call mom at three"),
                             ("add a task: call mom at 9pm", "call mom at 9pm")] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: ten), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertNil(m.slots.date, ask)
        }
    }

    func testThePlanCarriesTheReminder() throws {
        let plan = try XCTUnwrap(PIMIntents.plan(for: "Remind me to call the dentist tomorrow at 9 AM"))
        XCTAssertEqual(plan.toolName, "add_task")
        XCTAssertEqual(plan.toolInput?["title"] as? String, "Call the dentist")
        XCTAssertEqual(plan.cardTitle, "Call the dentist")
        XCTAssertEqual(plan.cardDetail, "task list, reminder tomorrow at 9 AM")
        XCTAssertEqual(plan.spokenAck, "Added to your tasks: call the dentist. I'll remind you tomorrow at 9 AM.")
        let reminder = try XCTUnwrap(plan.reminder)
        XCTAssertEqual(reminder.kind, .commitment)
        XCTAssertEqual(reminder.title, "Call the dentist")
        XCTAssertEqual(reminder.scheduledFor, tomorrowAt(9))
        XCTAssertEqual(reminder.body, "You asked me to remind you: call the dentist.")
    }

    /// The reminder is scheduled only when the task really landed, and the
    /// line in Chat says when it will come.
    func testTheReminderIsScheduledOnlyWhenTheTaskLands() async throws {
        let savedChat = AppState.shared.chat
        let savedMemory = AppState.shared.config.memoryEnabled
        AppState.shared.config.memoryEnabled = false
        defer {
            AppState.shared.chat = savedChat
            AppState.shared.config.memoryEnabled = savedMemory
        }
        let plan = try XCTUnwrap(PIMIntents.plan(for: "Remind me to call the dentist tomorrow at 9 AM"))
        guard case .tool(let name, let input) = plan.execution else { return XCTFail("not a tool plan") }
        var scheduled: [GruxReminder] = []
        let landed = await PIMConfirmationController.runAndTell(
            name: name, input: input, personAsked: false, reminder: plan.reminder,
            schedule: { scheduled.append($0) }, via: { _, _ in "ok: added 'Call the dentist' (NEXT)" })
        XCTAssertEqual(scheduled.map(\.scheduledFor), [tomorrowAt(9)])
        XCTAssertEqual(landed.reply, "Added \"Call the dentist\" to your tasks. "
                       + "I'll remind you tomorrow at 9 AM if Grux is open then.")
        XCTAssertEqual(AppState.shared.chat.last?.content, landed.reply)

        for failing in ["error: tasks store unavailable", JaxToolGate.dryRunStatus + " add_task"] {
            scheduled = []
            let out = await PIMConfirmationController.runAndTell(
                name: name, input: input, personAsked: false, reminder: plan.reminder,
                schedule: { scheduled.append($0) }, via: { _, _ in failing })
            XCTAssertTrue(scheduled.isEmpty, failing)
            XCTAssertFalse(out.reply.contains("remind you"), out.reply)
        }
    }

    /// Both doors that run a card pass its reminder on.
    func testBothCardDoorsPassTheReminder() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/Voice/PIMConfirmationCard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = source.components(separatedBy: "await Self.runAndTell(").count - 1
            + source.components(separatedBy: "await runAndTell(").count - 1
        let passing = source.components(separatedBy: "reminder: plan.reminder").count - 1
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(passing, calls)
    }
    /// Live at 12:30 PM: the judge held "Remind me to stretch in 2 minutes" back
    /// at 0.18, told only "add a task ... reminder today at 12:32 PM" with no
    /// clock to check "in 2 minutes" against. A reminder plan names the
    /// reminder in the action and the time now; other plans are unchanged.
    func testTheJudgeIsToldTheReminderAndTheTimeNow() throws {
        let now = Date()
        let words = "Remind me to stretch in 20 minutes"
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words, now: now))
        let state = ChatIntentClassifier.pimState(plan: plan, utterance: words, today: now)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US")
        clock.dateFormat = "h:mm a"
        XCTAssertTrue(state.contains("It is now \(clock.string(from: now))."), state)
        XCTAssertTrue(state.contains("add a task to the person's task list and remind them of it at the time named"), state)

        let plain = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: "remind me to call the plumber", now: now))
        let plainState = ChatIntentClassifier.pimState(plan: plain, utterance: "remind me to call the plumber", today: now)
        XCTAssertFalse(plainState.contains("It is now"), plainState)
        XCTAssertFalse(plainState.contains("remind them"), plainState)
    }

    /// D181, the suite at 12:05 AM on Friday Nov 6: "Remind me to call mom on
    /// Friday at 3pm" left no reminder. macOS reads "Friday at 3pm" said on a
    /// Friday as next Friday, 7 days and 15 hours away, past the week the day
    /// must fall in. Said on the day with the time still ahead, it is today;
    /// with the time gone (or too close to remind), next week's, as before.
    func testTheNamedWeekdayIsTodayWhileItsTimeIsAhead() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ h: Int, _ m: Int = 0, _ sec: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: sec))!
        }
        let friday = 6, nextFriday3pm = at(13, 15)
        // Today, Friday Nov 6, at 12:05 AM: 3 PM today.
        XCTAssertEqual(PIMIntents.weekdayReminderDate(read: nextFriday3pm, weekday: friday, now: at(6, 0, 5), calendar: cal), at(6, 15))
        // Exactly the minimum lead before 3 PM today still reminds today; a second inside it does not.
        let lead = PIMIntents.reminderMinimumLead
        XCTAssertEqual(PIMIntents.weekdayReminderDate(read: nextFriday3pm, weekday: friday,
                                                      now: at(6, 15).addingTimeInterval(-lead), calendar: cal), at(6, 15))
        XCTAssertNil(PIMIntents.weekdayReminderDate(read: nextFriday3pm, weekday: friday,
                                                    now: at(6, 15).addingTimeInterval(-lead + 1), calendar: cal))
        // At 4 PM Friday macOS reads next Friday, under 7 days away: kept.
        XCTAssertEqual(PIMIntents.weekdayReminderDate(read: nextFriday3pm, weekday: friday, now: at(6, 16), calendar: cal), nextFriday3pm)
        // Another day named, read inside the week: kept; a read on the wrong weekday or 8 days out: none.
        let saturday3pm = at(7, 15)
        XCTAssertEqual(PIMIntents.weekdayReminderDate(read: saturday3pm, weekday: 7, now: at(6, 0, 5), calendar: cal), saturday3pm)
        XCTAssertNil(PIMIntents.weekdayReminderDate(read: saturday3pm, weekday: friday, now: at(6, 0, 5), calendar: cal))
        XCTAssertNil(PIMIntents.weekdayReminderDate(read: at(14, 15), weekday: 7, now: at(6, 0, 5), calendar: cal))
    }

    /// W47-FIX P2 1: macOS reads only the clock in "next week at 3pm", "this
    /// weekend at 10pm", "at 11pm next month", and "Monday at 9am" in "every
    /// Monday at 9am", and dated them today or this Monday. A day word next to
    /// the time it read means the day is not known: no reminder, the words
    /// stay in the task as before.
    func testADayWordMacOSDidNotReadLeavesNoReminder() throws {
        for ask in ["Remind me to call mom next week at 3pm", "Remind me to call mom this weekend at 10pm",
                    "remind me to call mom at 11pm next month", "Remind me to call mom every Monday at 9am",
                    "remind me to water the plants every day at 9am", "remind me to pay rent at 9am every month",
                    "remind me to call mom at 3pm this week", "remind me to stretch every 2 hours"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertEqual(m.kind, .addTask, ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
            XCTAssertNil(PIMIntents.plan(for: ask)?.reminder, ask)
        }
        // A day macOS reads, or a word that is the task's own, still reminds.
        let friday = try XCTUnwrap(PIMIntents.match("Remind me to call mom on Friday at 3pm"))
        XCTAssertNotNil(friday.slots.date)
        XCTAssertEqual(friday.slots.title, "call mom")
        let sprint = try XCTUnwrap(PIMIntents.match("remind me to plan the next sprint tomorrow at 3pm"))
        XCTAssertEqual(sprint.slots.title, "plan the next sprint")
        XCTAssertEqual(sprint.slots.date, tomorrowAt(15))
    }

    private func todayAt(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    /// W47-FIX round 2 P2 1: the day word hid behind "the", "over", "in",
    /// "sometime", "following" and after "days". Any day or span word left
    /// beside the task, anywhere, now means the day is not known.
    func testADayWordAnywhereInTheRestLeavesNoReminder() throws {
        for ask in ["Remind me to call mom at 11pm on the weekend", "Remind me to call mom at 11pm over the weekend",
                    "Remind me to call mom at 11pm in a week", "Remind me to call mom at 11pm in a few days",
                    "Remind me to call mom in two days at 11pm", "Remind me to call mom at 11pm sometime next week",
                    "Remind me to call mom at 11pm on Christmas", "Remind me to call mom at 11pm the following week",
                    "Remind me to call mom at 11pm on her birthday", "remind me to send the weekly report at 11pm"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
    }

    /// Round 2 P2 2: "this" or "next" before the time names no day.
    /// Round 3: a reminder needs the time at the end, in a shape Grux reads
    /// itself ("at 9 AM", "at 9:30 pm", "at noon", with today, tonight,
    /// tomorrow or on a weekday beside it, or "in 20 minutes"); the task is
    /// every word before it.
    func testTheTimeAtTheEndIsTheReminderAndTheRestIsTheTask() throws {
        let cases: [(String, String, Date)] = [
            ("Remind me to finish this tomorrow at 11pm", "finish this", tomorrowAt(23)),
            ("Remind me to do the next one tomorrow at 11pm", "do the next one", tomorrowAt(23)),
            ("Remind me to call mom at 11 PM tomorrow", "call mom", tomorrowAt(23)),
            ("Remind me to call mom tomorrow at 11:00 pm", "call mom", tomorrowAt(23)),
            ("Remind me to call mom tomorrow at noon", "call mom", tomorrowAt(12)),
            ("Remind me to call mom tomorrow at 11 p.m.", "call mom", tomorrowAt(23)),
            ("Remind me to join the standup on Zoom tomorrow at 9am", "join the standup on Zoom", tomorrowAt(9)),
        ]
        for (ask, title, date) in cases {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertEqual(m.slots.date, date, ask)
        }
        let weekday = try XCTUnwrap(PIMIntents.match("Remind me to call mom on Friday at 3pm"))
        XCTAssertEqual(weekday.slots.title, "call mom")
        XCTAssertEqual(weekday.slots.date.map { Calendar.current.component(.weekday, from: $0) }, 6)
    }

    /// Round 3 P2 1 and 2: anything else is a plain task with every word
    /// kept: a time in the middle, a word around the time, a plural weekday,
    /// a misspelled or short day, a year, a month. A miss costs a reminder,
    /// never a wrong day or a broken title.
    func testAnyOtherShapeIsAPlainTask() throws {
        for ask in ["Remind me to call mom at 11pm about the trip", "Remind me to pick up the kids at 11pm from school",
                    "Remind me to submit the report before 11pm", "Remind me to call mom at about 11pm",
                    "Remind me to call mom after 11pm", "Remind me to call mom no later than 11pm",
                    "Remind me to call mom at approximately 11pm", "Remind me to call mom around about 11pm",
                    "Remind me to call mom sometime around 11pm", "Remind me to call mom @ 11pm",
                    "Remind me to call mom at 11 pm sharp", "Remind me to take out the trash on Mondays at 8pm",
                    "Remind me to take out the trash at 8pm on Mondays", "Remind me to call mom on weeknights at 11pm",
                    "Remind me to call mom tommorow at 11pm", "Remind me to call mom tomorow at 11pm",
                    "Remind me to call mom tmr at 11pm", "Remind me to call mom on Xmas at 11pm",
                    "Remind me to call mom on her bday at 11pm", "Remind me to call mom in 2 wks at 11pm",
                    "Remind me to call mom next yr at 11pm", "Remind me to call mom in 2027 at 11pm",
                    "Remind me to call mom in May at 11pm", "Remind me to call mom at 7"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertEqual(m.kind, .addTask, ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
    }

    /// Round 4 P2 1: macOS reads no date in "on the 1st", "on the 15th" or
    /// "on sat", so a bare "at 11pm" went to today. With no day in the time
    /// phrase, the task part may hold no "on", no number and no ordinal; an
    /// ordinal or "on" a short weekday refuses whatever the time says.
    /// Round 4 P3: "tonight at 9am" is not tonight.
    func testADayMacOSCannotReadInTheTaskLeavesNoReminder() throws {
        for ask in ["Remind me to pay rent on the 1st at 11pm", "Remind me to call mom on the 15th at 11pm",
                    "Remind me to call mom on the 4th at 11pm", "Remind me to pay rent on the first at 11pm",
                    "Remind me to call mom on sat at 11pm", "Remind me to call mom on Sat. at 11pm",
                    "Remind me to call mom on wed at 11pm", "Remind me to call mom on sun at 10pm",
                    "Remind me to call mom on mon at 10pm", "Remind me to file the report at the end of the quarter at 11pm",
                    "Remind me to pay rent on the 1st tomorrow at 9am", "Remind me to call mom tonight at 9am",
                    "Remind me to call mom at midnight", "Remind me to stretch in twenty minutes"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        // A day said in the time phrase still allows "on Zoom" and numbers in the task.
        let zoom = try XCTUnwrap(PIMIntents.match("Remind me to book room 12 on Zoom tomorrow at 9am"))
        XCTAssertEqual(zoom.slots.title, "book room 12 on Zoom")
        XCTAssertEqual(zoom.slots.date, tomorrowAt(9))
    }

    /// Round 5 P2: a short weekday without "on", or a misspelled day, still
    /// reminded today. Day words are now matched loosely (a letter or two
    /// off, or the same consonants), and a short weekday anywhere refuses
    /// when the time phrase names no day.
    func testAMisspelledOrShortDayLeavesNoReminder() throws {
        for ask in ["Remind me to call mom Sat at 9pm", "Remind me to call mom Sat. at 9pm",
                    "Remind me to call mom this Sat at 9pm", "Remind me to call mom this sun at 9pm",
                    "Remind me to call mom this Wed at 9pm", "Remind me to call mom tomarrow at 9pm",
                    "Remind me to call mom tomorrw at 9pm", "Remind me to call mom tmrrw at 9pm",
                    "Remind me to call mom tomoro at 9pm", "Remind me to call mom tmrow at 9pm",
                    "Remind me to call mom thursdy at 9pm", "Remind me to call mom wensday at 9pm",
                    "Remind me to call mom this wkend at 9pm", "Remind me to call mom over the wknd at 9pm",
                    "Remind me to call mom tomorrow at 12am"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        // Round 5 P3: "later today" is the time phrase, not the task's.
        let later = try XCTUnwrap(PIMIntents.match("Remind me to call mom later tomorrow at 9pm"))
        XCTAssertEqual(later.slots.title, "call mom")
        XCTAssertEqual(later.slots.date, tomorrowAt(21))
        // Everyday words that are near no day still remind ("fortnite" is the
        // game far more often than "fortnight", so it is one of them).
        let monkey = try XCTUnwrap(PIMIntents.match("Remind me to feed the monkey tomorrow at 9pm"))
        XCTAssertEqual(monkey.slots.date, tomorrowAt(21))
        XCTAssertEqual(PIMIntents.match("Remind me to play Fortnite tomorrow at 9pm")?.slots.date, tomorrowAt(21))
    }

    /// Round 6 P2: "in sept", "this summer", "for valentines" reminded today.
    /// With no day in the time phrase, the words that tie a task to a time
    /// (in, on, by, next, this, end, of, for, every and the like, a closed
    /// set) now leave no reminder, whatever noun follows them.
    /// Round 6 P3: everyday words near no day remind ("study", "Wendy"); a
    /// first-letter typo of a long day word does not; 12:30am is refused.
    func testTimeWordsInTheTaskLeaveNoReminderAndEverydayWordsStillDo() throws {
        for ask in ["Remind me to renew passport in sept at 11pm", "Remind me to pay rent end of oct at 11pm",
                    "Remind me to pay the bill by dec at 11pm", "Remind me to pay the bill in jan at 11pm",
                    "Remind me to book flights this summer at 11pm", "Remind me to plan the trip next spring at 11pm",
                    "Remind me to rake leaves in the fall at 11pm", "Remind me to pay the bill next semester at 11pm",
                    "Remind me to pay rent next mnth at 11pm", "Remind me to buy flowers for valentines at 11pm",
                    "Remind me to buy gifts for hanukkah at 11pm", "Remind me to call mom yomorrow at 11pm",
                    "Remind me to call mom tomorrow at 12:30am"] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        for (ask, title) in [("Remind me to study tomorrow at 11pm", "study"), ("Remind me to call Wendy tomorrow at 11pm", "call Wendy"),
                             ("Remind me to fight the ticket tomorrow at 11pm", "fight the ticket")] {
            let m = try XCTUnwrap(PIMIntents.match(ask), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertEqual(m.slots.date, tomorrowAt(23), ask)
        }
        let hydrate = try XCTUnwrap(PIMIntents.match("Remind me to stay hydrated in 20 minutes"))
        XCTAssertEqual(hydrate.slots.title, "stay hydrated")
        XCTAssertNotNil(hydrate.slots.date)
    }

    private var tenToday: Date { Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())! }

    /// Round 7 P2 2: the round 6 tie words cost the most common reminders.
    /// With no day said, everyday prepositions and numbers stay in the task
    /// and the reminder is today (asked at 10 AM today, so the hour is ahead
    /// whenever the suite runs).
    func testEverydayTasksWithNoDaySaidRemindToday() throws {
        let cases: [(String, String, Int)] = [
            ("Remind me to pick up the kids from school at 3pm", "pick up the kids from school", 15),
            ("Remind me to leave for the airport at 5pm", "leave for the airport", 17),
            ("Remind me to put the chicken in the oven at 6pm", "put the chicken in the oven", 18),
            ("Remind me to turn on the dishwasher at 10pm", "turn on the dishwasher", 22),
            ("Remind me to check in for my flight at 3pm", "check in for my flight", 15),
            ("Remind me to finish this at 5pm", "finish this", 17),
            ("Remind me to take 2 pills at 9pm", "take 2 pills", 21),
            ("Remind me to call the head of sales at 11pm", "call the head of sales", 23),
            ("Remind me to call mom on her cell at 11pm", "call mom on her cell", 23),
            ("Remind me to book room 12 at 11pm", "book room 12", 23),
        ]
        for (ask, title, hour) in cases {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertEqual(m.slots.date, Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()), ask)
        }
    }

    /// Round 7 P2 1 and P3, and round 6's P2 again under the new rule: the
    /// tomorrow typo family, other shorthands, and months, seasons and
    /// holidays written short or after "in", "by", "this", "next".
    func testTheDayWordsPeopleTypeLeaveNoReminder() throws {
        for ask in ["Remind me to call mom tomrow at 9pm", "Remind me to call mom tomorw at 9pm",
                    "Remind me to call mom tmorow at 9pm", "Remind me to call mom tmrrow at 9pm",
                    "Remind me to call mom tmorrw at 9pm", "Remind me to call mom tmoro at 9pm",
                    "Remind me to call mom tommoro at 9pm", "Remind me to call mom tommorw at 9pm",
                    "Remind me to call mom tomo at 9pm", "Remind me to call mom tomoz at 9pm",
                    "Remind me to call mom morrow at 9pm", "Remind me to call mom satday at 9pm",
                    "Remind me to renew passport in sept at 9pm", "Remind me to pay rent end of oct at 9pm",
                    "Remind me to pay the bill by dec at 9pm", "Remind me to pay the bill in jan at 9pm",
                    "Remind me to pay the bill by mar at 9pm", "Remind me to book flights this summer at 9pm",
                    "Remind me to plan the trip next spring at 9pm", "Remind me to rake leaves in the fall at 9pm",
                    "Remind me to pay the bill next semester at 9pm", "Remind me to pay rent next mnth at 9pm",
                    "Remind me to buy flowers for valentines at 9pm", "Remind me to buy gifts for diwali at 9pm",
                    "Remind me to fast for ramadan at 9pm", "Remind me to plan the seder for passover at 9pm",
                    "Remind me to pay rent on the 15 at 9pm", "Remind me to call mom on Feb 3 at 9pm"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        // A name is a name: "Jan", "May" and "Frida" are people when no time word leads them.
        for (ask, title) in [("Remind me to call Jan at 9pm", "call Jan"), ("Remind me to email May at 9pm", "email May"),
                             ("Remind me to feed the monkey at 9pm", "feed the monkey")] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertNotNil(m.slots.date, ask)
        }
    }

    /// Round 8 P2: two swapped letters were two edits, so "tuseday" and
    /// "wekeend" reminded today; a swap is one edit now. Round 8 P3: more
    /// shorthands, and month-day digits macOS does not read.
    func testSwappedLettersAndDateDigitsLeaveNoReminder() throws {
        for ask in ["Remind me to call mom tuseday at 9pm", "Remind me to call mom tuesady at 9pm",
                    "Remind me to call mom tuesdya at 9pm", "Remind me to call mom this wekeend at 9pm",
                    "Remind me to call mom weekedn at 9pm", "Remind me to call mom 2mrw at 9pm",
                    "Remind me to call mom tmro at 9pm", "Remind me to call mom tomrw at 9pm",
                    "Remind me to pay the bill on 11-15 at 9pm", "Remind me to pay rent 11-15 at 9pm",
                    "Remind me to pay rent on 11.15 at 9pm", "Remind me to pay rent on 15 at 9pm"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        XCTAssertNotNil(PIMIntents.match("Remind me to feed the monkey at 9pm", now: tenToday)?.slots.date)
        XCTAssertNotNil(PIMIntents.match("Remind me to take 2 pills at 9pm", now: tenToday)?.slots.date)
    }

    /// Round 9 P2: a number typed together with its unit ("in 3days",
    /// "in 2wks") was one word and no day word. Round 9 P3: more shorthands;
    /// "take 1-2 tablets" is a dose, not a date.
    func testANumberGluedToItsUnitLeavesNoReminder() throws {
        for ask in ["Remind me to call mom in 3days at 9pm", "Remind me to call mom in 2weeks at 9pm",
                    "Remind me to call mom in 2wks at 9pm", "Remind me to call mom in 1wk at 9pm",
                    "Remind me to call mom in 6months at 9pm", "Remind me to call mom in 1yr at 9pm",
                    "Remind me to call mom in 2days time at 9pm", "Remind me to call mom tomor at 9pm",
                    "Remind me to call mom 2mor at 9pm", "Remind me to call mom 2morro at 9pm",
                    "Remind me to call mom tmmrw at 9pm", "Remind me to call mom satur at 9pm",
                    "Remind me to get paid on payday at 9pm"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        for (ask, title) in [("Remind me to take 1-2 tablets at 9pm", "take 1-2 tablets"),
                             ("Remind me to do 5-10 pushups at 9pm", "do 5-10 pushups")] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            XCTAssertNotNil(m.slots.date, ask)
        }
    }

    /// Round 10 P2: "mo" and "mos" after a number are months; "call Mo" is a
    /// person. Round 10 P3: units a day or longer after a number, repeat
    /// words, run-together day words, more shorthands.
    func testAMonthShortAfterANumberLeavesNoReminder() throws {
        for ask in ["Remind me to call mom in 6mo at 9pm", "Remind me to renew the lease in 3 mos at 9pm",
                    "Remind me to call mom in 2d at 9pm", "Remind me to call mom in 2 dys at 9pm",
                    "Remind me to water the plants biweekly at 9pm", "Remind me to pay rent bimonthly at 9pm",
                    "Remind me to call mom wkly at 9pm", "Remind me to call mom nextweek at 9pm",
                    "Remind me to call mom thisweekend at 9pm", "Remind me to call mom nxtwk at 9pm",
                    "Remind me to call mom 2mrow at 9pm"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
        for (ask, title) in [("Remind me to call Mo at 9pm", "call Mo"), ("Remind me to buy 2 d batteries at 9pm", "buy 2 d batteries")] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: tenToday), ask)
            XCTAssertEqual(m.slots.title, title, ask)
            if ask.contains("Mo ") { XCTAssertNotNil(m.slots.date, ask) }
        }
    }

    // MARK: - W47-P3 item 1: the undo window never crosses the reminder

    /// "at 10 AM" said at 9:59:57 was a reminder: the card ran after its 5 s
    /// undo window, the reminder fired at once, and Chat named a time already
    /// gone. A reminder needs its time at least `reminderMinimumLead` away (the
    /// undo window and 30 s more); a nearer one stays a plain task, every word
    /// kept. On the boundary it is a reminder; one second under, a task.
    func testAReminderTooSoonStaysAPlainTask() throws {
        let cal = Calendar.current
        let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(PIMIntents.reminderMinimumLead, PIMIntents.undoWindowSeconds + 30)
        let lead = PIMIntents.reminderMinimumLead
        for (before, reminds) in [(lead, true), (lead + 1, true), (lead - 1, false), (3.0, false), (600.0, true)] {
            let now = ten.addingTimeInterval(-before)
            let m = try XCTUnwrap(PIMIntents.match("Remind me to stretch at 10 AM", now: now), "\(before)")
            XCTAssertEqual(m.kind, .addTask)
            if reminds {
                XCTAssertEqual(m.slots.title, "stretch", "\(before)")
                XCTAssertEqual(m.slots.date, ten, "\(before)")
            } else {
                XCTAssertEqual(m.slots.title, "stretch at 10 AM", "\(before)")
                XCTAssertNil(m.slots.date, "\(before)")
            }
        }
        // "in 1 minute" is past the lead and still reminds.
        let soon = try XCTUnwrap(PIMIntents.match("remind me to stretch in 1 minute", now: ten))
        XCTAssertEqual(soon.slots.date, ten.addingTimeInterval(60))
    }

    // MARK: - W47-P3 item 3: a reminder belongs to its task

    /// The reminder carried no task, so checking the task off or removing it
    /// left the reminder to fire anyway. The task's id rides on the reminder
    /// once the task lands.
    func testTheReminderCarriesItsTask() async throws {
        let savedChat = AppState.shared.chat
        let savedMemory = AppState.shared.config.memoryEnabled
        AppState.shared.config.memoryEnabled = false
        defer {
            AppState.shared.chat = savedChat
            AppState.shared.config.memoryEnabled = savedMemory
        }
        let plan = try XCTUnwrap(PIMIntents.plan(for: "Remind me to call the dentist tomorrow at 9 AM"))
        guard case .tool(let name, let input) = plan.execution else { return XCTFail("not a tool plan") }
        let task = UUID()
        var asked: [String] = []
        var scheduled: [GruxReminder] = []
        _ = await PIMConfirmationController.runAndTell(
            name: name, input: input, personAsked: false, reminder: plan.reminder,
            schedule: { scheduled.append($0) },
            taskId: { asked.append($0); return task },
            via: { _, _ in "ok: added 'Call the dentist' (NEXT)" })
        XCTAssertEqual(asked, ["Call the dentist"])
        XCTAssertEqual(scheduled.map(\.taskId), [task])
        XCTAssertEqual(scheduled.map(\.taskTitle), ["Call the dentist"])
    }

    /// At its time, a reminder whose task was checked off or removed does not
    /// come: it is set aside, whichever door ended the task. A reminder with
    /// no task, or with its task still open, comes as before.
    func testAReminderForAnEndedTaskDoesNotCome() throws {
        let open = UUID(), ended = UUID()
        let isOpen: (UUID) -> Bool = { $0 == open }
        func r(_ task: UUID?) -> GruxReminder {
            GruxReminder(kind: .commitment, title: "t", body: "b", scheduledFor: Date(), taskId: task)
        }
        XCTAssertFalse(GruxReminderState.taskEnded(r(nil), taskIsOpen: isOpen,
                                                        titleIsOpen: { _ in false }))
        XCTAssertFalse(GruxReminderState.taskEnded(r(open), taskIsOpen: isOpen,
                                                        titleIsOpen: { _ in false }))
        XCTAssertTrue(GruxReminderState.taskEnded(r(ended), taskIsOpen: isOpen,
                                                        titleIsOpen: { _ in false }))

        // Through the one door every due reminder fires by.
        let state = GruxReminderState.shared
        let saved = state.reminders
        defer { state.reminders = saved; state.save() }
        let gone = r(UUID())
        state.reminders.insert(gone, at: 0)
        state.fire(gone.id)
        let after = try XCTUnwrap(state.reminders.first { $0.id == gone.id })
        XCTAssertNil(after.firedAt, "a reminder for a task that is gone fired")
        XCTAssertTrue(after.dismissed)
        XCTAssertNotEqual(state.activeToast?.id, gone.id)
    }

    /// W48-P3 item 3: with "Call mom" already open, "remind me to call mom at
    /// 9pm" adds a second one and the reminder binds to it. Checking that one
    /// off, or removing it and adding the title back, left a "Call mom" open,
    /// so the reminder still comes. It is set aside only when no open task
    /// carries its task's title (in any case, around any spaces).
    func testAReminderComesWhileATaskWithItsTitleIsOpen() {
        let ended = UUID()
        func r(_ title: String?) -> GruxReminder {
            var x = GruxReminder(kind: .commitment, title: "t", body: "b", scheduledFor: Date(), taskId: ended)
            x.taskTitle = title
            return x
        }
        let closed: (UUID) -> Bool = { _ in false }
        let openTitles: (String) -> Bool = { GruxReminderState.sameTaskTitle($0, "Call mom") }
        XCTAssertFalse(GruxReminderState.taskEnded(r("Call mom"), taskIsOpen: closed, titleIsOpen: openTitles))
        XCTAssertFalse(GruxReminderState.taskEnded(r(" call MOM "), taskIsOpen: closed, titleIsOpen: openTitles))
        XCTAssertTrue(GruxReminderState.taskEnded(r("Call mo"), taskIsOpen: closed, titleIsOpen: openTitles))
        XCTAssertTrue(GruxReminderState.taskEnded(r("Call mom later"), taskIsOpen: closed, titleIsOpen: openTitles))
        XCTAssertTrue(GruxReminderState.taskEnded(r(nil), taskIsOpen: closed, titleIsOpen: openTitles),
                      "a reminder with no title of its task ends with its task")
        XCTAssertTrue(GruxReminderState.taskEnded(r(""), taskIsOpen: closed, titleIsOpen: { _ in true }),
                      "an empty title never keeps a reminder")
    }

    /// The default title check reads open tasks only.
    func testTheDefaultTitleCheckReadsOpenTasks() {
        let saved = AppState.shared.tasks
        defer { AppState.shared.tasks = saved }
        var t = FocusTask(title: "W48 item 3 call", project: "", priority: .next, parentId: nil)
        AppState.shared.tasks.insert(t, at: 0)
        XCTAssertTrue(GruxReminderState.titleIsOpenInList("w48 item 3 CALL"))
        t.completed = true
        AppState.shared.tasks[0] = t
        XCTAssertFalse(GruxReminderState.titleIsOpenInList("W48 item 3 call"))
    }

    /// The default reads the task list: an open task is open; a checked-off
    /// or removed one is not.
    func testTheDefaultTaskCheckReadsTheTaskList() {
        let saved = AppState.shared.tasks
        defer { AppState.shared.tasks = saved }
        let t = FocusTask(title: "w47p3 item 3", project: "", priority: .next, parentId: nil)
        AppState.shared.tasks.insert(t, at: 0)
        XCTAssertTrue(GruxReminderState.taskIsOpenInList(t.id))
        AppState.shared.tasks[0].completed = true
        XCTAssertFalse(GruxReminderState.taskIsOpenInList(t.id))
        AppState.shared.tasks.removeAll { $0.id == t.id }
        XCTAssertFalse(GruxReminderState.taskIsOpenInList(t.id))
    }

    /// Wave 48 review: a reminder whose task was checked off at 3 PM stayed in
    /// Home's open commitments and the morning brief until its 9 PM time.
    /// Pending means its task is still open too.
    func testAReminderForAnEndedTaskIsNotPending() {
        let state = GruxReminderState.shared
        let saved = state.reminders
        let savedTasks = AppState.shared.tasks
        defer { state.reminders = saved; state.save(); AppState.shared.tasks = savedTasks }
        let open = FocusTask(title: "w48 open", project: "", priority: .next, parentId: nil)
        AppState.shared.tasks.insert(open, at: 0)
        let later = Date().addingTimeInterval(3600)
        let gone = GruxReminder(kind: .commitment, title: "gone", body: "b", scheduledFor: later, taskId: UUID())
        let kept = GruxReminder(kind: .commitment, title: "kept", body: "b", scheduledFor: later, taskId: open.id)
        let plain = GruxReminder(kind: .commitment, title: "plain", body: "b", scheduledFor: later)
        state.reminders = [gone, kept, plain]
        XCTAssertEqual(state.pendingScheduled.map(\.title), ["kept", "plain"])
        AppState.shared.tasks[0].completed = true
        XCTAssertEqual(state.pendingScheduled.map(\.title), ["plain"])
    }

    // MARK: - W47-P3 item 4: the spans people say out loud

    /// "Remind me to call mom in an hour" got no reminder: the span grammar
    /// took digits only. The spoken spans with one meaning become reminders;
    /// "at 9" (no AM or PM) and a bare "tonight" stay plain tasks, because
    /// Grux does not pick an hour nobody said.
    func testSpokenSpansRemind() throws {
        let now = Date()
        for (ask, minutes) in [("remind me to call mom in an hour", 60.0),
                               ("Remind me to call mom in half an hour", 30),
                               ("remind me to call mom in a half hour", 30),
                               ("remind me to call mom in an hour and a half", 90)] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: now), ask)
            XCTAssertEqual(m.kind, .addTask, ask)
            XCTAssertEqual(m.slots.title, "call mom", ask)
            let gap = try XCTUnwrap(m.slots.date, ask).timeIntervalSince(now)
            XCTAssertEqual(gap, minutes * 60, accuracy: 60, ask)
        }
        for ask in ["remind me to call mom at 9", "remind me to call mom tonight",
                    "remind me to call mom in a while", "remind me to call mom in an hour or two"] {
            let m = try XCTUnwrap(PIMIntents.match(ask, now: now), ask)
            XCTAssertNil(m.slots.date, ask)
            XCTAssertEqual(m.slots.title, String(ask.dropFirst("remind me to ".count)), ask)
        }
    }
}
