import XCTest
@testable import Grux

/// D115 item 10. A stranger's first question, "What can you do?", on a local
/// model (qwen3.5:4b, installed 238727ad, 2026-11-01 11:10 AM) called
/// list_tasks, waited a second hop, and answered with the owner's tasks,
/// although the same prompt carried WHAT_YOU_CAN_DO. The lean prompt's only
/// tool rule said "call a tool only when the user asks for something it does",
/// and nothing said a question about Grux itself needs none.
@MainActor
final class LocalSelfQuestionTests: XCTestCase {

    /// The name the feature registry's block opens with, read from the block
    /// itself, so a rename there cannot leave the rule pointing at nothing.
    private var heading: String {
        let block = FeatureRegistry.systemPromptBlock(signInExpired: false)
        return String(block.prefix { !$0.isWhitespace && $0 != "(" })
    }

    func test_theRegistryBlockHasANameToPointAt() {
        XCTAssertEqual(heading, "WHAT_YOU_CAN_DO")
    }

    func test_theLeanToolRuleSendsAQuestionAboutGruxToTheListNotToATool() {
        let lean = LocalTurn.leanStable("PERSONA\n\n\(LocalTurn.leanCut). manual",
                                        tail: [FeatureRegistry.systemPromptBlock(signInExpired: false)])
        let rule = LocalTurn.toolNote
        XCTAssertTrue(lean.contains(rule), "the tool rule left the lean prompt")
        XCTAssertTrue(rule.contains(heading), "the tool rule does not name the list a question about Grux is answered from")
        XCTAssertTrue(rule.lowercased().contains("what you can do"), "the tool rule does not name the question")
        XCTAssertTrue(rule.lowercased().contains("no tool"), "the tool rule does not say a question about Grux needs no tool")
        // The rule comes before the list it points at, as the model reads it.
        let ruleAt = lean.range(of: rule)?.lowerBound
        let listAt = lean.range(of: heading + " (")?.lowerBound
        XCTAssertNotNil(listAt, "the list is not in the lean prompt")
        if let ruleAt, let listAt { XCTAssertLessThan(ruleAt, listAt) }
    }
}

/// W31 round 1 (P3): item 10 sends "What can you do?" to WHAT_YOU_CAN_DO, which put
/// Agents under WORKING RIGHT NOW while the last agent run found Claude's sign-in
/// expired, so the model could offer agents that cannot run. The list now asks the
/// setup card's own sign-in rule, as first run and Sessions do (D115 item 4).
@MainActor
final class WhatYouCanDoSignInTests: XCTestCase {
    private func block(expired: Bool, unmet: [String: [SetupRequirement]] = [:]) -> String {
        FeatureRegistry.systemPromptBlock(
            signInExpired: expired,
            state: { (unmet[$0.id] ?? []).isEmpty ? .ready : .needsSetup },
            unmet: { unmet[$0.id] ?? [] })
    }

    private func working(_ text: String) -> String {
        text.components(separatedBy: "\n").first { $0.hasPrefix("WORKING RIGHT NOW") } ?? ""
    }

    func test_anExpiredSignInMovesAgentsOutOfWorking() throws {
        let agents = try XCTUnwrap(FeatureRegistry.row(id: "agents"))
        XCTAssertTrue(agents.blocking.contains(.stepAgentCliInstalled))
        let fine = block(expired: false)
        XCTAssertTrue(working(fine).contains("Agents (labs)"), fine)
        let expired = block(expired: true)
        XCTAssertFalse(working(expired).contains("Agents (labs)"), expired)
        XCTAssertTrue(expired.contains("- Agents (labs): needs a Claude sign-in"), expired)
    }

    func test_aMissingCLIIsNamedNotTheSignIn() {
        let text = block(expired: true, unmet: ["agents": [.stepAgentCliInstalled]])
        let line = text.components(separatedBy: "\n").first { $0.hasPrefix("- Agents (labs):") } ?? ""
        XCTAssertTrue(line.contains(SetupRequirement.stepAgentCliInstalled.label), line)
        XCTAssertFalse(line.contains("sign-in"), line)
    }

    func test_aFeatureWithoutTheAgentIsUntouched() throws {
        let rows = FeatureRegistry.rows.filter { !$0.blocking.contains(.stepAgentCliInstalled) }
        let first = try XCTUnwrap(rows.first)
        let name = first.label + (first.tier == .labs ? " (labs)" : "")
        XCTAssertTrue(working(block(expired: true)).contains(name))
    }
}

/// W31 round 2 (P2): a feature the person did not pick fell into ONE STEP AWAY as
/// "- Mail: needs " with nothing after it (21 such lines on this Mini, 2026-11-01), and
/// "What can you do?" now reads this list. Every state, sign-in verdict and unmet set.
@MainActor
final class WhatYouCanDoStatesTests: XCTestCase {
    func test_noLineSaysNeedsNothing_andAnUnchosenFeatureIsTurnedOff() throws {
        let agents = try XCTUnwrap(FeatureRegistry.row(id: "agents"))
        let states: [FeatureState] = [.ready, .needsSetup, .degraded, .unavailable, .notChosen]
        let unmets: [[SetupRequirement]] = [[], [.stepAgentCliInstalled], [.stepCorpusSourcesConfirmed]]
        for state in states {
            for expired in [false, true] {
                for unmet in unmets {
                    let text = FeatureRegistry.systemPromptBlock(
                        signInExpired: expired,
                        state: { $0.id == agents.id ? state : .ready },
                        unmet: { $0.id == agents.id ? unmet : [] },
                        enableCommand: FeatureRegistry.enableCommand(bundlePath: "/Applications/Grux.app"))
                    let at = "state \(state) expired \(expired) unmet \(unmet.map(\.label))"
                    let lines = text.components(separatedBy: "\n")
                    XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("needs") || $0.hasSuffix("needs ") }, "\(at)\n\(text)")
                    let pending = lines.first { $0.hasPrefix("- Agents (labs):") }
                    let off = lines.first { $0.hasPrefix("TURNED OFF") } ?? ""
                    let working = lines.first { $0.hasPrefix("WORKING RIGHT NOW") } ?? ""
                    if state == .notChosen {
                        XCTAssertNil(pending, at)
                        XCTAssertTrue(off.contains("Agents (labs)"), at)
                        XCTAssertTrue(off.contains("grux-cli enable <id>"), at)
                        XCTAssertFalse(working.contains("Agents (labs)"), at)
                    } else {
                        XCTAssertFalse(off.contains("Agents (labs)"), at)
                    }
                }
            }
        }
    }

    func test_withEverythingChosenThereIsNoTurnedOffLine() {
        let text = FeatureRegistry.systemPromptBlock(signInExpired: false, state: { _ in .ready }, unmet: { _ in [] })
        XCTAssertFalse(text.contains("TURNED OFF"), text)
    }
}

/// W31 round 3 (P2): the TURNED OFF line named features by label and said `grux enable`
/// turns one on, but `grux enable` matches a feature id exactly ("No feature with id
/// Agents"), so every command the model could build from the line failed. Each name
/// now carries the id the command takes.
@MainActor
final class WhatYouCanDoTurnedOffIdsTests: XCTestCase {
    func test_everyTurnedOffNameCarriesTheIdGruxEnableTakes() throws {
        let command = FeatureRegistry.enableCommand(bundlePath: "/Applications/Grux.app")
        let text = FeatureRegistry.systemPromptBlock(signInExpired: false, state: { _ in .notChosen }, unmet: { _ in [] },
                                                     enableCommand: command)
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("TURNED OFF") })
        XCTAssertTrue(line.contains("`/Applications/Grux.app/Contents/MacOS/grux-cli enable <id>` in Terminal"), line)
        for row in FeatureRegistry.rows {
            var name = row.label + (row.tier == .labs ? " (labs)" : "")
            if let home = FeatureRegistry.homes[row.id] { name += " (\(home))" }
            XCTAssertTrue(line.contains("\(name) [\(row.id)]"), "\(row.id) is not listed with its id\n\(line)")
        }
        // Every bracketed id is one `grux enable` accepts: a registry row's own id.
        let re = try NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        let ns = line as NSString
        let ids = re.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertEqual(ids.count, FeatureRegistry.rows.count)
        for id in ids { XCTAssertNotNil(FeatureRegistry.row(id: id), "[\(id)] is not a feature id") }
    }
}

/// W31 round 4 (P2): the TURNED OFF line said `grux enable <id>`, and a disk image
/// install has no `grux` on PATH ("command not found" on this Mini). The line names the
/// CLI inside the running app's own bundle, where build.sh always puts it.
@MainActor
final class WhatYouCanDoEnableCommandTests: XCTestCase {
    func test_theCommandIsTheBundledCLI_quotedWhenThePathHasASpace() {
        XCTAssertEqual(FeatureRegistry.enableCommand(bundlePath: "/Applications/Grux.app"),
                       "/Applications/Grux.app/Contents/MacOS/grux-cli enable <id>")
        XCTAssertEqual(FeatureRegistry.enableCommand(bundlePath: "/Users/a/My Apps/Grux.app"),
                       "'/Users/a/My Apps/Grux.app/Contents/MacOS/grux-cli' enable <id>")
        XCTAssertEqual(FeatureRegistry.enableCommand(bundlePath: "/Users/a/Jo's/Grux.app"),
                       "'/Users/a/Jo'\\''s/Grux.app/Contents/MacOS/grux-cli' enable <id>")
    }

    func test_theLiveBlockUsesTheRunningBundle_andTheBundleShipsTheCLIThere() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/FeatureRegistry.swift"), encoding: .utf8)
        XCTAssertTrue(registry.contains("enableCommand: enableCommand(bundlePath: Bundle.main.bundlePath)"))
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains(#"cp "$CLI_SRC" "$APP/Contents/MacOS/grux-cli""#), "the bundle no longer ships the CLI where the line says")
        let live = FeatureRegistry.systemPromptBlock(signInExpired: false)
        if live.contains("TURNED OFF") {
            XCTAssertTrue(live.contains(FeatureRegistry.enableCommand(bundlePath: Bundle.main.bundlePath)))
        }
        XCTAssertFalse(live.contains("`grux enable"), "the line names a command a disk image install does not have")
    }
}
