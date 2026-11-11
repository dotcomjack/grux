import XCTest
@testable import Grux

/// D102 (sense pass 9, 2026-10-31): the README promised "you can run the whole
/// thing without sending a token to anyone" twice, and listed "An Anthropic API
/// key, or Ollama running locally" as the requirement, while Focus log and
/// Compare need an Anthropic key whatever runs locally and the agent features
/// hand work to the Claude Code CLI. A person who chose a local model because of
/// that line found three panes asking for Claude.
///
/// The features that need the key are read from the registry, so a new one the
/// README does not name turns this red.
final class ReadmeLocalModelClaimTests: XCTestCase {
    private func readme() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    }

    /// The features a local model cannot stand in for: they require the
    /// Anthropic key and no either-or group lets a local model satisfy it.
    private var needClaudeKey: [String] {
        FeatureRegistry.rows.filter { row in
            row.requires.contains(.keyAnthropic)
                && !row.anyOf.contains { $0.capabilities.contains(.keyAnthropic) && $0.capabilities.contains(.endpointOllama) }
        }.map(\.label)
    }

    /// The features that cannot run without the Claude Code CLI: a blocking
    /// `stepAgentCliInstalled` in the registry.
    private var runClaudeCode: [String] {
        FeatureRegistry.rows.filter { $0.steps.contains(.stepAgentCliInstalled) }.map(\.label)
    }

    /// Paragraphs, split on blank lines.
    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
    }

    func test_theRegistryStillNamesFeaturesThatNeedTheKey() {
        XCTAssertEqual(Set(needClaudeKey), ["Compare", "Focus log"],
                       "the set changed: the README's local-model lines must name the new set")
        XCTAssertEqual(Set(runClaudeCode), ["Agents", "Jax Command", "Self-Upgrade"],
                       "the set changed: the README's local-model lines must name the new set")
    }

    func test_theReadmeNeverPromisesTheWholeThingRunsLocally() throws {
        let text = try readme().lowercased()
        for promise in ["run the whole thing without", "the whole thing without sending",
                        "everything runs locally", "everything without sending"] {
            XCTAssertFalse(text.contains(promise), "the README promises \"\(promise)\"")
        }
    }

    /// Every paragraph that says a local model sends no token names, in the
    /// same paragraph, each feature that still needs Claude.
    func test_everyNoTokenLineNamesWhatStillNeedsClaude() throws {
        // 3.2.0 words the claim "what you type goes to no model provider".
        let claims = paragraphs(try readme()).filter {
            $0.contains("without sending a token") || $0.contains("goes to no model provider")
        }
        XCTAssertFalse(claims.isEmpty, "the README no longer says what runs locally at all")
        for p in claims {
            for label in needClaudeKey + runClaudeCode {
                XCTAssertTrue(p.contains(label), "a no-token line does not name \(label): \(p)")
            }
        }
    }

    /// The requirement line says which features the key or the CLI is for.
    func test_theRequirementsSayWhatNeedsTheKey() throws {
        let line = try XCTUnwrap(try readme().components(separatedBy: "\n")
            .first { $0.contains("Ollama running locally") })
        for label in needClaudeKey + runClaudeCode {
            XCTAssertTrue(line.contains(label), "the requirement line does not name \(label): \(line)")
        }
    }
}
