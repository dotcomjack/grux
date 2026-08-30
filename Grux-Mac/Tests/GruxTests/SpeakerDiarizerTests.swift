import XCTest
@testable import Grux

final class SpeakerDiarizerTests: XCTestCase {

    // Synthesize a 2-second, 16-kHz-mono signal that mimics a vowel by
    // summing harmonics of a fundamental frequency `f0`. Speakers differ
    // primarily in fundamental + formant structure, so distinct `f0` +
    // formants → distinct MFCC embeddings.
    private func synthVoice(f0: Float, formants: [Float], durationSeconds: Float = 2.0) -> [Float] {
        let sr: Float = 16_000
        let n = Int(sr * durationSeconds)
        var out = [Float](repeating: 0, count: n)
        // Carrier: 15 harmonics of f0 decaying 1/k.
        for k in 1...15 {
            let freq = f0 * Float(k)
            guard freq < sr / 2 else { break }
            for i in 0..<n {
                out[i] += (1.0 / Float(k)) * sinf(2 * .pi * freq * Float(i) / sr)
            }
        }
        // Formant shaping: add strong partials near each formant freq.
        for f in formants {
            for i in 0..<n {
                out[i] += 0.6 * sinf(2 * .pi * f * Float(i) / sr)
            }
        }
        // Add mild envelope so VAD lets voiced frames through.
        for i in 0..<n {
            let t = Float(i) / sr
            let env = 0.4 + 0.6 * max(0, sinf(.pi * t / durationSeconds))
            out[i] *= env
        }
        // Normalize to [-0.8, 0.8] so we're not clipping.
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for i in 0..<n { out[i] = 0.8 * out[i] / peak }
        }
        return out
    }

    // MARK: - Embedder

    func test_embedder_returnsFixedLengthNormalized() {
        let voice = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let emb = SpeakerEmbedder.embed(samples: voice)
        XCTAssertNotNil(emb)
        XCTAssertEqual(emb!.count, SpeakerEmbedder.embeddingDims)
        // L2 norm ≈ 1.
        let norm = sqrt(emb!.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func test_embedder_silenceReturnsNil() {
        let silence = [Float](repeating: 0, count: 32_000)
        XCTAssertNil(SpeakerEmbedder.embed(samples: silence))
    }

    func test_sameVoiceTwiceHasHighSimilarity() {
        let v1 = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let v2 = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let e1 = SpeakerEmbedder.embed(samples: v1)!
        let e2 = SpeakerEmbedder.embed(samples: v2)!
        let sim = SpeakerEmbedder.cosineSimilarity(e1, e2)
        XCTAssertGreaterThan(sim, 0.99,
            "Identical synthetic voices should produce near-identical embeddings, got \(sim)")
    }

    func test_differentVoicesHaveLowerSimilarity() {
        // A lower-pitched "male" voice vs a higher-pitched "female" voice.
        let male   = synthVoice(f0: 110, formants: [500, 1100, 2400])
        let female = synthVoice(f0: 220, formants: [850, 1900, 3200])
        let e1 = SpeakerEmbedder.embed(samples: male)!
        let e2 = SpeakerEmbedder.embed(samples: female)!
        let sim = SpeakerEmbedder.cosineSimilarity(e1, e2)
        XCTAssertLessThan(sim, SpeakerDiarizer.clusterThreshold,
            "Distinct voices must stay under the cluster threshold, got \(sim)")
    }

    // MARK: - Diarizer

    @MainActor
    func test_diarizer_clustersSameVoiceTogether() {
        // Use a fresh in-memory profile store so test data from other runs
        // doesn't cross-contaminate identification.
        let diarizer = SpeakerDiarizer()
        let a1 = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let a2 = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let a3 = synthVoice(f0: 130, formants: [700, 1200, 2500])
        let x1 = diarizer.assign(samples: a1)
        let x2 = diarizer.assign(samples: a2)
        let x3 = diarizer.assign(samples: a3)
        XCTAssertNotNil(x1); XCTAssertNotNil(x2); XCTAssertNotNil(x3)
        XCTAssertEqual(x1!.speakerId, x2!.speakerId)
        XCTAssertEqual(x2!.speakerId, x3!.speakerId)
        XCTAssertEqual(x1!.label, "Speaker 1")
    }

    @MainActor
    func test_diarizer_separatesDistinctVoices() {
        let diarizer = SpeakerDiarizer()
        let male   = synthVoice(f0: 110, formants: [500, 1100, 2400])
        let female = synthVoice(f0: 220, formants: [850, 1900, 3200])
        let a = diarizer.assign(samples: male)
        let b = diarizer.assign(samples: female)
        let aAgain = diarizer.assign(samples: male)
        XCTAssertNotNil(a); XCTAssertNotNil(b); XCTAssertNotNil(aAgain)
        XCTAssertNotEqual(a!.speakerId, b!.speakerId)
        XCTAssertEqual(a!.speakerId, aAgain!.speakerId,
            "Male returning after female should re-join its own cluster")
        XCTAssertEqual(a!.label, "Speaker 1")
        XCTAssertEqual(b!.label, "Speaker 2")
    }

    // MARK: - Profile enrollment

    @MainActor
    func test_profileMatching_labelsClusterByName() {
        let store = SpeakerProfileStore.shared
        // Clean slate for this test.
        for p in store.profiles { store.delete(id: p.id) }

        let enrolledVoice = synthVoice(f0: 110, formants: [500, 1100, 2400])
        let emb = SpeakerEmbedder.embed(samples: enrolledVoice)!
        store.enroll(name: "Enrolled-TEST", embedding: emb)

        // New diarizer session. Now that "Enrolled-TEST" is enrolled, a matching
        // voice should get labeled with the profile name instead of
        // "Speaker 1".
        let diarizer = SpeakerDiarizer(profileStore: store)
        let assign = diarizer.assign(samples: enrolledVoice)
        XCTAssertNotNil(assign)
        XCTAssertEqual(assign!.label, "Enrolled-TEST")
        XCTAssertNotNil(assign!.matchedProfile)

        // Tidy up so other tests don't see this profile.
        if let p = store.get(name: "Enrolled-TEST") { store.delete(id: p.id) }
    }

    @MainActor
    func test_profileStore_enrollMergesSameName() {
        let store = SpeakerProfileStore.shared
        for p in store.profiles where p.name == "Merge-TEST" { store.delete(id: p.id) }
        let e1 = SpeakerEmbedder.embed(samples: synthVoice(f0: 150, formants: [800, 1400, 2700]))!
        let p1 = store.enroll(name: "Merge-TEST", embedding: e1)
        let p2 = store.enroll(name: "Merge-TEST", embedding: e1)
        XCTAssertEqual(p1.id, p2.id, "Second enroll with same name must merge, not duplicate")
        XCTAssertEqual(p2.sampleCount, 2)
        store.delete(id: p2.id)
    }
}
