import Foundation

// Claude-tool adapter for speaker diarization / voice profile enrollment.
// Parallel to MeetingTool: thin switch → call into SpeakerProfileStore and
// the live MeetingCaptureService diarizer.
enum SpeakerTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "list_speakers",
                description: "List every enrolled voice profile. Returns id, name, sampleCount (how many audio chunks have shaped the embedding), and the time it was last updated. Use when they ask 'who have I enrolled' or 'what speakers does Grux know'.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            ClaudeTool(
                name: "enroll_speaker_from_current_meeting",
                description: "Take one of the live-meeting diarizer's clusters (e.g. 'Speaker 2') and save it as a named, globally-enrolled voice profile. Future meetings will auto-label this person by name. Requires an active or just-ended meeting - the diarizer state resets when the next meeting starts.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The person's display name, e.g. 'Dad', 'Sarah'."
                        ],
                        "cluster_label": [
                            "type": "string",
                            "description": "Cluster label as shown in the meeting UI, e.g. 'Speaker 1'. Matching is case-insensitive. If omitted, the cluster with the most assigned chunks wins (almost always the user's own voice)."
                        ]
                    ],
                    "required": ["name"]
                ]
            ),
            ClaudeTool(
                name: "rename_speaker",
                description: "Rename an enrolled voice profile. Use when the user relabels a mis-identified or generically-named speaker.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "speaker_id": [
                            "type": "string",
                            "description": "Profile UUID from list_speakers."
                        ],
                        "new_name": [
                            "type": "string",
                            "description": "New display name."
                        ]
                    ],
                    "required": ["speaker_id", "new_name"]
                ]
            ),
            ClaudeTool(
                name: "delete_speaker",
                description: "Forget an enrolled voice profile. Future meetings will fall back to anonymous 'Speaker N' labels for that person.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "speaker_id": [
                            "type": "string",
                            "description": "Profile UUID from list_speakers."
                        ]
                    ],
                    "required": ["speaker_id"]
                ]
            ),
            ClaudeTool(
                name: "enroll_speaker_from_meeting",
                description: "Enroll a diarizer cluster from a STORED meeting record (works after the live session has ended). Use when the user asks to enroll someone from a past meeting by cluster label ('Speaker 2') or by the in-transcript self-introduction name hint.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": [
                            "type": "string",
                            "description": "MeetingRecord UUID. Get one from list_meetings."
                        ],
                        "cluster_label": [
                            "type": "string",
                            "description": "Cluster label as stored on the meeting, e.g. 'Speaker 1'. Case-insensitive. If omitted, the cluster with the most assigned chunks wins."
                        ],
                        "name": [
                            "type": "string",
                            "description": "The person's display name. Future meetings auto-label them by this name."
                        ]
                    ],
                    "required": ["meeting_id", "name"]
                ]
            ),
            ClaudeTool(
                name: "rename_cluster_in_meeting",
                description: "Rename a speaker cluster INSIDE a specific stored meeting without enrolling a global profile. Rewrites every utterance with that cluster so the transcript reads the new label immediately. Pair with enroll_speaker_from_meeting when they want the rename to persist to future meetings too.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": [
                            "type": "string",
                            "description": "MeetingRecord UUID."
                        ],
                        "cluster_label": [
                            "type": "string",
                            "description": "Current cluster label to rename, e.g. 'Speaker 2'. Case-insensitive."
                        ],
                        "new_label": [
                            "type": "string",
                            "description": "Replacement label, e.g. 'Sarah'."
                        ]
                    ],
                    "required": ["meeting_id", "cluster_label", "new_label"]
                ]
            ),
            ClaudeTool(
                name: "speaker_stats",
                description: "Cross-meeting stats for each enrolled voice profile: how many meetings included them, how many utterances they produced, when they were last heard. Use for 'how many times have I met with Sarah?' or 'who talks most in my meetings?'.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "list_speakers":
            let profiles = await MainActor.run { SpeakerProfileStore.shared.profiles }
            if profiles.isEmpty { return "(no speakers enrolled yet)" }
            let df = DateFormatter()
            df.dateFormat = "MMM d h:mm a"
            df.timeZone = .current
            return profiles.map { p in
                "- id=\(p.id.uuidString) · \(p.name) · \(p.sampleCount) sample(s) · updated \(df.string(from: p.updatedAt))"
            }.joined(separator: "\n")

        case "enroll_speaker_from_current_meeting":
            guard let rawName = input["name"] as? String,
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "error: 'name' is required and must be non-empty"
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let clusterLabel = (input["cluster_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let centroids = await MainActor.run { MeetingCaptureService.shared.currentDiarizerCentroids }
            guard let list = centroids, !list.isEmpty else {
                return "error: no diarizer state - start a meeting first (or enroll right after one ends, before starting the next)"
            }

            let target: (id: UUID, label: String, centroid: [Float], count: Int)
            if let lbl = clusterLabel, !lbl.isEmpty {
                guard let hit = list.first(where: { $0.label.caseInsensitiveCompare(lbl) == .orderedSame }) else {
                    let avail = list.map { "'\($0.label)'" }.joined(separator: ", ")
                    return "error: no cluster named '\(lbl)'. Available: \(avail)"
                }
                target = hit
            } else {
                target = list.max(by: { $0.count < $1.count })!
            }

            let profile = await MainActor.run {
                SpeakerProfileStore.shared.enroll(name: name, embedding: target.centroid)
            }
            return "ok: enrolled id=\(profile.id.uuidString) name=\(profile.name) from cluster='\(target.label)' (\(target.count) chunk(s))"

        case "rename_speaker":
            guard let idStr = input["speaker_id"] as? String, let id = UUID(uuidString: idStr) else {
                return "error: speaker_id must be a valid UUID"
            }
            guard let raw = input["new_name"] as? String,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "error: new_name is required"
            }
            let newName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let updated = await MainActor.run(body: {
                SpeakerProfileStore.shared.rename(id: id, to: newName)
            }) else {
                return "error: no speaker with that id"
            }
            return "ok: renamed id=\(updated.id.uuidString) → \(updated.name)"

        case "delete_speaker":
            guard let idStr = input["speaker_id"] as? String, let id = UUID(uuidString: idStr) else {
                return "error: speaker_id must be a valid UUID"
            }
            let ok = await MainActor.run { SpeakerProfileStore.shared.delete(id: id) }
            return ok ? "ok: deleted \(idStr)" : "error: no speaker with that id"

        case "enroll_speaker_from_meeting":
            guard let rawName = input["name"] as? String,
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "error: 'name' is required"
            }
            guard let meetingIdStr = input["meeting_id"] as? String,
                  let meetingId = UUID(uuidString: meetingIdStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            let rawLabel = (input["cluster_label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result = await MainActor.run { () -> String in
                guard let rec = MeetingStore.shared.loadRecord(id: meetingId) else {
                    return "error: no meeting with id \(meetingIdStr)"
                }
                guard let clusters = rec.speakerClusters, !clusters.isEmpty else {
                    return "error: meeting \(meetingIdStr) has no stored speaker clusters (pre-diarization record?)"
                }
                let target: SpeakerClusterSnapshot
                if let lbl = rawLabel, !lbl.isEmpty {
                    guard let hit = clusters.first(where: {
                        $0.label.caseInsensitiveCompare(lbl) == .orderedSame
                    }) else {
                        let avail = clusters.map { "'\($0.label)'" }.joined(separator: ", ")
                        return "error: no cluster named '\(lbl)' in this meeting. Available: \(avail)"
                    }
                    target = hit
                } else {
                    target = clusters.max(by: { $0.sampleCount < $1.sampleCount })!
                }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let profile = SpeakerProfileStore.shared.enroll(name: name, embedding: target.centroid)
                // Also relabel the stored meeting in place so the transcript
                // reflects the new name immediately.
                _ = MeetingStore.shared.renameCluster(
                    meetingId: meetingId,
                    speakerId: target.speakerId,
                    to: profile.name,
                    profileId: profile.id
                )
                return "ok: enrolled id=\(profile.id.uuidString) name=\(profile.name) from meeting=\(meetingIdStr) cluster='\(target.label)' (\(target.sampleCount) sample chunk(s))"
            }
            return result

        case "rename_cluster_in_meeting":
            guard let meetingIdStr = input["meeting_id"] as? String,
                  let meetingId = UUID(uuidString: meetingIdStr) else {
                return "error: meeting_id must be a valid UUID"
            }
            guard let clusterLabel = (input["cluster_label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !clusterLabel.isEmpty else {
                return "error: cluster_label is required"
            }
            guard let newLabel = (input["new_label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !newLabel.isEmpty else {
                return "error: new_label is required"
            }
            let result = await MainActor.run { () -> String in
                guard let rec = MeetingStore.shared.loadRecord(id: meetingId) else {
                    return "error: no meeting with id \(meetingIdStr)"
                }
                guard let clusters = rec.speakerClusters,
                      let hit = clusters.first(where: {
                          $0.label.caseInsensitiveCompare(clusterLabel) == .orderedSame
                      }) else {
                    return "error: no cluster named '\(clusterLabel)' in this meeting"
                }
                guard let updated = MeetingStore.shared.renameCluster(
                    meetingId: meetingId,
                    speakerId: hit.speakerId,
                    to: newLabel
                ) else {
                    return "error: rename failed - utterance rewrite did not match"
                }
                let count = updated.utterances.filter { $0.speakerId == hit.speakerId }.count
                return "ok: renamed cluster '\(clusterLabel)' → '\(newLabel)' across \(count) utterance(s) in \(meetingIdStr)"
            }
            return result

        case "speaker_stats":
            let stats = await MainActor.run { () -> [(profile: SpeakerProfile, meetings: Int, utterances: Int, lastSeen: Date?)] in
                let store = SpeakerProfileStore.shared
                let profiles = store.profiles
                var perProfileMeetings: [UUID: Int] = [:]
                var perProfileUtterances: [UUID: Int] = [:]
                var perProfileLastSeen: [UUID: Date] = [:]
                for entry in MeetingStore.shared.index {
                    guard let rec = MeetingStore.shared.loadRecord(id: entry.id) else { continue }
                    var seenInThisMeeting: Set<UUID> = []
                    for u in rec.utterances {
                        guard let pid = u.speakerProfileId else { continue }
                        perProfileUtterances[pid, default: 0] += 1
                        if !seenInThisMeeting.contains(pid) {
                            seenInThisMeeting.insert(pid)
                            perProfileMeetings[pid, default: 0] += 1
                            let at = rec.startedAt
                            if let prev = perProfileLastSeen[pid] {
                                perProfileLastSeen[pid] = max(prev, at)
                            } else {
                                perProfileLastSeen[pid] = at
                            }
                        }
                    }
                }
                return profiles.map { p in
                    (p,
                     perProfileMeetings[p.id] ?? 0,
                     perProfileUtterances[p.id] ?? 0,
                     perProfileLastSeen[p.id])
                }.sorted { $0.meetings > $1.meetings }
            }
            if stats.isEmpty { return "(no speakers enrolled yet)" }
            let df = DateFormatter()
            df.dateFormat = "MMM d, yyyy"
            df.timeZone = .current
            return stats.map { s in
                let last = s.lastSeen.map { df.string(from: $0) } ?? "never"
                return "- \(s.profile.name) · \(s.meetings) meeting(s) · \(s.utterances) utterance(s) · last heard \(last)"
            }.joined(separator: "\n")

        default:
            return "error: unknown speaker tool '\(name)'"
        }
    }
}
