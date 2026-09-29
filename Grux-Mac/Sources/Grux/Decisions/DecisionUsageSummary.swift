import Foundation

/// What today's decisions cost, in words a person can read. Every tell in the
/// app (orb hover, the Settings Usage card, the menu bar, the morning
/// briefing) renders from here, so the same day never gets described two
/// different ways on two different surfaces.
///
/// Pure value type computed from ledger rows: no clock of its own, no store,
/// nothing to mock.
struct DecisionUsageSummary: Equatable {
    let count: Int
    let meanLatencyMs: Int
    /// The middle latency, which the Usage card calls typical speed. A MEDIAN,
    /// not a mean, on purpose: one slow call (a cold connection, a timeout that
    /// fell through to this Mac) drags a mean far from what a person usually
    /// waits, and the median does not move.
    let medianLatencyMs: Int
    let spendUSD: Double
    /// Decisions answered by Jev, and decisions answered on this Mac.
    let jevCount: Int
    let localCount: Int

    static let empty = DecisionUsageSummary(count: 0, meanLatencyMs: 0, medianLatencyMs: 0, spendUSD: 0,
                                            jevCount: 0, localCount: 0)

    var isEmpty: Bool { count == 0 }

    /// Rows from the start of `now`'s day onward, summarised.
    static func today(_ rows: [DecisionLedgerEntry],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> DecisionUsageSummary {
        since(calendar.startOfDay(for: now), rows: rows)
    }

    /// Rows from the first day of `now`'s month onward, summarised.
    static func thisMonth(_ rows: [DecisionLedgerEntry],
                          now: Date = Date(),
                          calendar: Calendar = .current) -> DecisionUsageSummary {
        since(startOfMonth(now, calendar: calendar), rows: rows)
    }

    static func startOfMonth(_ now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    static func since(_ start: Date, rows: [DecisionLedgerEntry]) -> DecisionUsageSummary {
        let day = rows.filter { $0.at >= start }
        guard !day.isEmpty else { return .empty }
        return DecisionUsageSummary(
            count: day.count,
            meanLatencyMs: day.map(\.latencyMs).reduce(0, +) / day.count,
            medianLatencyMs: median(day.map(\.latencyMs)),
            spendUSD: day.map(\.costUSD).reduce(0, +),
            jevCount: day.filter { $0.provider == .jev }.count,
            localCount: day.filter { $0.provider == .local }.count)
    }

    // MARK: - Words

    /// The one line the orb hover and the briefing use.
    /// "24 decisions today, 512 ms average, under $0.01"
    var line: String {
        guard !isEmpty else { return "No decisions yet today" }
        return "\(countPhrase) today, \(meanLatencyMs) ms average, \(spendPhrase)"
    }

    /// Where the decisions were made. Empty when they all went one way and
    /// there is nothing to contrast.
    var providerPhrase: String {
        if jevCount > 0 && localCount > 0 { return "\(jevCount) on Jev, \(localCount) on this Mac" }
        if jevCount > 0 { return "all on Jev" }
        if localCount > 0 { return "all on this Mac" }
        return ""
    }

    var countPhrase: String { count == 1 ? "1 decision" : "\(count) decisions" }

    /// The middle value; with an even count, the mean of the two middle ones.
    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Spend never reads as a bare zero, and never as a number so small it
    /// looks like a rendering bug.
    var spendPhrase: String { Self.money(spendUSD) ?? "no spend" }

    /// Money as a person reads it: "$0.12", or "under $0.01" when it would
    /// round to nothing. Nil for exactly nothing, so each surface says zero in
    /// its own sentence ("no spend", "nothing") rather than "$0.00".
    static func money(_ usd: Double) -> String? {
        if usd <= 0 { return nil }
        if usd < 0.01 { return "under $0.01" }
        return "$" + String(format: "%.2f", usd)
    }

    // MARK: - The orb's hover

    /// The clause the rail orb adds to its hover: the last decision's speed
    /// and cost. Nil unless that decision happened today, so the orb never
    /// quotes yesterday as if it were now.
    /// "Last decision took 444 ms and cost under $0.01."
    static func hoverClause(_ last: DecisionLedgerEntry?,
                            now: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        guard let last, calendar.isDate(last.at, inSameDayAs: now) else { return nil }
        return "Last decision took \(last.latencyMs) ms and cost \(money(last.costUSD) ?? "nothing")."
    }

    /// The orb's whole hover: its listening sentence, then the clause when
    /// there is one.
    static func orbHelp(_ base: String, clause: String?) -> String {
        guard let clause, !clause.isEmpty else { return base }
        return base + " " + clause
    }

    // MARK: - The last decision, for the menu bar

    /// "open my calendar, 480 ms". Nil when nothing has been decided yet.
    /// The heard text is trimmed to the arrow the ledger summary writes, so
    /// the menu bar shows what was said and not the engine's answer shape.
    static func lastLine(_ entry: DecisionLedgerEntry?) -> String? {
        guard let entry else { return nil }
        return "\(heard(in: entry.summary)), \(entry.latencyMs) ms"
    }

    /// The lead-ins each gate writes in front of its state. They are how a
    /// question is put to the provider, not something a person says, so the
    /// card shows what follows them. Seen live on the card on 2026-09-21:
    /// "Last decision: Heard: question, right?".
    static let stateLeadIns = ["Heard: ", "The person said: ", "The action is: ", "The command about to run is: "]

    static func heard(in summary: String) -> String {
        var text = summary
        if let arrow = text.range(of: " -> ") { text = String(text[text.startIndex..<arrow.lowerBound]) }
        // A state can carry a second line (Grux's last reply); the card wants
        // only what was heard.
        text = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in stateLeadIns where text.hasPrefix(lead) {
            text = String(text.dropFirst(lead.count))
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
