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

    /// The typical wait on Jev today, the same median the Usage card calls typical speed, for the
    /// Integrations card. A Jev call that gave no answer is recorded as a local row with
    /// `fallbackFrom: .jev` and the whole wait. It counts when it may have been billed (a timeout,
    /// a server error), the rule `DecisionLedger.countRemote` uses, because that was a real wait
    /// on Jev; a call refused at once (offline, a bad key, a 429) measures nothing about Jev. Nil
    /// when Jev answered nothing today, so a day of refusals never reads as fast.
    static func jevTypicalMs(_ rows: [DecisionLedgerEntry],
                             now: Date = Date(),
                             calendar: Calendar = .current) -> Int? {
        let start = calendar.startOfDay(for: now)
        let today = rows.filter { $0.at >= start }
        guard today.contains(where: { $0.provider == .jev }) else { return nil }
        let waits = today.filter { $0.provider == .jev || ($0.fallbackFrom == .jev && $0.fallbackMayHaveBilled == true) }
        return median(waits.map(\.latencyMs))
    }

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
        if !usd.isFinite || usd <= 0 { return nil }
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
        var said = heard(in: entry.summary)
        // Only the tool gate's own state, never words a person said (W54-P3 item 4).
        if renamedSurfaces.contains(entry.surface), let named = gatedToolGist(said) { said = named }
        // A row the engine clipped down to a stub ("S...") says what was decided.
        if said.replacingOccurrences(of: "...", with: "").count < 3, let gist = surfaceGists[entry.surface] {
            said = gist
        }
        // A sentence's own period before the comma read "approval., 144 ms" (D8).
        if said.hasSuffix(".") && !said.hasSuffix("...") { said.removeLast() }
        return "\(said), \(entry.latencyMs) ms"
    }

    /// Surfaces whose state Grux builds from a gated action's own summary,
    /// never from a person's words, so a "Run tool 'x'" there is renamed: the
    /// tool gate, and the risk judgment that reads the same summary (wave 55
    /// P2-1: its row read raw again after W54-P3 item 4).
    static let renamedSurfaces = [DecisionGate.surface, ApprovalRiskJudgment.surface]

    /// What the last decision line is labelled wherever it shows.
    static let lastDecisionLabel = "Last decision about"

    /// The menu bar's last decision line, labelled the way Settings labels it:
    /// a bare gist "Delete the meeting folder, 131 ms" read as a thing Grux
    /// had done (W54-P3 item 5).
    static func menuBarLine(_ dated: String) -> String { "\(lastDecisionLabel): \(dated)" }

    /// The last decision for a surface that sits beside today's numbers: the
    /// Usage card under "Decisions today", the menu bar under a hover that says
    /// "No decisions yet today". Not today, it names the day, and the year
    /// when that differs, so the two never read as if they disagreed (D8, D54).
    static func datedLastLine(_ entry: DecisionLedgerEntry?, now: Date = Date(),
                              calendar: Calendar = .current) -> String? {
        guard let entry, let line = lastLine(entry) else { return nil }
        if calendar.isDate(entry.at, inSameDayAs: now) { return line }
        return line + ", " + dayLabel(entry.at, now: now, calendar: calendar)
    }

    /// "Sep 18", or "Dec 31, 2025" in another year. English on purpose, like
    /// every other word on these surfaces.
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// The tool gate's fallback state, `Run tool 'create_note' (unclassified
    /// side ...`, named the way Approvals names it ("Save your note"), or
    /// "Use the fs list tool" for a tool Approvals has no words for (D166
    /// item 2: Settings, Models showed the raw state). Nil for anything else,
    /// a person's own words included.
    static func gatedToolGist(_ said: String) -> String? {
        let prefix = "Run tool '"
        guard said.hasPrefix(prefix) else { return nil }
        let rest = said.dropFirst(prefix.count)
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let tool = String(rest[rest.startIndex..<close])
        let separators: Set<Character> = ["_", "-", "."]
        guard !tool.isEmpty, tool.allSatisfy({ $0.isLetter || $0.isNumber || separators.contains($0) }) else { return nil }
        if let summary = ToolReplyCopy.approvalSummary(tool: tool, input: [:]) {
            return summary.hasSuffix(".") ? String(summary.dropLast()) : summary
        }
        let words = tool.split(whereSeparator: { separators.contains($0) }).joined(separator: " ")
        return words.isEmpty ? nil : "Use the \(words) tool"
    }

    /// What a decision was, by surface, for a row whose own words were lost.
    static let surfaceGists = [ApprovalRiskJudgment.surface: "Judged an approval's risk"]

    /// The state with its opener dropped. The engine clips the ledger summary
    /// after this, so the clip keeps what was asked about, not the opener.
    static func withoutPreamble(_ state: String) -> String {
        for preamble in statePreambles where state.hasPrefix(preamble) {
            return String(state.dropFirst(preamble.count))
        }
        return state
    }

    /// Opening lines a gate puts above the state it asks about. They describe
    /// the question, so the card shows the line after them (D8: the card read
    /// "An action is waiting for the person's approval., 144 ms").
    static let statePreambles = ["An action is waiting for the person's approval.\n"]

    /// The lead-ins each gate writes in front of its state. They are how a
    /// question is put to the provider, not something a person says, so the
    /// card shows what follows them. Seen live on the card on 2026-09-21:
    /// "Last decision: Heard: question, right?".
    static let stateLeadIns = ["Heard: ", "The person said: ", "The action is: ", "The command about to run is: ",
                               "Action: "]

    static func heard(in summary: String) -> String {
        var text = summary
        if let arrow = text.range(of: " -> ") { text = String(text[text.startIndex..<arrow.lowerBound]) }
        text = withoutPreamble(text)
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
