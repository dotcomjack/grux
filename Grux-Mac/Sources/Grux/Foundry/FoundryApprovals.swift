import Foundation
import SwiftUI
import Combine

// Install-approval machinery for the Foundry (blueprint section 04, Phase C:
// "Install-approval cards on Mac and phone (surface sync)").
//
// A Tier 1 (auto-build) pair builds and verifies autonomously, then waits
// for a one-tap approval before GruxUpdater.selfInstall fires. Approvals
// arrive from the Mac card (FoundryApprovalsPanel, mounted in
// SelfUpgradeView) or from the phone over the encrypted 0x40 channel.
//
// WIRE STRATEGY (mirrors SurfaceSync exactly, zero framing changes):
// FoundryApprovalEnvelope is a THIRD tagged-union riding the 0x40
// CHAT_ENVELOPE frame, with type names no ChatEnvelope or SurfaceEnvelope
// build has ever used ("approvalsSubscribe", "approvalRequest",
// "approvalResponse", "approvalResolved"). Both sides decode 0x40 payloads
// as ChatEnvelope first, then SurfaceEnvelope, then FoundryApprovalEnvelope.
// Compatibility matrix:
//   old phone + new Mac: the old phone never sends approvalsSubscribe, so
//     the Mac never pushes an approval byte at it. Gate holds by default.
//   new phone + old Mac: the phone's approvalsSubscribe fails both of the
//     Mac's decoders and is silently ignored. No teardown.
// The subscribe carries the phone's approval protocol version; the Mac
// pushes requests tagged min(phoneVersion, macVersion) and only handles
// inbound responses whose version it understands.

// MARK: - Wire version

enum FoundryApprovalWire {
    // Bump when the approval schema changes incompatibly. Additive optional
    // fields do NOT need a bump.
    static let version: Int = 1
}

// MARK: - Storage path

extension FoundryPaths {
    static var approvalsURL: URL { dir.appendingPathComponent("approvals.json") }
}

// MARK: - Models

enum FoundryApprovalState: String, Codable, Sendable {
    case pending
    case approved
    case rejected
    case expired
}

// Wire + disk shape of one install-approval request. Value-only, Codable,
// shared verbatim with the phone (keep in sync with GruxPhone's copy).
struct FoundryApprovalRequestDTO: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var proposalId: UUID
    var title: String
    var lane: String
    var domain: String
    var risk: String
    // Always carries the word "estimated" (subscription powered).
    var estCostLabel: String
    var createdAt: Date = Date()
}

struct FoundryApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    var request: FoundryApprovalRequestDTO
    var state: FoundryApprovalState = .pending
    var decidedAt: Date? = nil
    var decidedVia: String? = nil   // "mac" or "phone"

    var id: UUID { request.id }
}

// MARK: - Trust transitions (promote/demote wiring)

// One choke point for the ledger writes tied to proposal outcomes, so the
// promotion/demotion audit (the timeline mirror, hard rail five) can never
// be forgotten at a call site.
//   kept (survived 24h watch)  -> recordAcceptedAndKept (streak of 5 promotes)
//   rejected (user declined)   -> recordRejection (two in a row demotes)
//   rolled back                -> recordRollback (demotes immediately)
@MainActor
enum FoundryTrustTransitions {

    @discardableResult
    static func recordKept(
        proposal: UpgradeProposal,
        ledger: TrustLedger? = nil,
        timeline: FoundryTimelineStore? = nil
    ) -> TrustLedger.LedgerEntry {
        let ledger = ledger ?? .shared
        let before = ledger.tier(lane: proposal.lane, domain: proposal.domain)
        let entry = ledger.recordAcceptedAndKept(
            lane: proposal.lane, domain: proposal.domain, proposalId: proposal.id
        )
        announceTierChange(from: before, entry: entry, timeline: timeline)
        return entry
    }

    @discardableResult
    static func recordRejected(
        proposal: UpgradeProposal,
        ledger: TrustLedger? = nil,
        timeline: FoundryTimelineStore? = nil
    ) -> TrustLedger.LedgerEntry {
        let ledger = ledger ?? .shared
        let before = ledger.tier(lane: proposal.lane, domain: proposal.domain)
        let entry = ledger.recordRejection(
            lane: proposal.lane, domain: proposal.domain, proposalId: proposal.id
        )
        announceTierChange(from: before, entry: entry, timeline: timeline)
        return entry
    }

    @discardableResult
    static func recordRollback(
        proposal: UpgradeProposal,
        ledger: TrustLedger? = nil,
        timeline: FoundryTimelineStore? = nil
    ) -> TrustLedger.LedgerEntry {
        let ledger = ledger ?? .shared
        let before = ledger.tier(lane: proposal.lane, domain: proposal.domain)
        let entry = ledger.recordRollback(
            lane: proposal.lane, domain: proposal.domain, proposalId: proposal.id
        )
        announceTierChange(from: before, entry: entry, timeline: timeline)
        return entry
    }

    private static func announceTierChange(
        from before: TrustTier,
        entry: TrustLedger.LedgerEntry,
        timeline: FoundryTimelineStore?
    ) {
        guard entry.tier != before else { return }
        let promoted = entry.tier > before
        (timeline ?? .shared).append(FoundryTimelineEntry(
            kind: promoted ? .promotion : .demotion,
            title: "\(promoted ? "Promoted" : "Demoted"): \(entry.lane.displayName) x \(entry.domain.displayName)",
            detail: "Tier \(before.rawValue) to Tier \(entry.tier.rawValue) (\(entry.tier.displayName)).",
            lane: entry.lane.displayName,
            domain: entry.domain.displayName
        ))
    }
}

// MARK: - Approval store

// Small JSON-on-disk store of approval requests. Mirrors ProposalStore's
// shape: @MainActor singleton, @Published records, debounced atomic writes.
// Decisions wire straight into the engine: approve fires onApproved (the
// integrator points it at GruxUpdater.selfInstall), reject transitions the
// proposal and records the ledger rejection (two in a row demotes).
@MainActor
final class FoundryApprovalStore: ObservableObject {
    static let shared = FoundryApprovalStore()

    @Published private(set) var records: [FoundryApprovalRecord] = []

    // Integration hook: wired at startup to kick the actual install, e.g.
    //   FoundryApprovalStore.shared.onApproved = { record, proposal in
    //       try? GruxUpdater.shared.selfInstall(fromWorktree: ..., proposal: proposal)
    //   }
    var onApproved: ((FoundryApprovalRecord, UpgradeProposal) -> Void)?

    private let storageURL: URL
    private let proposalStore: ProposalStore
    private let trustLedger: TrustLedger
    private let timeline: FoundryTimelineStore
    private var saveTask: Task<Void, Never>?

    // Tests inject temp-URL stores; the app uses the shared singletons.
    init(
        storageURL: URL = FoundryPaths.approvalsURL,
        proposalStore: ProposalStore? = nil,
        trustLedger: TrustLedger? = nil,
        timeline: FoundryTimelineStore? = nil
    ) {
        self.storageURL = storageURL
        self.proposalStore = proposalStore ?? .shared
        self.trustLedger = trustLedger ?? .shared
        self.timeline = timeline ?? .shared
        load()
    }

    func load() {
        records = Persistence.load([FoundryApprovalRecord].self, from: storageURL, fallback: [])
    }

    var pending: [FoundryApprovalRecord] {
        records.filter { $0.state == .pending }.sorted { $0.request.createdAt > $1.request.createdAt }
    }

    func record(id: UUID) -> FoundryApprovalRecord? {
        records.first { $0.id == id }
    }

    // MARK: Filing

    // File an install-approval request for a built-and-verified proposal.
    // Dedupes on proposalId so a re-verify never stacks a second card.
    // Protected proposals never get a card: they cannot auto-install.
    @discardableResult
    func requestApproval(for proposal: UpgradeProposal) -> FoundryApprovalRecord? {
        guard proposal.riskClass != .protected else { return nil }
        if let existing = records.first(where: {
            $0.request.proposalId == proposal.id && $0.state == .pending
        }) {
            return existing
        }
        let record = FoundryApprovalRecord(request: FoundryApprovalRequestDTO(
            proposalId: proposal.id,
            title: proposal.title,
            lane: proposal.lane.displayName,
            domain: proposal.domain.displayName,
            risk: proposal.riskClass.displayName,
            estCostLabel: proposal.estCostLabel
        ))
        records.insert(record, at: 0)
        scheduleSave()
        timeline.append(FoundryTimelineEntry(
            kind: .built,
            title: "Awaiting install approval: \(proposal.title)",
            detail: "Built and verified. Approve on Mac or phone. \(proposal.estCostLabel)",
            lane: proposal.lane.displayName,
            domain: proposal.domain.displayName
        ))
        FoundryApprovalSync.shared.pushPending()
        return record
    }

    // MARK: Decisions

    // One decision per request; later responses (the other device tapping a
    // stale card) are ignored. `via` is "mac" or "phone".
    @discardableResult
    func decide(id: UUID, approved: Bool, via: String) -> FoundryApprovalRecord? {
        guard let idx = records.firstIndex(where: { $0.id == id }),
              records[idx].state == .pending else { return nil }
        records[idx].state = approved ? .approved : .rejected
        records[idx].decidedAt = Date()
        records[idx].decidedVia = via
        let record = records[idx]
        scheduleSave()

        let proposal = proposalStore.proposal(id: record.request.proposalId)
        if approved {
            timeline.append(FoundryTimelineEntry(
                kind: .accepted,
                title: "Install approved (\(via)): \(record.request.title)",
                detail: "GruxUpdater archives the current build, installs, and watches for 24h.",
                lane: record.request.lane,
                domain: record.request.domain
            ))
            if let proposal {
                onApproved?(record, proposal)
            }
        } else {
            timeline.append(FoundryTimelineEntry(
                kind: .rejected,
                title: "Install rejected (\(via)): \(record.request.title)",
                detail: "Two rejections on a (lane x domain) pair demote its tier.",
                lane: record.request.lane,
                domain: record.request.domain
            ))
            if let proposal {
                proposalStore.transition(id: proposal.id, to: .rejected)
                FoundryTrustTransitions.recordRejected(
                    proposal: proposal, ledger: trustLedger, timeline: timeline
                )
            }
        }
        FoundryApprovalSync.shared.pushResolved(id: record.id)
        return record
    }

    func clearDecided() {
        records.removeAll { $0.state != .pending }
        scheduleSave()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = records
        let url = storageURL
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot, to: url)
        }
    }

    // Force a synchronous write (tests, app termination paths).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(records, to: storageURL)
    }
}

// MARK: - FoundryApprovalEnvelope (tagged-union, rides the 0x40 frame)

enum FoundryApprovalEnvelope: Codable {
    // phone -> mac
    case approvalsSubscribe(version: Int)                       // capability announce
    case approvalResponse(version: Int, id: UUID, approved: Bool)
    // mac -> phone
    case approvalRequest(version: Int, request: FoundryApprovalRequestDTO)
    case approvalResolved(version: Int, id: UUID)               // dismiss a settled card

    enum CodingKeys: String, CodingKey { case type, payload }
    private struct SubscribeP: Codable { let version: Int }
    private struct ResponseP: Codable { let version: Int; let id: UUID; let approved: Bool }
    private struct RequestP: Codable { let version: Int; let request: FoundryApprovalRequestDTO }
    private struct ResolvedP: Codable { let version: Int; let id: UUID }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approvalsSubscribe(let v):
            try c.encode("approvalsSubscribe", forKey: .type)
            try c.encode(SubscribeP(version: v), forKey: .payload)
        case .approvalResponse(let v, let id, let approved):
            try c.encode("approvalResponse", forKey: .type)
            try c.encode(ResponseP(version: v, id: id, approved: approved), forKey: .payload)
        case .approvalRequest(let v, let request):
            try c.encode("approvalRequest", forKey: .type)
            try c.encode(RequestP(version: v, request: request), forKey: .payload)
        case .approvalResolved(let v, let id):
            try c.encode("approvalResolved", forKey: .type)
            try c.encode(ResolvedP(version: v, id: id), forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "approvalsSubscribe":
            let p = try c.decode(SubscribeP.self, forKey: .payload)
            self = .approvalsSubscribe(version: p.version)
        case "approvalResponse":
            let p = try c.decode(ResponseP.self, forKey: .payload)
            self = .approvalResponse(version: p.version, id: p.id, approved: p.approved)
        case "approvalRequest":
            let p = try c.decode(RequestP.self, forKey: .payload)
            self = .approvalRequest(version: p.version, request: p.request)
        case "approvalResolved":
            let p = try c.decode(ResolvedP.self, forKey: .payload)
            self = .approvalResolved(version: p.version, id: p.id)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown approval envelope type: \(type)"
            )
        }
    }

    // Same date strategy as ChatEnvelope / SurfaceEnvelope so all three
    // unions share the 0x40 frame without ambiguity.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    func encode() throws -> Data { try Self.encoder.encode(self) }
    static func decode(_ data: Data) throws -> FoundryApprovalEnvelope {
        try Self.decoder.decode(FoundryApprovalEnvelope.self, from: data)
    }
}

// MARK: - Mac-side approval sync engine

// One engine for the (single) phone session. PhoneReceiverService activates
// it when the phone announces approval capability and deactivates it on
// teardown, exactly like SurfaceSyncEngine. Pending requests push on
// activation, on filing, and on resolution.
@MainActor
final class FoundryApprovalSync {
    static let shared = FoundryApprovalSync()

    private(set) var isActive = false
    private(set) var peerVersion: Int = 0

    private var send: ((Data) -> Void)?
    private let storeRef: FoundryApprovalStore?
    private var store: FoundryApprovalStore { storeRef ?? .shared }

    // Test seam: inject a store so tests never touch the singleton.
    init(store: FoundryApprovalStore? = nil) {
        self.storeRef = store
    }

    var negotiatedVersion: Int {
        min(FoundryApprovalWire.version, max(1, peerVersion))
    }

    func activate(peerVersion: Int, send: @escaping (Data) -> Void) {
        self.peerVersion = peerVersion
        self.send = send
        isActive = true
        pushPending()
        WakeLog.shared.log("foundry-approvals: activated (phone v\(peerVersion), mac v\(FoundryApprovalWire.version))")
    }

    func deactivate() {
        isActive = false
        send = nil
        peerVersion = 0
    }

    // Ship every pending request to the phone. Cheap and idempotent: the
    // phone dedupes by request id.
    func pushPending() {
        guard isActive, let send else { return }
        for record in store.pending {
            guard let data = try? FoundryApprovalEnvelope
                .approvalRequest(version: negotiatedVersion, request: record.request)
                .encode() else { continue }
            guard data.count < PhoneWire.maxPayloadBytes else { continue }
            send(data)
        }
    }

    // A decision landed (either device): tell the phone to drop the card.
    func pushResolved(id: UUID) {
        guard isActive, let send else { return }
        guard let data = try? FoundryApprovalEnvelope
            .approvalResolved(version: negotiatedVersion, id: id)
            .encode() else { return }
        send(data)
    }
}

// MARK: - Inbound dispatch (PhoneReceiverService hook)

// Third decoder in the 0x40 fall-back chain: ChatEnvelope, SurfaceEnvelope,
// then this. Returns true when the payload was an approval envelope.
// Inbound responses are gated on protocol version: a response speaking a
// newer schema than this Mac understands is logged and dropped, never
// half-applied.
@MainActor
enum FoundryApprovalSyncInbound {
    @discardableResult
    static func handle(
        _ payload: Data,
        send: @escaping (Data) -> Void,
        sync: FoundryApprovalSync? = nil,
        store: FoundryApprovalStore? = nil
    ) -> Bool {
        guard let env = try? FoundryApprovalEnvelope.decode(payload) else { return false }
        let sync = sync ?? .shared
        switch env {
        case .approvalsSubscribe(let version):
            sync.activate(peerVersion: version, send: send)
        case .approvalResponse(let version, let id, let approved):
            guard version >= 1, version <= FoundryApprovalWire.version else {
                WakeLog.shared.log("foundry-approvals: dropped response v\(version) (mac speaks v\(FoundryApprovalWire.version))")
                break
            }
            (store ?? .shared).decide(id: id, approved: approved, via: "phone")
        case .approvalRequest, .approvalResolved:
            // Mac -> phone only; ignore an echo.
            break
        }
        return true
    }
}

// MARK: - Mac approval card (mounted in SelfUpgradeView, see integration)

// Pending install-approval cards. Renders nothing when the queue is empty,
// so it adds zero chrome to a quiet Foundry.
struct FoundryApprovalsPanel: View {
    @ObservedObject private var store = FoundryApprovalStore.shared

    var body: some View {
        if !store.pending.isEmpty {
            VStack(spacing: 10) {
                ForEach(store.pending) { record in
                    FoundryApprovalCardView(record: record) { approved in
                        store.decide(id: record.id, approved: approved, via: "mac")
                    }
                }
            }
        }
    }
}

struct FoundryApprovalCardView: View {
    let record: FoundryApprovalRecord
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GruxTheme.warnAmber)
                Text("READY TO INSTALL")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.2)
                    .foregroundStyle(GruxTheme.warnAmber)
                Spacer()
                Text(FoundryFormat.relativeStamp(record.request.createdAt))
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            Text(record.request.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(2)

            HStack(spacing: 6) {
                chip(record.request.lane, color: GruxTheme.accentPrimary)
                chip(record.request.domain, color: GruxTheme.accentCo)
                chip("\(record.request.risk.uppercased()) RISK", color: riskColor)
            }

            Text(record.request.estCostLabel)
                .font(GruxTheme.Font.mono)
                .foregroundStyle(GruxTheme.textTertiary)

            HStack(spacing: 8) {
                GruxChip(title: "APPROVE INSTALL", systemImage: "checkmark.seal", style: .primary) {
                    decide(true)
                }
                GruxChip(title: "REJECT", systemImage: "xmark", style: .destructive) {
                    decide(false)
                }
                Spacer()
                Text("Built, verified, archived. Auto-rollback armed for 24h.")
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(GruxTheme.warnAmber.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.warnAmber.opacity(0.35), lineWidth: 1)
        )
    }

    private var riskColor: Color {
        switch record.request.risk.lowercased() {
        case "high", "protected": return GruxTheme.destructiveRose
        case "medium": return GruxTheme.warnAmber
        default: return GruxTheme.successMint
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GruxTheme.Font.microCaps)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
