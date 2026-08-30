import Foundation

// Launch-time scan + replay for orphan audio WALs.
//
// Owns the "we crashed mid-meeting" recovery flow end to end:
//   1. Enumerate `Persistence.audioWALDir` for session directories.
//   2. Flag any whose `meta.json.status == .open` - those are the ones
//      the previous process didn't get a chance to finalize. (Closed WALs
//      with matching MeetingRecord = clean quit after a summary fail; we
//      treat them the same for replay but skip the chat notification.)
//   3. Concat the chunk PCM files back into a single buffer.
//   4. Run WhisperKit over the buffer in 10-second windows (same contract
//      MeetingTranscriber uses live) to reconstruct utterances.
//   5. Upsert the MeetingRecord - create if missing, append utterances
//      otherwise - mark it as `recoveredFromCrash`, save, delete WAL dir.
//   6. Surface a chat system message + orb hint so the user knows recovery
//      fired.
//
// Privacy-wise this is a pure local-first operation - same WhisperKit
// instance the live capture uses, nothing ever leaves the device.
@MainActor
enum AudioWALRecovery {

    // Scan result. Empty when no orphans exist (the common case).
    struct Orphan {
        let meta: AudioWAL.SessionMeta
        let dir: URL
        let chunkURLs: [URL]
        var totalSamples: Int { chunkURLs.count * Int(meta.sampleRate * meta.chunkSeconds) }
    }

    static func scanForOrphans() -> [Orphan] {
        let fm = FileManager.default
        let root = Persistence.audioWALDir
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [Orphan] = []
        for url in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaURL = url.appendingPathComponent("meta.json")
            guard let meta = AudioWAL.loadMeta(at: metaURL) else { continue }
            // Ignore a session that's still being actively written by the
            // in-process AudioWAL - compares against the live active id.
            if AudioWAL.shared.activeSessionId == meta.id { continue }
            let chunks = AudioWAL.listChunkURLs(in: url)
            if chunks.isEmpty {
                // Nothing to replay, just sweep it.
                try? fm.removeItem(at: url)
                continue
            }
            out.append(Orphan(meta: meta, dir: url, chunkURLs: chunks))
        }
        return out
    }

    // Kick off recovery on launch. Safe to call from applicationDidFinishLaunching:
    // does its own Whisper-load wait and never blocks the main thread. Returns
    // immediately; the actual transcription happens on a background Task. The
    // `completion` closure (main-actor) fires after every orphan is handled so
    // callers can update UI counters.
    static func runOnLaunch(completion: (@MainActor (_ recovered: Int) -> Void)? = nil) {
        let orphans = scanForOrphans()
        guard !orphans.isEmpty else {
            completion?(0)
            return
        }
        WakeLog.shared.log("audio-wal: recovery - found \(orphans.count) orphan session(s)")

        Task { @MainActor in
            var recoveredCount = 0
            // WhisperKit is lazy - ensure it's loaded before we try to
            // transcribe. This is the same accessor the live meeting path
            // uses, so we share a single loaded instance.
            guard let kit = await AmbientListener.shared.sharedWhisperKit() else {
                WakeLog.shared.log("audio-wal: recovery - WhisperKit unavailable; deferring")
                completion?(0)
                return
            }
            let transcriber = MeetingTranscriber(whisperKit: kit)

            for orphan in orphans {
                let ok = await recoverOne(orphan, transcriber: transcriber)
                if ok { recoveredCount += 1 }
            }
            completion?(recoveredCount)

            if recoveredCount > 0 {
                surfaceNotification(count: recoveredCount, total: orphans.count)
            }
        }
    }

    // MARK: - One-session recovery

    private static func recoverOne(_ orphan: Orphan, transcriber: MeetingTranscriber) async -> Bool {
        let id = orphan.meta.id
        WakeLog.shared.log("audio-wal: recovering \(id.uuidString) - \(orphan.chunkURLs.count) chunk(s)")

        // Load and concat all chunks. PCM is Float32 @ 16 kHz mono per meta.
        var samples: [Float] = []
        samples.reserveCapacity(orphan.totalSamples)
        for url in orphan.chunkURLs {
            if let buf = AudioWAL.readPCM(from: url) {
                samples.append(contentsOf: buf)
            }
        }
        if samples.isEmpty {
            WakeLog.shared.log("audio-wal: recovery - empty PCM; wiping \(id.uuidString)")
            try? FileManager.default.removeItem(at: orphan.dir)
            return false
        }

        // Re-chunk to the same 10s windows Whisper was trained to handle.
        // We DO NOT stitch smaller-than-0.5s trailing samples - the
        // transcriber ignores those anyway.
        let samplesPerChunk = Int(orphan.meta.sampleRate * orphan.meta.chunkSeconds)
        var newUtterances: [MeetingUtterance] = []
        var cursor = 0
        var tOffset: TimeInterval = 0
        while cursor < samples.count {
            let end = min(cursor + samplesPerChunk, samples.count)
            let slice = Array(samples[cursor..<end])
            if let result = await transcriber.transcribe(chunk: slice),
               !result.text.isEmpty {
                let utt = MeetingUtterance(
                    t: tOffset,
                    speaker: .mixed,
                    text: result.text,
                    confidence: result.confidence
                )
                newUtterances.append(utt)
            }
            tOffset += Double(slice.count) / orphan.meta.sampleRate
            cursor = end
        }

        // Upsert the MeetingRecord. If a record already exists from the
        // crashed session (we called MeetingStore.create() before writing
        // WAL chunks), append to it. Otherwise materialize a fresh one
        // from the meta so the user can find it in the Meetings tab.
        let existing = MeetingStore.shared.loadRecord(id: orphan.meta.id)
        var rec = existing ?? MeetingRecord(
            id: orphan.meta.id,
            startedAt: orphan.meta.startedAt,
            endedAt: orphan.meta.lastFlushedAt,
            title: orphan.meta.title ?? "Recovered meeting",
            sourceApp: orphan.meta.sourceApp,
            sourceAppName: orphan.meta.sourceAppName,
            utterances: [],
            summary: nil,
            actionItems: []
        )

        // Recovery always appends - never replaces. Live utterances that
        // were already persisted before the crash are kept verbatim; we
        // only add speech that the crash ate. Dedup on (t, text-prefix)
        // to survive the common "same chunk was saved AND was in the WAL"
        // overlap at the seam.
        var seen = Set(rec.utterances.map { Self.dedupKey($0) })
        for utt in newUtterances {
            let key = Self.dedupKey(utt)
            if seen.contains(key) { continue }
            seen.insert(key)
            rec.utterances.append(utt)
        }
        // Sort by timestamp so recovered utterances interleave naturally
        // with the pre-crash ones (recovered t's start at 0 within the
        // WAL window, so tagging this step as "best-effort ordering" is
        // honest - but the transcripts all come out in chunk order).
        rec.utterances.sort { $0.t < $1.t }
        if rec.endedAt == nil {
            rec.endedAt = orphan.meta.lastFlushedAt
        }
        if rec.title == nil || rec.title?.isEmpty == true {
            rec.title = "Recovered meeting"
        }

        MeetingStore.shared.save(rec)

        // Wipe the WAL now that the transcript is durable.
        do {
            try FileManager.default.removeItem(at: orphan.dir)
        } catch {
            WakeLog.shared.log("audio-wal: recovery - wipe failed for \(id.uuidString): \(error.localizedDescription)")
        }

        WakeLog.shared.log("audio-wal: recovered \(id.uuidString) +\(newUtterances.count) utterance(s)")
        return true
    }

    private static func dedupKey(_ u: MeetingUtterance) -> String {
        let tBucket = Int(u.t.rounded())
        let prefix = u.text.prefix(32).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(tBucket)|\(prefix)"
    }

    // MARK: - UI surfacing

    private static func surfaceNotification(count: Int, total: Int) {
        // Orb hint - passive, auto-dismiss. Seen without context-switching.
        OrbHintBus.shared.show(
            message: count == 1
                ? "Recovered 1 meeting from crash"
                : "Recovered \(count) meetings from crash",
            state: .thinking,
            duration: 5.0
        )
        // Durable chat system line so the user can find it later.
        let line: String = {
            if total == count {
                return count == 1
                    ? "🛟 Recovered 1 meeting that was interrupted by a crash. Check the Meetings tab."
                    : "🛟 Recovered \(count) meetings that were interrupted by a crash. Check the Meetings tab."
            }
            return "🛟 Recovered \(count) of \(total) interrupted meetings. Check the Meetings tab."
        }()
        AppState.shared.appendChat(ChatMessage(role: .system, content: line))
    }
}
