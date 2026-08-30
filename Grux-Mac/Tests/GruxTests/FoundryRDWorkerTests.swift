import XCTest
@testable import Grux
import GruxAgentCore

// Unit tests for the Foundry R&D worker rail: prompt composition snapshots,
// worktree slug/branch/path logic, git command builders, effort sizing, the
// stream-event fold over mock CLI output fixtures, and the RDRunLog NDJSON
// round trip. NOTHING here spawns a real claude subprocess; the execute /
// escalate paths ride the already-tested SwarmWorker rail and stay out of
// unit scope by design.
@MainActor
final class FoundryRDWorkerTests: XCTestCase {

    // Fixed UUID so slugs and snapshots are deterministic.
    private let fixedId = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000BEEF")!

    private func makeProposal(
        title: String = "Speed up chat intake",
        lane: UpgradeLane = .performance,
        domain: UpgradeDomain = .mac,
        gain: Double = 0.62,
        risk: RiskClass = .low,
        costLabel: String = "$2 estimated",
        prompt: String = "Refactor Sources/Grux/Chat/ChatIntake.swift to batch token handling.",
        touchedPaths: [String] = ["Sources/Grux/Chat/ChatIntake.swift"],
        evidence: [UpgradeEvidence] = [UpgradeEvidence(source: "metrics", detail: "p95 chat latency 4.2s over 7d")]
    ) -> UpgradeProposal {
        UpgradeProposal(
            id: fixedId,
            title: title,
            lane: lane,
            domain: domain,
            evidence: evidence,
            expectedGain: gain,
            riskClass: risk,
            estCostLabel: costLabel,
            tierRequired: .propose,
            readyPrompt: prompt,
            touchedPaths: touchedPaths
        )
    }

    // MARK: - Prompt composition snapshots

    func testComposePromptSnapshot() throws {
        let prompt = RDWorker.composePrompt(makeProposal())
        let expected = """
        You are the Grux Foundry R&D worker. Deliver exactly one upgrade end to end inside the workspace described below, then stop. Work autonomously: read the evidence, make the change, verify, commit.

        ## Proposal
        - Title: Speed up chat intake
        - Lane: Performance | Domain: Mac
        - Risk class: Low | Trust tier required: Propose
        - Expected gain: 0.62 of 1.0
        - Cost: $2 estimated

        ## Evidence
        - metrics: p95 chat latency 4.2s over 7d

        ## Files in scope (exact paths)
        - Sources/Grux/Chat/ChatIntake.swift

        \(RDWorker.conventionsBlock())

        ## Task
        Refactor Sources/Grux/Chat/ChatIntake.swift to batch token handling.

        \(RDWorker.verifyBlock())
        """
        XCTAssertEqual(prompt, expected)
    }

    func testComposePromptWorktreeVariantAddsWorkspaceBlock() throws {
        let prompt = RDWorker.composePrompt(
            makeProposal(),
            worktreePath: "/tmp/.worktrees/speed-up-chat-intake-0a1b2c",
            branch: "upgrade/speed-up-chat-intake-0a1b2c"
        )
        XCTAssertTrue(prompt.contains("## Workspace"))
        XCTAssertTrue(prompt.contains("- Worktree: /tmp/.worktrees/speed-up-chat-intake-0a1b2c"))
        XCTAssertTrue(prompt.contains("- Branch: upgrade/speed-up-chat-intake-0a1b2c (created from the current branch; commit here only)"))
        XCTAssertTrue(prompt.contains("Never modify files outside this worktree."))
        // Workspace slots between Files and Conventions.
        let filesIdx = prompt.range(of: "## Files in scope")!.lowerBound
        let wsIdx = prompt.range(of: "## Workspace")!.lowerBound
        let convIdx = prompt.range(of: "## Conventions")!.lowerBound
        XCTAssertTrue(filesIdx < wsIdx && wsIdx < convIdx)
    }

    func testComposePromptCarriesConventionsEvidenceAndVerifyGates() throws {
        let prompt = RDWorker.composePrompt(makeProposal())
        // Conventions block names every hard rule.
        XCTAssertTrue(prompt.contains("No em dash (U+2014) and no en dash (U+2013)"))
        XCTAssertTrue(prompt.contains("labeled estimated"))
        XCTAssertTrue(prompt.contains("Conventional Commits"))
        XCTAssertTrue(prompt.contains("Tests stay at baseline"))
        XCTAssertTrue(prompt.contains("Zero new dependencies"))
        // Protected zones ride along from TrustLedger.
        XCTAssertTrue(prompt.contains("keychainstore.swift"))
        XCTAssertTrue(prompt.contains("sources/grux/security/"))
        // Verify steps are ordered.
        XCTAssertTrue(prompt.contains("1. swift build"))
        XCTAssertTrue(prompt.contains("2. swift test"))
        XCTAssertTrue(prompt.contains("RD_RESULT:"))
        // The prompt itself obeys the dash ban.
        XCTAssertFalse(prompt.contains("\u{2014}"))
        XCTAssertFalse(prompt.contains("\u{2013}"))
    }

    func testComposePromptEmptyEvidenceAndPathsGetHonestPlaceholders() throws {
        let prompt = RDWorker.composePrompt(makeProposal(touchedPaths: [], evidence: []))
        XCTAssertTrue(prompt.contains("- (no recorded signals; treat the task description as the evidence)"))
        XCTAssertTrue(prompt.contains("- (no paths pinned; choose the smallest possible blast radius)"))
    }

    func testComposeFollowUpPromptIncludesPriorReportAndGates() throws {
        let followUp = RDWorker.composeFollowUpPrompt(
            title: "Speed up chat intake",
            branch: "upgrade/speed-up-chat-intake-0a1b2c",
            worktreePath: "/tmp/wt",
            previousFinalText: "RD_RESULT: PASS batched the token handling.",
            instruction: "Also cover the streaming path."
        )
        XCTAssertTrue(followUp.contains("continuing Foundry upgrade 'Speed up chat intake'"))
        XCTAssertTrue(followUp.contains("RD_RESULT: PASS batched the token handling."))
        XCTAssertTrue(followUp.contains("Also cover the streaming path."))
        XCTAssertTrue(followUp.contains("## Verify before you finish"))

        let blank = RDWorker.composeFollowUpPrompt(
            title: "T", branch: "b", worktreePath: "/tmp/wt",
            previousFinalText: nil, instruction: "x"
        )
        XCTAssertTrue(blank.contains("(none captured)"))
    }

    func testNormalizedCostLabelAlwaysCarriesEstimated() throws {
        XCTAssertEqual(RDWorker.normalizedCostLabel("$2 estimated"), "$2 estimated")
        XCTAssertEqual(RDWorker.normalizedCostLabel("$5"), "$5 estimated")
        XCTAssertEqual(RDWorker.normalizedCostLabel("  $3 Estimated  "), "$3 Estimated")
        XCTAssertEqual(RDWorker.normalizedCostLabel(""), "$0 estimated")
    }

    // MARK: - Worktree slug / branch / path logic

    func testSlugIsKebabWithIdSuffix() throws {
        let p = makeProposal(title: "Speed up chat intake")
        XCTAssertEqual(RDWorktree.slug(for: p), "speed-up-chat-intake-0a1b2c")
    }

    func testSlugStripsPunctuationAndCollapsesRuns() throws {
        let p = makeProposal(title: "  Fix: Cache flush (2x)!! ")
        XCTAssertEqual(RDWorktree.slug(for: p), "fix-cache-flush-2x-0a1b2c")
    }

    func testSlugCapsLengthAndHandlesEmptyTitles() throws {
        let long = makeProposal(title: String(repeating: "verylongword ", count: 12))
        let slug = RDWorktree.slug(for: long)
        XCTAssertTrue(slug.hasSuffix("-0a1b2c"))
        XCTAssertLessThanOrEqual(slug.count, 40 + 7)
        XCTAssertFalse(slug.contains("--0a1b2c"))

        let empty = makeProposal(title: "!!! ???")
        XCTAssertEqual(RDWorktree.slug(for: empty), "upgrade-0a1b2c")
    }

    func testBranchAndWorktreePathConventions() throws {
        let slug = "speed-up-chat-intake-0a1b2c"
        XCTAssertEqual(RDWorktree.branchName(slug: slug), "upgrade/\(slug)")
        let repoRoot = URL(fileURLWithPath: "/Users/example/Code/Grux-Mac")
        let wt = RDWorktree.worktreeURL(repoRoot: repoRoot, slug: slug)
        // Sibling .worktrees dir, same convention as the roadmap worktree.
        XCTAssertEqual(wt.path, "/Users/example/Code/.worktrees/\(slug)")
    }

    func testGitCommandBuilders() throws {
        let add = RDWorktree.addCommand(
            repoRoot: "/repo",
            branch: "upgrade/x-0a1b2c",
            worktreePath: "/code/.worktrees/x-0a1b2c"
        )
        XCTAssertTrue(add.contains("mkdir -p '/code/.worktrees'"))
        XCTAssertTrue(add.contains("git -C '/repo' worktree add -b 'upgrade/x-0a1b2c' '/code/.worktrees/x-0a1b2c' HEAD"))

        let rm = RDWorktree.removeCommand(repoRoot: "/repo", worktreePath: "/code/.worktrees/x-0a1b2c")
        XCTAssertTrue(rm.contains("worktree remove --force '/code/.worktrees/x-0a1b2c'"))
        XCTAssertTrue(rm.contains("worktree prune"))

        let del = RDWorktree.deleteBranchCommand(repoRoot: "/repo", branch: "upgrade/x-0a1b2c")
        XCTAssertTrue(del.contains("branch -D 'upgrade/x-0a1b2c'"))
    }

    func testShellQuoteEscapesSingleQuotes() throws {
        XCTAssertEqual(RDWorktree.shellQuote("a'b"), "'a'\\''b'")
    }

    // MARK: - Effort sizing routes M+ to the swarm

    func testEffortEstimation() throws {
        // Low risk, 1 path, short prompt: S, runs single session.
        XCTAssertEqual(RDEffort.estimate(for: makeProposal()), .s)
        // Medium risk bumps to M.
        XCTAssertEqual(RDEffort.estimate(for: makeProposal(risk: .medium)), .m)
        // Three pinned paths bump to M.
        XCTAssertEqual(
            RDEffort.estimate(for: makeProposal(touchedPaths: ["a", "b", "c"])),
            .m
        )
        // High risk + wide blast radius: L.
        XCTAssertEqual(
            RDEffort.estimate(for: makeProposal(risk: .high, touchedPaths: ["a", "b", "c", "d", "e", "f"])),
            .l
        )
        // Comparable: the escalate gate is effort >= .m.
        XCTAssertTrue(RDEffort.m >= .m)
        XCTAssertFalse(RDEffort.s >= .m)
        XCTAssertEqual(RDEffort.l.displayName, "L")
    }

    // MARK: - Stream-event fold (mock CLI output, no real claude ever)

    private let fixtureLines: [String] = [
        #"{"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-7"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the proposal evidence now."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"Build complete!"}]}}"#,
        #"{"type":"assistant","message":{"content":[],"usage":{"input_tokens":900,"output_tokens":120}},"total_cost_usd":0.0421}"#,
        #"{"type":"result","subtype":"success","total_cost_usd":0.0834,"result":"RD_RESULT: PASS batched token handling."}"#
    ]

    func testFoldOverHappyPathFixtures() throws {
        let (state, events) = RDStreamFold.fold(rawLines: fixtureLines)
        XCTAssertEqual(state.assistantTexts, ["Reading the proposal evidence now."])
        XCTAssertEqual(state.toolUseCount, 1)
        XCTAssertEqual(state.toolResultCount, 1)
        XCTAssertEqual(state.costUSD, 0.0834, accuracy: 0.0001)
        XCTAssertEqual(state.finalText, "RD_RESULT: PASS batched token handling.")
        XCTAssertEqual(state.finalSuccess, true)
        XCTAssertFalse(state.limitDetected)

        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds, [.info, .assistantText, .toolUse, .toolResult, .usage, .runEnd])
        XCTAssertEqual(events.last?.costUSD ?? 0, 0.0834, accuracy: 0.0001)
    }

    func testFoldDetectsMonthlyLimitViaExistingDetector() throws {
        // Shape captured from a real limit hit (see LimitSignal.swift docs).
        let limitLines = [
            #"{"type":"assistant","error":"rate_limit","message":{"content":[{"type":"text","text":"You've hit your org's monthly usage limit"}]},"model":"<synthetic>"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your org's monthly usage limit"}"#
        ]
        let (state, events) = RDStreamFold.fold(rawLines: limitLines)
        XCTAssertTrue(state.limitDetected)
        XCTAssertEqual(events.first?.kind, .limitDetected)
    }

    func testFoldIgnoresMalformedAndUnknownLines() throws {
        let (state, events) = RDStreamFold.fold(rawLines: ["", "not json", #"{"type":"mystery"}"#])
        XCTAssertEqual(state, RDFoldState())
        XCTAssertTrue(events.isEmpty)
    }

    func testStepMappingFlagsStuckAndLimit() throws {
        let stuck = RDStreamFold.event(forStep: AgentStep(
            kind: .error,
            text: "idle TTL exceeded (600s of stream-json silence) | claude went quiet mid-run"
        ))
        XCTAssertEqual(stuck.kind, .stuckDetected)

        let plainError = RDStreamFold.event(forStep: AgentStep(kind: .error, text: "spawn failed"))
        XCTAssertEqual(plainError.kind, .error)

        let limit = RDStreamFold.event(forStep: AgentStep(kind: .authLimitDetected, text: "limit"))
        XCTAssertEqual(limit.kind, .limitDetected)

        let tool = RDStreamFold.event(forStep: AgentStep(kind: .toolUse, toolName: "Bash", text: "Bash swift build"))
        XCTAssertEqual(tool.kind, .toolUse)

        let start = RDStreamFold.event(forStep: AgentStep(kind: .workerStart, text: "spawning"))
        XCTAssertEqual(start.kind, .info)
    }

    // MARK: - Run handle persistence (engine state survives relaunch)

    func testRunHandleCodableRoundTrip() throws {
        let handle = RDRunHandle(
            runId: "rd-1749500000-fix-chat-abc123",
            proposalId: UUID(),
            proposalTitle: "Fix chat",
            lane: .performance,
            domain: .mac,
            slug: "fix-chat-abc123",
            branch: "upgrade/fix-chat-abc123",
            repoRoot: URL(fileURLWithPath: "/tmp/repo"),
            worktreePath: "/tmp/.worktrees/fix-chat-abc123",
            runDir: URL(fileURLWithPath: "/tmp/runs/rd-1")
        )
        let map: [UUID: RDRunHandle] = [handle.proposalId: handle]
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode([UUID: RDRunHandle].self, from: data)
        XCTAssertEqual(back[handle.proposalId]?.runId, handle.runId)
        XCTAssertEqual(back[handle.proposalId]?.branch, handle.branch)
        XCTAssertEqual(back[handle.proposalId]?.worktreePath, handle.worktreePath)
        XCTAssertEqual(back[handle.proposalId]?.repoRoot, handle.repoRoot)
    }

    // MARK: - Token usage forwarding (budget governor seam)

    func testTokenUsageParsesStreamPayloadShapes() throws {
        // Top-level usage object.
        let top = #"{"usage":{"input_tokens":1200,"output_tokens":340,"cache_read_input_tokens":50,"cache_creation_input_tokens":7}}"#
        let u1 = RDStreamFold.tokenUsage(fromPayloadJSON: top)
        XCTAssertEqual(u1?.inputTokens, 1200)
        XCTAssertEqual(u1?.outputTokens, 340)
        XCTAssertEqual(u1?.cacheReadTokens, 50)
        XCTAssertEqual(u1?.cacheCreationTokens, 7)
        XCTAssertEqual(u1?.total, 1597)

        // Nested under message (assistant message shape).
        let nested = #"{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":20}}}"#
        let u2 = RDStreamFold.tokenUsage(fromPayloadJSON: nested)
        XCTAssertEqual(u2?.total, 30)

        // No usage, malformed, nil: all nil, never a zero-token record.
        XCTAssertNil(RDStreamFold.tokenUsage(fromPayloadJSON: #"{"type":"assistant"}"#))
        XCTAssertNil(RDStreamFold.tokenUsage(fromPayloadJSON: "not json"))
        XCTAssertNil(RDStreamFold.tokenUsage(fromPayloadJSON: nil))
        XCTAssertNil(RDStreamFold.tokenUsage(fromPayloadJSON: #"{"usage":{"input_tokens":0,"output_tokens":0}}"#))
    }

    func testRunSinkForwardsUsageToTheRecorder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-rd-sink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class Box: @unchecked Sendable {
            var recorded: [(FoundryTokenUsage, String)] = []
        }
        let box = Box()
        let sink = RDRunSink(
            log: RDRunLog(runDir: dir),
            modelID: "claude-opus-4-7",
            recordUsage: { usage, model in box.recorded.append((usage, model)) }
        )

        await sink.worker("w1", didEmit: AgentStep(
            kind: .usage,
            text: "cost=$0.0421",
            payloadJSON: #"{"usage":{"input_tokens":100,"output_tokens":25}}"#,
            costUSD: 0.0421
        ))
        // Non-usage steps and usage steps without token payloads never forward.
        await sink.worker("w1", didEmit: AgentStep(kind: .assistantText, text: "hi"))
        await sink.worker("w1", didEmit: AgentStep(kind: .usage, text: "cost only", payloadJSON: nil, costUSD: 0.01))

        XCTAssertEqual(box.recorded.count, 1, "exactly one token-bearing usage step forwarded")
        XCTAssertEqual(box.recorded.first?.0.total, 125)
        XCTAssertEqual(box.recorded.first?.1, "claude-opus-4-7")
    }

    // MARK: - RDRunLog NDJSON round trip

    func testRunLogAppendsAndReloadsNDJSON() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-rd-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = RDRunLog(runDir: dir)
        await log.append(RDRunEvent(kind: .runStart, text: "executing 'x'"))
        await log.append(RDRunEvent(kind: .toolUse, text: "Bash swift build", costUSD: nil))
        await log.append(RDRunEvent(kind: .usage, text: "cost $0.0421 estimated", costUSD: 0.0421))
        await log.writePrompt("the prompt body")

        let events = await log.load()
        XCTAssertEqual(events.map(\.kind), [.runStart, .toolUse, .usage])
        XCTAssertEqual(events[2].costUSD ?? 0, 0.0421, accuracy: 0.0001)

        // NDJSON on disk: one compact JSON object per line.
        let raw = try String(contentsOf: dir.appendingPathComponent("log.ndjson"), encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").count, 3)

        // Prompt forensics copy landed beside the log.
        let prompt = try String(contentsOf: dir.appendingPathComponent("prompt.md"), encoding: .utf8)
        XCTAssertEqual(prompt, "the prompt body")

        // Tail limit.
        let tail = await log.load(limit: 1)
        XCTAssertEqual(tail.map(\.kind), [.usage])
    }
}
