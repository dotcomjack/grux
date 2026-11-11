import XCTest
@testable import Grux

/// D121 (sense pass 12, `home-page1.png`, `jaxHQ-page1.png`, and live 9:06 PM in
/// `logs/d117-live/`): the briefing told a person "the day is clear of urgent
/// emails or critical ops signals" with no mailbox connected, and "I've queued a
/// backup for the Mini and watered the office plants so you don't have to" about
/// two task items Grux never touched, and "I'm already tracking the next week's
/// roadmap". The prompt gave the model "(none)" for a source Grux cannot see, the
/// same word it gives a connected source with nothing in it, and nothing checked
/// the draft for an action Grux did not take. Now an unseen source is named as
/// unseen, and a draft that vouches for one or claims an action is refused for
/// the honest fallback.
final class BriefingClaimsTests: XCTestCase {

    private let nothingConnected = BriefingSources(mail: false, calendar: false, ops: false)
    private let everythingConnected = BriefingSources(mail: true, calendar: true, ops: true)

    // MARK: the drafts seen live are refused

    func test_theDraftsSeenLiveAreRefused() {
        let live = [
            "Evening, the day is clear of urgent emails or critical ops signals, so you can wind down.",
            "Evening. I've queued a backup for the Mini and watered the office plants so you don't have to.",
            "Morning. I'm already tracking the next week's roadmap, nothing else needs you.",
            "Afternoon, the daylight saving time shift just ended, so your schedule is now a few minutes longer.",
        ]
        for draft in live {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: nothingConnected), draft)
        }
    }

    // MARK: actions Grux did not take

    func test_aClaimedActionIsRefusedEvenWithEverySourceConnected() {
        let claims = [
            "Morning. I've queued a backup for the Mini.",
            "Morning. I have already sent the reply to Dana.",
            "Morning. I watered the office plants.",
            "Morning. I just booked the dentist for Friday.",
            "Morning. We've moved the call to Thursday.",
            "Morning. I\u{2019}ve handled the invoices.",
            "Morning. I'm already tracking the roadmap.",
            "Morning. I am monitoring the storefront for you.",
            "Morning. I took care of the backup.",
        ]
        for draft in claims {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    func test_honestDraftsPass() {
        let honest = [
            "Morning, you have two emails that need a reply, and one thing is waiting for your OK.",
            "Afternoon. Back up the Mini and water the office plants are still on your list.",
            "Evening. Nothing urgent needs you right now.",
            "Morning. I noticed two self-upgrade proposals are waiting for your review.",
            "Morning, your calendar has the standup at 9:30 AM, then a clear afternoon.",
            "Morning. Ad pacing is at $12 of $16 today.",
        ]
        for draft in honest {
            XCTAssertNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    // MARK: sources Grux cannot see

    func test_mailIsNeverVouchedForWithoutAMailbox() {
        for draft in ["Morning, your inbox is quiet.", "Morning, no emails need you.",
                      "Morning, nothing in your mail needs a reply.", "Morning, the mailbox is clear."] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: nothingConnected), draft)
            XCTAssertNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    func test_theCalendarIsNeverVouchedForWithoutAccess() {
        for draft in ["Morning, your calendar is clear.", "Morning, no meetings today.",
                      "Morning, your schedule is open."] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: nothingConnected), draft)
            XCTAssertNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    func test_opsAreNeverVouchedForWithoutAnOpsSnapshot() {
        let draft = "Morning, no critical ops signals and ad spend is steady."
        XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: nothingConnected))
        XCTAssertNil(BriefingEngine.overclaim(draft, sources: everythingConnected))
    }

    func test_theRefusalNamesWhatItCaught() {
        XCTAssertEqual(BriefingEngine.overclaim("Morning, your inbox is quiet.", sources: nothingConnected),
                       "mentions mail with no mailbox connected")
        XCTAssertEqual(BriefingEngine.overclaim("Morning. I watered the plants.", sources: everythingConnected),
                       "claims an action Grux did not take: \"I watered\"")
    }

    // MARK: the prompt names an unseen source as unseen

    func test_thePromptTellsAnUnseenSourceFromAnEmptyOne() {
        let unseen = BriefingEngine.sourceLines([], connected: false)
        let empty = BriefingEngine.sourceLines([], connected: true)
        XCTAssertEqual(empty, "(none)")
        XCTAssertNotEqual(unseen, empty, "the model could not tell no mailbox from an empty one")
        XCTAssertTrue(unseen.contains("not connected"), unseen)
        XCTAssertTrue(unseen.contains("say nothing"), unseen)
    }

    // MARK: the fallback keeps the same rules

    func test_theFallbackNeverOverclaims() {
        let items = [
            BriefingItem(kind: .task, title: "Back up the Mini", detail: ""),
            BriefingItem(kind: .proposalPending, title: "1 self-upgrade proposal", detail: "awaiting your review"),
        ]
        for slot in [Briefing.Slot.morning, .night, .onDemand] {
            let text = BriefingEngine.fallbackSpoken(slot: slot, items: items)
            XCTAssertNil(BriefingEngine.overclaim(text, sources: nothingConnected), text)
            XCTAssertNil(BriefingEngine.overclaim(BriefingEngine.fallbackSpoken(slot: slot, items: []),
                                                  sources: nothingConnected))
        }
    }

    // MARK: D139, holds, readiness and promises Grux does not have

    /// Sense pass 16 (`logs/s16-shots/jaxHQ-page1.png`, written 1:50 PM on 9d2f7890):
    /// the briefing said Grux was holding two of the person's tasks until they
    /// confirmed, that it was ready to fire focus reminders, and that a holiday on
    /// the calendar was the person's day off. The briefing holds nothing, waits on
    /// nothing and will do nothing, and a holiday is not a day off.
    func test_theD139DraftSeenLiveIsRefused() {
        let live = "afternoon, here is where we stand: two items in my queue need your green light before I proceed, "
            + "and a self-upgrade proposal sits waiting for your review; you have all day off due to the Day of the Dead, "
            + "so no meetings are blocking you, but I am holding back on the Mini backup and plant watering until you "
            + "confirm; Grux is ready to fire those focus reminders once we clear the approvals."
        XCTAssertNotNil(BriefingEngine.overclaim(live, sources: everythingConnected))
    }

    func test_aClaimedHoldReadinessOrPromiseIsRefused() {
        let claims = [
            "Afternoon. I am holding back on the Mini backup until you confirm.",
            "Afternoon. I'm holding off on the plants.",
            "Afternoon. We're waiting on you to approve the backup.",
            "Afternoon. Two items need your green light before I proceed.",
            "Afternoon. Once you approve it, I'll run the backup.",
            "Afternoon. I will send the reply after lunch.",
            "Afternoon. Grux is ready to fire those focus reminders.",
            "Afternoon. I'm ready to start the backup whenever you are.",
            "Afternoon. I am about to water the plants.",
            "Afternoon. The backup is on hold until you say so, I'm keeping it parked.",
        ]
        for draft in claims {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    func test_aHolidayIsNotTheirDayOff() {
        let holiday = [BriefingItem(kind: .agenda, title: "Day of the Dead", detail: "All day")]
        for draft in ["Afternoon. You have all day off due to the Day of the Dead.",
                      "Morning, you have the day off today.",
                      "Morning. You're off today for the holiday."] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
        // Wave 42 round 3: not even an entry saying so, which may be a colleague's
        // on a shared calendar. The composed briefing names the entry instead.
        let off = [BriefingItem(kind: .agenda, title: "Vacation", detail: "All day")]
        XCTAssertNotNil(BriefingEngine.overclaim("Morning, you have the day off today.",
                                                 sources: everythingConnected))
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: off)
            .contains("On your calendar: Vacation, all day."))
    }

    func test_waitingWordsAboutTheirOwnThingsStillPass() {
        let honest = [
            "Afternoon. Two things are waiting for your OK, and a self-upgrade proposal is waiting for your review.",
            "Afternoon. The gate code note waits until you approve it.",
            "Afternoon. Day of the Dead is on your calendar today, and back up the Mini is on deck.",
            "Afternoon. Your approvals are on hold for your OK.",
            "Evening. We are going into a quiet night, and the backup is set for you to run.",
        ]
        for draft in honest {
            XCTAssertNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    func test_theOpenerIsCapitalized() {
        XCTAssertEqual(BriefingEngine.sanitize("afternoon, here is where we stand."),
                       "Afternoon, here is where we stand.")
        XCTAssertEqual(BriefingEngine.sanitize("  late check, all quiet.  "), "Late check, all quiet.")
        XCTAssertEqual(BriefingEngine.sanitize(""), "")
    }

    func test_thePromptForbidsHoldsPromisesAndDaysOff() {
        let rules = BriefingEngine.spokenRules
        XCTAssertTrue(rules.contains("never that you are holding, waiting on, ready for or about to do anything"), rules)
        XCTAssertTrue(rules.contains("Never say they are off or have the day off"), rules)
    }

    // MARK: D139 part 2, the local route composes from the items

    /// Live on 616a32a6, 5:46 PM, qwen3.5:4b: of six on-demand drafts two were
    /// refused for mail and the two that passed the guard still invented ("so we
    /// pause operations for that day", "need your final sign-off before they
    /// proceed", "Tomorrow requires you to back up the Mini", "a spend request").
    /// On the local route the briefing is composed from the items, never drafted.
    func test_theLocalRouteNeverDraftsTheBriefing() {
        XCTAssertFalse(BriefingEngine.draftsWithModel(on: .local))
        XCTAssertTrue(BriefingEngine.draftsWithModel(on: .anthropic))
        XCTAssertTrue(BriefingEngine.draftsWithModel(on: .custom(UUID())))
    }

    private let liveItems = [
        BriefingItem(kind: .agenda, title: "Day of the Dead", detail: "All day"),
        BriefingItem(kind: .task, title: "Back up the Mini", detail: ""),
        BriefingItem(kind: .task, title: "Water the office plants", detail: ""),
        BriefingItem(kind: .task, title: "Wire up Grux and confirm focus reminders fire", detail: "GruxAI"),
        BriefingItem(kind: .approvalPending, title: "2 waiting for your OK", detail: "Jax HQ approval queue", count: 2),
        BriefingItem(kind: .proposalPending, title: "1 self-upgrade proposal", detail: "awaiting your review", count: 1),
    ]

    /// D124 with it: the honest briefing said only "3 things are waiting for your
    /// OK" while a calendar entry and three tasks sat in its items.
    func test_theComposedBriefingNamesTheDayAndTheList() {
        let text = BriefingEngine.fallbackSpoken(slot: .night, items: liveItems)
        XCTAssertEqual(text, "End of the day. 2 things are waiting for your OK in Approvals. 1 self-upgrade proposal is waiting for your review in Self-Upgrade. "
            + "On your calendar: Day of the Dead, all day. "
            + "On your list: Back up the Mini, Water the office plants, and 1 more.")
        XCTAssertNil(BriefingEngine.overclaim(text, sources: everythingConnected), text)
    }

    func test_theComposedBriefingAtEveryCount() {
        func at(_ items: [BriefingItem]) -> String { BriefingEngine.fallbackSpoken(slot: .morning, items: items) }
        let task = { (t: String) in BriefingItem(kind: .task, title: t, detail: "") }
        XCTAssertEqual(at([]), "Morning. " + BriefingEngine.quietFallbackLine)
        XCTAssertEqual(at([task("A")]), "Morning. " + BriefingEngine.quietFallbackLine + " On your list: A.")
        XCTAssertEqual(at([task("A"), task("B")]), "Morning. " + BriefingEngine.quietFallbackLine
                       + " On your list: A and B.")
        XCTAssertEqual(at([task("A"), task("B"), task("C")]), "Morning. " + BriefingEngine.quietFallbackLine
                       + " On your list: A, B, and 1 more.")
        let ev = { (t: String, d: String) in BriefingItem(kind: .agenda, title: t, detail: d) }
        XCTAssertEqual(at([ev("Standup", "9:30 AM")]), "Morning. " + BriefingEngine.quietFallbackLine
                       + " On your calendar: Standup at 9:30 AM.")
        XCTAssertEqual(at([ev("Standup", "9:30 AM"), ev("Lunch", "1:00 PM"), ev("Gym", "6:00 PM")]),
                       "Morning. " + BriefingEngine.quietFallbackLine
                       + " On your calendar: Standup at 9:30 AM, Lunch at 1:00 PM, and 1 more.")
    }

    // MARK: wave 42 review

    /// P2-1: the briefing keeps at most 4 calendar entries and 3 tasks, and "and
    /// 1 more" counted only what was kept, so 7 tasks were spoken as 3.
    func test_andMoreCountsWhatWasLeftOut() {
        let tasks = (1...7).map { BriefingItem(kind: .task, title: "T\($0)") }
        let kept = BriefingEngine.summarized(tasks, cap: 3)
        XCTAssertEqual(kept.map(\.title), ["T1", "T2", "T3"])
        XCTAssertEqual(kept.last?.count, 5, "the last kept row stands for itself and the 4 left out")
        XCTAssertEqual(BriefingEngine.fallbackSpoken(slot: .morning, items: kept),
                       "Morning. " + BriefingEngine.quietFallbackLine + " On your list: T1, T2, and 5 more.")
        // On, under and over the cap.
        XCTAssertNil(BriefingEngine.summarized(Array(tasks.prefix(3)), cap: 3).last?.count)
        XCTAssertNil(BriefingEngine.summarized(Array(tasks.prefix(2)), cap: 3).last?.count)
        XCTAssertEqual(BriefingEngine.summarized(Array(tasks.prefix(4)), cap: 3).last?.count, 2)
        XCTAssertEqual(BriefingEngine.summarized([], cap: 3), [])
        let events = (1...9).map { BriefingItem(kind: .agenda, title: "E\($0)", detail: "9:00 AM") }
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: BriefingEngine.summarized(events, cap: 4))
            .contains("On your calendar: E1 at 9:00 AM, E2 at 9:00 AM, and 7 more."))
        // A summarized task row never adds to the waiting count.
        XCTAssertFalse(BriefingEngine.fallbackSpoken(slot: .morning, items: kept).contains("waiting"))
    }

    /// P2-2: the day off allowance read every item's title, so a task "Leave for
    /// the airport at 3" let "you have all day off" through.
    func test_onlyACalendarEntryMakesADayOffTrue() {
        let draft = "Afternoon. You have all day off due to the Day of the Dead."
        let holiday = BriefingItem(kind: .agenda, title: "Day of the Dead", detail: "All day")
        for other in [BriefingItem(kind: .task, title: "Leave for the airport at 3"),
                      BriefingItem(kind: .task, title: "Book vacation"),
                      BriefingItem(kind: .emailNeedsYou, title: "Re: PTO request"),
                      BriefingItem(kind: .goalAdvanced, title: "Annual leave policy")] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected),
                            other.title)
        }
        XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected))
    }

    /// P3-3: the composed briefing keeps the house rules on titles as stored.
    func test_theComposedBriefingKeepsTheHouseRules() {
        let items = [BriefingItem(kind: .task, title: "Q4 plan \u{2014} draft"),
                     BriefingItem(kind: .task, title: "Call mom?")]
        let text = BriefingEngine.fallbackSpoken(slot: .morning, items: items)
        XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
        XCTAssertTrue(text.hasSuffix("On your list: Q4 plan, draft and Call mom."), text)
    }

    /// P3-1: one word away from the live sentence.
    func test_setToAndStandingByAreHolds() {
        for draft in ["Afternoon. Grux is set to fire those focus reminders once we clear the approvals.",
                      "Afternoon. I'm standing by to run the backup once you confirm."] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected), draft)
        }
    }

    /// Wave 42 round 2: "Leave for Mom's" at 3:00 PM is a calendar entry and not a
    /// day off. Only an all day entry whose title says they are off counts.
    func test_aDayOffNeedsAnAllDayEntrySayingSo() {
        let draft = "Afternoon. You have all day off due to Thanksgiving."
        let holiday = BriefingItem(kind: .agenda, title: "Thanksgiving", detail: "All day")
        for other in [BriefingItem(kind: .agenda, title: "Leave for Mom's", detail: "3:00 PM"),
                      BriefingItem(kind: .agenda, title: "Annual leave policy review", detail: "10:00 AM"),
                      BriefingItem(kind: .agenda, title: "Leave early", detail: "All day"),
                      BriefingItem(kind: .agenda, title: "PTO", detail: "9:00 AM")] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected),
                            other.title)
        }
        // A colleague's "Sam OOO" on a shared team calendar reads the same as their own.
        for off in ["PTO", "Vacation", "Day off", "Out of office", "On leave", "Annual leave", "Sam OOO"] {
            XCTAssertNotNil(BriefingEngine.overclaim(draft, sources: everythingConnected),
                         off)
        }
    }

    /// Wave 42 round 2 P3: a title that is only punctuation is spoken as untitled.
    func test_aTitleOfOnlyPunctuationIsUntitled() {
        let items = [BriefingItem(kind: .task, title: "\u{2014}"), BriefingItem(kind: .task, title: "?")]
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: items)
            .hasSuffix("On your list: (untitled) and (untitled)."))
    }
}
