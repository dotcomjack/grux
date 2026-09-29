import XCTest
import SwiftUI
import Combine
@testable import Grux

/// P-A10-2: the Settings Usage card and the orb's hover clause.
///
/// Every ledger here is `DecisionLedger(storeURL: nil)`: nothing reads the
/// Keychain, the network or the operator's real decisions file.
@MainActor
final class UsageCardTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private func at(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func row(_ latencyMs: Int, _ provider: DecisionProviderKind, inputTokens: Int = 0,
                     at: Date, heard: String = "open my calendar") -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "voice", provider: provider, latencyMs: latencyMs,
                            inputTokens: provider == .jev ? inputTokens : 0, outputTokens: 0,
                            at: at, summary: "\(heard) -> voice.intent=open 0.94")
    }
    private func text(_ c: UsageCardContent) -> [String] { c.lines.map { "\($0.label): \($0.value)" } }

    // MARK: - What the card says

    /// A keyless install answers everything on this Mac and spends nothing.
    /// That is the correct state for it, so it must read as a plain fact and
    /// never as something broken.
    func test_aKeylessInstallReadsAsOnThisMacAndNothingSpent() {
        let now = at(9, 21, 15)
        let rows = [row(6, .local, at: at(8, 30)),
                    row(4, .local, at: at(9, 21, 9)), row(3, .local, at: at(9, 21, 10)),
                    row(7, .local, at: at(9, 21, 14))]
        let card = UsageCardContent.build(from: rows, now: now, calendar: utc)
        XCTAssertEqual(text(card), [
            "Decisions today: 3",
            "Typical speed: 4 ms",
            "Answered: All on this Mac",
            "Spent today: Nothing",
            "Spent this month: Nothing",
            "Last decision: open my calendar, 7 ms",
        ])
        let all = text(card).joined(separator: " ").lowercased()
        for alarm in ["error", "fail", "not connected", "missing", "no key", "unavailable", "$0.00"] {
            XCTAssertFalse(all.contains(alarm), "a keyless card reads as broken: \(alarm)")
        }
    }

    func test_aDayWithJevDecisionsReadsCountSpeedSplitAndMoney() {
        let now = at(9, 21, 15)
        let rows = [row(450, .jev, inputTokens: 1_000_000, at: at(8, 28)),
                    row(450, .jev, inputTokens: 1_000_000, at: at(9, 10)),
                    row(450, .jev, inputTokens: 1_000_000, at: at(9, 12)),
                    row(400, .jev, inputTokens: 4_468, at: at(9, 21, 9)),
                    row(4, .local, at: at(9, 21, 10), heard: "never mind"),
                    row(520, .jev, inputTokens: 4_468, at: at(9, 21, 14))]
        let card = UsageCardContent.build(from: rows, now: now, calendar: utc)
        XCTAssertEqual(text(card), [
            "Decisions today: 3",
            "Typical speed: 400 ms",
            "Answered: 2 on Jev, 1 on this Mac",
            "Spent today: Under $0.01",
            "Spent this month: $0.08",
            "Last decision: open my calendar, 520 ms",
        ])
    }

    /// The ledger keeps its most recent rows. When they do not reach back to
    /// the first of the month the total is partial, and the label says so.
    func test_aLedgerThatStartsMidMonthSaysWhereTheTotalStarts() {
        let now = at(9, 21, 15)
        let rows = [row(450, .jev, inputTokens: 1_000_000, at: at(9, 18)),
                    row(450, .jev, inputTokens: 1_000_000, at: at(9, 21, 9))]
        let card = UsageCardContent.build(from: rows, now: now, calendar: utc)
        XCTAssertTrue(text(card).contains("Spent since Sep 18: $0.08"), "\(text(card))")
        XCTAssertFalse(text(card).contains { $0.hasPrefix("Spent this month") },
                       "a partial total was called the whole month")

        // Rows that start today would repeat "Spent today" word for word.
        let fresh = UsageCardContent.build(from: [row(4, .local, at: at(9, 21, 9))], now: now, calendar: utc)
        XCTAssertEqual(text(fresh).filter { $0.hasPrefix("Spent") }, ["Spent today: Nothing"])
    }

    func test_aFreshInstallWithNoDecisionsSaysSo() {
        let card = UsageCardContent.build(from: [], now: at(9, 21), calendar: utc)
        XCTAssertEqual(text(card), ["Decisions today: None yet", "Spent today: Nothing", "Spent this month: Nothing"])
    }

    // MARK: - The status line P-R-3 fills

    func test_theStatusLineIsEmptyToday() {
        let card = UsageCard(usage: DecisionUsageModel(ledger: DecisionLedger(storeURL: nil)))
        XCTAssertNil(card.statusLine)
        XCTAssertNil(UsageCard.shownStatus(nil))
        XCTAssertNil(UsageCard.shownStatus("   \n"), "whitespace reserved a status row")
        XCTAssertEqual(UsageCard.shownStatus(" Your Jev credit ran out. "), "Your Jev credit ran out.")
    }

    /// Set, the line renders as one full row. Nil, it takes no space at all:
    /// the card grows by exactly the height of the status row when the line
    /// arrives, so nothing was reserved for it beforehand.
    func test_theStatusLineRendersWhenSetAndTakesNoSpaceWhenNil() {
        let model = DecisionUsageModel(ledger: DecisionLedger(storeURL: nil))
        let line = "Your Jev credit ran out, so Grux is deciding on this Mac. Top it up in Integrations."
        let without = height(UsageCard(usage: model, statusLine: nil))
        let with = height(UsageCard(usage: model, statusLine: line))
        let row = height(UsageCard.statusRow(line))
        XCTAssertGreaterThan(row, 10, "the status row measured as empty")
        XCTAssertEqual(with - without, row, accuracy: 0.5,
                       "the card grew by \(with - without)pt for a \(row)pt status row, "
                       + "so space was held for it while it was nil")
    }

    // MARK: - Computed once per ledger change, never per render

    func test_theLedgerIsScannedOncePerDecision_evenOnceTheLedgerIsFull() {
        let ledger = DecisionLedger(storeURL: nil)
        let model = DecisionUsageModel(ledger: ledger, dayChanged: Empty().eraseToAnyPublisher())
        XCTAssertEqual(model.scans, 1, "the model should scan once to start")
        for i in 0..<3 { ledger.record(row(400 + i, .jev, inputTokens: 4_468, at: Date())) }
        XCTAssertEqual(model.scans, 4)
        // Past the ledger's 2,000 row cap every record appends AND trims, which
        // is two changes to the rows for one decision. Still one scan.
        for _ in 0..<2_003 { ledger.record(row(4, .local, at: Date())) }
        XCTAssertEqual(model.scans, 4 + 2_003, "one decision caused more than one scan")
        XCTAssertEqual(model.snapshot.card.lines.first?.value, "\(ledger.recent.count)",
                       "the card is not reading the rows the ledger ended up with")
    }

    func test_renderingTheCardAndTheOrbNeverScansTheLedger() {
        let ledger = DecisionLedger(storeURL: nil)
        ledger.record(row(444, .jev, inputTokens: 4_468, at: Date()))
        let model = DecisionUsageModel(ledger: ledger, dayChanged: Empty().eraseToAnyPublisher())
        let before = model.scans
        for width in stride(from: 360.0, through: 760.0, by: 100.0) {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                UsageCard(usage: model)
                OrbDecisionHelp(base: ListeningTell.armed.help, usage: model, content: Text("orb"))
            }.frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        XCTAssertEqual(model.scans, before, "drawing the card or the orb scanned the ledger")
    }

    /// Midnight empties "today" with nothing recorded, and the orb must stop
    /// quoting a decision that is now yesterday's.
    func test_aDayChangeRescans_andTheOrbStopsQuotingYesterday() {
        let ledger = DecisionLedger(storeURL: nil)
        var clock = at(9, 21, 23, 58)
        let dayChanged = PassthroughSubject<Void, Never>()
        let model = DecisionUsageModel(ledger: ledger, now: { clock }, calendar: utc,
                                       dayChanged: dayChanged.eraseToAnyPublisher())
        ledger.record(row(444, .jev, inputTokens: 4_468, at: at(9, 21, 23, 57)))
        XCTAssertEqual(model.snapshot.hoverClause, "Last decision took 444 ms and cost under $0.01.")
        let scans = model.scans

        clock = at(9, 22, 0, 1)
        dayChanged.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(model.scans, scans + 1)
        XCTAssertNil(model.snapshot.hoverClause, "after midnight the orb still quoted yesterday's decision")
        XCTAssertEqual(model.snapshot.card.lines.first?.value, "None yet")
    }

    // MARK: - Where it lives and how it is found

    func test_theCardIsInSettingsAndTheSearchFindsIt() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("UsageCard()"), "the card exists but Settings never shows it")
        XCTAssertTrue(settings.contains(".id(\"models.usage\")"), "the card has no scroll anchor to land on")

        let expected = SettingsLocation(pane: .models, sub: "models", anchor: "models.usage")
        for query in ["usage", "cost", "spend", "latency", "speed"] {
            let hits = SettingsSearchRegistry.matches(query)
            XCTAssertTrue(hits.contains { $0.id == "models.usage" && $0.location == expected },
                          "searching Settings for \"\(query)\" does not find the Usage card")
        }
        XCTAssertFalse(SettingsSearchRegistry.matches("bluetooth").contains { $0.id == "models.usage" },
                       "the Usage entry matches everything, so the hits above prove nothing")
        XCTAssertEqual(SettingsTabAliases.resolve("usage"), expected)
    }

    /// The orb's hover carries the clause, and the ROOT does not observe the
    /// model: a decision redraws the tooltip, not the window.
    func test_theOrbHoverCarriesTheClauseWithoutTheRootObservingTheLedger() throws {
        let root = try source("Sources/Grux/LaunchRootView.swift")
        XCTAssertTrue(root.contains(".orbDecisionHelp(listeningTell.help)"),
                      "the rail orb's hover lost the last decision's speed and cost")
        XCTAssertFalse(root.contains("DecisionUsageModel") || root.contains("DecisionLedger"),
                       "LaunchRootView reads the ledger itself, so every decision redraws the whole window")
    }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) { view }
            .frame(width: 520, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 800)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
