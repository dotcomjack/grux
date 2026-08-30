import Foundation

// MARK: - ClaudeCodeAdapter
//
// The reference adapter. Reproduces SwarmWorker's exact `claude --print`
// invocation and reuses StreamJSONParser + LimitSignal as its parser, so the
// bridge path and the legacy SwarmWorker path stay byte-for-byte identical in
// how they drive Claude Code. Everything Claude-specific lives here; the runner
// stays CLI-agnostic.

public struct ClaudeCodeAdapter: AgentAdapter {
    public let id = "claude"
    public let displayName = "Claude Code"
    public let defaultModel: String

    public init(defaultModel: String = "claude-opus-4-8") {
        self.defaultModel = defaultModel
    }

    public var detectionCandidates: AdapterDetectionCandidates {
        // Mirrors SwarmWorker.resolveClaudeBinary: $CLAUDE_BIN, then the same
        // fixed candidate list, in the same priority order.
        AdapterDetectionCandidates(
            toolName: "claude",
            envVar: "CLAUDE_BIN",
            candidatePaths: [
                "~/.local/bin/claude",
                "~/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "/usr/bin/claude"
            ],
            versionArgs: ["--version"]
        )
    }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(supportsResume: true, supportsStreamJSON: true, promptViaStdin: true)
    }

    public func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation {
        let resolvedModel = model ?? defaultModel
        let execPath = AgentCLIRegistry.resolveExecutablePath(for: detectionCandidates)
        // EXACT SwarmWorker argv (SwarmWorker.run L316-346). --verbose is
        // required for stream-json; --permission-mode bypassPermissions means
        // the sandbox is the only guard (the runner wraps this in sandbox-exec);
        // --no-session-persistence keeps the run ephemeral (the stream is the
        // log). extraArgs slot in where SwarmWorker adds --append-system-prompt
        // and --allowedTools. The prompt goes on stdin, never argv.
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--model", resolvedModel,
            "--add-dir", cwd,
            "--no-session-persistence"
        ]
        args.append(contentsOf: extraArgs)
        args.append(contentsOf: ["--input-format", "text"])

        // Strip API-billing env so the CLI stays on the Claude.ai subscription.
        let env = AgentCLIRegistry.oauthSafeEnvironment()

        return AdapterInvocation(
            executablePath: execPath,
            args: args,
            env: env,
            stdinPayload: prompt + "\n",
            cwd: cwd
        )
    }

    public func makeStreamParser() -> any AdapterStreamParsing {
        ClaudeStreamAdapterParser()
    }
}

// Wraps the existing StreamJSONParser + LimitSignal into AdapterEvents. Holds
// no cross-chunk state itself: the residual buffer lives in the runner and
// StreamJSONParser.parseChunk is a pure function, so this just maps.
public final class ClaudeStreamAdapterParser: AdapterStreamParsing {
    public init() {}

    public func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String) {
        let (streamEvents, remainder) = StreamJSONParser.parseChunk(chunk)
        var out: [AdapterEvent] = []
        out.reserveCapacity(streamEvents.count)
        for ev in streamEvents {
            let raw = Self.rawLine(of: ev)
            // Fold the monthly-limit detector in exactly where SwarmWorker runs
            // it: on every event's raw line. Emit the marker BEFORE the mapped
            // event so a consumer sees the pause reason first.
            if LimitSignal.detect(rawLine: raw) {
                out.append(.limitSignal(raw: raw))
            }
            out.append(Self.map(ev))
        }
        return (out, remainder)
    }

    private static func map(_ ev: StreamJSONEvent) -> AdapterEvent {
        switch ev {
        case .systemInit(let sid, let model, let raw):
            return .systemInit(sessionId: sid, model: model, raw: raw)
        case .assistantText(let text, let raw):
            return .assistantText(text: text, raw: raw)
        case .toolUse(let name, let inputJSON, let raw):
            return .toolUse(name: name, inputJSON: inputJSON, raw: raw)
        case .toolResult(let text, let raw):
            return .toolResult(text: text, raw: raw)
        case .usage(let cost, let inT, let outT, let raw):
            return .usage(costUSD: cost, inputTokens: inT, outputTokens: outT, raw: raw)
        case .finalResult(let text, let cost, let success, let raw):
            return .finalResult(text: text, costUSD: cost, success: success, raw: raw)
        case .unknown(let raw):
            return .unknown(raw: raw)
        }
    }

    private static func rawLine(of ev: StreamJSONEvent) -> String {
        switch ev {
        case .systemInit(_, _, let raw): return raw
        case .assistantText(_, let raw): return raw
        case .toolUse(_, _, let raw): return raw
        case .toolResult(_, let raw): return raw
        case .usage(_, _, _, let raw): return raw
        case .finalResult(_, _, _, let raw): return raw
        case .unknown(let raw): return raw
        }
    }
}
