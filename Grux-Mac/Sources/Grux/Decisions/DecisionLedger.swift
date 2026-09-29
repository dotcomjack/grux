import Foundation
import Combine

struct DecisionLedgerEntry: Codable, Equatable {
    let surface: String
    let provider: DecisionProviderKind
    let latencyMs: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
    let at: Date
    /// One line a person can read: what was heard and what was decided.
    let summary: String
    /// The provider that was asked first and gave no answer, when `provider`
    /// answered in its place. `latencyMs` then covers both, end to end.
    let fallbackFrom: DecisionProviderKind?
    /// With `fallbackFrom`: the call that gave no answer may still have been
    /// billed (it timed out, or the server failed after taking it).
    let fallbackMayHaveBilled: Bool?

    init(surface: String, provider: DecisionProviderKind, latencyMs: Int, inputTokens: Int,
         outputTokens: Int, at: Date, summary: String, fallbackFrom: DecisionProviderKind? = nil,
         fallbackMayHaveBilled: Bool? = nil) {
        self.surface = surface
        self.fallbackFrom = fallbackFrom
        self.fallbackMayHaveBilled = fallbackMayHaveBilled
        self.provider = provider
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.at = at
        self.summary = summary
        self.costUSD = provider == .jev
            ? Double(inputTokens) / 1_000_000 * DecisionLedger.jevInputUSDPerMillion
            : 0
    }
}

/// Every decision, with its latency and cost, kept locally as one JSON line
/// per record. This is what the orb hover, the Usage card and the morning
/// briefing read. Nothing here is sent anywhere.
@MainActor
final class DecisionLedger: ObservableObject {
    static let shared = DecisionLedger(storeURL: Persistence.supportDir.appendingPathComponent("decisions.jsonl"))

    /// Jev input price observed 2026-09-20. Output is free. Change here only.
    static let jevInputUSDPerMillion = 0.042

    @Published private(set) var last: DecisionLedgerEntry?
    @Published private(set) var recent: [DecisionLedgerEntry] = []

    private let storeURL: URL?
    private let maxRecent = 2_000

    /// Remote decisions since midnight, counted as they are recorded rather
    /// than read off `recent`, which keeps the last 2,000 rows of every
    /// provider: a daily cap above what that window happens to hold would
    /// never trip, and Tuning would be promising a limit nothing enforces.
    private var remoteDay: Date = .distantPast
    private var remoteCount = 0

    init(storeURL: URL?) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recent = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(DecisionLedgerEntry.self, from: Data($0)) }
            last = recent.last
            recent.forEach(countRemote)
        }
    }

    func record(_ r: DecisionLedgerEntry) {
        countRemote(r)
        recent.append(r)
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
        last = r
        guard let storeURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(r) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: storeURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: storeURL, options: .atomic)
        }
    }

    /// How many decisions went to Jev on the day `now` falls in.
    func remoteDecisions(on now: Date = Date()) -> Int {
        Calendar.current.isDate(remoteDay, inSameDayAs: now) ? remoteCount : 0
    }

    /// A remote call counts when it answered, or when it gave no answer but
    /// may still have been billed (timed out, or a server error).
    private func countRemote(_ r: DecisionLedgerEntry) {
        guard r.provider == .jev || (r.fallbackFrom == .jev && r.fallbackMayHaveBilled == true) else { return }
        if Calendar.current.isDate(remoteDay, inSameDayAs: r.at) {
            remoteCount += 1
        } else if r.at > remoteDay {
            remoteDay = r.at
            remoteCount = 1
        }
    }

    func today(now: Date = Date()) -> (count: Int, avgLatencyMs: Int, costUSD: Double) {
        let start = Calendar.current.startOfDay(for: now)
        let rows = recent.filter { $0.at >= start }
        guard !rows.isEmpty else { return (0, 0, 0) }
        let avg = rows.map(\.latencyMs).reduce(0, +) / rows.count
        return (rows.count, avg, rows.map(\.costUSD).reduce(0, +))
    }
}
