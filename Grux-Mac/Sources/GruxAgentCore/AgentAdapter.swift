import Foundation

// MARK: - AgentAdapter
//
// The contract that turns "some agent CLI on this machine" into something the
// bridge can spawn and stream uniformly. Extracted along the seams the
// external-agent-rail contract identified in SwarmWorker.run():
//   1. spawn  -> buildInvocation(...) -> AdapterInvocation
//   2. stream -> makeStreamParser()   -> AdapterStreamParsing (per-run state)
//   3. detect -> detectionCandidates  -> AgentCLIRegistry probes these
//
// Adapters are pure descriptions: they carry NO process, NO mutable run state,
// and never execute anything themselves. Detection and execution live in
// AgentCLIRegistry and AgentBridgeRunner respectively, so an adapter value is
// trivially Sendable and safe to hand across isolation domains.

// How the registry finds this CLI on disk. Probed in order: the env override,
// then the fixed candidate paths, then `which <toolName>` on PATH. Detection
// NEVER runs the CLI for real: it only runs `<path> <versionArgs>` (short,
// bounded) to confirm the binary is the tool we think it is.
public struct AdapterDetectionCandidates: Sendable, Equatable {
    // Bare command name, e.g. "claude" / "codex" / "gemini" / "aider". Used for
    // the `which` fallback and as the last-resort executable when nothing else
    // resolves (let PATH sort it out at spawn time).
    public let toolName: String
    // Environment variable that, when set to an executable path, wins outright
    // (e.g. "CLAUDE_BIN"). Mirrors SwarmWorker.resolveClaudeBinary's $CLAUDE_BIN.
    public let envVar: String
    // Fixed absolute or ~-prefixed paths to probe, in priority order.
    public let candidatePaths: [String]
    // Args that make the CLI print its version fast and exit (the probe).
    public let versionArgs: [String]

    public init(toolName: String, envVar: String, candidatePaths: [String], versionArgs: [String]) {
        self.toolName = toolName
        self.envVar = envVar
        self.candidatePaths = candidatePaths
        self.versionArgs = versionArgs
    }
}

// A fully-formed spawn recipe. AgentBridgeRunner wraps executablePath in
// sandbox-exec, sets env + cwd, feeds stdinPayload (if any), and runs args.
public struct AdapterInvocation: Sendable {
    // The agent binary itself (absolute path, or a bare name for /usr/bin/env
    // resolution when the path could not be resolved up front).
    public let executablePath: String
    // Args passed to the agent binary (NOT including the sandbox-exec wrapper,
    // which the runner adds).
    public let args: [String]
    // Full environment for the child. Claude's adapter strips API-billing keys
    // here via AgentCLIRegistry.oauthSafeEnvironment; others pass their own
    // provider keys through untouched.
    public let env: [String: String]
    // Prompt delivered on stdin (preferred for long prompts). nil when the
    // prompt is carried as an arg instead (promptViaStdin == false).
    public let stdinPayload: String?
    public let cwd: String

    public init(executablePath: String, args: [String], env: [String: String], stdinPayload: String?, cwd: String) {
        self.executablePath = executablePath
        self.args = args
        self.env = env
        self.stdinPayload = stdinPayload
        self.cwd = cwd
    }
}

// Coarse feature flags the caller uses to decide routing (e.g. only a
// stream-json CLI gets live tool-by-tool UI; a resume-capable CLI can be
// re-queued with a session id rather than restarted from scratch).
public struct AdapterCapabilities: Sendable, Equatable {
    // Can this CLI resume a prior session (claude --resume <id>)? Reserved:
    // resume is orchestrator-level today, this just advertises the capability.
    public let supportsResume: Bool
    // Does it emit structured stream-json (true) or plain text (false)?
    public let supportsStreamJSON: Bool
    // Is the prompt fed on stdin (true) or as a CLI arg (false)?
    public let promptViaStdin: Bool

    public init(supportsResume: Bool, supportsStreamJSON: Bool, promptViaStdin: Bool) {
        self.supportsResume = supportsResume
        self.supportsStreamJSON = supportsStreamJSON
        self.promptViaStdin = promptViaStdin
    }
}

// Per-run incremental parser. Stateful across chunks (a plain-text adapter
// accumulates a diff block across many reads), so a FRESH instance is minted
// per run via AgentAdapter.makeStreamParser(). Residual-buffer semantics: the
// caller keeps the trailing partial line the parser returns and prepends it to
// the next chunk, exactly like StreamJSONParser.parseChunk.
//
// AnyObject (reference type) because it holds mutable per-run state. NOT
// required to be Sendable: it is created and used entirely inside the runner's
// actor and never sent across isolation domains.
public protocol AdapterStreamParsing: AnyObject {
    // Consume as much of `chunk` as forms complete units, returning the parsed
    // events plus the unconsumed trailing remainder to carry into the next call.
    func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String)
}

// The adapter itself. Value-type-friendly: implementers are structs.
public protocol AgentAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }
    var detectionCandidates: AdapterDetectionCandidates { get }
    var capabilities: AdapterCapabilities { get }

    // Build the spawn recipe. `model` nil = the adapter's own default. Any
    // adapter-specific extras (a scaffold, an allowedTools list) come in via
    // extraArgs so this stays a pure argv builder.
    func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation

    // Fresh per-run parser (see AdapterStreamParsing).
    func makeStreamParser() -> any AdapterStreamParsing
}

public extension AgentAdapter {
    // Convenience overload so callers that need neither a model override nor
    // extra args stay terse.
    func buildInvocation(prompt: String, cwd: String) -> AdapterInvocation {
        buildInvocation(prompt: prompt, cwd: cwd, model: nil, extraArgs: [])
    }
}
