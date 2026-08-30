import Foundation

// A model provider Grux can route a turn through. Methods + labels + default
// arg values match ClaudeClient verbatim so any backend is drop-in. All types
// (ClaudeMessage, ClaudeTool, ClaudeStreamEvent, ClaudeToolsResponse) stay the
// canonical wire shapes defined in Claude.swift, no renaming, no new structs.
//
// NOTE on defaults: a Swift protocol requirement can't itself carry default
// argument values, but conforming concrete types CAN, and ClaudeClient already
// does (maxTokens=1024/2048, temperature=0.2/0.3, spanName/feature literals).
// Existing call sites that omit args bind to the concrete ClaudeClient defaults.
// The ONLY call site that invokes through a ModelBackend-typed variable, the
// ChatService seam, passes every argument explicitly, so through-protocol
// calls never rely on protocol-level defaults.
//
// That last sentence used to read "the other 17 call sites keep calling the
// concrete `ClaudeClient()` they instantiate directly", and it was the whole
// defect: only chat was ever routed, so every other feature ignored the user's
// provider entirely. Twenty five of those sites now resolve through
// `ModelRegistry.resolvedRouting`. Three do not, on purpose, and
// `BackendSweepTests` names them with the reason and fails if a reason stops
// being true. Two of the three want prompt caching, which this protocol does
// not expose yet: adding `completeCached` here, with an OpenAI compatible
// implementation, is what would let them move.
protocol ModelBackend: Actor {
    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error>

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int)
}

// AnthropicBackend, the canonical default. ClaudeClient already implements
// every signature above with identical external labels, so this is a pure
// retroactive conformance: zero body, zero behavior change. Claude.swift is
// untouched and stays the default backend.
extension ClaudeClient: ModelBackend {}
