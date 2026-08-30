import Foundation

// Persisted voice profile. `embedding` is a 26-dim L2-normalized MFCC-stats
// vector produced by SpeakerEmbedder. `updatedAt` lets us show how fresh a
// profile is in the UI.
struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var embedding: [Float]
    var sampleCount: Int            // how many chunks have been merged in
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        sampleCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// Global store of named voice profiles. Lives in
// ~/Library/Application Support/Grux/speakers.json. Flat list; no index file
// since we expect <50 enrolled speakers max.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    static let shared = SpeakerProfileStore()

    @Published private(set) var profiles: [SpeakerProfile] = []

    private var storeURL: URL {
        Persistence.supportDir.appendingPathComponent("speakers.json")
    }

    private init() {
        profiles = Persistence.load([SpeakerProfile].self, from: storeURL, fallback: [])
    }

    // MARK: - CRUD

    @discardableResult
    func enroll(name: String, embedding: [Float]) -> SpeakerProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "Unnamed" : trimmed
        // If a profile already has this name, update its embedding (merge)
        // rather than creating a duplicate.
        if let idx = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(resolvedName) == .orderedSame }) {
            var existing = profiles[idx]
            let alpha: Float = 1.0 / Float(existing.sampleCount + 1)
            existing.embedding = SpeakerEmbedder.blendCentroid(existing.embedding, with: embedding, alpha: alpha)
            existing.sampleCount += 1
            existing.updatedAt = Date()
            profiles[idx] = existing
            persist()
            return existing
        }
        let p = SpeakerProfile(name: resolvedName, embedding: embedding)
        profiles.append(p)
        persist()
        return p
    }

    @discardableResult
    func rename(id: UUID, to newName: String) -> SpeakerProfile? {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        profiles[idx].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[idx].updatedAt = Date()
        persist()
        return profiles[idx]
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let before = profiles.count
        profiles.removeAll { $0.id == id }
        if profiles.count != before {
            persist()
            return true
        }
        return false
    }

    func get(id: UUID) -> SpeakerProfile? {
        profiles.first { $0.id == id }
    }

    func get(name: String) -> SpeakerProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // Merge new sample data into an existing profile's embedding. Used when
    // the user enrolls additional chunks for an already-known speaker.
    @discardableResult
    func merge(id: UUID, additionalEmbedding: [Float]) -> SpeakerProfile? {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var existing = profiles[idx]
        let alpha: Float = 1.0 / Float(existing.sampleCount + 1)
        existing.embedding = SpeakerEmbedder.blendCentroid(existing.embedding, with: additionalEmbedding, alpha: alpha)
        existing.sampleCount += 1
        existing.updatedAt = Date()
        profiles[idx] = existing
        persist()
        return existing
    }

    // MARK: - Matching

    struct Match {
        let profile: SpeakerProfile
        let similarity: Float
    }

    // Return the closest enrolled profile above `minSim`, or nil.
    func bestMatch(for embedding: [Float], minSim: Float = 0.85) -> Match? {
        guard !profiles.isEmpty else { return nil }
        var bestProfile: SpeakerProfile?
        var bestSim: Float = -1
        for p in profiles {
            guard p.embedding.count == embedding.count else { continue }
            let s = SpeakerEmbedder.cosineSimilarity(p.embedding, embedding)
            if s > bestSim {
                bestSim = s
                bestProfile = p
            }
        }
        guard let bp = bestProfile, bestSim >= minSim else { return nil }
        return Match(profile: bp, similarity: bestSim)
    }

    // MARK: - Persistence

    private func persist() {
        Persistence.save(profiles, to: storeURL)
    }
}
