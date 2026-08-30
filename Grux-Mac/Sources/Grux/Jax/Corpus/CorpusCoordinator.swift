import Foundation
import Combine

// Orchestrates Jax's corpus ingestion: the "you-ness" data pipeline that
// indexes the user's own authored voice (sent mail, their iMessages, Notes, Claude /
// ChatGPT exports, voice recordings) into SemanticMemory (on-device retrieval)
// and the companion RAG store (durable). Everything stays LOCAL.
//
// Pattern: @MainActor ObservableObject + static let shared (mirrors AppState,
// EmailAccountStore, SemanticMemory). Owns one actor ingester per source. The
// per-source status snapshot persists to Application Support/Grux/jax/corpus/
// status.json so Jax HQ / Settings can render last-run + counts immediately on
// launch without re-probing.
//
// Concurrency: ingesters are actors (IO off the main actor); the coordinator
// awaits them and publishes status back on the main actor. A single in-flight
// guard prevents overlapping full sweeps.
@MainActor
final class CorpusCoordinator: ObservableObject {
    static let shared = CorpusCoordinator()

    // Per-source UI-facing status. Codable so it round-trips to status.json.
    struct SourceStatus: Codable, Identifiable {
        let source: CorpusSource
        var permission: CorpusPermission
        var lastRunAt: Date?
        var lastNote: String
        var totalIndexed: Int      // cumulative items indexed across all runs
        var lastRunIndexed: Int
        var isRunning: Bool

        var id: String { source.rawValue }
        var displayName: String { source.displayName }
    }

    @Published private(set) var statuses: [CorpusSource: SourceStatus] = [:]
    @Published private(set) var isSweeping = false
    @Published private(set) var lastSweepSummary: String = ""

    // One ingester per source. RAGClient is shared (an actor, cheap to share).
    // Ingestion pushes large batches, so give it a generous timeout (the default
    // 10s is for interactive queries, not bulk corpus indexing).
    private let rag = RAGClient(timeout: 60)
    private lazy var ingesters: [CorpusSource: any CorpusIngester] = [
        .gmailSent:      GmailSentIngester(rag: rag),
        .iMessage:       IMessageIngester(rag: rag),
        .notes:          NotesIngester(rag: rag),
        .chatHistory:    ChatHistoryImporter(rag: rag),
        .voiceRecording: VoiceRecordingsIngester(rag: rag)
    ]

    private var scheduleTimer: Timer?

    private init() {
        loadStatus()
        // Seed any source missing from a prior snapshot with an unknown stub so
        // the UI shows all five immediately.
        for source in CorpusSource.allCases where statuses[source] == nil {
            statuses[source] = SourceStatus(
                source: source, permission: .unknown, lastRunAt: nil,
                lastNote: "Not run yet", totalIndexed: 0, lastRunIndexed: 0, isRunning: false
            )
        }
    }

    // Ordered list for the UI (stable, matches CorpusSource.allCases order).
    var orderedStatuses: [SourceStatus] {
        CorpusSource.allCases.compactMap { statuses[$0] }
    }

    // MARK: - Probe (cheap permission refresh, no ingest)

    // Refresh permission state for every source without running a full ingest.
    // Call on Jax HQ / Settings appear so the permission rows are current.
    func refreshPermissions() async {
        await withTaskGroup(of: (CorpusSource, CorpusPermission).self) { group in
            for (source, ingester) in ingesters {
                group.addTask { (source, await ingester.probe()) }
            }
            for await (source, perm) in group {
                if var s = statuses[source] {
                    s.permission = perm
                    if s.lastRunAt == nil { s.lastNote = perm.humanReason }
                    statuses[source] = s
                }
            }
        }
        saveStatus()
    }

    // MARK: - Run

    // Run a single source. Updates its status row and persists. Returns the
    // result so a caller (e.g. a per-source "Run" button) can react.
    @discardableResult
    func run(_ source: CorpusSource) async -> CorpusRunResult {
        guard let ingester = ingesters[source] else {
            return .blocked(.unknown)
        }
        setRunning(source, true)
        let result = await ingester.ingest()
        apply(result, to: source)
        setRunning(source, false)
        WakeLog.shared.log("corpus[\(source.rawValue)]: \(result.note) (rag+\(result.pushedToRAG))")
        return result
    }

    // Run every source sequentially (avoids hammering the mic/CPU/network all
    // at once; voice transcription in particular is CPU-heavy). Single in-flight
    // guard. Returns a one-line summary.
    @discardableResult
    func runAll() async -> String {
        guard !isSweeping else { return "corpus sweep already running" }
        isSweeping = true
        defer { isSweeping = false }

        var totalIndexed = 0
        for source in CorpusSource.allCases {
            let r = await run(source)
            totalIndexed += r.indexed
        }
        lastSweepSummary = "Corpus sweep: indexed \(totalIndexed) new items across \(CorpusSource.allCases.count) sources"
        WakeLog.shared.log("corpus: \(lastSweepSummary)")
        return lastSweepSummary
    }

    // MARK: - Scheduling (optional)

    // Light recurring sweep. Off by default; Jax HQ / Settings can enable it.
    // Default cadence is daily so fresh sent mail / messages / notes keep
    // the clone current without a manual trigger. Idempotent (replaces timer).
    func startSchedule(interval: TimeInterval = 24 * 60 * 60) {
        scheduleTimer?.invalidate()
        // First tick after a short delay so launch is not contended.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in _ = await CorpusCoordinator.shared.runAll() }
        }
        WakeLog.shared.log("corpus: scheduled sweep every \(Int(interval/3600))h")
    }

    func stopSchedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
    }

    // Probe permissions on launch (cheap). Does NOT auto-run a full sweep:
    // ingesting is user-triggered (or scheduled) so we never surprise-scan
    // chat.db / Notes behind a permission prompt at every launch.
    func bootstrap() {
        Task { @MainActor in await refreshPermissions() }
    }

    // MARK: - Status plumbing

    private func setRunning(_ source: CorpusSource, _ running: Bool) {
        guard var s = statuses[source] else { return }
        s.isRunning = running
        statuses[source] = s
    }

    private func apply(_ result: CorpusRunResult, to source: CorpusSource) {
        guard var s = statuses[source] else { return }
        s.permission = result.permission
        s.lastRunAt = Date()
        s.lastNote = result.note
        s.lastRunIndexed = result.indexed
        s.totalIndexed += result.indexed
        statuses[source] = s
        saveStatus()
    }

    // MARK: - Persistence

    private func loadStatus() {
        let loaded = Persistence.load([SourceStatus].self, from: Persistence.jaxCorpusStatusURL, fallback: [])
        for s in loaded { statuses[s.source] = s }
    }

    private func saveStatus() {
        Persistence.save(orderedStatuses, to: Persistence.jaxCorpusStatusURL)
    }
}
