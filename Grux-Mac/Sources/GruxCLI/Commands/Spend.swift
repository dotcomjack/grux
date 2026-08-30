import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux spend

/// What the model calls have cost, read from the ledger Grux already keeps.
///
/// It reads a file and never a vendor. Asking Anthropic what you spent needs a key with
/// billing scope, which is a strictly larger permission than the one Grux has for making the
/// calls, and no read-only report is worth widening a credential for.
///
/// THE FRESHNESS IS PART OF THE ANSWER. The ledger is refreshed by the app, so a number here
/// can be weeks old while looking exactly like a live one. On the machine this was written on
/// it was seventeen days stale, and "today: $0.00" would have been read as "I have spent
/// nothing today" when it meant "nobody has looked since the eleventh".
struct Spend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spend",
        abstract: "What the model calls have cost. Reads Grux's own ledger, never a vendor.")

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    struct Ledger: Decodable {
        var lastFetch: String?
        var snapshot: Snapshot?
        struct Snapshot: Decodable {
            var todayUSD: Double?
            var total30dUSD: Double?
            var baseline7dAvgUSD: Double?
            var latestCompleteDay: String?
            var days: [Day]?
            var providerTotals30d: [Provider]?
        }
        struct Day: Decodable { var day: String; var totalUSD: Double }
        struct Provider: Decodable { var provider: String; var usd: Double; var generations: Int }
    }

    static var ledgerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/llm-spend-state.json")
    }

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        guard let data = try? Data(contentsOf: Self.ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              let snap = ledger.snapshot else {
            if json { print("{}"); leave(.done) }
            frame.open(.look)
            // NOT AN ERROR. A Mac that has never made a paid call has no ledger, and that is
            // the expected state of a fresh install, not a fault to report.
            print(r.prose("No spend recorded on this Mac yet. Grux writes this after its "
                          + "first model call, and local models cost nothing to record."))
            leave(.done)
        }

        if json { print(String(decoding: data, as: UTF8.self)); leave(.done) }

        frame.open(.look)

        let total = snap.total30dUSD ?? 0
        // THE ANSWER FIRST, as one sentence, in numerals with the symbol.
        print(r.prose("\(money(total)) over the last 30 days."))
        print("")
        print(r.row(state: .satisfied, label: "Today", detail: money(snap.todayUSD ?? 0),
                    labelWidth: 18))
        print(r.row(state: .satisfied, label: "Last 30 days", detail: money(total),
                    labelWidth: 18))
        print(r.row(state: .satisfied, label: "Typical day",
                    detail: money(snap.baseline7dAvgUSD ?? 0), labelWidth: 18))

        let providers = (snap.providerTotals30d ?? []).sorted { $0.usd > $1.usd }
        if !providers.isEmpty {
            print("")
            print("  " + r.heading("WHERE IT WENT"))
            let width = providers.map(\.provider.count).max() ?? 12
            for p in providers {
                print("    " + r.style.ink(.ok, "+") + " "
                      + p.provider.padding(toLength: width, withPad: " ", startingAt: 0)
                      + "  " + money(p.usd).padding(toLength: 9, withPad: " ", startingAt: 0)
                      + r.style.ink(.dim, "\(p.generations) call"
                                    + (p.generations == 1 ? "" : "s")))
            }
            // COUNTS MATCH THE LIST. A rounding gap between the providers and the headline
            // is the sort of thing somebody notices and stops trusting the whole screen for.
            let summed = providers.reduce(0) { $0 + $1.usd }
            if abs(summed - total) > 0.005 {
                print("")
                print(r.style.ink(.dim, r.prose(
                    "The providers add up to \(money(summed)), not \(money(total)). The "
                    + "difference is calls the ledger has no provider for.", indent: 4)))
            }
        }

        print("")
        print(r.rule())
        // STALENESS, ALWAYS, and as a sentence rather than a timestamp.
        if let raw = ledger.lastFetch, let when = ISO8601DateFormatter().date(from: raw) {
            let days = Int(Date().timeIntervalSince(when) / 86400)
            if days >= 2 {
                print(r.style.ink(.attention, r.prose(
                    "Last updated \(days) days ago, so today's figure is not today's. Grux "
                    + "refreshes this while it is running.")))
            } else {
                print(r.style.ink(.dim, r.prose("Updated \(days == 0 ? "today" : "yesterday").")))
            }
        } else {
            print(r.style.ink(.attention, r.prose(
                "The ledger does not say when it was last updated, so treat these as a "
                + "lower bound.")))
        }
        leave(.done)
    }

    /// Numerals with the symbol, always. Two decimals unless that would round a real cost to
    /// nothing, because "$0.00" next to 355 calls reads as broken rather than as cheap.
    private func money(_ usd: Double) -> String {
        if usd > 0 && usd < 0.005 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
}
