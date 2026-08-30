import Foundation

// Stage 1 of the Foundry loop: Sense. Fans out every registered
// FoundrySignalSource concurrently, isolates failures per source (one broken
// log format never blanks the pass), and returns a single report the
// ProposalEngine consumes. Read-only by design, harvesting mutates nothing.
struct SignalHarvestReport: Sendable {
    var signals: [FoundrySignal]
    // sourceName -> error description for every source that threw.
    var sourceErrors: [String: String]
    var startedAt: Date
    var finishedAt: Date

    var bySeverity: [FoundrySignal.Severity: Int] {
        var counts: [FoundrySignal.Severity: Int] = [:]
        for s in signals { counts[s.severity, default: 0] += 1 }
        return counts
    }
}

struct SignalHarvester: Sendable {

    var sources: [any FoundrySignalSource]

    init(sources: [any FoundrySignalSource]) {
        self.sources = sources
    }

    // The default local-only lineup: everything that reads disk state. The
    // UX audit lane (app launch + vision spend) is opt-in via uxAudit.
    static func standard(uxAudit: UXAuditSource? = nil) -> SignalHarvester {
        var sources: [any FoundrySignalSource] = [
            TelemetrySignalSource(),
            TranscriptSignalSource(),
            SwarmSignalSource(),
            FlakeSignalSource(),
            CompareSignalSource()
        ]
        if let uxAudit { sources.append(uxAudit) }
        return SignalHarvester(sources: sources)
    }

    func harvest() async -> SignalHarvestReport {
        let startedAt = Date()
        var signals: [FoundrySignal] = []
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, Result<[FoundrySignal], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.sourceName, .success(try await source.harvest()))
                    } catch {
                        return (source.sourceName, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let s): signals += s
                case .failure(let err): errors[name] = String(describing: err)
                }
            }
        }

        // Deterministic order: severity (high first), then source, then summary.
        signals.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.source != b.source { return a.source < b.source }
            return a.summary < b.summary
        }

        return SignalHarvestReport(
            signals: signals,
            sourceErrors: errors,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }
}
