import XCTest
@testable import Grux

// Phase C approval machinery: store round-trip, decision wiring into
// ProposalStore + TrustLedger, the FoundryApprovalEnvelope wire kinds
// (encode/decode + 0x40 coexistence with ChatEnvelope and SurfaceEnvelope),
// and the version-gated inbound dispatch.
@MainActor
final class FoundryApprovalsTests: XCTestCase {

    private var root: URL!
    private var proposalStore: ProposalStore!
    private var trustLedger: TrustLedger!
    private var timeline: FoundryTimelineStore!
    private var approvals: FoundryApprovalStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundry-approvals-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        proposalStore = ProposalStore(storageURL: root.appendingPathComponent("proposals.json"))
        trustLedger = TrustLedger(storageURL: root.appendingPathComponent("ledger.json"))
        timeline = FoundryTimelineStore(storageURL: root.appendingPathComponent("timeline.json"))
        approvals = FoundryApprovalStore(
            storageURL: root.appendingPathComponent("approvals.json"),
            proposalStore: proposalStore,
            trustLedger: trustLedger,
            timeline: timeline
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func fileVerifyingProposal(
        lane: UpgradeLane = .uxPolish,
        domain: UpgradeDomain = .mac,
        risk: RiskClass = .low
    ) -> UpgradeProposal {
        let filed = proposalStore.file(UpgradeProposal(
            title: "Tighten the orb glow",
            lane: lane,
            domain: domain,
            expectedGain: 0.6,
            riskClass: risk,
            estCostLabel: "$3 estimated",
            tierRequired: .autoBuild,
            readyPrompt: "polish it"
        ))
        proposalStore.transition(id: filed.id, to: .accepted)
        proposalStore.transition(id: filed.id, to: .building)
        proposalStore.transition(id: filed.id, to: .verifying)
        return proposalStore.proposal(id: filed.id)!
    }

    private func sampleRequest() -> FoundryApprovalRequestDTO {
        FoundryApprovalRequestDTO(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            proposalId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Tighten the orb glow",
            lane: "UX Polish",
            domain: "Mac",
            risk: "Low",
            estCostLabel: "$3 estimated",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    // MARK: - Store round-trip

    func testApprovalStoreRoundTrip() {
        let proposal = fileVerifyingProposal()
        let record = approvals.requestApproval(for: proposal)
        XCTAssertNotNil(record)
        approvals.flush()

        let reloaded = FoundryApprovalStore(
            storageURL: root.appendingPathComponent("approvals.json"),
            proposalStore: proposalStore,
            trustLedger: trustLedger,
            timeline: timeline
        )
        XCTAssertEqual(reloaded.records.count, 1)
        let r = reloaded.records[0]
        XCTAssertEqual(r.request.proposalId, proposal.id)
        XCTAssertEqual(r.request.title, "Tighten the orb glow")
        XCTAssertEqual(r.request.estCostLabel, "$3 estimated")
        XCTAssertEqual(r.state, .pending)
    }

    func testRequestApprovalDedupesOnProposalId() {
        let proposal = fileVerifyingProposal()
        let first = approvals.requestApproval(for: proposal)
        let second = approvals.requestApproval(for: proposal)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(approvals.records.count, 1)
    }

    func testProtectedProposalsNeverGetAnApprovalCard() {
        let proposal = fileVerifyingProposal(risk: .protected)
        XCTAssertNil(approvals.requestApproval(for: proposal),
                     "protected zones cannot auto-install, so no card")
        XCTAssertTrue(approvals.records.isEmpty)
    }

    // MARK: - Decisions

    func testApproveFiresHookAndSettlesOnce() {
        let proposal = fileVerifyingProposal()
        let record = approvals.requestApproval(for: proposal)!

        var hookProposal: UpgradeProposal?
        approvals.onApproved = { _, p in hookProposal = p }

        let decided = approvals.decide(id: record.id, approved: true, via: "mac")
        XCTAssertEqual(decided?.state, .approved)
        XCTAssertEqual(decided?.decidedVia, "mac")
        XCTAssertEqual(hookProposal?.id, proposal.id, "approve hands the proposal to the installer hook")

        // A stale tap from the other device is ignored.
        XCTAssertNil(approvals.decide(id: record.id, approved: false, via: "phone"))
        XCTAssertEqual(approvals.record(id: record.id)?.state, .approved)
    }

    func testRejectTransitionsProposalAndRecordsLedgerRejection() {
        let proposal = fileVerifyingProposal()
        let record = approvals.requestApproval(for: proposal)!

        approvals.decide(id: record.id, approved: false, via: "phone")

        XCTAssertEqual(proposalStore.proposal(id: proposal.id)?.status, .rejected)
        let entry = trustLedger.entry(lane: .uxPolish, domain: .mac)
        XCTAssertEqual(entry.consecutiveRejections, 1)
        XCTAssertTrue(timeline.entries.contains { $0.title.contains("Install rejected (phone)") })
    }

    // MARK: - Trust transitions (promote/demote wiring)

    func testFiveKeptChangesPromoteAndAnnounce() {
        for _ in 0..<5 {
            let p = fileVerifyingProposal(lane: .reliability, domain: .mini)
            FoundryTrustTransitions.recordKept(proposal: p, ledger: trustLedger, timeline: timeline)
        }
        XCTAssertEqual(trustLedger.tier(lane: .reliability, domain: .mini), .autoBuild)
        XCTAssertTrue(timeline.entries.contains { $0.kind == .promotion },
                      "promotion mirrored to the timeline")
    }

    func testRollbackDemotesAndAnnounces() {
        for _ in 0..<5 {
            trustLedger.recordAcceptedAndKept(lane: .cost, domain: .site)
        }
        XCTAssertEqual(trustLedger.tier(lane: .cost, domain: .site), .autoBuild)
        let p = fileVerifyingProposal(lane: .cost, domain: .site)
        FoundryTrustTransitions.recordRollback(proposal: p, ledger: trustLedger, timeline: timeline)
        XCTAssertEqual(trustLedger.tier(lane: .cost, domain: .site), .propose)
        XCTAssertTrue(timeline.entries.contains { $0.kind == .demotion })
    }

    // MARK: - Envelope round trips

    func testSubscribeRoundTrip() throws {
        let data = try FoundryApprovalEnvelope.approvalsSubscribe(version: 1).encode()
        guard case .approvalsSubscribe(let v) = try FoundryApprovalEnvelope.decode(data) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(v, 1)
    }

    func testRequestRoundTripPreservesEveryField() throws {
        let req = sampleRequest()
        let data = try FoundryApprovalEnvelope.approvalRequest(version: 1, request: req).encode()
        guard case .approvalRequest(let v, let out) = try FoundryApprovalEnvelope.decode(data) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(v, 1)
        XCTAssertEqual(out.id, req.id)
        XCTAssertEqual(out.proposalId, req.proposalId)
        XCTAssertEqual(out.title, "Tighten the orb glow")
        XCTAssertEqual(out.lane, "UX Polish")
        XCTAssertEqual(out.domain, "Mac")
        XCTAssertEqual(out.risk, "Low")
        XCTAssertEqual(out.estCostLabel, "$3 estimated")
        XCTAssertEqual(out.createdAt.timeIntervalSince1970,
                       req.createdAt.timeIntervalSince1970, accuracy: 0.005)
    }

    func testResponseAndResolvedRoundTrips() throws {
        let id = UUID()
        let respData = try FoundryApprovalEnvelope
            .approvalResponse(version: 1, id: id, approved: true).encode()
        guard case .approvalResponse(let v, let outId, let approved) =
                try FoundryApprovalEnvelope.decode(respData) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(v, 1)
        XCTAssertEqual(outId, id)
        XCTAssertTrue(approved)

        let resolvedData = try FoundryApprovalEnvelope
            .approvalResolved(version: 1, id: id).encode()
        guard case .approvalResolved(_, let resolvedId) =
                try FoundryApprovalEnvelope.decode(resolvedData) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(resolvedId, id)
    }

    // MARK: - Coexistence on the 0x40 frame

    // Approval payloads must NOT decode as ChatEnvelope or SurfaceEnvelope:
    // that is exactly how old builds (which use try?) skip them silently.
    func testApprovalPayloadIsIgnoredByOlderDecoders() throws {
        let data = try FoundryApprovalEnvelope
            .approvalRequest(version: 1, request: sampleRequest()).encode()
        XCTAssertNil(try? ChatEnvelope.decode(data),
                     "old builds must silently ignore approval envelopes")
        XCTAssertNil(try? SurfaceEnvelope.decode(data),
                     "surface decoder must not swallow approval envelopes")
    }

    func testChatAndSurfacePayloadsAreIgnoredByApprovalDecoder() throws {
        let chat = try ChatEnvelope.requestSync.encode()
        XCTAssertNil(try? FoundryApprovalEnvelope.decode(chat))
        let surface = try SurfaceEnvelope.surfacesSubscribe(version: 1).encode()
        XCTAssertNil(try? FoundryApprovalEnvelope.decode(surface))
        XCTAssertNil(try? FoundryApprovalEnvelope.decode(Data([0x00, 0x01])))
    }

    // MARK: - Inbound dispatch + version gating

    func testSubscribeActivatesSyncAndPushesPending() throws {
        let proposal = fileVerifyingProposal()
        approvals.requestApproval(for: proposal)
        let sync = FoundryApprovalSync(store: approvals)
        defer { sync.deactivate() }

        var sent: [Data] = []
        let sub = try FoundryApprovalEnvelope.approvalsSubscribe(version: 1).encode()
        XCTAssertTrue(FoundryApprovalSyncInbound.handle(
            sub, send: { sent.append($0) }, sync: sync, store: approvals
        ))
        XCTAssertTrue(sync.isActive)
        XCTAssertEqual(sync.peerVersion, 1)
        XCTAssertEqual(sent.count, 1, "activation pushes the pending request")
        guard case .approvalRequest(let v, let req) = try FoundryApprovalEnvelope.decode(sent[0]) else {
            return XCTFail("expected an approvalRequest push")
        }
        XCTAssertEqual(v, 1)
        XCTAssertEqual(req.proposalId, proposal.id)
    }

    func testInboundResponseAppliesWhenVersionUnderstood() throws {
        let proposal = fileVerifyingProposal()
        let record = approvals.requestApproval(for: proposal)!
        let resp = try FoundryApprovalEnvelope
            .approvalResponse(version: 1, id: record.id, approved: false).encode()
        let sync = FoundryApprovalSync(store: approvals)

        XCTAssertTrue(FoundryApprovalSyncInbound.handle(
            resp, send: { _ in }, sync: sync, store: approvals
        ))
        XCTAssertEqual(approvals.record(id: record.id)?.state, .rejected)
        XCTAssertEqual(approvals.record(id: record.id)?.decidedVia, "phone")
    }

    func testInboundResponseDroppedWhenVersionTooNew() throws {
        let proposal = fileVerifyingProposal()
        let record = approvals.requestApproval(for: proposal)!
        let resp = try FoundryApprovalEnvelope
            .approvalResponse(version: FoundryApprovalWire.version + 1,
                              id: record.id, approved: true).encode()
        let sync = FoundryApprovalSync(store: approvals)

        // Recognized as ours (true) but never half-applied.
        XCTAssertTrue(FoundryApprovalSyncInbound.handle(
            resp, send: { _ in }, sync: sync, store: approvals
        ))
        XCTAssertEqual(approvals.record(id: record.id)?.state, .pending,
                       "a response speaking a newer schema is dropped")
    }

    func testNegotiatedVersionIsMinOfPeers() {
        let sync = FoundryApprovalSync(store: approvals)
        sync.activate(peerVersion: 99, send: { _ in })
        XCTAssertEqual(sync.negotiatedVersion, FoundryApprovalWire.version)
        sync.deactivate()
    }
}
