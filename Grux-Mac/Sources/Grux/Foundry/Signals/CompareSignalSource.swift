import Foundation

// Compare lane of the Sense pass. Reads ComparisonStore's history file
// directly off disk (comparisons.json, a flat [ComparisonRecord]) so the
// harvester never has to hop to the MainActor store. Patterns:
//
//   - Lopsided win/loss: a backend that keeps losing voted comparisons is a
//     routing-table candidate (stop sending that workload there).
//   - Error-prone backend: contenders that error out repeatedly.
//   - Unvoted backlog: lots of runs with no vote means the blind-compare UX
//     isn't closing the loop, a UX-polish signal about the Compare tab itself.
struct CompareSignalSource: FoundrySignalSource {

    let sourceName = "compare"

    var historyURL: URL
    var lookback: TimeInterval
    var now: @Sendable () -> Date

    init(
        historyURL: URL = Persistence.supportDir.appendingPathComponent("comparisons.json"),
        lookback: TimeInterval = 30 * 24 * 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.historyURL = historyURL
        self.lookback = lookback
        self.now = now
    }

    func harvest() async throws -> [FoundrySignal] {
        let records = Persistence.load([ComparisonRecord].self, from: historyURL, fallback: [])
        let cutoff = now().addingTimeInterval(-lookback)
        return Self.signals(from: records.filter { $0.createdAt >= cutoff })
    }

    // Exposed for tests: pure function over the record history.
    static func signals(from records: [ComparisonRecord]) -> [FoundrySignal] {
        guard !records.isEmpty else { return [] }
        var out: [FoundrySignal] = []

        // Win/loss per backend across voted records.
        var wins: [String: Int] = [:]
        var appearances: [String: Int] = [:]
        var errors: [String: [String]] = [:]
        var votedCount = 0

        for rec in records {
            let votedId = rec.votedOutputId
            if votedId != nil { votedCount += 1 }
            for output in rec.outputs {
                appearances[output.backendName, default: 0] += 1
                if let err = output.errorText {
                    errors[output.backendName, default: []].append(String(err.prefix(140)))
                }
                if let votedId, output.id == votedId {
                    wins[output.backendName, default: 0] += 1
                }
            }
        }

        // Lopsided losers: appeared in 4+ voted matchups, won under 20%.
        for (backend, seen) in appearances.sorted(by: { $0.key < $1.key }) {
            let votedAppearances = records.filter { rec in
                rec.votedOutputId != nil && rec.outputs.contains(where: { $0.backendName == backend })
            }.count
            guard votedAppearances >= 4 else { continue }
            let w = wins[backend] ?? 0
            let rate = Double(w) / Double(votedAppearances)
            if rate < 0.2 {
                out.append(FoundrySignal(
                    source: "compare",
                    severity: .medium,
                    summary: "Compare: '\(backend)' wins \(w)/\(votedAppearances) voted matchups (\(Int(rate * 100))%)",
                    evidence: "appearances: \(seen), wins: \(w), voted matchups: \(votedAppearances). Candidate for demotion in the model routing table.",
                    suggestedLane: .capability,
                    suggestedDomain: "compare"
                ))
            }
        }

        // Error-prone backends: 2+ errored outputs in the window.
        for (backend, errs) in errors.sorted(by: { $0.key < $1.key }) where errs.count >= 2 {
            out.append(FoundrySignal(
                source: "compare",
                severity: errs.count >= 5 ? .high : .medium,
                summary: "Compare: '\(backend)' errored in \(errs.count) runs",
                evidence: errs.suffix(3).joined(separator: "\n"),
                suggestedLane: .reliability,
                suggestedDomain: "compare"
            ))
        }

        // Unvoted backlog: 8+ runs and under half voted.
        if records.count >= 8, votedCount * 2 < records.count {
            out.append(FoundrySignal(
                source: "compare",
                severity: .low,
                summary: "Compare: only \(votedCount)/\(records.count) recent comparisons got a vote",
                evidence: "Votes drive the win-rate routing data. The Compare tab may need a lighter-weight vote affordance.",
                suggestedLane: .uxPolish,
                suggestedDomain: "ui:compare"
            ))
        }
        return out
    }
}
