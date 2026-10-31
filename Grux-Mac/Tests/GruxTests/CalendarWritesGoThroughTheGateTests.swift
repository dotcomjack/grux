import XCTest
@testable import Grux

/// Grux asks before it puts anything on the person's calendar (D60).
///
/// Measured on the Mini 2026-10-30: Calendar held "If I don't..." and "Maybe it's
/// something with my..." at 12:00 PM, and Reactor promoted one as the next event.
/// `CommitmentScheduler` ran every 10 s over the ambient memories and, for any
/// sentence with a time 30 s to 72 h ahead, saved a Calendar event straight
/// through `CalendarService` with the heard words as its title. The chat
/// `create_event` tool was always gated; this path never reached the gate.
@MainActor
final class CalendarWritesGoThroughTheGateTests: XCTestCase {

    private var reminders: [GruxReminder] = []
    private var asks: [ProposedAction] = []

    private func scheduler() -> CommitmentScheduler {
        CommitmentScheduler(scheduleReminder: { [unowned self] in reminders.append($0) },
                            askToAddToCalendar: { [unowned self] in asks.append($0) })
    }

    private func input(of ask: ProposedAction) throws -> [String: Any] {
        try XCTUnwrap(ask.detail["__replay_input"].flatMap(ApprovalQueue.decodeInput))
    }

    // MARK: The class guard

    /// Every call that writes an event is the gated tool or the person's own button
    /// in the Calendar tab. A timer, an agent or a listener that wants an event has
    /// to file a card that replays `create_event`.
    func test_onlyTheGatedToolAndThePersonsOwnButtonWriteEvents() throws {
        let root = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources")
        let allowed: Set<String> = ["CalendarTool.swift", "CalendarView.swift"]
        var writers: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                guard code.contains("createEvent("), !code.contains("func createEvent(") else { continue }
                if !allowed.contains(url.lastPathComponent) { writers.append("\(url.lastPathComponent):\(i + 1)") }
            }
        }
        XCTAssertEqual(writers, [], "these write Calendar events without asking: \(writers)")
        let scheduler = try String(contentsOf: root.appendingPathComponent("Grux/Reminders/CommitmentScheduler.swift"),
                                   encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
        XCTAssertFalse(scheduler.contains { $0.contains("CalendarService") },
                       "the ambient scheduler reaches Calendar only through Approvals")
    }

    // MARK: The scheduler asks

    func test_aDatedCommitmentAsksOnceAndSavesNothing() throws {
        let now = Date()
        let heard = AmbientMemory(kind: .commitment, text: "I'll call the dentist in 2 hours")
        let s = scheduler()
        s.scan([heard], onTheBooks: [], now: now)

        XCTAssertEqual(reminders.count, 1, "the in-app reminder is unchanged")
        XCTAssertEqual(asks.count, 1, "one calendar card")
        let ask = try XCTUnwrap(asks.first)
        XCTAssertEqual(ask.detail["__replay_tool"], "create_event")
        XCTAssertTrue(ask.summary.hasPrefix("Add \"I'll call the dentist in 2 hours\" to your calendar, "), ask.summary)
        let replay = try input(of: ask)
        XCTAssertEqual(replay["title"] as? String, "I'll call the dentist in 2 hours")
        let start = try XCTUnwrap(CalendarTool.parseDateInput(try XCTUnwrap(replay["start"] as? String)))
        let end = try XCTUnwrap(CalendarTool.parseDateInput(try XCTUnwrap(replay["end"] as? String)))
        XCTAssertFalse(start.isDateOnly)
        XCTAssertEqual(start.date.timeIntervalSince(now), 7200, accuracy: 61, "the card's time is the heard time")
        XCTAssertEqual(end.date.timeIntervalSince(start.date), 1800, accuracy: 1, "a 30 minute block, as before")

        // The next tick sees the same memory and asks nothing more.
        s.scan([heard], onTheBooks: [], now: now)
        XCTAssertEqual(asks.count, 1)
    }

    func test_aRelaunchDoesNotAskAgainForWhatIsOnTheBooks() throws {
        let heard = AmbientMemory(kind: .commitment, text: "I'll ship it in 3 hours")
        scheduler().scan([heard], onTheBooks: [], now: Date())
        let first = try XCTUnwrap(reminders.first)
        scheduler().scan([heard], onTheBooks: [(text: first.sourceCommitmentText, at: first.scheduledFor)], now: Date())
        XCTAssertEqual(asks.count, 1, "a second launch the same day files no second card")
    }

    /// Wave 15 review P2. "In 3 hours" is parsed from the clock at scan time, so a
    /// relaunch five minutes later put the same sentence five minutes later, missed the
    /// text-and-minute match and filed a second card, once per launch.
    func test_aRelaunchMinutesLaterDoesNotAskAgainForTheSameSentence() throws {
        let heard = AmbientMemory(kind: .commitment, text: "I'll ship it in 3 hours",
                                  timestamp: Date().addingTimeInterval(-300))
        scheduler().scan([heard], onTheBooks: [], now: Date())
        var first = try XCTUnwrap(reminders.first)
        XCTAssertEqual(first.sourceMemoryId, heard.id, "the reminder remembers the sentence it came from")
        // As if that scan had run five minutes before this launch.
        first.scheduledFor = first.scheduledFor?.addingTimeInterval(-300)

        // Through the file the next launch reads.
        let saved = try JSONDecoder().decode(GruxReminder.self, from: JSONEncoder().encode(first))
        scheduler().scan([heard], onTheBooks: [(text: saved.sourceCommitmentText, at: saved.scheduledFor)],
                         alreadyAskedBy: [saved], now: Date())
        XCTAssertEqual(asks.count, 1, "a relaunch five minutes later filed a second card for one sentence")
        XCTAssertEqual(reminders.count, 1)

        // Once it has fired it is still handled: it is not on the books, and still not asked again.
        var fired = saved
        fired.firedAt = Date()
        scheduler().scan([heard], onTheBooks: [], alreadyAskedBy: [fired], now: Date())
        XCTAssertEqual(asks.count, 1, "a fired reminder's sentence was asked about again")
    }

    /// A reminder file written before the field existed still reads.
    func test_aReminderSavedBeforeTheMemoryIdStillLoads() throws {
        let old = #"{"id":"8C1E7C55-0D55-4C4B-9D0A-6E3F1A2B3C4D","kind":"commitment","title":"t","body":"b","createdAt":0,"accepted":false,"dismissed":false}"#
        let r = try JSONDecoder().decode(GruxReminder.self, from: Data(old.utf8))
        XCTAssertNil(r.sourceMemoryId)
    }

    /// Wave 15 round 2 P2. Reminders saved by the build before the memory id existed
    /// carry none, so the launch that installed the fix asked again for every one of
    /// them: a pending one whose "in 3 hours" now parsed later, and a fired one at all.
    func test_theUpgradeLaunchDoesNotAskAgainForAnOlderBuildsReminders() throws {
        let heardAt = Date().addingTimeInterval(-600)
        let heard = AmbientMemory(kind: .commitment, text: "I'll ship it in 3 hours", timestamp: heardAt)
        let made = heardAt.addingTimeInterval(5)
        let pending = GruxReminder(kind: .commitment, title: heard.text, body: "",
                                   createdAt: made, scheduledFor: made.addingTimeInterval(3 * 3600),
                                   sourceCommitmentText: heard.text)
        var fired = pending
        fired.firedAt = Date()
        for older in [pending, fired] {
            XCTAssertNil(older.sourceMemoryId, "control: an older build's reminder has no memory id")
            scheduler().scan([heard], onTheBooks: older.firedAt == nil ? [(text: older.sourceCommitmentText, at: older.scheduledFor)] : [],
                             alreadyAskedBy: [older], now: Date())
        }
        XCTAssertEqual(asks.count, 0, "the upgrade launch asked again for a sentence an older build already asked about")

        // Made AT the moment it was heard still counts; one second before it does not.
        XCTAssertTrue(CommitmentScheduler.isHandled(heard, by: [GruxReminder(kind: .commitment, title: "", body: "", createdAt: heardAt, sourceCommitmentText: heard.text)]))
        XCTAssertFalse(CommitmentScheduler.isHandled(heard, by: [GruxReminder(kind: .commitment, title: "", body: "", createdAt: heardAt.addingTimeInterval(-1), sourceCommitmentText: heard.text)]))
    }

    /// The same words said again on a later day are a new commitment, and still ask.
    func test_theSameWordsSaidAgainLaterStillAsk() {
        let yesterday = GruxReminder(kind: .commitment, title: "", body: "",
                                     createdAt: Date().addingTimeInterval(-86_400),
                                     sourceCommitmentText: "I'll ship it in 3 hours")
        let again = AmbientMemory(kind: .commitment, text: "I'll ship it in 3 hours")
        scheduler().scan([again], onTheBooks: [], alreadyAskedBy: [yesterday], now: Date())
        XCTAssertEqual(asks.count, 1, "words an older reminder used, said again later, asked nothing")
    }

    /// Round 3 P2. In the running app too, at the next tick, not at the next launch:
    /// the in-session skip list was keyed on the id alone.
    func test_anEditInTheRunningAppAsksAtTheNextTick() throws {
        var heard = AmbientMemory(kind: .commitment, text: "call Sam in 2 hours")
        let s = scheduler()
        s.scan([heard], onTheBooks: [], now: Date())
        let first = try XCTUnwrap(reminders.first)
        s.scan([heard], onTheBooks: [], alreadyAskedBy: [first], now: Date())
        XCTAssertEqual(asks.count, 1, "control: the same sentence on the next tick asks nothing")
        heard.text = "call Sam in 5 hours"
        s.scan([heard], onTheBooks: [(text: first.sourceCommitmentText, at: first.scheduledFor)],
               alreadyAskedBy: [first], now: Date())
        XCTAssertEqual(asks.count, 2, "an edit in the running app was not asked about until a relaunch")
    }

    /// Round 2 P3. An edited memory keeps its id; its new time is a new commitment.
    func test_anEditedSentenceAsksForItsNewTime() throws {
        var heard = AmbientMemory(kind: .commitment, text: "call Sam in 2 hours")
        scheduler().scan([heard], onTheBooks: [], now: Date())
        let first = try XCTUnwrap(reminders.first)
        heard.text = "call Sam in 5 hours"
        scheduler().scan([heard], onTheBooks: [(text: first.sourceCommitmentText, at: first.scheduledFor)],
                         alreadyAskedBy: [first], now: Date())
        XCTAssertEqual(asks.count, 2, "the edited sentence's new time was never asked about")
        XCTAssertFalse(CommitmentScheduler.isHandled(AmbientMemory(kind: .commitment, text: "call Sam in 2 hours"), by: [first]),
                       "another sentence with the same words is not this reminder's")
    }

    func test_factsUndatedAndFarOffSentencesAskNothing() {
        scheduler().scan([
            AmbientMemory(kind: .fact, text: "The dentist is open in 2 hours"),
            AmbientMemory(kind: .commitment, text: "If I don't..."),
            AmbientMemory(kind: .intent, text: "I'll renew it in 4 days"),
        ], onTheBooks: [], now: Date())
        XCTAssertEqual(asks.count, 0)
        XCTAssertEqual(reminders.count, 0)
    }

    // MARK: The card's yes runs the gated tool

    func test_approvingTheCardRunsCreateEventWithTheCardsTitle() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("d60-\(UUID().uuidString.prefix(8))/approvals.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = ApprovalQueue(storeURL: url)
        queue.judgeRisk = nil
        let fireAt = Date().addingTimeInterval(3600)
        let item = queue.enqueue(CommitmentScheduler.calendarAsk(text: "Lunch with Sam at noon", at: fireAt),
                                 reason: CommitmentScheduler.calendarAskReason)
        XCTAssertEqual(queue.pending.map(\.id), [item.id])
        XCTAssertTrue(item.summary.hasPrefix("Add \"Lunch with Sam at noon\" to your calendar, "),
                      "the card keeps its own words: \(item.summary)")
        XCTAssertFalse(item.urgent, "a heard sentence waits quietly, it does not ping")

        // The suite never has calendar access, so the replay ends in create_event's own
        // no-access answer: proof the yes reached the tool and not some other path.
        let result = await queue.approveAndExecute(item.id)
        XCTAssertTrue(result.hasPrefix("error: calendar access"), result)
        XCTAssertEqual(queue.items.first { $0.id == item.id }?.state, .pending, "a failed add still waits")
    }

    func test_anEmptyHeardSentenceStillGetsATitle() throws {
        let replay = try input(of: CommitmentScheduler.calendarAsk(text: "   ", at: Date().addingTimeInterval(600)))
        XCTAssertEqual(replay["title"] as? String, "Commitment")
    }
}
