import XCTest
@testable import Grux

final class WorkdayLogStoreTests: XCTestCase {

    func test_jsonRoundTrip_preservesAllFields() throws {
        let sample = fixture(dayKey: "2026-04-22")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(sample)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(WorkdayLog.self, from: data)

        XCTAssertEqual(sample, decoded)
    }

    func test_deterministicID_isStableAndDifferentPerDay() {
        let a = WorkdayLog.deterministicID(forDayKey: "2026-04-22")
        let b = WorkdayLog.deterministicID(forDayKey: "2026-04-22")
        let c = WorkdayLog.deterministicID(forDayKey: "2026-04-23")
        XCTAssertEqual(a, b, "Same dayKey must produce same UUID")
        XCTAssertNotEqual(a, c, "Different dayKeys must produce different UUIDs")
    }

    func test_renderMarkdown_includesKeySections() {
        let log = fixture(dayKey: "2026-04-22")
        let md = WorkdayLogRenderer.renderMarkdown(log)
        XCTAssertTrue(md.contains("# 2026-04-22 Workday"))
        XCTAssertTrue(md.contains("## Narrative"))
        XCTAssertTrue(md.contains("## Shipped"))
        XCTAssertTrue(md.contains("## Conversations"))
        XCTAssertTrue(md.contains("## Commitments"))
        XCTAssertTrue(md.contains("## Focus"))
        XCTAssertTrue(md.contains("## Insights"))
        XCTAssertTrue(md.contains("Test narrative"))
    }

    func test_renderMarkdown_emptyLogRendersWithPlaceholders() {
        let log = emptyFixture(dayKey: "2026-04-22")
        let md = WorkdayLogRenderer.renderMarkdown(log)
        XCTAssertTrue(md.contains("(nothing marked complete)"))
        XCTAssertTrue(md.contains("(no code shipments recorded)"))
    }

    // MARK: - Helpers

    private func fixture(dayKey: String) -> WorkdayLog {
        let cal = Calendar(identifier: .gregorian)
        let (start, end, _) = WorkdayLogAssembler.windowDates(forDayKey: dayKey, calendar: cal)
        let mid = start.addingTimeInterval(4 * 3600)

        return WorkdayLog(
            id: WorkdayLog.deterministicID(forDayKey: dayKey),
            dayKey: dayKey,
            windowStart: start,
            windowEnd: end,
            generatedAt: start.addingTimeInterval(24 * 3600),
            schemaVersion: WorkdayLog.currentSchemaVersion,
            completedTasks: [
                LoggedTask(title: "Ship workday log v1",
                           project: "Grux-Mac", completedAt: mid, source: "manual")
            ],
            codeShipped: [
                CodeShipment(
                    project: "Grux-Mac",
                    gitBranch: "main",
                    commits: [
                        LoggedCommit(sha: String(repeating: "a", count: 40),
                                     message: "feat: workday-log", timestamp: mid,
                                     filesChanged: 12, insertions: 1200, deletions: 40)
                    ],
                    claudeSessions: [
                        LoggedClaudeSession(sessionId: "abc123de",
                                            cwd: "/Users/dev/Grux-Mac",
                                            turns: 8, totalCost: 1.42, totalTokens: 123_456,
                                            outcomeSummary: "Shipped archival workday log scaffolding.")
                    ]
                )
            ],
            conversations: [
                ConversationSummary(timestamp: mid, source: .chat,
                                    durationMinutes: 12,
                                    summary: "Planning the workday log system",
                                    topics: ["workday-log", "scoping"])
            ],
            commitments: CommitmentsBreakdown(
                made: ["Ship v1 today"],
                kept: ["Ship v1 today"],
                stillOpen: []
            ),
            focusStats: FocusStats(
                onTaskMinutes: 240, driftingMinutes: 15, offTaskMinutes: 5,
                perAppMinutes: ["Xcode": 230, "Safari": 15],
                perProjectMinutes: ["Grux-Mac": 240]
            ),
            insights: ["Mornings were heads-down, afternoon drifted briefly."],
            narrative: "Test narrative: shipped the workday log scaffolding and kept the one commitment.",
            tags: ["Grux-Mac"],
            totalProductiveMinutes: 255
        )
    }

    private func emptyFixture(dayKey: String) -> WorkdayLog {
        let cal = Calendar(identifier: .gregorian)
        let (start, end, _) = WorkdayLogAssembler.windowDates(forDayKey: dayKey, calendar: cal)
        return WorkdayLog(
            id: WorkdayLog.deterministicID(forDayKey: dayKey),
            dayKey: dayKey, windowStart: start, windowEnd: end, generatedAt: start,
            schemaVersion: WorkdayLog.currentSchemaVersion,
            completedTasks: [], codeShipped: [], conversations: [],
            commitments: CommitmentsBreakdown(made: [], kept: [], stillOpen: []),
            focusStats: FocusStats(onTaskMinutes: 0, driftingMinutes: 0, offTaskMinutes: 0,
                                   perAppMinutes: [:], perProjectMinutes: [:]),
            insights: [],
            narrative: "Quiet day",
            tags: [], totalProductiveMinutes: 0
        )
    }
}
