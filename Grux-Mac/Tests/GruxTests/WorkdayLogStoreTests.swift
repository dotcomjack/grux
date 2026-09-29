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

    // MARK: - The date is a date (integrated review follow-up)

    /// `read_workday_log` used the model's `date` as a file name unchecked, so
    /// `../x` read a JSON file outside the log folder. A day key is now a real
    /// calendar date, yyyy-MM-dd, and the file it names sits in the log folder.
    func test_aDayKeyThatIsNotACalendarDateNamesNoFile() {
        for bad in ["../../../../Desktop/x", "../outside", "/etc/passwd", "/tmp/2026-09-28",
                    "..%2F..%2Fx", "%2e%2e%2foutside", "2026-09-28/../../x", "2026-09-28%2F..",
                    "2026-02-30", "2026-13-01", "2026-9-28", "20260928", "2026-09-28 ", "", "today"] {
            XCTAssertNil(WorkdayLogStore.jsonURL(forDayKey: bad), bad)
        }
        let dir = Persistence.workdayLogsDir.standardizedFileURL.resolvingSymlinksInPath()
        for good in ["2026-09-28", "2024-02-29", "1999-12-31"] {
            let url = WorkdayLogStore.jsonURL(forDayKey: good)
            XCTAssertEqual(url?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(), dir, good)
            XCTAssertEqual(url?.lastPathComponent, "\(good).json")
        }
    }

    /// The live read, with a real log planted one folder up.
    @MainActor
    func test_readWorkdayLogCannotReadAFileOutsideTheLogFolder() async throws {
        let name = "outside-\(UUID().uuidString.prefix(8))"
        let planted = Persistence.workdayLogsDir.deletingLastPathComponent().appendingPathComponent("\(name).json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(emptyFixture(dayKey: "2026-04-22")).write(to: planted)
        defer { try? FileManager.default.removeItem(at: planted) }

        XCTAssertNil(WorkdayLogStore.load(dayKey: "../\(name)"), "the store read a file outside its folder")
        for date in ["../\(name)", planted.deletingPathExtension().path, "..%2F\(name)"] {
            let out = await ChatService.dispatchTool(name: "read_workday_log", input: ["date": date])
            XCTAssertTrue(out.hasPrefix("error:"), "\(date): \(out.prefix(120))")
            XCTAssertFalse(out.contains("Quiet day"), "\(date): the planted log was read")
        }
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
