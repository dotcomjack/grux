import XCTest
@testable import Grux

final class DecisionUsageSummaryTests: XCTestCase {
    private func row(_ latencyMs: Int, _ provider: DecisionProviderKind, inputTokens: Int = 0,
                     at: Date, summary: String = "heard -> decided") -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "ambient", provider: provider, latencyMs: latencyMs,
                            inputTokens: inputTokens, outputTokens: 0, at: at, summary: summary)
    }

    func test_yesterdaysRows_doNotCountTowardToday() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-60 * 60 * 30)
        let s = DecisionUsageSummary.today([row(900, .jev, at: yesterday), row(100, .local, at: now)], now: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.meanLatencyMs, 100)
    }

    func test_meanLatencyAndProviderSplit() {
        let now = Date()
        let s = DecisionUsageSummary.today([
            row(400, .jev, at: now), row(600, .jev, at: now), row(200, .local, at: now)
        ], now: now)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.meanLatencyMs, 400)
        XCTAssertEqual(s.jevCount, 2)
        XCTAssertEqual(s.localCount, 1)
        XCTAssertEqual(s.providerPhrase, "2 on Jev, 1 on this Mac")
    }

    func test_spendIsTheSumOfTheRowsOwnCost() {
        let now = Date()
        // One million input tokens is exactly the published Jev rate.
        let s = DecisionUsageSummary.today([row(500, .jev, inputTokens: 1_000_000, at: now)], now: now)
        XCTAssertEqual(s.spendUSD, DecisionLedger.jevInputUSDPerMillion, accuracy: 1e-9)
        XCTAssertEqual(s.spendPhrase, "$0.04")
    }

    func test_aRealDaysSpendReadsAsUnderACentRatherThanAStringOfZeros() {
        let now = Date()
        // 4,466 input tokens is the measured size of one live ambient decision.
        let rows = (0..<24).map { _ in row(500, .jev, inputTokens: 4_466, at: now) }
        let s = DecisionUsageSummary.today(rows, now: now)
        XCTAssertEqual(s.spendPhrase, "under $0.01")
        XCTAssertEqual(s.line, "24 decisions today, 500 ms average, under $0.01")
    }

    func test_localOnlyDayCostsNothingAndSaysSo() {
        let now = Date()
        let s = DecisionUsageSummary.today([row(12, .local, at: now)], now: now)
        XCTAssertEqual(s.spendPhrase, "no spend")
        XCTAssertEqual(s.line, "1 decision today, 12 ms average, no spend")
        XCTAssertEqual(s.providerPhrase, "all on this Mac")
    }

    func test_anEmptyDaySaysSoInsteadOfRenderingZeros() {
        let s = DecisionUsageSummary.today([], now: Date())
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.line, "No decisions yet today")
        XCTAssertEqual(s.providerPhrase, "")
    }

    func test_lastLineShowsWhatWasHeardNotTheAnswerShape() {
        let e = row(480, .jev, at: Date(), summary: "open my calendar -> intent=open_calendar 0.94")
        XCTAssertEqual(DecisionUsageSummary.lastLine(e), "open my calendar, 480 ms")
    }

    /// Real ledger rows carry each gate's lead-in and sometimes a second line.
    /// Seen on the live card: "Last decision: Heard: question, right?".
    func test_lastLineDropsTheGatesLeadInAndSecondLine() {
        let rows = [
            ("Heard: question, right? -> voice.intent=not_a_command 0.97", "question, right?"),
            ("Heard: open my calendar\nGrux last spoke 12s ago and... -> voice.intent=tab:calendar 0.95", "open my calendar"),
            // A gate-shaped state on another surface is left as written (W54-P3 item 4).
            ("The action is: Run tool 'shell_start' (unclassified side ... -> rule=neither 1.00", "Run tool 'shell_start' (unclassified side ..."),
            ("The person said: note that the soap is a 2 pack -> meant=0.90", "note that the soap is a 2 pack"),
        ]
        for (summary, shown) in rows {
            let e = DecisionLedgerEntry(surface: "voice", provider: .jev, latencyMs: 368, inputTokens: 0,
                                        outputTokens: 0, at: Date(), summary: summary)
            XCTAssertEqual(DecisionUsageSummary.lastLine(e), "\(shown), 368 ms")
        }
    }

    /// D166 item 3's neighbour, item 2 (sense pass 20): Settings, Models read
    /// "Last decision about: Run tool 'create_note' (unclassified side ...",
    /// the gate's fallback state clipped at 57 characters. It names the tool
    /// the way Approvals does.
    func test_lastLineNamesAGatedToolTheWayApprovalsDoes() {
        let rows = [
            ("The action is: Run tool 'create_note' (unclassified side ... -> rule=not_a_command 0.85", "Save your note"),
            ("The action is: Run tool 'create_event' (unclassified side ... -> rule=neither 1.00", "Add your event to your calendar"),
            ("The action is: Run tool 'foundry_upgrade_cycle' (unclassified ... -> rule=neither 1.00", "Start a self-upgrade cycle"),
            ("The action is: Run tool 'fs_list' (unclassified side effect). -> rule=neither 1.00", "Use the fs list tool"),
            ("Run tool 'create_note' (unclassified side effect).", "Save your note"),
        ]
        for (summary, shown) in rows {
            let e = DecisionLedgerEntry(surface: "jax.gate", provider: .local, latencyMs: 131, inputTokens: 0,
                                        outputTokens: 0, at: Date(), summary: summary)
            XCTAssertEqual(DecisionUsageSummary.lastLine(e), "\(shown), 131 ms", summary)
        }
    }

    /// Only the gate's own shape is renamed: words a person said that start
    /// the same way stay theirs.
    func test_lastLineKeepsAPersonsOwnWordsAboutRunningATool() {
        let e = row(200, .jev, at: Date(), summary: "Heard: run tool checks on the build -> voice.intent=not_a_command 0.90")
        XCTAssertEqual(DecisionUsageSummary.lastLine(e), "run tool checks on the build, 200 ms")
    }

    /// W54-P3 items 2 to 4: a long id keeps its closing quote through the
    /// ledger's clip, separators read as spaces, and only the gate's own
    /// surface is renamed.
    @MainActor
    func test_aGatedToolIdOfAnyLengthAndSpellingIsNamed() {
        let result = DecisionResult(answers: ["rule": .choice("neither", confidence: 1, probabilities: [:])],
                                    latencyMs: 131, inputTokens: 0, outputTokens: 0, provider: .local)
        let cases = [
            ("enroll_speaker_from_current_meeting", "Learn a speaker's voice from a meeting"),
            ("mcp__github__create_issue", "Use the mcp github create issue tool"),
            ("mcp-github.create", "Use the mcp github create tool"),
            (String(repeating: "x", count: 31), "Use the \(String(repeating: "x", count: 31)) tool"),
            (String(repeating: "x", count: 32), "Use the \(String(repeating: "x", count: 32)) tool"),
        ]
        for (tool, shown) in cases {
            let state = "The action is: Run tool '\(tool)' (unclassified side effect).\nIts target is: \(tool)\nDetails: tool \(tool)"
            let summary = DecisionEngine.summary(state: state, result: result)
            let e = DecisionLedgerEntry(surface: "jax.gate", provider: .local, latencyMs: 131, inputTokens: 0,
                                        outputTokens: 0, at: Date(), summary: summary)
            XCTAssertEqual(DecisionUsageSummary.lastLine(e), "\(shown), 131 ms", summary)
        }
    }

    func test_aPersonsOwnQuotedRunToolStaysTheirs() {
        let e = DecisionLedgerEntry(surface: "voice", provider: .jev, latencyMs: 200, inputTokens: 0, outputTokens: 0,
                                    at: Date(), summary: "Heard: Run tool 'create_note' please -> voice.intent=not_a_command 0.90")
        XCTAssertEqual(DecisionUsageSummary.lastLine(e), "Run tool 'create_note' please, 200 ms")
    }

    /// The ledger's clip still applies to everything else.
    @MainActor
    func test_theClipIsUnchangedForOtherStates() {
        let result = DecisionResult(answers: [:], latencyMs: 1, inputTokens: 0, outputTokens: 0, provider: .local)
        let long = String(repeating: "a", count: 61)
        XCTAssertEqual(DecisionEngine.summary(state: long, result: result), String(repeating: "a", count: 57) + "... -> ")
        let sixty = String(repeating: "a", count: 60)
        XCTAssertEqual(DecisionEngine.summary(state: sixty, result: result), sixty + " -> ")
    }

    func test_lastLineSurvivesASummaryWithNoArrow() {
        let e = row(12, .local, at: Date(), summary: "  close everything  ")
        XCTAssertEqual(DecisionUsageSummary.lastLine(e), "close everything, 12 ms")
    }

    func test_noDecisionYetHasNoLastLine() {
        XCTAssertNil(DecisionUsageSummary.lastLine(nil))
    }

    // MARK: - P-A10-2: typical speed, the month, money, and the orb's clause

    /// A fixed clock and calendar, so a run at 11:59 PM or on the first of the
    /// month cannot move a row across a boundary.
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private func day(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func test_typicalSpeedIsTheMedianNotTheMean() {
        let now = day(9, 21)
        // One timeout that fell through to this Mac must not decide what
        // "typical" means: the mean here is 3,166 ms, the median 400.
        let odd = DecisionUsageSummary.today([row(100, .jev, at: now), row(9_000, .jev, at: now),
                                              row(400, .jev, at: now)], now: now, calendar: utc)
        XCTAssertEqual(odd.medianLatencyMs, 400)
        XCTAssertEqual(odd.meanLatencyMs, 3_166, "the mean is kept for the menu bar line")
        let even = DecisionUsageSummary.today([row(300, .jev, at: now), row(100, .jev, at: now),
                                               row(900, .jev, at: now), row(200, .jev, at: now)],
                                              now: now, calendar: utc)
        XCTAssertEqual(even.medianLatencyMs, 250, "an even count takes the mean of the two middle values")
        XCTAssertEqual(DecisionUsageSummary.today([], now: now, calendar: utc).medianLatencyMs, 0)
    }

    func test_thisMonthCountsFromTheFirstAndNotBefore() {
        let now = day(9, 21)
        let rows = [row(500, .jev, inputTokens: 1_000_000, at: day(8, 31, 23, 59)),
                    row(500, .jev, inputTokens: 1_000_000, at: day(9, 1, 0, 0)),
                    row(500, .jev, inputTokens: 1_000_000, at: now)]
        let m = DecisionUsageSummary.thisMonth(rows, now: now, calendar: utc)
        XCTAssertEqual(m.count, 2, "August 31 at 11:59 PM counted toward September")
        XCTAssertGreaterThan(rows[0].costUSD, 0)
        XCTAssertEqual(m.spendUSD, rows[1].costUSD + rows[2].costUSD, accuracy: 1e-12,
                       "the month's spend included a row from before the first")
    }

    func test_moneyIsNumeralsWithTheDollarSign_andNeverAStringOfZeros() {
        XCTAssertNil(DecisionUsageSummary.money(0), "zero is worded by each surface, never $0.00")
        XCTAssertEqual(DecisionUsageSummary.money(0.000188), "under $0.01")
        XCTAssertEqual(DecisionUsageSummary.money(0.0099), "under $0.01", "rounding up to $0.01 would overstate it")
        XCTAssertEqual(DecisionUsageSummary.money(0.12), "$0.12")
        XCTAssertEqual(DecisionUsageSummary.money(5), "$5.00")
    }

    func test_theOrbClauseIsTheLastDecisionsSpeedAndCost() {
        let now = day(9, 21, 15)
        // 4,468 input tokens is the measured size of one live voice decision.
        let jev = row(444, .jev, inputTokens: 4_468, at: day(9, 21, 14))
        XCTAssertEqual(DecisionUsageSummary.hoverClause(jev, now: now, calendar: utc),
                       "Last decision took 444 ms and cost under $0.01.")
        let local = row(4, .local, at: day(9, 21, 9))
        XCTAssertEqual(DecisionUsageSummary.hoverClause(local, now: now, calendar: utc),
                       "Last decision took 4 ms and cost nothing.")
    }

    func test_theOrbSaysNothingAboutYesterdaysDecision() {
        let now = day(9, 21, 0, 5)
        XCTAssertNil(DecisionUsageSummary.hoverClause(row(444, .jev, at: day(9, 20, 23, 55)), now: now, calendar: utc),
                     "a decision from before midnight was quoted as if it were today's")
        XCTAssertNil(DecisionUsageSummary.hoverClause(nil, now: now, calendar: utc))
    }

    func test_theOrbHelpIsTheListeningSentenceThenTheClause() {
        let base = ListeningTell.armed.help
        XCTAssertEqual(DecisionUsageSummary.orbHelp(base, clause: "Last decision took 444 ms and cost under $0.01."),
                       base + " Last decision took 444 ms and cost under $0.01.")
        XCTAssertEqual(DecisionUsageSummary.orbHelp(base, clause: nil), base)
        XCTAssertEqual(DecisionUsageSummary.orbHelp(base, clause: ""), base)
    }
}
