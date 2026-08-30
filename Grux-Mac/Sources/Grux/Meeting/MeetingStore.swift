import Foundation

// JSON-on-disk store for meetings. Mirrors the rest of Grux persistence: one
// record per file in ~/Library/Application Support/Grux/meetings/ plus a
// compact index.json for fast listings. No CoreData; no schema migrations.
@MainActor
final class MeetingStore {
    static let shared = MeetingStore()

    private(set) var index: [MeetingIndexEntry] = []
    private let indexLock = NSLock()

    private init() {
        _ = Persistence.meetingsDir   // create directory eagerly
        loadIndex()
    }

    // MARK: - Write path

    func create(title: String?, sourceApp: String?, sourceAppName: String?) -> MeetingRecord {
        let rec = make(title: title, sourceApp: sourceApp, sourceAppName: sourceAppName)
        commit(rec)
        return rec
    }

    /// Builds a record WITHOUT writing it to disk.
    ///
    /// `MeetingCaptureService.start()` needs an id before it knows whether
    /// capture will succeed, and it can still fail afterwards on mic auth,
    /// ScreenCaptureKit, or a mute landing mid-start. Persisting up front meant
    /// every one of those failures left a permanent zero-length meeting in the
    /// list with no explanation, which is worse than the failure it was
    /// recording. Make it here, commit it once capture is actually live.
    func make(title: String?, sourceApp: String?, sourceAppName: String?) -> MeetingRecord {
        MeetingRecord(title: title, sourceApp: sourceApp, sourceAppName: sourceAppName)
    }

    /// Persists a record and puts it in the index.
    func commit(_ record: MeetingRecord) {
        save(record)
        reindex()
    }

    func save(_ record: MeetingRecord) {
        Persistence.save(record, to: url(for: record.id))
    }

    func finalize(_ record: MeetingRecord) {
        var rec = record
        if rec.endedAt == nil { rec.endedAt = Date() }
        save(rec)
        reindex()
    }

    // MARK: - Read path

    /// COULD NEVER RETURN NIL, WHICH IS THE OPPOSITE OF WHAT AN OPTIONAL SAYS.
    ///
    /// The old version loaded with `fallback: MeetingRecord(id: id)` and then
    /// tested `.id == id` to decide whether the record existed. The fallback
    /// carries the very id it was asked for, so that test passed for a meeting
    /// that had never been saved, and the caller got a phantom empty record
    /// instead of nil. It also loaded the file twice to do it.
    ///
    /// Found by a test written for a different defect: asserting that an
    /// unsaved record is absent could not fail, no matter what the store did.
    /// Delegates, rather than being a second way to do this.
    ///
    /// `loadRecord(id:)` sits forty lines below and has always been correct: it
    /// passes a NONCE id as the fallback, so a miss is detected by mismatch. The
    /// broken version compared against a fallback carrying the id it was asked
    /// for, which can never mismatch. Two functions doing one job in one file is
    /// how one of them rots, and this is the one that rotted, because nothing
    /// called it.
    ///
    /// The nonce version is also strictly stronger: it returns nil for a file
    /// that exists but does not decode, where an existence check alone hands
    /// back an empty record for a corrupt one.
    func get(id: UUID) -> MeetingRecord? {
        loadRecord(id: id)
    }

    func list(limit: Int = 20, since: Date? = nil, folderId: UUID? = nil) -> [MeetingIndexEntry] {
        let filtered = index.filter { entry in
            if let since, entry.startedAt < since { return false }
            if let folderId, entry.folderId != folderId { return false }
            return true
        }
        return Array(filtered.sorted { $0.startedAt > $1.startedAt }.prefix(max(1, limit)))
    }

    // Map of folder id → member count. Called by the UI and list_folders tool
    // to avoid an O(n) scan per folder row.
    func folderCounts() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for entry in index {
            guard let fid = entry.folderId else { continue }
            out[fid, default: 0] += 1
        }
        return out
    }

    // Count of meetings that haven't been assigned to any folder yet.
    var unsortedCount: Int {
        index.reduce(into: 0) { if $1.folderId == nil { $0 += 1 } }
    }

    // MARK: - Speaker cluster rename

    // Rename a diarizer cluster inside a single meeting. Rewrites every
    // utterance with the matching speakerId to the new label AND updates
    // the stored `speakerClusters` snapshot so the Meetings UI reflects
    // the new name on next load. Returns the updated record, or nil if
    // the record is missing / the cluster id isn't in it.
    //
    // This is NOT the same as enrolling a profile: nothing is persisted
    // globally. Use SpeakerProfileStore.enroll for cross-meeting
    // recognition. Callers that want both typically call enroll first,
    // then renameCluster, so the stored utterances show the final name
    // immediately.
    @discardableResult
    func renameCluster(
        meetingId: UUID,
        speakerId: UUID,
        to newLabel: String,
        profileId: UUID? = nil
    ) -> MeetingRecord? {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var rec = loadRecord(id: meetingId) else { return nil }
        var matched = false
        rec.utterances = rec.utterances.map { u -> MeetingUtterance in
            guard u.speakerId == speakerId else { return u }
            matched = true
            return MeetingUtterance(
                id: u.id,
                t: u.t,
                speaker: u.speaker,
                text: u.text,
                confidence: u.confidence,
                speakerId: u.speakerId,
                speakerLabel: trimmed,
                speakerProfileId: profileId ?? u.speakerProfileId
            )
        }
        if var clusters = rec.speakerClusters {
            clusters = clusters.map { c -> SpeakerClusterSnapshot in
                guard c.speakerId == speakerId else { return c }
                matched = true
                return SpeakerClusterSnapshot(
                    speakerId: c.speakerId,
                    label: trimmed,
                    profileId: profileId ?? c.profileId,
                    centroid: c.centroid,
                    sampleCount: c.sampleCount,
                    nameHint: c.nameHint
                )
            }
            rec.speakerClusters = clusters
        }
        guard matched else { return nil }
        save(rec)
        reindex()
        return rec
    }

    // MARK: - Folder assignment

    // Move a single meeting into a folder (or out, when folderId is nil).
    // Rewrites the record file + the index row; returns the updated entry so
    // callers can reflect the new state in their UI.
    @discardableResult
    func assign(meetingId: UUID, folderId: UUID?) -> MeetingIndexEntry? {
        guard var rec = loadRecord(id: meetingId) else { return nil }
        rec.folderId = folderId
        save(rec)
        reindex()
        return index.first { $0.id == meetingId }
    }

    // Bulk cascade when a folder is deleted. Every record carrying the old
    // folderId is rewritten to point at the new one (or nil to unsort).
    func reassignAll(fromFolder oldId: UUID, toFolder newId: UUID?) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Persistence.meetingsDir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != "index.json" && item.pathExtension == "json" {
            let fallback = MeetingRecord(id: UUID())
            var rec = Persistence.load(MeetingRecord.self, from: item, fallback: fallback)
            if rec.id == fallback.id { continue }
            if rec.folderId == oldId {
                rec.folderId = newId
                save(rec)
            }
        }
        reindex()
    }

    func search(query: String, limit: Int = 20) -> [MeetingIndexEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list(limit: limit) }
        // First pass: index-level hits on title/summary/app.
        let indexHits = index.filter { entry in
            (entry.title?.lowercased().contains(q) ?? false)
            || (entry.summaryExcerpt?.lowercased().contains(q) ?? false)
            || (entry.sourceAppName?.lowercased().contains(q) ?? false)
        }
        if indexHits.count >= limit { return Array(indexHits.prefix(limit)) }
        // Fallback: scan utterances of the N most-recent meetings for hits.
        var hits = Set(indexHits.map { $0.id })
        var results = indexHits
        for entry in index.sorted(by: { $0.startedAt > $1.startedAt }).prefix(50) {
            if hits.contains(entry.id) { continue }
            guard let rec = loadRecord(id: entry.id) else { continue }
            if rec.utterances.contains(where: { $0.text.lowercased().contains(q) }) {
                results.append(entry)
                hits.insert(entry.id)
                if results.count >= limit { break }
            }
        }
        return Array(results.prefix(limit))
    }

    func loadRecord(id: UUID) -> MeetingRecord? {
        let fallback = MeetingRecord(id: UUID())   // nonce; we detect the miss by id mismatch
        let loaded = Persistence.load(MeetingRecord.self, from: url(for: id), fallback: fallback)
        return loaded.id == fallback.id ? nil : loaded
    }

    // MARK: - Index

    private func url(for id: UUID) -> URL {
        Persistence.meetingsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        Persistence.meetingsDir.appendingPathComponent("index.json")
    }

    private func loadIndex() {
        indexLock.lock()
        defer { indexLock.unlock() }
        index = Persistence.load([MeetingIndexEntry].self, from: indexURL, fallback: [])
    }

    func reindex() {
        // Walk the meetings dir, rebuild the index. Cheap enough for <5000
        // meetings; re-run whenever we save or finalize.
        let fm = FileManager.default
        let dir = Persistence.meetingsDir
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var rebuilt: [MeetingIndexEntry] = []
        for item in items where item.lastPathComponent != "index.json" && item.pathExtension == "json" {
            let fallback = MeetingRecord(id: UUID())
            let rec = Persistence.load(MeetingRecord.self, from: item, fallback: fallback)
            if rec.id == fallback.id { continue }
            let excerpt: String? = {
                guard let s = rec.summary, !s.isEmpty else { return nil }
                return String(s.prefix(140))
            }()
            rebuilt.append(MeetingIndexEntry(
                id: rec.id,
                startedAt: rec.startedAt,
                endedAt: rec.endedAt,
                title: rec.title,
                sourceAppName: rec.sourceAppName,
                utteranceCount: rec.utterances.count,
                summaryExcerpt: excerpt,
                folderId: rec.folderId
            ))
        }
        rebuilt.sort { $0.startedAt > $1.startedAt }
        indexLock.lock()
        self.index = rebuilt
        indexLock.unlock()
        Persistence.save(rebuilt, to: indexURL)
    }
}
