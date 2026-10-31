import Foundation

// Stage 2 of the Foundry loop: Synthesize. The cycle used to harvest signals,
// log a count, and stop, so "Grux, upgrade yourself" never left a proposal
// behind and the Self-Upgrade pane stayed empty whatever the signals said.
// This turns one pass's signals into proposals: one per (source, lane,
// domain) group, citing every signal in it, ranked by severity and count.
//
// Deterministic and free on purpose: no model call decides what to file, so
// a pass costs nothing until a person accepts a proposal and the build rail
// spends their subscription on it.
enum SignalProposalFiler {

    // A pass files at most this many proposals, highest gain first, so one
    // noisy log cannot bury the pane.
    static let maxPerPass = 5
    // Evidence cited per proposal; the rest is counted in the title.
    static let maxEvidencePerProposal = 8
    // After a fix lands, its group stays quiet this long: sources look back
    // up to 30 days (Compare) and stamp signals with the harvest time, so
    // until then the pass would mostly see the problem from before the fix.
    // After it, only a signal the fix did not cover files again.
    static let quietAfterLanding: TimeInterval = 30 * 86_400
    // Receipts quoted into the worker's prompt per signal.
    private static let receiptLimit = 600

    static func key(for signal: FoundrySignal) -> String {
        "\(signal.source)|\(signal.suggestedLane.rawValue)|\(signal.suggestedDomain)"
    }

    static func proposals(from signals: [FoundrySignal], existing: [UpgradeProposal], now: Date = Date()) -> [UpgradeProposal] {
        let blocked = Set(existing.compactMap { p -> String? in
            guard let key = p.signalKey, blocks(p, now: now) else { return nil }
            return key
        })
        // Past its quiet period a landed fix still answers the signals it
        // covered from a source with no lookback window (`carriesNoAge`), so
        // the very signal it fixed does not file it again.
        var answered: Set<String> = []
        for p in existing where p.status == .landed {
            guard let key = p.signalKey else { continue }
            for summary in p.coveredSignals ?? p.evidence.map(\.detail) { answered.insert(key + "\n" + summary) }
        }
        var groups: [String: [FoundrySignal]] = [:]
        for signal in signals where signal.severity > .info {
            let key = key(for: signal)
            guard !blocked.contains(key) else { continue }
            if carriesNoAge(signal), answered.contains(key + "\n" + signal.identity) { continue }
            groups[key, default: []].append(signal)
        }
        let filed = groups.map { key, members in
            proposal(key: key, signals: members.sorted { a, b in
                a.severity != b.severity ? a.severity > b.severity : a.summary < b.summary
            }, now: now)
        }
        return Array(filed.sorted { a, b in
            a.expectedGain != b.expectedGain ? a.expectedGain > b.expectedGain : a.title < b.title
        }.prefix(maxPerPass))
    }

    // Sources that read their whole history with no lookback window: chat
    // threads (every message of a thread still in use), the flake log, and
    // the whole-file error-log counts. Only their signals can still be the
    // pre-fix evidence once the quiet period is over. Every other source
    // looks back 30 days or less, so past the quiet period the same wording
    // is the problem coming back. A new source counts as windowed, which
    // errs toward filing a recurrence.
    static func carriesNoAge(_ signal: FoundrySignal) -> Bool {
        switch signal.source {
        case "transcript", "flake": return true
        case "telemetry": return signal.suggestedDomain == "logs"
        default: return false
        }
    }

    // Whether a proposal on file keeps its group from filing again: while it
    // is open, when the person turned it down, and for the quiet period after
    // it landed. A rejection Grux made itself does not, and neither does a
    // rolled back fix (it did not hold).
    static func blocks(_ p: UpgradeProposal, now: Date) -> Bool {
        switch p.status {
        case .proposed, .accepted, .building, .verifying: return true
        case .rejected: return p.declinedByPerson == true
        case .landed: return now < p.updatedAt.addingTimeInterval(quietAfterLanding)
        case .rolledBack: return false
        }
    }

    // Files this pass's new proposals into the store (which applies the
    // protected-zone pinning) and returns them.
    @MainActor
    @discardableResult
    static func file(from signals: [FoundrySignal], into store: ProposalStore, now: Date = Date()) -> [UpgradeProposal] {
        proposals(from: signals, existing: store.proposals, now: now).map { store.file($0) }
    }

    // The timeline line a cycle leaves behind.
    static func cycleDetail(signals: Int, sourceErrors: Int, filed: Int) -> String {
        let harvested = "Harvested \(signals) signal\(signals == 1 ? "" : "s")"
        let proposals = filed == 0
            ? "filed no new proposals"
            : "filed \(filed) new proposal\(filed == 1 ? "" : "s")"
        let errors = sourceErrors == 0 ? "" : "; \(sourceErrors) source error\(sourceErrors == 1 ? "" : "s")"
        return "\(harvested); \(proposals)\(errors)."
    }

    private static func proposal(key: String, signals: [FoundrySignal], now: Date) -> UpgradeProposal {
        let top = signals[0]
        let more = signals.count - 1
        let title = more == 0 ? top.summary : "\(top.summary) (and \(more) more like it)"
        let cited = signals.prefix(maxEvidencePerProposal)
        return UpgradeProposal(
            title: title,
            lane: lane(top.suggestedLane),
            domain: .mac,
            evidence: cited.map { UpgradeEvidence(source: $0.source, detail: $0.summary) },
            expectedGain: gain(top: top.severity, count: signals.count),
            riskClass: .medium,
            estCostLabel: "$3 estimated",
            tierRequired: .propose,
            createdAt: now,
            updatedAt: now,
            readyPrompt: prompt(area: top.suggestedDomain, signals: Array(cited)),
            signalKey: key,
            coveredSignals: signals.map(\.identity)
        )
    }

    // Severity sets the base; every further signal in the group adds a
    // little, capped, so a problem seen often outranks one seen once.
    static func gain(top: FoundrySignal.Severity, count: Int) -> Double {
        let base: Double
        switch top {
        case .high: base = 0.7
        case .medium: base = 0.5
        case .low, .info: base = 0.3
        }
        return min(1.0, base + min(0.2, 0.05 * Double(max(0, count - 1))))
    }

    private static func lane(_ lane: FoundryLane) -> UpgradeLane {
        switch lane {
        case .performance: return .performance
        case .reliability: return .reliability
        case .capability: return .capability
        case .cost: return .cost
        case .codeHealth: return .codeHealth
        case .uxPolish: return .uxPolish
        }
    }

    private static func prompt(area: String, signals: [FoundrySignal]) -> String {
        let receipts = signals.map { s -> String in
            let quote = s.evidence.count > receiptLimit ? String(s.evidence.prefix(receiptLimit)) + " ..." : s.evidence
            return "### \(s.source), \(s.severity.rawValue): \(s.summary)\n\(quote)"
        }.joined(separator: "\n\n")
        return """
        Grux's own signals show a problem a person using Grux runs into, in the \(area) area of the Mac app (Grux-Mac). Find the root cause, then fix it with the smallest change that makes this kind of problem impossible rather than hiding one instance. Write a test that fails before the fix and passes after it. If the signals turn out to be noise and there is nothing to fix, change nothing and say why in your final report.

        ## What the signals say
        \(receipts)
        """
    }
}
