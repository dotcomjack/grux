import Foundation

// Crash-safe write-ahead log for meeting audio.
//
// Why this exists: Grux persists each transcribed utterance to
// MeetingStore the moment Whisper returns. But the audio in the mixer's
// ring buffer between chunk flushes (up to `chunkSeconds`) + any chunk
// that finished mixing but hadn't reached Whisper before a crash/SIGKILL
// would vanish silently. Omi's `/wals` gave them the same guarantee for
// their phone+cloud path; this is the Mac-native equivalent, scoped to
// the local-first posture (no backend, no sync, no batching).
//
// On-disk layout (under `Persistence.audioWALDir`):
//
//   audio-wal/
//     <meeting-uuid>/
//       meta.json                 ← session metadata + status
//       chunk-000000.pcm          ← one chunk per file, numbered
//       chunk-000001.pcm          ← raw Float32 LE 16 kHz mono PCM
//       …
//
// Retention: only the most recent `retentionChunks` chunk files are
// kept on disk at any time. Older ones are deleted after each append,
// so a single rolling WAL never exceeds ~6 MB for a 10s-chunk × 9-chunk
// (90 s) window. Clean `finalize()` wipes the whole session dir.
//
// Recovery: `AudioWALRecovery.scanForOrphans()` walks the root dir on
// launch and returns any session whose `meta.json` is still marked
// `open` - i.e. a previous process didn't get to call `finalize(clean:)`.
// Those PCM files are concat'd in order and replayed through WhisperKit.
@MainActor
final class AudioWAL {
    static let shared = AudioWAL()

    // Layout format - bumped whenever meta.json or chunk encoding changes
    // in a way the recovery path needs to know about. Old WALs with a
    // different formatVersion are archived to a `corrupt/` sibling dir
    // rather than being force-replayed with the wrong decoder.
    static let formatVersion: Int = 1

    // Single-chunk size (in seconds) - must match MeetingAudioMixer.chunkSeconds
    // or recovery replays out-of-tempo. Kept as a stored property so tests
    // can create a WAL with a different chunk size without reaching into
    // the mixer.
    let chunkSeconds: Double

    // How many chunks to retain on disk. At 10 s/chunk that's ~90 s of
    // rolling history. Configurable via settings so a power user can
    // trade disk for margin.
    let retentionChunks: Int

    // Audio format constants mirror MeetingAudioMixer's output.
    let sampleRate: Double = MeetingAudioMixer.sampleRate
    let channels: Int = 1
    let bytesPerSample: Int = MemoryLayout<Float>.size   // Float32

    struct SessionMeta: Codable {
        var id: UUID
        var startedAt: Date
        var sourceApp: String?
        var sourceAppName: String?
        var title: String?
        var lastFlushedAt: Date
        var status: Status
        var chunkSeconds: Double
        var sampleRate: Double
        var channels: Int
        var bytesPerSample: Int
        var retentionChunks: Int
        var chunksWritten: Int
        var formatVersion: Int

        enum Status: String, Codable { case open, closed }
    }

    private struct ActiveSession {
        let id: UUID
        let dir: URL
        var meta: SessionMeta
        var nextChunkIndex: Int
    }

    private var active: ActiveSession?

    // Serialize file IO off the main actor to avoid blocking the UI on
    // the 10-s flush tick. All disk work happens on this queue; the
    // actor guards the `active` field.
    private let ioQueue = DispatchQueue(label: "grux.audio-wal.io", qos: .utility)

    init(chunkSeconds: Double = 10.0, retentionChunks: Int = 9) {
        self.chunkSeconds = chunkSeconds
        self.retentionChunks = retentionChunks
    }

    var isActive: Bool { active != nil }

    var activeSessionId: UUID? { active?.id }

    // Must be called on the main actor before any `appendChunk`. Idempotent
    // for the same meeting id - a second begin with a matching UUID is
    // treated as a resume (no data wiped). Re-beginning with a different
    // UUID while another session is open is a bug (we log + close the
    // previous one as `closed` to avoid leaving a phantom open WAL).
    func begin(meetingId: UUID, sourceApp: String?, sourceAppName: String?, title: String?) {
        if let existing = active, existing.id != meetingId {
            WakeLog.shared.log("audio-wal: begin() called with new id while \(existing.id) still active - closing previous")
            finalize(clean: false)
        }
        let dir = Persistence.audioWALDir.appendingPathComponent(meetingId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            WakeLog.shared.log("audio-wal: mkdir failed for \(dir.path): \(error.localizedDescription)")
            return
        }

        // Prefer existing meta if we're resuming the same id (e.g. a stale
        // manifest from earlier in the same process).
        var meta: SessionMeta
        let metaURL = dir.appendingPathComponent("meta.json")
        if let existing = Self.loadMeta(at: metaURL), existing.id == meetingId {
            meta = existing
            meta.status = .open
            meta.lastFlushedAt = Date()
        } else {
            meta = SessionMeta(
                id: meetingId,
                startedAt: Date(),
                sourceApp: sourceApp,
                sourceAppName: sourceAppName,
                title: title,
                lastFlushedAt: Date(),
                status: .open,
                chunkSeconds: chunkSeconds,
                sampleRate: sampleRate,
                channels: channels,
                bytesPerSample: bytesPerSample,
                retentionChunks: retentionChunks,
                chunksWritten: 0,
                formatVersion: Self.formatVersion
            )
        }
        Self.writeMeta(meta, to: metaURL)

        // Determine next chunk index by scanning existing files. Lets us
        // resume across a re-begin without a full disk wipe if the user
        // hits pause→resume (future surface) or the pipeline restarts.
        let nextIdx: Int = {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
            let indices = items.compactMap { name -> Int? in
                guard name.hasPrefix("chunk-"), name.hasSuffix(".pcm") else { return nil }
                let core = name.dropFirst("chunk-".count).dropLast(".pcm".count)
                return Int(core)
            }
            return (indices.max() ?? -1) + 1
        }()

        active = ActiveSession(id: meetingId, dir: dir, meta: meta, nextChunkIndex: nextIdx)
        WakeLog.shared.log("audio-wal: begin id=\(meetingId.uuidString) dir=\(dir.lastPathComponent) nextIdx=\(nextIdx)")
    }

    // Append a fresh PCM chunk (Float32 16 kHz mono) and prune older chunks.
    // Non-blocking: fire-and-forget on `ioQueue`. A failed write is logged
    // but never thrown - the capture pipeline MUST NOT stall on disk IO.
    func appendChunk(_ samples: [Float]) {
        guard var session = active else { return }
        guard !samples.isEmpty else { return }
        let idx = session.nextChunkIndex
        session.nextChunkIndex += 1
        session.meta.chunksWritten += 1
        session.meta.lastFlushedAt = Date()
        active = session

        let dir = session.dir
        let retention = retentionChunks
        let metaURL = dir.appendingPathComponent("meta.json")
        let metaCopy = session.meta

        ioQueue.async {
            let chunkURL = dir.appendingPathComponent(Self.chunkFileName(index: idx))
            do {
                try Self.writePCM(samples, to: chunkURL)
            } catch {
                WakeLog.shared.log("audio-wal: write chunk \(idx) failed: \(error.localizedDescription)")
                return
            }
            Self.writeMeta(metaCopy, to: metaURL)
            Self.pruneOldChunks(dir: dir, keepMostRecent: retention)
        }
    }

    // Close the current session. `clean == true` means the MeetingRecord
    // was safely persisted by MeetingStore - we can delete the WAL entirely.
    // `clean == false` preserves the files for recovery (or is a no-op if
    // there's no active session, e.g. the app terminates without an active
    // capture).
    @discardableResult
    func finalize(clean: Bool) -> URL? {
        guard let session = active else { return nil }
        active = nil
        let dir = session.dir
        let id = session.id
        if clean {
            ioQueue.async {
                // Never delete out of a just-restored tree.
                guard !Persistence.writesSuspended else { return }
                do {
                    try FileManager.default.removeItem(at: dir)
                    WakeLog.shared.log("audio-wal: finalize clean - removed \(id.uuidString)")
                } catch {
                    WakeLog.shared.log("audio-wal: finalize clean - remove failed: \(error.localizedDescription)")
                }
            }
            return nil
        } else {
            // Mark as closed but leave files. Used by
            // applicationWillTerminate so we know this WAL was flushed
            // through a graceful quit (vs a SIGKILL) but the surrounding
            // MeetingRecord may or may not have finished summarizing.
            // Recovery on next launch will still decide whether to
            // replay based on the MeetingRecord's own state.
            var meta = session.meta
            meta.status = .closed
            meta.lastFlushedAt = Date()
            let metaURL = dir.appendingPathComponent("meta.json")
            Self.writeMeta(meta, to: metaURL)
            WakeLog.shared.log("audio-wal: finalize preserve - marked closed \(id.uuidString)")
            return dir
        }
    }

    // Synchronous flush for use in applicationWillTerminate - we have ~5s
    // before macOS kills us, so blocking here is fine (and required, since
    // the async queue may not drain in time).
    func flushSync() {
        ioQueue.sync { /* barrier */ }
    }

    // MARK: - Static helpers (usable from recovery path off-main)

    static func chunkFileName(index: Int) -> String {
        String(format: "chunk-%06d.pcm", index)
    }

    static func writePCM(_ samples: [Float], to url: URL) throws {
        // Restore kill switch: the WAL lives in the backed-up-and-restored
        // supportDir tree; applicationWillTerminate's finalize/flushSync
        // (and any in-flight capture) must not write into a restored tree.
        guard !Persistence.writesSuspended else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    static func readPCM(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let stride = MemoryLayout<Float>.size
        guard data.count % stride == 0 else { return nil }
        let count = data.count / stride
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    static func loadMeta(at url: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionMeta.self, from: data)
    }

    static func writeMeta(_ meta: SessionMeta, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(meta) else { return }
        // Guarded for the same reason as writePCM (restore kill switch).
        Persistence.write(data, to: url)
    }

    static func pruneOldChunks(dir: URL, keepMostRecent: Int) {
        let fm = FileManager.default
        guard keepMostRecent > 0 else { return }
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let chunks: [(index: Int, name: String)] = items.compactMap { name in
            guard name.hasPrefix("chunk-"), name.hasSuffix(".pcm") else { return nil }
            let core = name.dropFirst("chunk-".count).dropLast(".pcm".count)
            guard let idx = Int(core) else { return nil }
            return (idx, name)
        }
        guard chunks.count > keepMostRecent else { return }
        let sorted = chunks.sorted { $0.index < $1.index }
        let toDrop = sorted.prefix(chunks.count - keepMostRecent)
        for item in toDrop {
            let url = dir.appendingPathComponent(item.name)
            try? fm.removeItem(at: url)
        }
    }

    // List chunk files in a session dir in ascending order.
    static func listChunkURLs(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let chunks: [(index: Int, url: URL)] = items.compactMap { name in
            guard name.hasPrefix("chunk-"), name.hasSuffix(".pcm") else { return nil }
            let core = name.dropFirst("chunk-".count).dropLast(".pcm".count)
            guard let idx = Int(core) else { return nil }
            return (idx, dir.appendingPathComponent(name))
        }
        return chunks.sorted { $0.index < $1.index }.map { $0.url }
    }
}
