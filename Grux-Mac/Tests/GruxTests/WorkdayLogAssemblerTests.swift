import XCTest
@testable import Grux

final class WorkdayLogAssemblerTests: XCTestCase {

    // MARK: - windowDates

    func test_windowDates_isoParseAndSpan() {
        let cal = Calendar(identifier: .gregorian)
        let (start, endDisplay, endExclusive) = WorkdayLogAssembler.windowDates(
            forDayKey: "2026-04-22", calendar: cal
        )
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 22)
        XCTAssertEqual(comps.hour, 6)
        XCTAssertEqual(comps.minute, 0)
        // Exclusive end is start + 24h
        XCTAssertEqual(endExclusive.timeIntervalSince(start), 24 * 3600, accuracy: 0.5)
        // Display end is 1s before exclusive end
        XCTAssertEqual(endExclusive.timeIntervalSince(endDisplay), 1.0, accuracy: 0.5)
    }

    // MARK: - dayKey mapping

    func test_dayKey_beforeSixAM_mapsToPrevious() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 23
        comps.hour = 5; comps.minute = 30; comps.second = 0
        let d = cal.date(from: comps)!
        XCTAssertEqual(
            WorkdayLogAssembler.dayKey(forDate: d, calendar: cal),
            "2026-04-22"
        )
    }

    func test_dayKey_afterSixAM_mapsToSameCalendarDay() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 23
        comps.hour = 6; comps.minute = 0; comps.second = 1
        let d = cal.date(from: comps)!
        XCTAssertEqual(
            WorkdayLogAssembler.dayKey(forDate: d, calendar: cal),
            "2026-04-23"
        )
    }

    // MARK: - computeFocusStats

    func test_computeFocusStats_basicAggregation() {
        let cal = Calendar(identifier: .gregorian)
        let (start, _, endExclusive) = WorkdayLogAssembler.windowDates(
            forDayKey: "2026-04-22", calendar: cal
        )

        // Three events: two onTask 5m apart, then drifting 3m, then outside.
        let events: [FocusEvent] = [
            FocusEvent(timestamp: start.addingTimeInterval(60 * 60 * 2),
                       currentTaskId: nil, currentTaskTitle: "Ship",
                       activeApp: "Xcode", windowTitle: "Ship · Grux-Mac",
                       verdict: .onTask, confidence: 1.0, rationale: "",
                       suggestedTaskId: nil, suggestedTaskTitle: nil, screenTextSnippet: ""),
            FocusEvent(timestamp: start.addingTimeInterval(60 * 60 * 2 + 300),
                       currentTaskId: nil, currentTaskTitle: "Ship",
                       activeApp: "Xcode", windowTitle: "Ship · Grux-Mac",
                       verdict: .onTask, confidence: 1.0, rationale: "",
                       suggestedTaskId: nil, suggestedTaskTitle: nil, screenTextSnippet: ""),
            FocusEvent(timestamp: start.addingTimeInterval(60 * 60 * 2 + 480),
                       currentTaskId: nil, currentTaskTitle: "Ship",
                       activeApp: "Safari", windowTitle: "Twitter",
                       verdict: .drifting, confidence: 1.0, rationale: "",
                       suggestedTaskId: nil, suggestedTaskTitle: nil, screenTextSnippet: "")
        ]
        let stats = WorkdayLogAssembler.computeFocusStats(
            events: events,
            windowStart: start,
            windowEndExclusive: endExclusive,
            knownProjects: []
        )
        XCTAssertGreaterThan(stats.onTaskMinutes, 0)
        // The last event is drifting; interval = endExclusive - start+hr2+480s
        // which is capped at 20 min.
        XCTAssertEqual(stats.driftingMinutes, 20)
        XCTAssertEqual(stats.offTaskMinutes, 0)
        XCTAssertGreaterThan(stats.perAppMinutes["Xcode", default: 0], 0)
        XCTAssertGreaterThan(stats.perAppMinutes["Safari", default: 0], 0)
    }

    // MARK: - chat grouping

    func test_groupChatMessages_splitsOn30MinGap() {
        let cal = Calendar(identifier: .gregorian)
        let (start, _, endExclusive) = WorkdayLogAssembler.windowDates(
            forDayKey: "2026-04-22", calendar: cal
        )
        let t0 = start.addingTimeInterval(3 * 3600)
        let messages = [
            ChatMessage(role: .user, content: "hi",  timestamp: t0),
            ChatMessage(role: .assistant, content: "yo",  timestamp: t0.addingTimeInterval(60)),
            // 35 min gap → new conversation
            ChatMessage(role: .user, content: "ok now",
                        timestamp: t0.addingTimeInterval(60 + 35 * 60)),
        ]
        let convs = WorkdayLogAssembler.groupChatMessages(
            messages, windowStart: start, windowEndExclusive: endExclusive
        )
        XCTAssertEqual(convs.count, 2)
        XCTAssertEqual(convs[0].source, .chat)
    }

    func test_groupChatMessages_filtersOutsideWindow() {
        let cal = Calendar(identifier: .gregorian)
        let (start, _, endExclusive) = WorkdayLogAssembler.windowDates(
            forDayKey: "2026-04-22", calendar: cal
        )
        // 5:59:00 on 04-22 is BEFORE the window (before 6am anchor) → excluded
        let before = start.addingTimeInterval(-60)
        // 5:59:00 on 04-23 is IN the window (prior to 6am next day) → included
        let late = endExclusive.addingTimeInterval(-60)
        let messages = [
            ChatMessage(role: .user, content: "too early", timestamp: before),
            ChatMessage(role: .user, content: "last moment", timestamp: late),
        ]
        let convs = WorkdayLogAssembler.groupChatMessages(
            messages, windowStart: start, windowEndExclusive: endExclusive
        )
        XCTAssertEqual(convs.count, 1)
        XCTAssertTrue(convs[0].summary.contains("last moment"))
    }

    // MARK: - ambient grouping

    func test_groupAmbientSummaries_collapsesConsecutiveHours() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let recs = [
            AmbientHourlySummaryRecord(hourStart: base,
                                       hourEnd: base.addingTimeInterval(3600),
                                       summary: "A",
                                       chunkCount: 3),
            AmbientHourlySummaryRecord(hourStart: base.addingTimeInterval(3600),
                                       hourEnd: base.addingTimeInterval(7200),
                                       summary: "quiet",
                                       chunkCount: 2),
            AmbientHourlySummaryRecord(hourStart: base.addingTimeInterval(7200),
                                       hourEnd: base.addingTimeInterval(10_800),
                                       summary: "B",
                                       chunkCount: 4),
            // 2h gap → new group
            AmbientHourlySummaryRecord(hourStart: base.addingTimeInterval(18_000),
                                       hourEnd: base.addingTimeInterval(21_600),
                                       summary: "C",
                                       chunkCount: 1),
        ]
        let convs = WorkdayLogAssembler.groupAmbientSummaries(recs)
        XCTAssertEqual(convs.count, 2)
        XCTAssertTrue(convs[0].summary.contains("A"))
        XCTAssertTrue(convs[0].summary.contains("B"))
        XCTAssertFalse(convs[0].summary.lowercased().contains("quiet"))
        XCTAssertTrue(convs[1].summary.contains("C"))
    }

    // MARK: - commitments

    func test_breakdownCommitments_classifies() {
        let cal = Calendar(identifier: .gregorian)
        let (start, _, endExclusive) = WorkdayLogAssembler.windowDates(
            forDayKey: "2026-04-22", calendar: cal
        )
        let mid = start.addingTimeInterval(5 * 3600)
        let priorDay = start.addingTimeInterval(-26 * 3600)

        let memories = [
            AmbientMemory(kind: .commitment, text: "Ship the stripe webhook",
                          project: nil, timestamp: mid),
            AmbientMemory(kind: .commitment, text: "Call mom",
                          project: nil, timestamp: priorDay),
            AmbientMemory(kind: .commitment, text: "Refactor KeychainStore",
                          project: nil, timestamp: priorDay),
        ]
        let completed = ["Refactor KeychainStore"]
        let result = WorkdayLogAssembler.breakdownCommitments(
            memories: memories, completedTitles: completed,
            windowStart: start, windowEndExclusive: endExclusive
        )
        XCTAssertEqual(result.made.count, 1)
        XCTAssertTrue(result.kept.contains(where: { $0.contains("Refactor KeychainStore") }))
        XCTAssertTrue(result.stillOpen.contains(where: { $0.contains("Call mom") }))
    }
}
