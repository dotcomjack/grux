import Foundation

// Universal output surface for every external agent CLI the bridge drives.
//
// Mirrors StreamJSONParser.StreamJSONEvent one-to-one for the Claude adapter,
// then adds two cases the non-claude adapters need:
//   - .limitSignal: a monthly-subscription-limit marker (Claude adapter folds
//     LimitSignal.detect into its parser and emits this alongside the event).
//   - .fileArtifact: a plain-text CLI (aider) that writes a file via a diff or
//     SEARCH/REPLACE block, surfaced as a structured artifact rather than an
//     opaque wall of assistant text.
//
// Downstream consumers (AgentBridgeRunner, the Studio engine, UI) fold these
// into whatever surface they already speak (AgentStep, run results) without
// knowing which CLI produced them.
public enum AdapterEvent: Sendable {
    case systemInit(sessionId: String?, model: String?, raw: String)
    case assistantText(text: String, raw: String)
    case toolUse(name: String, inputJSON: String, raw: String)
    case toolResult(text: String, raw: String)
    case usage(costUSD: Double?, inputTokens: Int?, outputTokens: Int?, raw: String)
    case finalResult(text: String, costUSD: Double?, success: Bool, raw: String)
    // The active subscription hit its provider quota. The runner classifies
    // the whole run as limit-paused when it sees this, exactly like SwarmWorker
    // does with LimitSignal. Carries the raw line for the log.
    case limitSignal(raw: String)
    // A plain-text CLI produced a file write. path is repo-relative or absolute
    // as the CLI reported it; content is best-effort reconstructed body.
    case fileArtifact(path: String, content: String, raw: String)
    case unknown(raw: String)

    // The unparsed source line (or a synthetic marker) behind this event.
    // Uniform accessor so consumers can log/debug without a switch.
    public var raw: String {
        switch self {
        case .systemInit(_, _, let raw): return raw
        case .assistantText(_, let raw): return raw
        case .toolUse(_, _, let raw): return raw
        case .toolResult(_, let raw): return raw
        case .usage(_, _, _, let raw): return raw
        case .finalResult(_, _, _, let raw): return raw
        case .limitSignal(let raw): return raw
        case .fileArtifact(_, _, let raw): return raw
        case .unknown(let raw): return raw
        }
    }
}
