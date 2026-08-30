import Foundation

// Per-meeting online speaker diarizer. Takes audio chunks as they come in,
// computes a voice embedding, and assigns each chunk to either an existing
// cluster (by cosine sim) or a fresh one. Also attempts to match clusters to
// globally enrolled `SpeakerProfile`s so a meeting can show "Dana" instead of
// "Speaker 1" when we recognize that person's voice.
//
// Not thread-safe on its own; callers use it from the MainActor (meeting
// capture pipeline is MainActor-confined).
@MainActor
final class SpeakerDiarizer {

    struct Assignment {
        let speakerId: UUID        // stable within this meeting
        let label: String          // "Speaker 1" (local) OR a profile name when matched
        let matchedProfile: SpeakerProfile?
        let confidence: Float      // cosine sim to assigned centroid, 0..1
    }

    struct Cluster {
        let id: UUID
        var centroid: [Float]
        var count: Int              // chunks assigned so far (drives EMA weight)
        var firstSeenIndex: Int     // for stable "Speaker 1/2/3..." numbering
        var matchedProfileId: UUID? // sticky once identified
    }

    // Cosine similarity thresholds (on L2-normalized embeddings):
    //
    //  • clusterThreshold: a new chunk within this of an existing centroid is
    //    absorbed into that cluster. Tuned for MFCC mean+std; raise to be more
    //    aggressive about splitting, lower to merge more.
    //
    //  • profileThreshold: a centroid within this of an enrolled profile's
    //    embedding is labeled with that profile's name. Higher than cluster
    //    threshold because misidentification is worse than missing an
    //    identification.
    nonisolated static let clusterThreshold: Float = 0.78
    nonisolated static let profileThreshold: Float = 0.85

    private var clusters: [Cluster] = []
    private var chunkIndex: Int = 0
    private let profileStore: SpeakerProfileStore

    init(profileStore: SpeakerProfileStore = .shared) {
        self.profileStore = profileStore
    }

    // Primary entry: pass the PCM samples for the speech portion of a chunk.
    // Returns nil when the chunk is pure silence / no voice activity.
    func assign(samples: [Float]) -> Assignment? {
        guard let emb = SpeakerEmbedder.embed(samples: samples) else {
            return nil
        }
        return assign(embedding: emb)
    }

    // Secondary entry: caller already has the embedding (e.g. for tests).
    func assign(embedding emb: [Float]) -> Assignment {
        chunkIndex += 1

        // Find best-matching existing cluster.
        var bestIdx: Int? = nil
        var bestSim: Float = -1
        for (i, c) in clusters.enumerated() {
            let s = SpeakerEmbedder.cosineSimilarity(c.centroid, emb)
            if s > bestSim {
                bestSim = s
                bestIdx = i
            }
        }

        let assignedIdx: Int
        let confidence: Float

        if let bi = bestIdx, bestSim >= Self.clusterThreshold {
            // Absorb. Update centroid with decreasing step as the cluster grows.
            var c = clusters[bi]
            let alpha: Float = 1.0 / Float(c.count + 1)
            c.centroid = SpeakerEmbedder.blendCentroid(c.centroid, with: emb, alpha: alpha)
            c.count += 1
            clusters[bi] = c
            assignedIdx = bi
            confidence = bestSim
        } else {
            // New cluster.
            let newCluster = Cluster(
                id: UUID(),
                centroid: emb,
                count: 1,
                firstSeenIndex: clusters.count,
                matchedProfileId: nil
            )
            clusters.append(newCluster)
            assignedIdx = clusters.count - 1
            confidence = 1.0
        }

        // Attempt to match this cluster to an enrolled profile. Sticky:
        // once matched, a later chunk with a slightly different embedding
        // won't un-match as long as the cluster stays coherent.
        var cluster = clusters[assignedIdx]
        if cluster.matchedProfileId == nil {
            if let match = profileStore.bestMatch(for: cluster.centroid, minSim: Self.profileThreshold) {
                cluster.matchedProfileId = match.profile.id
                clusters[assignedIdx] = cluster
            }
        }

        let profile: SpeakerProfile? = cluster.matchedProfileId.flatMap { profileStore.get(id: $0) }
        let label: String = profile?.name ?? "Speaker \(cluster.firstSeenIndex + 1)"

        return Assignment(
            speakerId: cluster.id,
            label: label,
            matchedProfile: profile,
            confidence: confidence
        )
    }

    // Exposed for post-meeting "enroll this cluster as <name>" flows.
    var clusterCentroids: [(id: UUID, label: String, centroid: [Float], count: Int)] {
        clusters.map { c in
            let profile = c.matchedProfileId.flatMap { profileStore.get(id: $0) }
            let label = profile?.name ?? "Speaker \(c.firstSeenIndex + 1)"
            return (c.id, label, c.centroid, c.count)
        }
    }

    func reset() {
        clusters.removeAll()
        chunkIndex = 0
    }
}
