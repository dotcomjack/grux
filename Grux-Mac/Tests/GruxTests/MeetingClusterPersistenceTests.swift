import XCTest
@testable import Grux

// Tests the post-Omi-gap additions: per-meeting SpeakerClusterSnapshot
// round-tripping, MeetingStore.renameCluster atomicity, and backward-
// compat decoding of legacy records that predate the new field.
final class MeetingClusterPersistenceTests: XCTestCase {

    // MARK: - Snapshot codable round-trip

    func test_meetingRecord_encodesDecodesClusterSnapshot() throws {
        let centroid: [Float] = (0..<SpeakerEmbedder.embeddingDims).map { _ in Float.random(in: -1...1) }
        let snap = SpeakerClusterSnapshot(
            speakerId: UUID(),
            label: "Speaker 1",
            profileId: nil,
            centroid: centroid,
            sampleCount: 14,
            nameHint: "Sarah"
        )
        let rec = MeetingRecord(
            id: UUID(),
            utterances: [],
            speakerClusters: [snap]
        )
        let data = try JSONEncoder().encode(rec)
        let round = try JSONDecoder().decode(MeetingRecord.self, from: data)
        XCTAssertEqual(round.speakerClusters?.count, 1)
        XCTAssertEqual(round.speakerClusters?.first?.label, "Speaker 1")
        XCTAssertEqual(round.speakerClusters?.first?.nameHint, "Sarah")
        XCTAssertEqual(round.speakerClusters?.first?.centroid.count, SpeakerEmbedder.embeddingDims)
        XCTAssertEqual(round.speakerClusters?.first?.sampleCount, 14)
    }

    // Legacy JSON (no `speakerClusters` key) must still decode: pre-
    // diarization records already on disk can't migrate.
    func test_meetingRecord_legacyJSON_decodesWithNilClusters() throws {
        let legacyJSON = """
        {
          "id": "4C2A2B69-3F81-4BF3-B85F-09E3A67F65A0",
          "startedAt": 730000000,
          "utterances": [],
          "actionItems": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let rec = try decoder.decode(MeetingRecord.self, from: legacyJSON)
        XCTAssertNil(rec.speakerClusters)
        XCTAssertEqual(rec.utterances.count, 0)
    }

    // MARK: - renameCluster

    @MainActor
    func test_renameCluster_rewritesAllMatchingUtterances() throws {
        let store = MeetingStore.shared
        let speakerA = UUID()
        let speakerB = UUID()
        let rec = MeetingRecord(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            title: "CLUSTER-RENAME-TEST",
            utterances: [
                MeetingUtterance(t: 0.0, speaker: .mixed, text: "hello", confidence: 0.9,
                                 speakerId: speakerA, speakerLabel: "Speaker 1", speakerProfileId: nil),
                MeetingUtterance(t: 1.0, speaker: .mixed, text: "hi", confidence: 0.9,
                                 speakerId: speakerB, speakerLabel: "Speaker 2", speakerProfileId: nil),
                MeetingUtterance(t: 2.0, speaker: .mixed, text: "thanks", confidence: 0.9,
                                 speakerId: speakerA, speakerLabel: "Speaker 1", speakerProfileId: nil)
            ],
            speakerClusters: [
                SpeakerClusterSnapshot(speakerId: speakerA, label: "Speaker 1", profileId: nil,
                                       centroid: Array(repeating: 0.1, count: 52), sampleCount: 2, nameHint: nil),
                SpeakerClusterSnapshot(speakerId: speakerB, label: "Speaker 2", profileId: nil,
                                       centroid: Array(repeating: 0.2, count: 52), sampleCount: 1, nameHint: nil)
            ]
        )
        store.save(rec)
        defer {
            // Cleanup so repeated test runs don't pile up on disk.
            let path = Persistence.meetingsDir.appendingPathComponent("\(rec.id.uuidString).json")
            try? FileManager.default.removeItem(at: path)
            store.reindex()
        }

        let updated = store.renameCluster(meetingId: rec.id, speakerId: speakerA, to: "Sarah")
        XCTAssertNotNil(updated)
        let reloaded = store.loadRecord(id: rec.id)!
        let speakerALabels = reloaded.utterances.filter { $0.speakerId == speakerA }.map { $0.speakerLabel }
        let speakerBLabels = reloaded.utterances.filter { $0.speakerId == speakerB }.map { $0.speakerLabel }
        XCTAssertEqual(Set(speakerALabels.compactMap { $0 }), ["Sarah"],
                       "All speakerA utterances should now read 'Sarah'")
        XCTAssertEqual(Set(speakerBLabels.compactMap { $0 }), ["Speaker 2"],
                       "speakerB utterances must be untouched")
        XCTAssertEqual(reloaded.speakerClusters?.first(where: { $0.speakerId == speakerA })?.label, "Sarah")
        XCTAssertEqual(reloaded.speakerClusters?.first(where: { $0.speakerId == speakerB })?.label, "Speaker 2")
    }

    @MainActor
    func test_renameCluster_missingMeetingReturnsNil() {
        let store = MeetingStore.shared
        XCTAssertNil(store.renameCluster(meetingId: UUID(), speakerId: UUID(), to: "Nobody"))
    }

    @MainActor
    func test_renameCluster_emptyNameReturnsNil() throws {
        let store = MeetingStore.shared
        let sid = UUID()
        let rec = MeetingRecord(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            title: "EMPTY-RENAME-TEST",
            utterances: [MeetingUtterance(t: 0, speaker: .mixed, text: "x", confidence: 1,
                                          speakerId: sid, speakerLabel: "Speaker 1", speakerProfileId: nil)],
            speakerClusters: [SpeakerClusterSnapshot(speakerId: sid, label: "Speaker 1", profileId: nil,
                                                    centroid: Array(repeating: 0, count: 52), sampleCount: 1, nameHint: nil)]
        )
        store.save(rec)
        defer {
            let path = Persistence.meetingsDir.appendingPathComponent("\(rec.id.uuidString).json")
            try? FileManager.default.removeItem(at: path)
            store.reindex()
        }
        XCTAssertNil(store.renameCluster(meetingId: rec.id, speakerId: sid, to: "   "))
    }

    // MARK: - Enrollment from a stored snapshot

    @MainActor
    func test_enrollFromSnapshot_matchesFutureVoice() {
        let store = SpeakerProfileStore.shared
        for p in store.profiles where p.name.hasPrefix("SNAPSHOT-TEST-") { store.delete(id: p.id) }

        // Synthesize a distinct voice, embed it, save into a snapshot, then
        // enroll from the snapshot and verify a fresh diarizer tags a new
        // sample of the same voice with the profile name.
        let samples = Self.synthVoice(f0: 120, formants: [600, 1100, 2300])
        let emb = SpeakerEmbedder.embed(samples: samples)!
        let snap = SpeakerClusterSnapshot(
            speakerId: UUID(),
            label: "Speaker 1",
            profileId: nil,
            centroid: emb,
            sampleCount: 5,
            nameHint: nil
        )
        let profile = store.enroll(name: "SNAPSHOT-TEST-Alice", embedding: snap.centroid)
        defer { store.delete(id: profile.id) }

        let diarizer = SpeakerDiarizer(profileStore: store)
        let again = Self.synthVoice(f0: 120, formants: [600, 1100, 2300])
        let assign = diarizer.assign(samples: again)
        XCTAssertNotNil(assign)
        XCTAssertEqual(assign?.label, "SNAPSHOT-TEST-Alice",
                       "Diarizer should label the re-synthesized voice with the enrolled name")
    }

    // Shared synth helper (kept private to this file to avoid cross-file
    // coupling with SpeakerDiarizerTests).
    private static func synthVoice(f0: Float, formants: [Float], durationSeconds: Float = 2.0) -> [Float] {
        let sr: Float = 16_000
        let n = Int(sr * durationSeconds)
        var out = [Float](repeating: 0, count: n)
        for k in 1...15 {
            let freq = f0 * Float(k)
            guard freq < sr / 2 else { break }
            for i in 0..<n {
                out[i] += (1.0 / Float(k)) * sinf(2 * .pi * freq * Float(i) / sr)
            }
        }
        for f in formants {
            for i in 0..<n {
                out[i] += 0.6 * sinf(2 * .pi * f * Float(i) / sr)
            }
        }
        for i in 0..<n {
            let t = Float(i) / sr
            let env = 0.4 + 0.6 * max(0, sinf(.pi * t / durationSeconds))
            out[i] *= env
        }
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for i in 0..<n { out[i] = 0.8 * out[i] / peak }
        }
        return out
    }
}
