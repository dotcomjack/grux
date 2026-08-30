import XCTest
@testable import Grux

// Unit tests for the Foundry core: proposal ranking, trust ledger
// promotion/demotion, protected-path pinning, and JSON round-trips.
// Every test uses its own temp storage URL so nothing touches the real
// ~/Library/Application Support/Grux/foundry/. flush() forces past the
// debounced scheduleSave before reload assertions.
@MainActor
final class FoundryCoreTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-foundry-test-\(name)-\(UUID().uuidString).json")
    }

    private func makeProposal(
        title: String = "Speed up chat intake",
        lane: UpgradeLane = .performance,
        domain: UpgradeDomain = .mac,
        gain: Double = 0.5,
        risk: RiskClass = .low,
        prompt: String = "Refactor Sources/Grux/Chat/ChatIntake.swift to batch token handling.",
        touchedPaths: [String] = [],
        evidence: [UpgradeEvidence] = [UpgradeEvidence(source: "metrics", detail: "p95 latency 4.2s over 7d")]
    ) -> UpgradeProposal {
        UpgradeProposal(
            title: title,
            lane: lane,
            domain: domain,
            evidence: evidence,
            expectedGain: gain,
            riskClass: risk,
            estCostLabel: "$2 estimated",
            tierRequired: .propose,
            readyPrompt: prompt,
            touchedPaths: touchedPaths
        )
    }

    // MARK: - Ranking

    func testRankedOrdersByGainDescThenRiskAsc() throws {
        let store = ProposalStore(storageURL: tempURL("rank"))
        let lowGain = store.file(makeProposal(title: "Low gain", gain: 0.2, risk: .low))
        let highGainRisky = store.file(makeProposal(title: "High gain risky", gain: 0.9, risk: .high))
        let highGainSafe = store.file(makeProposal(title: "High gain safe", gain: 0.9, risk: .low))
        let midGain = store.file(makeProposal(title: "Mid gain", gain: 0.5, risk: .medium))

        let ranked = store.ranked()
        XCTAssertEqual(ranked.count, 4)
        XCTAssertEqual(ranked[0].id, highGainSafe.id, "gain ties break toward lower risk")
        XCTAssertEqual(ranked[1].id, highGainRisky.id)
        XCTAssertEqual(ranked[2].id, midGain.id)
        XCTAssertEqual(ranked[3].id, lowGain.id)
    }

    func testRankedExcludesTerminalAndLanded() throws {
        let store = ProposalStore(storageURL: tempURL("rank-terminal"))
        let open = store.file(makeProposal(title: "Open", gain: 0.1))
        let rejected = store.file(makeProposal(title: "Rejected", gain: 0.9))
        let landed = store.file(makeProposal(title: "Landed", gain: 0.95))

        store.transition(id: rejected.id, to: .rejected)
        store.transition(id: landed.id, to: .accepted)
        store.transition(id: landed.id, to: .building)
        store.transition(id: landed.id, to: .verifying)
        store.transition(id: landed.id, to: .landed)

        let ranked = store.ranked()
        XCTAssertEqual(ranked.map(\.id), [open.id], "ranked queue holds only open proposals")
        XCTAssertEqual(store.ranked(includeAll: true).count, 3)
    }

    // MARK: - Status transitions

    func testStatusTransitionsFollowTheLoop() throws {
        let store = ProposalStore(storageURL: tempURL("transitions"))
        let p = store.file(makeProposal())

        // Illegal: cannot leap straight to landed or building.
        XCTAssertNil(store.transition(id: p.id, to: .landed))
        XCTAssertNil(store.transition(id: p.id, to: .building))

        // Legal walk through the five-stage loop.
        XCTAssertEqual(store.transition(id: p.id, to: .accepted)?.status, .accepted)
        XCTAssertEqual(store.transition(id: p.id, to: .building)?.status, .building)
        XCTAssertEqual(store.transition(id: p.id, to: .verifying)?.status, .verifying)
        XCTAssertEqual(store.transition(id: p.id, to: .landed)?.status, .landed)
        XCTAssertEqual(store.transition(id: p.id, to: .rolledBack)?.status, .rolledBack)

        // Terminal: rolledBack never transitions again.
        XCTAssertNil(store.transition(id: p.id, to: .proposed))
        XCTAssertNil(store.transition(id: p.id, to: .accepted))
    }

    // A headless build that ends paused / stuck / failed leaves the proposal
    // in .building. FoundryEngine.rejectStrandedBuild (and the missing-handle
    // guards in escalatedJobChanged + install) recover by transitioning to
    // .rejected, the only legal escape from .building (and from .verifying).
    // This guards that escape AND that the card no longer reads ACCEPTED: a
    // .building/.verifying proposal maps to .accepted, but once rejected it
    // maps to .rejected, so the Self-Upgrade card stops being a one-way door.
    func testStrandedBuildEscapesViaRejectAndCardStopsReadingAccepted() throws {
        let store = ProposalStore(storageURL: tempURL("stranded"))
        let p = store.file(makeProposal())
        XCTAssertEqual(store.transition(id: p.id, to: .accepted)?.status, .accepted)
        XCTAssertEqual(store.transition(id: p.id, to: .building)?.status, .building)

        // While stuck in .building the card reads ACCEPTED (the dead-end).
        XCTAssertEqual(FoundryViewBridge.cardStatus(.building), .accepted)
        // .verifying (the consumed-approval install limbo) also reads ACCEPTED.
        XCTAssertEqual(FoundryViewBridge.cardStatus(.verifying), .accepted)

        // The recovery: .building -> .rejected is legal and fires.
        let rejected = store.transition(id: p.id, to: .rejected)
        XCTAssertEqual(rejected?.status, .rejected,
                       ".building must be able to escape to .rejected so a stranded build is not permanent")
        // Now the card reads REJECTED, not ACCEPTED, no longer a one-way door.
        XCTAssertEqual(FoundryViewBridge.cardStatus(.rejected), .rejected)
    }

    // The install / escalated-done missing-handle guards transition from
    // .verifying -> .rejected. Confirm that escape is legal too (the only
    // alternative to .landed), so a lost handle can't strand a consumed
    // approval in .verifying forever.
    func testVerifyingEscapesViaRejectWhenInstallCannotRun() throws {
        let store = ProposalStore(storageURL: tempURL("verifying-escape"))
        let p = store.file(makeProposal())
        store.transition(id: p.id, to: .accepted)
        store.transition(id: p.id, to: .building)
        store.transition(id: p.id, to: .verifying)

        let rejected = store.transition(id: p.id, to: .rejected)
        XCTAssertEqual(rejected?.status, .rejected,
                       ".verifying must escape to .rejected when a lost handle blocks install")
    }

    // MARK: - Trust ledger promotion / demotion table

    func testLedgerPromotesAfterFiveConsecutiveKeeps() throws {
        let ledger = TrustLedger(storageURL: tempURL("promote"))
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .propose, "every pair starts at propose")

        for i in 1...4 {
            let e = ledger.recordAcceptedAndKept(lane: .performance, domain: .mac)
            XCTAssertEqual(e.tier, .propose, "no promotion before five keeps (at \(i))")
            XCTAssertEqual(e.streak, i)
        }
        let promoted = ledger.recordAcceptedAndKept(lane: .performance, domain: .mac)
        XCTAssertEqual(promoted.tier, .autoBuild, "fifth consecutive keep promotes")
        XCTAssertEqual(promoted.streak, 0, "streak resets so the next rung is earned from scratch")

        // Five more reach autoLand; five beyond that stay clamped.
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .performance, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoLand)
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .performance, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoLand, "autoLand is the ceiling")
    }

    func testLedgerRollbackDemotesImmediatelyAndResetsStreak() throws {
        let ledger = TrustLedger(storageURL: tempURL("rollback"))
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .uxPolish, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .uxPolish, domain: .mac), .autoBuild)

        // Mid-streak rollback: demote one tier, streak gone.
        for _ in 1...3 { _ = ledger.recordAcceptedAndKept(lane: .uxPolish, domain: .mac) }
        let demoted = ledger.recordRollback(lane: .uxPolish, domain: .mac)
        XCTAssertEqual(demoted.tier, .propose)
        XCTAssertEqual(demoted.streak, 0)

        // Floor: rollback at propose stays at propose.
        let floored = ledger.recordRollback(lane: .uxPolish, domain: .mac)
        XCTAssertEqual(floored.tier, .propose, "propose is the floor")
    }

    func testLedgerTwoConsecutiveRejectionsDemote() throws {
        let ledger = TrustLedger(storageURL: tempURL("rejections"))
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .cost, domain: .mini) }
        XCTAssertEqual(ledger.tier(lane: .cost, domain: .mini), .autoBuild)

        // One rejection: streak resets, tier holds.
        let one = ledger.recordRejection(lane: .cost, domain: .mini)
        XCTAssertEqual(one.tier, .autoBuild)
        XCTAssertEqual(one.streak, 0)
        XCTAssertEqual(one.consecutiveRejections, 1)

        // Second consecutive rejection: demote.
        let two = ledger.recordRejection(lane: .cost, domain: .mini)
        XCTAssertEqual(two.tier, .propose)
        XCTAssertEqual(two.consecutiveRejections, 0, "counter resets after the demotion fires")
    }

    func testLedgerKeepBreaksRejectionStreak() throws {
        let ledger = TrustLedger(storageURL: tempURL("reject-break"))
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .reliability, domain: .phone) }
        XCTAssertEqual(ledger.tier(lane: .reliability, domain: .phone), .autoBuild)

        _ = ledger.recordRejection(lane: .reliability, domain: .phone)
        _ = ledger.recordAcceptedAndKept(lane: .reliability, domain: .phone)
        let after = ledger.recordRejection(lane: .reliability, domain: .phone)
        XCTAssertEqual(after.tier, .autoBuild, "non-consecutive rejections do not demote")
        XCTAssertEqual(after.consecutiveRejections, 1)
    }

    func testLedgerPairsAreIndependent() throws {
        let ledger = TrustLedger(storageURL: tempURL("pairs"))
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .performance, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoBuild)
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .phone), .propose, "domains track separately")
        XCTAssertEqual(ledger.tier(lane: .reliability, domain: .mac), .propose, "lanes track separately")
    }

    // MARK: - Protected-path pinning

    func testIsProtectedPathMatchesPinnedZones() throws {
        XCTAssertTrue(TrustLedger.isProtectedPath("Sources/Grux/iPhone/PhoneProtocol.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("Sources/Grux/iPhone/PhoneCrypto.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("/abs/worktree/Grux-Mac/Sources/Grux/KeychainStore.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("Sources/Grux/Security/SensitiveActionGate.swift"))
        XCTAssertFalse(TrustLedger.isProtectedPath("Sources/Grux/Notes/NotesStore.swift"))
        XCTAssertFalse(TrustLedger.isProtectedPath("Sources/Grux/iPhone/SurfaceSync.swift"))
    }

    // Git diffs and Claude Code prompts routinely reference files by
    // package-root-relative path (no Sources/ prefix) or by bare filename.
    // The old lone "sources/grux/security/" marker missed those, so a
    // low-risk proposal could auto-land a Security change. All these shapes
    // must now be detected as protected.
    func testIsProtectedPathCatchesRelativeSecurityPaths() throws {
        XCTAssertTrue(TrustLedger.isProtectedPath("Security/SecurityPolicy.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("Security/URLGuard.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("./Security/PromptSecurity.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("URLGuard.swift"))
        XCTAssertTrue(TrustLedger.isProtectedPath("a/b//security//SecurityAuditLog.swift"))
        // Control: an unrelated file is still not protected.
        XCTAssertFalse(TrustLedger.isProtectedPath("Notes/NotesStore.swift"))
    }

    // The full pinning path must climb to .protected for a relative Security
    // touchedPath plus a matching prompt, the exact escape the protected rail
    // forbids.
    func testProtectedPinningCatchesRelativeSecurityPath() throws {
        let pinned = TrustLedger.applyProtectedPinning(to: makeProposal(
            prompt: "Edit Security/SecurityPolicy.swift to relax the allowlist.",
            touchedPaths: ["Security/SecurityPolicy.swift"]
        ))
        XCTAssertEqual(pinned.riskClass, RiskClass.protected)
        XCTAssertEqual(pinned.tierRequired, TrustTier.propose)
    }

    func testProposalTouchingProtectedZoneIsPinnedOnFile() throws {
        let store = ProposalStore(storageURL: tempURL("pin-file"))
        let sneaky = makeProposal(
            title: "Tighten pairing",
            lane: .capability,
            domain: .phone,
            gain: 0.8,
            risk: .low,
            prompt: "Edit Sources/Grux/iPhone/PhoneProtocol.swift to add a new frame type."
        )
        let filed = store.file(sneaky)
        XCTAssertEqual(filed.riskClass, .protected, "prompt touching wire protocol forces protected")
        XCTAssertEqual(filed.tierRequired, .propose, "protected proposals are pinned to propose")
    }

    func testProtectedPinningViaTouchedPathsAndEvidence() throws {
        let viaPaths = TrustLedger.applyProtectedPinning(to: makeProposal(
            touchedPaths: ["Sources/Grux/Security/SecurityPolicy.swift"]
        ))
        XCTAssertEqual(viaPaths.riskClass, .protected)
        XCTAssertEqual(viaPaths.tierRequired, .propose)

        let viaEvidence = TrustLedger.applyProtectedPinning(to: makeProposal(
            evidence: [UpgradeEvidence(source: "fs-audit", detail: "stale token handling in KeychainStore.swift")]
        ))
        XCTAssertEqual(viaEvidence.riskClass, .protected)

        let clean = TrustLedger.applyProtectedPinning(to: makeProposal())
        XCTAssertEqual(clean.riskClass, .low, "non-protected proposals are untouched")
    }

    func testProtectedPinningSurvivesPromptUpdate() throws {
        let store = ProposalStore(storageURL: tempURL("pin-update"))
        let p = store.file(makeProposal())
        XCTAssertEqual(store.proposal(id: p.id)?.riskClass, .low)

        // A prompt rewrite that pulls a protected path into scope must
        // re-pin on update.
        let updated = store.update(id: p.id, readyPrompt: "Also adjust Sources/Grux/Security/URLGuard.swift allowlist.")
        XCTAssertEqual(updated?.riskClass, .protected)
        XCTAssertEqual(updated?.tierRequired, .propose)
    }

    // MARK: - Round-trips

    func testProposalStoreRoundTrip() throws {
        let url = tempURL("store-roundtrip")
        let store = ProposalStore(storageURL: url)
        let a = store.file(makeProposal(title: "Alpha", gain: 0.7))
        let b = store.file(makeProposal(title: "Beta", lane: .codeHealth, domain: .site, gain: 0.3, risk: .medium))
        store.transition(id: a.id, to: .accepted)
        store.flush()

        let reloaded = ProposalStore(storageURL: url)
        XCTAssertEqual(reloaded.proposals.count, 2)
        let ra = reloaded.proposal(id: a.id)
        XCTAssertEqual(ra?.title, "Alpha")
        XCTAssertEqual(ra?.status, .accepted)
        XCTAssertEqual(ra?.estCostLabel, "$2 estimated")
        XCTAssertEqual(ra?.evidence.first?.source, "metrics")
        let rb = reloaded.proposal(id: b.id)
        XCTAssertEqual(rb?.lane, .codeHealth)
        XCTAssertEqual(rb?.domain, .site)
        XCTAssertEqual(rb?.riskClass, .medium)
    }

    func testTrustLedgerRoundTrip() throws {
        let url = tempURL("ledger-roundtrip")
        let ledger = TrustLedger(storageURL: url)
        for _ in 1...5 { _ = ledger.recordAcceptedAndKept(lane: .uxPolish, domain: .mac) }
        _ = ledger.recordAcceptedAndKept(lane: .uxPolish, domain: .mac)
        _ = ledger.recordRejection(lane: .cost, domain: .mini)
        ledger.flush()

        let reloaded = TrustLedger(storageURL: url)
        XCTAssertEqual(reloaded.tier(lane: .uxPolish, domain: .mac), .autoBuild)
        XCTAssertEqual(reloaded.entry(lane: .uxPolish, domain: .mac).streak, 1)
        XCTAssertEqual(reloaded.entry(lane: .cost, domain: .mini).consecutiveRejections, 1)
        XCTAssertEqual(reloaded.entry(lane: .uxPolish, domain: .mac).history.count, 6)
    }


    func testTierComparableAndClamping() throws {
        XCTAssertTrue(TrustTier.propose < TrustTier.autoBuild)
        XCTAssertTrue(TrustTier.autoBuild < TrustTier.autoLand)
        XCTAssertEqual(TrustTier.autoLand.promoted, .autoLand)
        XCTAssertEqual(TrustTier.propose.demoted, .propose)
        XCTAssertEqual(TrustTier.autoBuild.promoted, .autoLand)
        XCTAssertEqual(TrustTier.autoBuild.demoted, .propose)
    }

    // MARK: - Auto-land gate (earned tier, not the frozen field)

    private func autoLandProposal(risk: RiskClass = .low) -> UpgradeProposal {
        var p = makeProposal(risk: risk)
        p.tierRequired = .autoLand
        return p
    }

    func testShouldAutoLandRequiresEarnedTier() throws {
        // A proposal stamped tierRequired=autoLand with ZERO earned trust
        // must NOT auto-install: min(earned, required) gates it.
        XCTAssertFalse(FoundryEngine.shouldAutoLand(earnedTier: .propose, proposal: autoLandProposal()))
        XCTAssertFalse(FoundryEngine.shouldAutoLand(earnedTier: .autoBuild, proposal: autoLandProposal()))
        XCTAssertTrue(FoundryEngine.shouldAutoLand(earnedTier: .autoLand, proposal: autoLandProposal()))
    }

    func testShouldAutoLandRespectsTheFrozenCeiling() throws {
        // An earned autoLand pair still cannot auto-install a proposal
        // whose own tierRequired sits lower.
        var p = makeProposal()
        p.tierRequired = .propose
        XCTAssertFalse(FoundryEngine.shouldAutoLand(earnedTier: .autoLand, proposal: p))
        p.tierRequired = .autoBuild
        XCTAssertFalse(FoundryEngine.shouldAutoLand(earnedTier: .autoLand, proposal: p))
    }

    func testShouldAutoLandNeverForProtected() throws {
        XCTAssertFalse(FoundryEngine.shouldAutoLand(
            earnedTier: .autoLand, proposal: autoLandProposal(risk: .protected)
        ))
    }

    func testDemotedPairLosesAutoLandMidFlight() throws {
        // Earn autoLand, then roll back: the live ledger read drops below
        // autoLand, so a frozen tierRequired=autoLand proposal routes to a
        // manual approval card instead of self-installing.
        let ledger = TrustLedger(storageURL: tempURL("autoland-demote"))
        for _ in 0..<10 { ledger.recordAcceptedAndKept(lane: .performance, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoLand)
        XCTAssertTrue(FoundryEngine.shouldAutoLand(
            earnedTier: ledger.tier(lane: .performance, domain: .mac),
            proposal: autoLandProposal()
        ))
        ledger.recordRollback(lane: .performance, domain: .mac)
        XCTAssertFalse(FoundryEngine.shouldAutoLand(
            earnedTier: ledger.tier(lane: .performance, domain: .mac),
            proposal: autoLandProposal()
        ), "a rollback demotion revokes auto-land for in-flight proposals")
    }

    // MARK: - Tab reject rides the trust-transitions choke point

    func testBridgeRejectDemotionAnnouncesLikeApprovalPath() throws {
        let store = ProposalStore(storageURL: tempURL("bridge-reject-store"))
        let ledger = TrustLedger(storageURL: tempURL("bridge-reject-ledger"))
        let dashboard = FoundryDashboardModel()
        FoundryViewBridge.deactivateForTesting(dashboard: dashboard)
        FoundryViewBridge.activate(proposalStore: store, trustLedger: ledger, dashboard: dashboard)
        defer { FoundryViewBridge.deactivateForTesting(dashboard: dashboard) }

        // Earn Tier 1 so the second rejection's demotion is observable.
        for _ in 0..<5 { ledger.recordAcceptedAndKept(lane: .performance, domain: .mac) }
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoBuild)

        let a = store.file(makeProposal(title: "Reject me first"))
        let b = store.file(makeProposal(title: "Reject me second"))
        dashboard.onReject?(FoundryViewBridge.card(from: a))
        XCTAssertEqual(store.proposal(id: a.id)?.status, .rejected)
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .autoBuild,
                       "one rejection keeps the tier")
        dashboard.onReject?(FoundryViewBridge.card(from: b))
        XCTAssertEqual(ledger.tier(lane: .performance, domain: .mac), .propose,
                       "two consecutive tab rejections demote through the choke point")
        let entry = ledger.entry(lane: .performance, domain: .mac)
        XCTAssertEqual(entry.history.filter { $0.outcome == .rejected }.count, 2)
    }
}
