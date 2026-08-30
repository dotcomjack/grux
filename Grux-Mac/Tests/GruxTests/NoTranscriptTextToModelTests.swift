import XCTest

/// The workday log may read that a Claude Code session happened. It may not read
/// what was said in it.
///
/// `~/.claude/projects` holds every Claude Code transcript on the machine.
/// `FilesystemTool` denylists `.claude` precisely so no model-facing tool can
/// reach it. `WorkdayLogAssembler` reached it anyway, on a scheduler that starts
/// at first launch, and put the first 200 characters the USER typed and the last
/// 200 the ASSISTANT wrote into a prompt:
///
///     let sample = "first: \(firstUser) | last: \(lastAssistant) | tools: ..."
///
/// That is around the boundary rather than through it, and it made the shipped
/// claim that the model's only route to disk is one Swift file untrue.
///
/// ## Why this is a source scan and not a behavioural test
///
/// The leak is not a wrong value, it is a BINDING: the moment somebody writes
/// `case .assistant(let ts, let text, ...)` in this file, the text is in hand
/// and the next line that interpolates it ships. Asserting on an output would
/// need a populated `~/.claude/projects`, which CI does not have and a
/// contributor's machine has too much of.
final class NoTranscriptTextToModelTests: XCTestCase {

    /// Files that read Claude Code session entries and also talk to a model.
    /// Repo-relative so two files of the same name cannot silently share an entry.
    private static let guardedFiles = [
        "Sources/Grux/WorkdayLog/WorkdayLogAssembler.swift",
    ]

    /// Pattern positions that carry MESSAGE TEXT in a `ClaudeSessionEntry`.
    /// A binding here means the text is available to interpolate.
    private static let textCarryingPatterns = [
        "case .user(let ts, let text",
        "case .assistant(let ts, let text",
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Anti-vacuity. Runs first, because a test that cannot find its file passes
    /// forever and says nothing.
    func testGuardedFilesExistAndStillReadSessions() throws {
        for rel in Self.guardedFiles {
            let url = repoRoot.appendingPathComponent(rel)
            let body = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(body.contains("case .user("),
                "\(rel) no longer pattern-matches session entries, so this guard is watching nothing. Delete it or repoint it.")
            XCTAssertTrue(body.contains("sessionSampleCache"),
                "\(rel) no longer builds a model payload from sessions; re-check whether this guard still has a job.")
        }
    }

    /// The invariant.
    func testWorkdayLogNeverBindsTranscriptText() throws {
        var offenders: [String] = []
        for rel in Self.guardedFiles {
            let body = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            for (i, line) in body.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                for pat in Self.textCarryingPatterns where code.contains(pat) {
                    offenders.append("\(rel):\(i + 1)  \(code)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) binding(s) of Claude Code message text in a file that sends data to a model:
            \(offenders.joined(separator: "\n"))
            Bind `_` for the text position. Tool names and turn counts describe what a session DID; \
            the message text is what the user and the assistant SAID, and it belongs on their disk.
            """)
    }
}
