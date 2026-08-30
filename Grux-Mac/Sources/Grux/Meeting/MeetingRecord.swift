import Foundation

// Persistent shape for a captured meeting. Utterances are written in
// arrival order; channel attribution lives on each utterance so future
// stereo-L/R transcription (v2) can drop in without a migration.
struct MeetingUtterance: Codable, Identifiable, Equatable {
    enum Speaker: String, Codable { case me, them, mixed }
    let id: UUID
    let t: TimeInterval            // seconds since startedAt
    let speaker: Speaker
    let text: String
    let confidence: Float
    // Voice-based diarization (separate from the mic/system channel `speaker`
    // above). `speakerId` is the per-meeting cluster UUID assigned by
    // SpeakerDiarizer; `speakerLabel` is the display label ("Speaker 1", or an
    // enrolled name); `speakerProfileId` is set when the cluster matched an
    // enrolled global SpeakerProfile. All optional so older JSON records
    // decode unchanged (pre-diarization meetings keep working).
    let speakerId: UUID?
    let speakerLabel: String?
    let speakerProfileId: UUID?

    init(
        id: UUID = UUID(),
        t: TimeInterval,
        speaker: Speaker,
        text: String,
        confidence: Float,
        speakerId: UUID? = nil,
        speakerLabel: String? = nil,
        speakerProfileId: UUID? = nil
    ) {
        self.id = id
        self.t = t
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.speakerProfileId = speakerProfileId
    }
}

// Frozen snapshot of a diarizer cluster at meeting-end. Written to the
// MeetingRecord so post-meeting enrollment ("enroll Speaker 2 as Sarah") keeps
// working after the live SpeakerDiarizer resets. Embeddings are L2-normalized
// 52-dim MFCC+delta vectors (see SpeakerEmbedder.embeddingDims) so a
// stored snapshot round-trips directly into SpeakerProfileStore.enroll.
//
// Optional per-cluster `nameHint` is the highest-confidence candidate name
// picked up by SpeakerNameDetector during the meeting (e.g. "my name is
// Sarah" → "Sarah"). The UI pre-fills the enroll sheet with it.
struct SpeakerClusterSnapshot: Codable, Equatable {
    let speakerId: UUID
    let label: String           // "Speaker 1" or the profile name if matched at stop time
    let profileId: UUID?        // non-nil when this cluster was recognized
    let centroid: [Float]
    let sampleCount: Int        // how many sub-window chunks landed in this cluster
    let nameHint: String?       // self-introduction seen in the transcript
}

struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var title: String?
    var sourceApp: String?          // bundle ID, e.g. "us.zoom.xos"
    var sourceAppName: String?      // display name, e.g. "zoom.us"
    var utterances: [MeetingUtterance]
    var summary: String?
    var actionItems: [String]
    // Folder assignment. Optional + defaulted-nil so legacy records decode
    // unchanged. nil means "not yet classified" - the UI renders it as the
    // Unsorted bucket and the post-summary classifier will fill it in.
    var folderId: UUID?
    // Diarizer cluster snapshots taken at stop(). Optional so legacy records
    // decode unchanged. Empty array means "diarized but no clusters formed"
    // (silent / single-speaker fallback). Powers retroactive enrollment and
    // in-record cluster rename.
    var speakerClusters: [SpeakerClusterSnapshot]?
    // High-quality batch transcript produced by the companion whisper queue
    // (large-v3_turbo) for long meetings. ADDITIVE: it never overwrites the
    // live diarized `utterances`. It's a cleaner flat transcript stored
    // alongside, and the summary is regenerated from it when present. All
    // optional so legacy records decode unchanged and short / offline meetings
    // stay nil.
    var remoteTranscript: String?
    var remoteTranscriptModel: String?
    var remoteTranscriptAt: Date?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String? = nil,
        sourceApp: String? = nil,
        sourceAppName: String? = nil,
        utterances: [MeetingUtterance] = [],
        summary: String? = nil,
        actionItems: [String] = [],
        folderId: UUID? = nil,
        speakerClusters: [SpeakerClusterSnapshot]? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.utterances = utterances
        self.summary = summary
        self.actionItems = actionItems
        self.folderId = folderId
        self.speakerClusters = speakerClusters
    }

    var durationSeconds: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let app = sourceAppName, !app.isEmpty { return "Meeting · \(app)" }
        return "Meeting"
    }

    // Flat plain-text transcript. Useful for LLM summarization prompts.
    // Prefers the diarized `speakerLabel` (an enrolled name, or "Speaker 2") when
    // present; falls back to the channel label (Me / Them / -) for older
    // records that pre-date diarization.
    func flatText() -> String {
        utterances.map { u in
            let who: String
            if let lbl = u.speakerLabel, !lbl.isEmpty {
                who = lbl
            } else {
                switch u.speaker {
                case .me: who = "Me"
                case .them: who = "Them"
                case .mixed: who = "-"
                }
            }
            return "[\(formatTime(u.t))] \(who): \(u.text)"
        }.joined(separator: "\n")
    }

    // Unique, ordered list of speaker labels seen in this meeting. Used by
    // the UI to render chips and by tools to report who was detected.
    var distinctSpeakers: [(label: String, speakerId: UUID?, profileId: UUID?)] {
        var seen = Set<String>()
        var out: [(String, UUID?, UUID?)] = []
        for u in utterances {
            let lbl = u.speakerLabel ?? ""
            guard !lbl.isEmpty, !seen.contains(lbl) else { continue }
            seen.insert(lbl)
            out.append((lbl, u.speakerId, u.speakerProfileId))
        }
        return out
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// Lightweight index-row for `list_meetings`. Keeps the on-disk index small.
// `folderId` is optional so any old index.json decodes unchanged; the next
// reindex writes the current assignment.
struct MeetingIndexEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let title: String?
    let sourceAppName: String?
    let utteranceCount: Int
    let summaryExcerpt: String?
    let folderId: UUID?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        title: String?,
        sourceAppName: String?,
        utteranceCount: Int,
        summaryExcerpt: String?,
        folderId: UUID? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.sourceAppName = sourceAppName
        self.utteranceCount = utteranceCount
        self.summaryExcerpt = summaryExcerpt
        self.folderId = folderId
    }
}
