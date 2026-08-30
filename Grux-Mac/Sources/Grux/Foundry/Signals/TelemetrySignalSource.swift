import Foundation

// Telemetry lane of the Sense pass. Three streams, all local-first:
//
//   1. fs-audit.log: the NDJSON audit trail FilesystemToolState writes for
//      every fs_read / fs_list call. Denials and rate-limit rejections inside
//      the lookback window become reliability signals (a tool that keeps
//      getting denied is either misconfigured or probing outside its sandbox).
//   2. *.log error scan: any other .log file under Application Support/Grux
//      is grep-scanned for error-shaped lines. Clusters become signals.
struct TelemetrySignalSource: FoundrySignalSource {

    let sourceName = "telemetry"

    // Directory scanned for fs-audit.log and other *.log files. Injectable so
    // tests point at a fixture dir instead of the real support dir.
    var supportDir: URL
    var lookback: TimeInterval
    var now: @Sendable () -> Date

    init(
        supportDir: URL = Persistence.supportDir,
        lookback: TimeInterval = 7 * 24 * 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supportDir = supportDir
        self.lookback = lookback
        self.now = now
    }

    func harvest() async throws -> [FoundrySignal] {
        var signals: [FoundrySignal] = []
        signals += harvestFSAudit()
        signals += harvestErrorLogs()
        return signals
    }

    // MARK: - fs-audit.log

    private func harvestFSAudit() -> [FoundrySignal] {
        let url = supportDir.appendingPathComponent("fs-audit.log")
        let asOf = now()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.signalsFromFSAudit(raw, since: asOf.addingTimeInterval(-lookback), asOf: asOf, staleAfter: lookback)
    }

    // Parses the NDJSON audit lines FilesystemToolState writes:
    //   {"ts":"...","tool":"fs_read","path":"...","resolved":"...",
    //    "outcome":"ok|denied|...","bytes":N,"reason":"..."}
    // staleAfter guards a dead-source case: if the newest line is older than
    // this window, the audit writer has gone silent (no fs_read / fs_list calls
    // in a long while). Rather than mine month-old denials as if they were
    // fresh, or silently emit nothing (which hides the dead source forever),
    // we emit one low-severity meta-signal so the Foundry notices the gap.
    // staleAfter defaults to .infinity (and asOf to .distantPast) so the
    // staleness guard never fires unless a caller opts in by passing both.
    // This keeps the existing 2-arg test callers compiling and behaving as
    // before; production harvestFSAudit passes real values to enable the guard.
    // Exposed for tests.
    static func signalsFromFSAudit(_ raw: String, since: Date, asOf: Date = .distantPast, staleAfter: TimeInterval = .infinity) -> [FoundrySignal] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        func parseTS(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }

        struct Denial { let outcome: String; let reason: String; let path: String }
        var denials: [Denial] = []
        var total = 0
        var newest: Date? = nil

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let ts = obj["ts"] as? String, let date = parseTS(ts) {
                if newest == nil || date > newest! { newest = date }
                if date < since { continue }
            }
            total += 1
            let outcome = (obj["outcome"] as? String ?? "").lowercased()
            guard !outcome.isEmpty, outcome != "ok" else { continue }
            denials.append(Denial(
                outcome: outcome,
                reason: obj["reason"] as? String ?? "",
                path: obj["path"] as? String ?? ""
            ))
        }

        // Dead-source guard. If we have a timestamped newest line and it is
        // older than the staleness window, the source is silent. Report that
        // (low severity, code-health) and do NOT emit the stale denials as if
        // they were current. A file with lines but no parseable timestamps, or
        // an empty/missing file, falls through to the normal path below.
        if let newest, asOf.timeIntervalSince(newest) > staleAfter {
            let days = Int((asOf.timeIntervalSince(newest) / 86400).rounded())
            return [FoundrySignal(
                source: "telemetry",
                severity: .low,
                summary: "fs-audit: log silent for \(days)d (last entry \(iso.string(from: newest))), no fresh filesystem-tool activity to harvest",
                evidence: "Newest fs-audit.log line predates the \(Int(staleAfter / 86400))d freshness window. The audit writer is wired but no fs_read / fs_list calls have run, so this source has no current signal. Treat the source as silent, not the system as healthy.",
                suggestedLane: .codeHealth,
                suggestedDomain: "telemetry"
            )]
        }

        // Not stale (or no parseable timestamps to judge freshness): fall
        // through and harvest the in-window denials as before.
        guard !denials.isEmpty else { return [] }
        var byOutcome: [String: [Denial]] = [:]
        for d in denials { byOutcome[d.outcome, default: []].append(d) }

        return byOutcome.map { outcome, group in
            let sampleLines = group.prefix(5)
                .map { "\($0.outcome) \($0.path) (\($0.reason))" }
                .joined(separator: "\n")
            let severity: FoundrySignal.Severity = group.count >= 10 ? .high : (group.count >= 3 ? .medium : .low)
            return FoundrySignal(
                source: "telemetry",
                severity: severity,
                summary: "fs-audit: \(group.count) '\(outcome)' filesystem-tool outcomes (of \(total) audited calls)",
                evidence: sampleLines,
                suggestedLane: .reliability,
                suggestedDomain: "filesystem-tool"
            )
        }.sorted { $0.summary < $1.summary }
    }

    // MARK: - generic error logs

    private func harvestErrorLogs() -> [FoundrySignal] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) else { return [] }
        var signals: [FoundrySignal] = []
        for url in items where url.pathExtension == "log" && url.lastPathComponent != "fs-audit.log" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let sig = Self.signalFromErrorLog(named: url.lastPathComponent, contents: raw) {
                signals.append(sig)
            }
        }
        return signals.sorted { $0.summary < $1.summary }
    }

    // Exposed for tests. Counts error-shaped lines; emits one signal per log
    // file that has any.
    static func signalFromErrorLog(named name: String, contents: String) -> FoundrySignal? {
        let markers = ["error", "fatal", "exception", "crash", "failed"]
        var hits: [String] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                hits.append(String(line))
            }
        }
        guard !hits.isEmpty else { return nil }
        let severity: FoundrySignal.Severity = hits.count >= 20 ? .high : (hits.count >= 5 ? .medium : .low)
        return FoundrySignal(
            source: "telemetry",
            severity: severity,
            summary: "\(name): \(hits.count) error-shaped log lines",
            evidence: hits.suffix(5).joined(separator: "\n"),
            suggestedLane: .reliability,
            suggestedDomain: "logs"
        )
    }
}
