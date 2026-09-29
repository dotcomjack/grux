import SwiftUI
import Combine

// The Settings Usage card and the rail orb's hover clause: what Grux's
// decisions cost and how fast they were, in plain words. Both read ONE model,
// and the model scans the ledger once per ledger change (and once when the
// calendar day turns over), never per render. A per-render scan was measured
// at 58 main thread samples in 5 idle seconds and removed; this model is here
// so that shape does not come back through the card or the orb.

/// What the card says, as plain values. Pure: built from ledger rows, rendered
/// as is.
struct UsageCardContent: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static let title = "Usage"

    /// What a decision is, because "decisions today" means nothing without it.
    static let explainer = "One decision is one judgment: whether something you said was meant for Grux, "
        + "what it asked for, or whether an action is safe to run."

    let lines: [Line]

    static let empty = UsageCardContent(lines: [])

    /// A keyless install reads as what it is: every decision answered on this
    /// Mac and nothing spent. Those are facts about the rows, so no Keychain
    /// read is needed to say them, and nothing here reads as an error.
    static func build(from rows: [DecisionLedgerEntry],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> UsageCardContent {
        let today = DecisionUsageSummary.today(rows, now: now, calendar: calendar)
        let monthStart = DecisionUsageSummary.startOfMonth(now, calendar: calendar)
        let month = DecisionUsageSummary.since(monthStart, rows: rows)

        var lines: [Line] = []
        lines.append(Line(label: "Decisions today", value: today.isEmpty ? "None yet" : "\(today.count)"))
        if !today.isEmpty {
            lines.append(Line(label: "Typical speed", value: "\(today.medianLatencyMs) ms"))
            lines.append(Line(label: "Answered", value: sentenceCase(today.providerPhrase)))
        }
        lines.append(Line(label: "Spent today",
                          value: sentenceCase(DecisionUsageSummary.money(today.spendUSD) ?? "nothing")))

        // The ledger keeps its most recent rows, not all of them, so the month
        // is only called "this month" when the rows reach back to its first
        // day. Otherwise the label says where they start, rather than passing
        // a partial total off as the whole month. When they start today the
        // row would repeat "Spent today", so it is left out.
        let oldest = rows.map(\.at).min()
        if let oldest, oldest > monthStart {
            if !calendar.isDate(oldest, inSameDayAs: now) {
                lines.append(Line(label: "Spent since " + dayLabel(oldest, calendar: calendar),
                                  value: sentenceCase(DecisionUsageSummary.money(month.spendUSD) ?? "nothing")))
            }
        } else {
            lines.append(Line(label: "Spent this month",
                              value: sentenceCase(DecisionUsageSummary.money(month.spendUSD) ?? "nothing")))
        }

        if let last = DecisionUsageSummary.lastLine(rows.last) {
            lines.append(Line(label: "Last decision", value: last))
        }
        return UsageCardContent(lines: lines)
    }

    /// "Sep 18". English on purpose, like every other word on the card.
    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

/// Everything the card and the orb hover show, computed once per ledger change.
@MainActor
final class DecisionUsageModel: ObservableObject {
    static let shared = DecisionUsageModel(ledger: .shared)

    struct Snapshot: Equatable {
        var card: UsageCardContent
        var hoverClause: String?
    }

    @Published private(set) var snapshot = Snapshot(card: .empty, hoverClause: nil)

    /// How many times the ledger has been scanned: once at start, once per
    /// recorded decision, once per calendar day change. A render never adds
    /// one, and a test holds that.
    private(set) var scans = 0

    private let ledger: DecisionLedger
    private let now: () -> Date
    private let calendar: Calendar
    private var subscriptions = Set<AnyCancellable>()

    init(ledger: DecisionLedger,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         dayChanged: AnyPublisher<Void, Never>? = nil) {
        self.ledger = ledger
        self.now = now
        self.calendar = calendar
        // `last`, not `recent`. `record` mutates `recent` twice once the ledger
        // is full (append, then trim), and sets `last` exactly once, after
        // both. `last` also publishes before it is stored, so the scan reads
        // `recent`, which is already final by then.
        ledger.$last
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &subscriptions)
        // At midnight "today" empties even though nothing was recorded, and
        // the hover must stop quoting yesterday's decision.
        (dayChanged ?? NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rescan() }
            .store(in: &subscriptions)
    }

    private func rescan() {
        scans += 1
        let rows = ledger.recent
        let at = now()
        let next = Snapshot(card: UsageCardContent.build(from: rows, now: at, calendar: calendar),
                            hoverClause: DecisionUsageSummary.hoverClause(rows.last, now: at, calendar: calendar))
        // Publishing an unchanged value still redraws every observer.
        if next != snapshot { snapshot = next }
    }
}

/// The Settings Usage card. Lives in Models, because what the models did and
/// what they cost belongs next to where they are chosen.
struct UsageCard: View {
    @ObservedObject private var usage: DecisionUsageModel
    /// Where the status line comes from (P-R-3). Observed HERE, like the
    /// usage model, so a credit running out redraws this card and nothing else.
    @ObservedObject private var credits: CreditMonitor

    /// A line passed in by a caller (a test, a preview). Nil reads the credits.
    private let pinnedStatus: String?

    /// THE ONE STATUS LINE. Filled by P-R-3 when a credit that was being used
    /// runs out: blunt about what got worse and how to refill, from
    /// `CreditNotice`. It renders first, above the numbers, and takes no space
    /// at all when nil, which is every install whose credits are fine.
    var statusLine: String? { pinnedStatus ?? credits.statusLine }

    init(statusLine: String? = nil) {
        self.init(usage: .shared, credits: .shared, statusLine: statusLine)
    }

    /// `credits` nil is the app's monitor.
    init(usage: DecisionUsageModel, credits: CreditMonitor? = nil, statusLine: String? = nil) {
        self.usage = usage
        self.credits = credits ?? .shared
        self.pinnedStatus = statusLine
    }

    /// A blank line is no line: whitespace never reserves a row.
    static func shownStatus(_ line: String?) -> String? {
        guard let t = line?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func statusRow(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(GruxTheme.warnAmber)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Section(UsageCardContent.title) {
            if let status = Self.shownStatus(statusLine) {
                Self.statusRow(status)
            }
            ForEach(usage.snapshot.card.lines) { line in
                LabeledContent(line.label, value: line.value)
            }
            Text(UsageCardContent.explainer)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The rail orb's hover: its listening sentence plus the last decision's speed
/// and cost. The model is observed HERE, not on LaunchRootView, so a decision
/// redraws one tooltip instead of the whole window.
///
/// A wrapping View rather than a ViewModifier, and that is measured: hosted
/// and laid out, a View's body ran and a ViewModifier's did not, so a modifier
/// left the render-never-scans test blind to the one body it exists to watch.
struct OrbDecisionHelp<Content: View>: View {
    let base: String
    @ObservedObject var usage: DecisionUsageModel
    let content: Content

    var body: some View {
        content.help(DecisionUsageSummary.orbHelp(base, clause: usage.snapshot.hoverClause))
    }
}

extension View {
    func orbDecisionHelp(_ base: String) -> some View {
        OrbDecisionHelp(base: base, usage: .shared, content: self)
    }
}
