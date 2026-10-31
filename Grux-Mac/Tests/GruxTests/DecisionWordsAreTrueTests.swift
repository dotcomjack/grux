import XCTest
@testable import Grux

/// D54 (wave 12 round 4 P3s, filed and fixed together):
/// 1. A residual hold's card said "This changes something, so it waits for
///    your OK." on actions that change nothing (deep_research, ios_doctor, a
///    read-only shell_run, start_meeting_capture). The sentence must be true
///    for every action the residual hold covers.
/// 2. The menu bar showed the last decision with no day while its hover read
///    "No decisions yet today"; the Usage card's day had no year.
@MainActor
final class DecisionWordsAreTrueTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func row(at: Date) -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "voice", provider: .local, latencyMs: 480, inputTokens: 0, outputTokens: 0,
                            at: at, summary: "open my calendar -> voice.intent=open 0.94")
    }

    func test_theResidualHoldSaysOnlyWhatIsTrueOfEveryAction() {
        XCTAssertEqual(DecisionGate.asksFirstReason, "This waits for your OK before it runs.")
        XCTAssertFalse(DecisionGate.asksFirstReason.contains("changes"))
    }

    /// A card stored under either earlier sentence reads the current one, so
    /// a card queued yesterday folds with today's ask and reads the same.
    func test_cardsStoredWithAnEarlierSentenceReadTheCurrentOne() throws {
        for old in ["This changes something, so it waits for your OK.", DecisionGate.legacyAsksFirstReason] {
            let item = PendingApproval(action: ProposedAction(kind: .other,
                                                              summary: "Run tool 'deep_research' (unclassified side effect).",
                                                              target: "deep_research"),
                                       reason: old)
            let back = try JSONDecoder().decode(PendingApproval.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(back.reason, DecisionGate.asksFirstReason, old)
        }
    }

    func test_todaysLastDecisionHasNoDay() {
        XCTAssertEqual(DecisionUsageSummary.datedLastLine(row(at: at(2026, 10, 29, 9)), now: at(2026, 10, 29, 15), calendar: utc),
                       "open my calendar, 480 ms")
    }

    func test_anEarlierDaySaysWhichDay() {
        XCTAssertEqual(DecisionUsageSummary.datedLastLine(row(at: at(2026, 10, 28, 23)), now: at(2026, 10, 29, 0), calendar: utc),
                       "open my calendar, 480 ms, Oct 28")
    }

    func test_anEarlierYearSaysTheYear() {
        XCTAssertEqual(DecisionUsageSummary.datedLastLine(row(at: at(2025, 12, 31, 23)), now: at(2026, 1, 1, 0), calendar: utc),
                       "open my calendar, 480 ms, Dec 31, 2025")
    }

    func test_theUsageCardAndTheMenuBarUseTheDatedLine() throws {
        let card = UsageCardContent.build(from: [row(at: at(2025, 12, 31))], now: at(2026, 1, 1), calendar: utc)
        XCTAssertEqual(card.lines.last?.value, "open my calendar, 480 ms, Dec 31, 2025")
        let menu = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/MenuBarView.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("DecisionUsageSummary.datedLastLine(ledger.last)"))
        XCTAssertFalse(menu.contains("DecisionUsageSummary.lastLine("))
    }
}
