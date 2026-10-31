import XCTest
@testable import Grux

// F3: "Grux, upgrade yourself" must leave proposals behind. Before this, the
// cycle harvested signals and logged a count, and nothing turned them into
// proposals, so the Self-Upgrade pane stayed empty forever no matter what the
// signals said. These tests pin the synthesis stage, the stranded-build sweep
// that also covers a build with no recorded worktree, and the chat tool's
// honest reply when self-upgrade is off.
@MainActor
final class FoundrySynthesisTests: XCTestCase {

    private func signal(
        _ source: String,
        _ severity: FoundrySignal.Severity,
        _ summary: String,
        lane: FoundryLane = .reliability,
        domain: String = "chat",
        evidence: String = "receipt line"
    ) -> FoundrySignal {
        FoundrySignal(source: source, severity: severity, summary: summary, evidence: evidence,
                      suggestedLane: lane, suggestedDomain: domain)
    }

    private func tempStore() -> ProposalStore {
        ProposalStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-synthesis-\(UUID().uuidString).json"))
    }

    // MARK: - Synthesis

    func test_signalsBecomeProposalsOnePerSourceLaneAndDomain() {
        let signals = [
            signal("transcript", .high, "Thread 'Trip': 4 user correction(s) right after assistant replies"),
            signal("transcript", .medium, "Thread 'Taxes': 2 user correction(s) right after assistant replies"),
            signal("swarm", .high, "Swarm job failed: 'Refactor'", domain: "swarm"),
            signal("telemetry", .info, "fs-audit: nothing to see", domain: "telemetry"),
        ]
        let filed = SignalProposalFiler.proposals(from: signals, existing: [])
        XCTAssertEqual(filed.count, 2, "two groups at low or above; info never files")
        let chat = filed.first { $0.signalKey == "transcript|reliability|chat" }
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.evidence.count, 2, "every signal in the group is cited")
        XCTAssertEqual(chat?.evidence.first?.source, "transcript")
        XCTAssertTrue(chat?.title.contains("and 1 more like it") ?? false, chat?.title ?? "")
        for p in filed {
            XCTAssertEqual(p.status, .proposed)
            XCTAssertEqual(p.tierRequired, .propose)
            XCTAssertEqual(p.domain, .mac)
            XCTAssertTrue(p.estCostLabel.hasPrefix("$") && p.estCostLabel.contains("estimated"))
            XCTAssertTrue(p.expectedGain > 0 && p.expectedGain <= 1)
            XCTAssertFalse(p.readyPrompt.isEmpty)
            XCTAssertTrue(p.readyPrompt.contains("test that fails before"), "the worker is told to prove it red first")
            for text in [p.title, p.readyPrompt] + p.evidence.map(\.detail) {
                XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "dash in \(p.title)")
            }
        }
    }

    func test_lanesCarryOver() {
        let filed = SignalProposalFiler.proposals(from: [
            signal("compare", .medium, "Compare: 'x' errored in 3 runs", lane: .performance, domain: "compare"),
            signal("ux-audit", .low, "[settings] clipped label", lane: .uxPolish, domain: "ui:settings"),
        ], existing: [])
        XCTAssertEqual(Set(filed.map(\.lane)), [.performance, .uxPolish])
    }

    func test_aRepeatPassFilesNothingNewAndWhatThePersonTurnedDownStaysDown() {
        let signals = [signal("swarm", .high, "Swarm job failed: 'A'", domain: "swarm")]
        var first = SignalProposalFiler.proposals(from: signals, existing: [])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(SignalProposalFiler.proposals(from: signals, existing: first).isEmpty,
                      "an open proposal for the same signals is not filed twice")
        first[0].status = .rejected
        first[0].declinedByPerson = true
        XCTAssertTrue(SignalProposalFiler.proposals(from: signals, existing: first).isEmpty,
                      "a proposal the person turned down is not filed again every pass")
        first[0].status = .rolledBack
        first[0].declinedByPerson = nil
        XCTAssertEqual(SignalProposalFiler.proposals(from: signals, existing: first).count, 1,
                       "a fix that was rolled back did not fix it: file again")
    }

    /// Wave 4 review, P2: Grux's own rejections (usage limit, stalled build,
    /// failed verify, lost worktree) blocked the group forever, while the
    /// reason told the person to re-file and nothing could.
    func test_aRejectionGruxMadeItselfDoesNotBlockTheNextPass() {
        let signals = [signal("swarm", .high, "Swarm job failed: 'A'", domain: "swarm")]
        var first = SignalProposalFiler.proposals(from: signals, existing: [])
        first[0].status = .rejected
        XCTAssertEqual(SignalProposalFiler.proposals(from: signals, existing: first).count, 1)
        first[0].declinedByPerson = false
        XCTAssertEqual(SignalProposalFiler.proposals(from: signals, existing: first).count, 1)
    }

    /// Wave 4 review, P2: a fix that just landed was filed again by the next
    /// pass from the same pre-fix signals (sources look back up to 30 days and
    /// stamp signals with the harvest time). Quiet for the longest window.
    func test_aLandedFixIsQuietForTheLongestHarvestWindow() {
        let signals = [signal("transcript", .medium, "Thread 'Trip': 2 user correction(s) right after assistant replies")]
        let landedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var first = SignalProposalFiler.proposals(from: signals, existing: [], now: landedAt)
        first[0].status = .landed
        first[0].updatedAt = landedAt
        let quiet = SignalProposalFiler.quietAfterLanding
        XCTAssertEqual(quiet, 30 * 86_400, "Compare looks back 30 days, the longest source")
        // A new problem in the same group waits out the quiet period; the
        // signal the fix answered never refiles it from a source with no
        // lookback (a windowed source refiles: see the recurrence test).
        let fresh = signals + [signal("transcript", .medium, "Thread 'Trip': 3 user correction(s) right after assistant replies")]
        for (offset, files, label) in [(60.0, false, "a minute after"), (quiet - 1, false, "one under"),
                                       (quiet, true, "exactly on"), (quiet + 1, true, "one over")] {
            let now = landedAt.addingTimeInterval(offset)
            XCTAssertEqual(SignalProposalFiler.proposals(from: fresh, existing: first, now: now).count,
                           files ? 1 : 0, "new signal, \(label)")
            XCTAssertTrue(SignalProposalFiler.proposals(from: signals, existing: first, now: now).isEmpty,
                          "answered signal, \(label)")
        }
    }

    /// Wave 4 re-review, P2: transcripts and the flake log have no lookback
    /// window, so after the quiet period the very signal the fix answered
    /// (an old correction in a thread still in use) filed the problem again.
    /// After the quiet period only a signal the landed fix did not cover files.
    func test_afterTheQuietPeriodOnlyANewSignalRefilesALandedFix() {
        let old = signal("transcript", .high, "Thread 'Trip': 4 user correction(s) right after assistant replies")
        let landedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var first = SignalProposalFiler.proposals(from: [old], existing: [], now: landedAt)
        XCTAssertEqual(first[0].coveredSignals, [old.summary])
        first[0].status = .landed
        first[0].updatedAt = landedAt
        let after = landedAt.addingTimeInterval(SignalProposalFiler.quietAfterLanding + 86_400)
        XCTAssertTrue(SignalProposalFiler.proposals(from: [old], existing: first, now: after).isEmpty,
                      "the signal the fix answered does not refile it")
        let fresh = signal("transcript", .high, "Thread 'Trip': 5 user correction(s) right after assistant replies")
        let refiled = SignalProposalFiler.proposals(from: [old, fresh], existing: first, now: after)
        XCTAssertEqual(refiled.count, 1, "a correction after the fix files again")
        XCTAssertEqual(refiled.first?.evidence.map(\.detail), [fresh.summary], "citing only what is new")
    }

    /// Wave 4 third review, P2: a source WITH a lookback window (swarm 14
    /// days, compare 30, fs-audit 7, the UX audit) only reports events after
    /// the quiet period that happened after the fix, so the same wording then
    /// is the problem coming back and must file. Only sources that carry no
    /// age (transcripts, the flake log, the whole-file error logs) are
    /// answered by a landed fix past its quiet period.
    func test_aSameWordedRecurrenceFromAWindowedSourceRefiles() {
        let landedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let day45 = landedAt.addingTimeInterval(45 * 86_400)
        let cases: [(FoundrySignal, Bool)] = [
            (signal("swarm", .high, "Swarm job failed: 'Nightly digest'", domain: "swarm"), true),
            (signal("compare", .medium, "Compare: 'x' errored in 3 runs", domain: "compare"), true),
            (signal("telemetry", .medium, "fs-audit: 3 'gated' filesystem-tool outcomes (of 9 audited calls)",
                    domain: "filesystem-tool"), true),
            (signal("ux-audit", .low, "[settings] clipped label", lane: .uxPolish, domain: "ui:settings"), true),
            (signal("transcript", .high, "Thread 'Trip': 4 user correction(s) right after assistant replies"), false),
            (signal("flake", .high, "Failing test: GruxTests.Foo testBar (failed 1x)", domain: "tests"), false),
            (signal("telemetry", .medium, "wake.log: 188 error-shaped log lines", domain: "logs"), false),
        ]
        for (sig, refiles) in cases {
            var first = SignalProposalFiler.proposals(from: [sig], existing: [], now: landedAt)
            first[0].status = .landed
            first[0].updatedAt = landedAt
            XCTAssertEqual(SignalProposalFiler.proposals(from: [sig], existing: first, now: day45).count,
                           refiles ? 1 : 0, sig.summary)
            XCTAssertEqual(SignalProposalFiler.carriesNoAge(sig), !refiles, sig.summary)
        }
    }

    /// Wave 4 fourth review, P2: transcript signals were known by their
    /// summary, which names the thread by title, and new threads are often
    /// titled "New chat". After a fix landed, one correction in a brand-new
    /// untitled thread matched the old summary and was dropped forever. A
    /// signal is now known by the evidence behind it (the thread and its
    /// count), not by how it reads.
    func test_aNewThreadWithTheSameTitleIsANewSignal() throws {
        func newChat(_ correction: String) -> ChatThread {
            ChatThread(title: "New chat", messages: [
                ChatMessage(role: .user, content: "what is on my calendar"),
                ChatMessage(role: .assistant, content: "Nothing today."),
                ChatMessage(role: .user, content: correction),
            ])
        }
        let fixed = try XCTUnwrap(TranscriptSignalSource.correctionSignal(in: newChat("no, I meant tomorrow")))
        let other = try XCTUnwrap(TranscriptSignalSource.correctionSignal(in: newChat("no, the work calendar")))
        XCTAssertEqual(fixed.summary, other.summary, "the two read the same")
        XCTAssertNotEqual(fixed.identity, other.identity, "and are different evidence")

        let landedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var first = SignalProposalFiler.proposals(from: [fixed], existing: [], now: landedAt)
        XCTAssertEqual(first[0].coveredSignals, [fixed.identity])
        first[0].status = .landed
        first[0].updatedAt = landedAt
        let day45 = landedAt.addingTimeInterval(45 * 86_400)
        XCTAssertTrue(SignalProposalFiler.proposals(from: [fixed], existing: first, now: day45).isEmpty,
                      "the thread the fix answered does not refile it")
        XCTAssertEqual(SignalProposalFiler.proposals(from: [fixed, other], existing: first, now: day45).count, 1,
                       "a correction in a different thread with the same title does")
    }

    func test_aSignalWithNoFingerprintIsKnownByItsSummary() {
        let s = signal("flake", .high, "Failing test: GruxTests.Foo testBar (failed 1x)", domain: "tests")
        XCTAssertNil(s.fingerprint)
        XCTAssertEqual(s.identity, s.summary)
    }

    func test_coveredSignalsListsEveryMemberEvenPastTheEvidenceCap() {
        let many = (0..<(SignalProposalFiler.maxEvidencePerProposal + 3)).map { signal("a", .high, "h\($0)") }
        let p = SignalProposalFiler.proposals(from: many, existing: [])[0]
        XCTAssertEqual(p.coveredSignals?.count, many.count)
        XCTAssertEqual(p.evidence.count, SignalProposalFiler.maxEvidencePerProposal)
    }

    func test_aNoOnAProposalGruxAlreadyRejectedIsStillRecorded() {
        let store = tempStore()
        let filed = SignalProposalFiler.file(from: [signal("swarm", .high, "s", domain: "swarm")], into: store)
        store.transition(id: filed[0].id, to: .rejected)
        XCTAssertEqual(store.decline(id: filed[0].id)?.declinedByPerson, true,
                       "the person refused the install after Grux had already given up on it")
        XCTAssertNil(store.decline(id: UUID()))
    }

    func test_declineRecordsThatThePersonSaidNo() {
        let store = tempStore()
        let filed = SignalProposalFiler.file(from: [signal("swarm", .high, "s", domain: "swarm")], into: store)
        let declined = store.decline(id: filed[0].id)
        XCTAssertEqual(declined?.status, .rejected)
        XCTAssertEqual(declined?.declinedByPerson, true)
        XCTAssertEqual(store.decline(id: filed[0].id)?.status, .rejected, "declining twice changes nothing else")
    }

    func test_everyPersonRejectPathDeclines() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/Grux/Foundry/FoundryViewBridge.swift", "Sources/Grux/Foundry/FoundryApprovals.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("to: .rejected)"), "\(path) rejects for the person through decline(id:)")
            XCTAssertTrue(text.contains(".decline(id:"), path)
        }
    }

    func test_gainRanksBySeverityAndCount() {
        let high = SignalProposalFiler.proposals(from: [signal("a", .high, "h")], existing: [])[0]
        let medium = SignalProposalFiler.proposals(from: [signal("a", .medium, "m")], existing: [])[0]
        let low = SignalProposalFiler.proposals(from: [signal("a", .low, "l")], existing: [])[0]
        XCTAssertGreaterThan(high.expectedGain, medium.expectedGain)
        XCTAssertGreaterThan(medium.expectedGain, low.expectedGain)
        let many = SignalProposalFiler.proposals(
            from: (0..<40).map { signal("a", .high, "h\($0)") }, existing: [])[0]
        XCTAssertGreaterThan(many.expectedGain, high.expectedGain)
        XCTAssertLessThanOrEqual(many.expectedGain, 1.0)
        XCTAssertLessThanOrEqual(many.evidence.count, SignalProposalFiler.maxEvidencePerProposal)
    }

    func test_onePassFilesAtMostTheCapHighestGainFirst() {
        let cap = SignalProposalFiler.maxPerPass
        var signals = (0..<(cap + 1)).map { signal("low\($0)", .low, "l\($0)") }
        signals.append(signal("urgent", .high, "h"))
        let filed = SignalProposalFiler.proposals(from: signals, existing: [])
        XCTAssertEqual(filed.count, cap, "exactly the cap, not one over")
        XCTAssertEqual(filed.first?.evidence.first?.source, "urgent")
        let atCap = SignalProposalFiler.proposals(from: Array(signals.prefix(cap)), existing: [])
        XCTAssertEqual(atCap.count, cap, "a pass with exactly the cap files every group")
    }

    func test_filingWritesTheStoreAndTheTimelineSaysHowMany() {
        let store = tempStore()
        let signals = [signal("swarm", .high, "Swarm job failed: 'A'", domain: "swarm")]
        let filed = SignalProposalFiler.file(from: signals, into: store)
        XCTAssertEqual(filed.count, 1)
        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(store.ranked().count, 1, "a filed proposal reaches the ranked queue the pane reads")
        XCTAssertTrue(SignalProposalFiler.file(from: signals, into: store).isEmpty)
        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(SignalProposalFiler.cycleDetail(signals: 3, sourceErrors: 0, filed: 1),
                       "Harvested 3 signals; filed 1 new proposal.")
        XCTAssertEqual(SignalProposalFiler.cycleDetail(signals: 1, sourceErrors: 2, filed: 0),
                       "Harvested 1 signal; filed no new proposals; 2 source errors.")
    }

    func test_aProposalFromBeforeThisFieldStillDecodes() throws {
        let json = """
        [{"id":"E69A9252-F4F8-496E-8732-1BFDCBB1444F","title":"t","lane":"uxPolish","domain":"mac",
          "evidence":[],"expectedGain":0.5,"riskClass":"low","estCostLabel":"$2 estimated",
          "tierRequired":0,"status":"building","createdAt":"2026-06-10T19:30:00Z",
          "updatedAt":"2026-06-10T19:30:00Z","readyPrompt":"p","touchedPaths":[]}]
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grux-old-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = ProposalStore(storageURL: url)
        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertNil(store.proposals[0].signalKey)
    }

    // MARK: - Stranded builds

    private func proposal(_ status: ProposalStatus) -> UpgradeProposal {
        var p = UpgradeProposal(title: "p", lane: .reliability, domain: .mac, expectedGain: 0.5,
                                riskClass: .low, estCostLabel: "$2 estimated", tierRequired: .propose,
                                readyPrompt: "p")
        p.status = status
        return p
    }

    private func handle(_ path: String) -> RDRunHandle {
        RDRunHandle(runId: "r", proposalId: UUID(), proposalTitle: "p", lane: .reliability, domain: .mac,
                    slug: "p", branch: "upgrade/x", repoRoot: URL(fileURLWithPath: "/tmp"),
                    worktreePath: path, runDir: URL(fileURLWithPath: "/tmp/run"))
    }

    func test_aBuildWithNoRecordedWorktreeIsStrandedWithAReason() {
        let building = proposal(.building)
        let verifying = proposal(.verifying)
        let open = proposal(.proposed)
        let accepted = proposal(.accepted)
        let stranded = FoundryEngine.strandedProposals(
            proposals: [building, verifying, open, accepted],
            handles: [:], escalated: [:], inFlight: [], worktreeExists: { _ in true })
        XCTAssertEqual(Set(stranded.map(\.id)), [building.id, verifying.id])
        XCTAssertTrue(stranded.allSatisfy { $0.reason.contains("next self-upgrade pass") })
    }

    func test_aBuildWhoseWorktreeVanishedIsStrandedAndALiveOneIsNot() {
        let gone = proposal(.building)
        let live = proposal(.building)
        let stranded = FoundryEngine.strandedProposals(
            proposals: [gone, live],
            handles: [gone.id: handle("/gone"), live.id: handle("/live")],
            escalated: [:], inFlight: [], worktreeExists: { $0 == "/live" })
        XCTAssertEqual(stranded.map(\.id), [gone.id])
        XCTAssertTrue(stranded[0].reason.contains("Worktree no longer on disk"))
    }

    func test_aBuildInFlightOrEscalatedIsNeverStranded() {
        let running = proposal(.building)
        let swarm = proposal(.building)
        let stranded = FoundryEngine.strandedProposals(
            proposals: [running, swarm], handles: [:], escalated: ["job-1": swarm.id],
            inFlight: [running.id], worktreeExists: { _ in false })
        XCTAssertTrue(stranded.isEmpty)
    }

    // MARK: - The chat tool when self-upgrade is off

    func test_upgradeYourselfSaysSoWhenSelfUpgradeIsOff() {
        let line = FoundryEngine.manualCycleRefusal(foundryEnabled: false)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("off") ?? false)
        XCTAssertTrue(line?.contains("Self-Upgrade") ?? false, "says where to turn it on")
        XCTAssertNil(FoundryEngine.manualCycleRefusal(foundryEnabled: true))
    }
}

/// release/3.2: one pass files from one place. The model-driven synthesizer
/// runs first; the deterministic filer only when it did not run or failed.
final class FoundryOneFilerPerPassTests: XCTestCase {
    func test_theFilerIsTheSynthesizersFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Foundry/FoundryEngine.swift"),
                             encoding: .utf8)
        let refresh = try XCTUnwrap(src.range(of: "synthesized = await ProposalSynthesizer.refresh("))
        let file = try XCTUnwrap(src.range(of: "SignalProposalFiler.file(from: report.signals"))
        XCTAssertLessThan(refresh.lowerBound, file.lowerBound, "the filer runs before the synthesizer")
        XCTAssertTrue(src.contains("let filed = !full && (synthesized == nil || synthesized?.error != nil)"),
                      "the filer runs beside the synthesizer, not instead of it")
    }
}
