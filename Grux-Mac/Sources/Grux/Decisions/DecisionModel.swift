import Foundation

// One shape for every small judgment Grux makes. A provider answers typed
// questions about a piece of state with a confidence attached; the engine
// picks the provider and the ledger records the cost. Text generation never
// goes through here, only decisions.

enum DecisionQuestion: Equatable {
    /// Pick one option. `criteria` maps an option name to its description.
    case choice(instructions: String, criteria: [String: String])
    /// A probability that a yes/no statement holds.
    case noul(instructions: String)
    /// A position on an ordered scale. `levels` runs from low to high.
    case score(instructions: String, levels: [String])
}

enum DecisionAnswer: Equatable {
    case choice(String, confidence: Double, probabilities: [String: Double])
    case noul(Double)
    case score(Double, confidence: Double)

    /// The confidence a router compares against the execute threshold.
    var confidence: Double {
        switch self {
        case .choice(_, let c, _): return c
        case .noul(let p): return max(p, 1 - p)
        case .score(_, let c): return c
        }
    }
}

enum DecisionProviderKind: String, Codable, Equatable {
    case jev, local
}

struct DecisionResult: Equatable {
    let answers: [String: DecisionAnswer]
    let latencyMs: Int
    let inputTokens: Int
    let outputTokens: Int
    let provider: DecisionProviderKind

    /// The same answers, timed as `ms`.
    func withLatency(_ ms: Int) -> DecisionResult {
        DecisionResult(answers: answers, latencyMs: ms, inputTokens: inputTokens,
                       outputTokens: outputTokens, provider: provider)
    }
}

protocol DecisionProvider {
    var kind: DecisionProviderKind { get }
    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult
}
