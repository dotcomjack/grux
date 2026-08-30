import Foundation

// MARK: - AiderAdapter
//
// aider is a plain-text CLI: no stream-json, no structured events. In one-shot
// mode (`aider --message <p> --yes-always --no-stream`) it prints conversational
// text interleaved with the edits it applies. The edits arrive as either
// SEARCH/REPLACE blocks (aider's default "diff" edit format) or unified diffs.
//
// The parser best-effort lifts those edits into .fileArtifact events and passes
// everything else through as .assistantText. It cannot recover a byte-perfect
// file (a SEARCH/REPLACE only shows the changed region), so .fileArtifact.content
// is the NEW-side text of the edit, which is enough for the Studio to show
// "aider touched <path>" and inspect the change.

public struct AiderAdapter: AgentAdapter {
    public let id = "aider"
    public let displayName = "Aider"

    public init() {}

    public var detectionCandidates: AdapterDetectionCandidates {
        AdapterDetectionCandidates(
            toolName: "aider",
            envVar: "AIDER_BIN",
            candidatePaths: [
                "~/.local/bin/aider",
                "/opt/homebrew/bin/aider",
                "/usr/local/bin/aider",
                "/usr/bin/aider"
            ],
            versionArgs: ["--version"]
        )
    }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(supportsResume: false, supportsStreamJSON: false, promptViaStdin: false)
    }

    public func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation {
        let execPath = AgentCLIRegistry.resolveExecutablePath(for: detectionCandidates)
        // --no-pretty strips ANSI color so the plain-text parser sees clean
        // lines; --yes-always answers aider's confirm prompts; --no-stream
        // makes it print complete output rather than token-by-token.
        var args: [String] = ["--message", prompt, "--yes-always", "--no-stream", "--no-pretty"]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: extraArgs)
        return AdapterInvocation(
            executablePath: execPath,
            args: args,
            env: ProcessInfo.processInfo.environment,
            stdinPayload: nil,
            cwd: cwd
        )
    }

    public func makeStreamParser() -> any AdapterStreamParsing {
        AiderStreamAdapterParser()
    }
}

public final class AiderStreamAdapterParser: AdapterStreamParsing {

    private enum Mode {
        case idle
        case srSearch          // inside <<<<<<< SEARCH, before =======
        case srReplace         // after =======, before >>>>>>> REPLACE
        case udiffMaybe        // saw "--- ", waiting to confirm "+++ " on next line
        case udiff             // confirmed unified-diff hunk
    }

    private var mode: Mode = .idle
    private var pendingPath = ""
    private var replaceLines: [String] = []
    private var addedLines: [String] = []
    private var lastNonEmptyLine = ""   // filename candidate for a S/R block
    private var pendingMinusHeader = "" // the "--- " line held during udiffMaybe

    public init() {}

    public func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String) {
        guard let lastNewline = chunk.lastIndex(of: "\n") else {
            return ([], chunk)
        }
        let complete = chunk[..<lastNewline]
        let remainder = String(chunk[chunk.index(after: lastNewline)...])
        var events: [AdapterEvent] = []
        // omittingEmptySubsequences:false keeps blank lines, which terminate a
        // unified-diff hunk.
        for lineSub in complete.split(separator: "\n", omittingEmptySubsequences: false) {
            process(String(lineSub), into: &events)
        }
        return (events, remainder)
    }

    private func process(_ line: String, into events: inout [AdapterEvent]) {
        switch mode {
        case .idle:
            if line.hasPrefix("<<<<<<< SEARCH") {
                pendingPath = Self.cleanPath(lastNonEmptyLine)
                replaceLines = []
                mode = .srSearch
                return
            }
            if line.hasPrefix("--- ") {
                pendingMinusHeader = line
                mode = .udiffMaybe
                return
            }
            emitText(line, into: &events)
            if !Self.isBlank(line) && !Self.isFence(line) {
                lastNonEmptyLine = line
            }

        case .srSearch:
            // Ignore the old-side content; a lone "=======" flips to REPLACE.
            if line.hasPrefix("=======") { mode = .srReplace }

        case .srReplace:
            if line.hasPrefix(">>>>>>> REPLACE") {
                let content = replaceLines.joined(separator: "\n")
                events.append(.fileArtifact(path: pendingPath, content: content, raw: line))
                replaceLines = []
                mode = .idle
                return
            }
            replaceLines.append(line)

        case .udiffMaybe:
            if line.hasPrefix("+++ ") {
                pendingPath = Self.cleanPath(Self.stripDiffHeader(line, prefix: "+++ "))
                addedLines = []
                mode = .udiff
            } else {
                // Not a diff after all: the held "--- " line and this line were
                // ordinary text.
                emitText(pendingMinusHeader, into: &events)
                pendingMinusHeader = ""
                mode = .idle
                process(line, into: &events)
            }

        case .udiff:
            if line.hasPrefix("+++ ") {
                // New target within the same diff: flush and re-anchor.
                flushUdiff(into: &events)
                pendingPath = Self.cleanPath(Self.stripDiffHeader(line, prefix: "+++ "))
                addedLines = []
                return
            }
            if line.hasPrefix("--- ") {
                flushUdiff(into: &events)
                pendingMinusHeader = line
                mode = .udiffMaybe
                return
            }
            if line.hasPrefix("@@") { return }              // hunk header
            if line.hasPrefix("+") { addedLines.append(String(line.dropFirst())); return }
            if line.hasPrefix("-") || line.hasPrefix(" ") { return } // removed / context
            // Anything else ends the hunk; reprocess it as ordinary text.
            flushUdiff(into: &events)
            mode = .idle
            process(line, into: &events)
        }
    }

    private func flushUdiff(into events: inout [AdapterEvent]) {
        guard !pendingPath.isEmpty, !addedLines.isEmpty else {
            addedLines = []
            return
        }
        let content = addedLines.joined(separator: "\n")
        events.append(.fileArtifact(path: pendingPath, content: content, raw: pendingPath))
        addedLines = []
    }

    private func emitText(_ line: String, into events: inout [AdapterEvent]) {
        // Skip pure-blank lines so the assistant stream is not padded with them.
        guard !Self.isBlank(line) else { return }
        events.append(.assistantText(text: line, raw: line))
    }

    // MARK: - helpers

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    // Strip a diff header prefix and any trailing "\t<timestamp>" aider/git append.
    private static func stripDiffHeader(_ line: String, prefix: String) -> String {
        var rest = String(line.dropFirst(prefix.count))
        if let tab = rest.firstIndex(of: "\t") {
            rest = String(rest[..<tab])
        }
        return rest
    }

    // Normalize a path token: trim, drop wrapping backticks, strip a leading
    // "a/" or "b/" git diff prefix.
    private static func cleanPath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("`") { p.removeFirst() }
        while p.hasSuffix("`") { p.removeLast() }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
        return p
    }
}
