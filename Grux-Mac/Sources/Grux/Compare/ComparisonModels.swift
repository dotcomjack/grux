import Foundation

// Blind model comparison data shapes. A ComparisonRecord captures one fan-out:
// the prompt, every contender's output (text, latency, token usage, error),
// a deterministic label-shuffle seed for blind display, the vote, and the
// optional synthesized merged answer. Persisted by ComparisonStore as a single
// JSON array, same Persistence.load/save conventions as FolderStore.

// One contender's result from a single fan-out run.
struct ComparisonOutput: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var backendName: String        // human-readable, e.g. "Claude (claude-haiku-4-5)"
    var modelId: String            // raw model id sent on the wire
    var text: String               // the completion (empty when failed)
    var latencySeconds: Double
    var inputTokens: Int
    var outputTokens: Int
    var errorText: String?         // non-nil when the call threw

    init(id: UUID = UUID(), backendName: String, modelId: String, text: String,
         latencySeconds: Double, inputTokens: Int = 0, outputTokens: Int = 0,
         errorText: String? = nil) {
        self.id = id
        self.backendName = backendName
        self.modelId = modelId
        self.text = text
        self.latencySeconds = latencySeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.errorText = errorText
    }

    var failed: Bool { errorText != nil }
}

// One complete comparison run, including vote + synthesis state.
struct ComparisonRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var createdAt: Date
    var prompt: String
    var outputs: [ComparisonOutput]
    var labelSeed: UInt64          // drives the deterministic blind shuffle
    var blind: Bool                // run started in blind mode
    var revealed: Bool             // user flipped the reveal toggle
    var votedOutputId: UUID?       // which output won the vote, nil until voted
    var synthesis: String?         // merged best answer, nil until synthesized
    var synthesizedBy: String?     // backend name that produced the synthesis

    init(id: UUID = UUID(), createdAt: Date = Date(), prompt: String,
         outputs: [ComparisonOutput], labelSeed: UInt64, blind: Bool = true,
         revealed: Bool = false, votedOutputId: UUID? = nil,
         synthesis: String? = nil, synthesizedBy: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.outputs = outputs
        self.labelSeed = labelSeed
        self.blind = blind
        self.revealed = revealed
        self.votedOutputId = votedOutputId
        self.synthesis = synthesis
        self.synthesizedBy = synthesizedBy
    }

    // Display slot s shows outputs[displayOrder[s]]. Deterministic per record
    // (seeded by labelSeed) so columns never re-jumble across view refreshes.
    var displayOrder: [Int] {
        ComparisonShuffle.shuffledIndices(count: outputs.count, seed: labelSeed)
    }

    var votedOutput: ComparisonOutput? {
        guard let votedOutputId else { return nil }
        return outputs.first(where: { $0.id == votedOutputId })
    }
}

// SplitMix64, a tiny seedable PRNG. Foundation's SystemRandomNumberGenerator
// can't take a seed, and we need the shuffle reproducible for a given record
// (and testable). Standard constants from Steele et al.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum ComparisonShuffle {
    // Fisher-Yates permutation of 0..<count, fully determined by the seed.
    static func shuffledIndices(count: Int, seed: UInt64) -> [Int] {
        guard count > 0 else { return [] }
        var gen = SeededGenerator(seed: seed)
        return Array(0..<count).shuffled(using: &gen)
    }

    // Anonymous label for a display slot: "A", "B", ... wraps past 26 with a
    // numeric suffix so any contender count stays unambiguous.
    static func label(forSlot slot: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if slot < letters.count { return String(letters[slot]) }
        return "\(letters[slot % letters.count])\(slot / letters.count + 1)"
    }
}
