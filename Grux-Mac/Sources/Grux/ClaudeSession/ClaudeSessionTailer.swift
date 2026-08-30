import Foundation
import Combine

// Tails a selected set of Claude Code JSONL session logs. On a 2s timer,
// reads the newly-appended bytes of each tracked file, parses only those
// lines, and folds them into a rolling ClaudeSessionSnapshot published
// by sessionId.
//
// Design notes:
// * We accumulate parsed entries in memory per-tracked-session. Typical
//   sessions are a few MB; a few thousand parsed entries is fine.
// * A half-written final line is stashed in `pendingLine` and merged with
//   the next tick's bytes. Claude appends line-at-a-time so this is rare
//   but the check is cheap.
// * `track(_:)` is the single entry point the caller uses to say "tail
//   these sessions, stop tailing anything not in the set". Existing per-
//   file offsets are preserved when a session stays tracked across calls.
@MainActor
final class ClaudeSessionTailer: ObservableObject {

    static let shared = ClaudeSessionTailer()

    @Published private(set) var snapshotsBySessionId: [String: ClaudeSessionSnapshot] = [:]

    private struct TrackedFile {
        let sessionId: String
        var offset: UInt64
        var entries: [ClaudeSessionEntry]
        var pendingLine: String
    }

    private var tracked: [URL: TrackedFile] = [:]
    private var timer: Timer?
    // Per-session fold state, so a tick costs the new bytes and not the whole file.
    private var accumulators: [String: ClaudeSessionJSONL.SnapshotAccumulator] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Replace the tracked set. Sessions that were already tracked keep their
    // file offset; new ones start at offset 0 so their full history gets
    // folded in on the next refresh.
    func track(sessions: [ClaudeSessionDescriptor]) {
        var next: [URL: TrackedFile] = [:]
        for desc in sessions {
            if let existing = tracked[desc.fileURL], existing.sessionId == desc.sessionId {
                next[desc.fileURL] = existing
            } else {
                next[desc.fileURL] = TrackedFile(
                    sessionId: desc.sessionId, offset: 0, entries: [], pendingLine: ""
                )
            }
        }
        // Drop snapshots for sessions no longer tracked.
        let trackedIDs = Set(next.values.map { $0.sessionId })
        snapshotsBySessionId = snapshotsBySessionId.filter { trackedIDs.contains($0.key) }
        accumulators = accumulators.filter { trackedIDs.contains($0.key) }
        tracked = next
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        guard !tracked.isEmpty else { return }
        var updatedTracked = tracked
        var updatedSnapshots = snapshotsBySessionId

        for (url, entry) in tracked {
            guard let (newEntry, appendedEntries) = readAppended(from: url, tracked: entry) else {
                continue
            }
            var mutable = entry
            mutable.offset = newEntry.offset
            mutable.pendingLine = newEntry.pendingLine
            updatedTracked[url] = mutable

            // Fold ONLY what arrived. This used to append to `mutable.entries` and then
            // re-fold the whole accumulated history every tick, on a 1.5 second timer,
            // against transcripts that reach several hundred megabytes. That was the app's
            // dominant idle cost, and it grew with session length, so the longer Grux ran
            // the hotter it got. The accumulator makes each tick proportional to the new
            // bytes instead of to the file.
            //
            // `entries` is no longer accumulated either. Nothing read it back, and holding
            // every parsed entry of a 537MB transcript in memory was its own problem.
            guard !appendedEntries.isEmpty else { continue }
            var acc = accumulators[mutable.sessionId]
                ?? ClaudeSessionJSONL.SnapshotAccumulator(sessionId: mutable.sessionId)
            ClaudeSessionJSONL.fold(appendedEntries, into: &acc)
            accumulators[mutable.sessionId] = acc
            if let snap = ClaudeSessionJSONL.build(acc) {
                updatedSnapshots[mutable.sessionId] = snap
            }
        }

        tracked = updatedTracked
        snapshotsBySessionId = updatedSnapshots
    }

    // Reads bytes appended since last seek. Returns the new offset + pending
    // line remainder plus the parsed complete lines, or nil if the file can't
    // be opened / nothing new.
    private func readAppended(
        from url: URL,
        tracked: TrackedFile
    ) -> ((offset: UInt64, pendingLine: String), [ClaudeSessionEntry])? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        do { try fh.seek(toOffset: tracked.offset) } catch { return nil }

        let data: Data
        do { data = try fh.readToEnd() ?? Data() } catch { return nil }
        guard !data.isEmpty else { return nil }

        let newOffset = tracked.offset + UInt64(data.count)
        let appended = String(data: data, encoding: .utf8) ?? ""
        let buffer = tracked.pendingLine + appended

        guard let lastNewline = buffer.lastIndex(of: "\n") else {
            // No complete line yet - stash the whole buffer for next tick.
            return ((newOffset, buffer), [])
        }

        let complete = buffer[..<lastNewline]
        let tail = String(buffer[buffer.index(after: lastNewline)...])

        var parsed: [ClaudeSessionEntry] = []
        for raw in complete.split(whereSeparator: { $0 == "\n" }) {
            if let entry = ClaudeSessionJSONL.parseLine(String(raw)) {
                parsed.append(entry)
            }
        }
        return ((newOffset, tail), parsed)
    }
}
