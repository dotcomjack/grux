import Foundation
import Combine

// BYTE-IDENTICAL wire copy of the Mac's Sources/Grux/iPhone/SurfaceSync.swift
// envelope + DTO section. Keep in lockstep.
//
// SurfaceEnvelope rides inside the existing 0x40 CHAT_ENVELOPE frame as a
// second JSON tagged-union. TransportService decodes 0x40 payloads as
// ChatEnvelope first and falls back to SurfaceEnvelope, so chat and surfaces
// share the channel without any framing or crypto change. The Mac never
// pushes surfaces until this phone sends surfacesSubscribe, which is the
// version-negotiation gate that keeps old builds on both sides safe.

enum SurfaceWire {
    // v2: adds the "activitySnapshot" envelope (live swarm jobs + Foundry
    // pass mirror). Macs gate activity pushes on min(macVersion,
    // peerVersion) >= activityMinVersion, so a v1 peer on either side
    // simply never sees the new type.
    static let version: Int = 2
    static let activityMinVersion: Int = 2
}

// MARK: - DTOs

struct SurfaceReminderDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: String
    let title: String
    let body: String
    let createdAt: Date
    let scheduledFor: Date?
    let firedAt: Date?
    let accepted: Bool
    let dismissed: Bool
    let snoozedUntil: Date?
}

struct SurfaceMeetingDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let sourceAppName: String?
    let summaryExcerpt: String?
    let utteranceCount: Int
}

struct SurfaceNoteDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let preview: String
    let tags: [String]
    let pinned: Bool
    let updatedAt: Date
}

struct SurfaceAgendaEventDTO: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarName: String
}

struct SurfacesSnapshotDTO: Codable, Hashable {
    let generatedAt: Date
    let reminders: [SurfaceReminderDTO]
    let meetings: [SurfaceMeetingDTO]
    let notes: [SurfaceNoteDTO]
    let agenda: [SurfaceAgendaEventDTO]
}

// Activity strip mirror (wire v2). One row per visible dot on the Mac's
// activity strip; phase strings match ActivityDot.Phase raw values
// (queued/running/waiting/done/failed/cancelled).
struct ActivityJobDTO: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let phase: String
    let isFoundry: Bool
    let estimatedUSD: Double
}

struct ActivitySnapshotDTO: Codable, Hashable {
    let generatedAt: Date
    let jobs: [ActivityJobDTO]
    // FoundryCyclePass.rawValue while the governor is mid-pass, else nil.
    let foundryPass: String?
    // Pre-rendered "$N estimated" so the phone never needs the rate table.
    // Empty string when nothing is spending.
    let estimatedCostLabel: String
}

// MARK: - SurfaceEnvelope

enum SurfaceEnvelope: Codable {
    // phone -> mac
    case surfacesSubscribe(version: Int)
    case surfacesRequest
    // mac -> phone
    case surfacesSnapshot(version: Int, snapshot: SurfacesSnapshotDTO)
    // mac -> phone, only when negotiated version >= activityMinVersion
    case activitySnapshot(version: Int, snapshot: ActivitySnapshotDTO)

    enum CodingKeys: String, CodingKey { case type, payload }
    private struct SubscribeP: Codable { let version: Int }
    private struct SnapshotP: Codable { let version: Int; let snapshot: SurfacesSnapshotDTO }
    private struct ActivityP: Codable { let version: Int; let snapshot: ActivitySnapshotDTO }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .surfacesSubscribe(let v):
            try c.encode("surfacesSubscribe", forKey: .type)
            try c.encode(SubscribeP(version: v), forKey: .payload)
        case .surfacesRequest:
            try c.encode("surfacesRequest", forKey: .type)
        case .surfacesSnapshot(let v, let snap):
            try c.encode("surfacesSnapshot", forKey: .type)
            try c.encode(SnapshotP(version: v, snapshot: snap), forKey: .payload)
        case .activitySnapshot(let v, let snap):
            try c.encode("activitySnapshot", forKey: .type)
            try c.encode(ActivityP(version: v, snapshot: snap), forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "surfacesSubscribe":
            let p = try c.decode(SubscribeP.self, forKey: .payload)
            self = .surfacesSubscribe(version: p.version)
        case "surfacesRequest":
            self = .surfacesRequest
        case "surfacesSnapshot":
            let p = try c.decode(SnapshotP.self, forKey: .payload)
            self = .surfacesSnapshot(version: p.version, snapshot: p.snapshot)
        case "activitySnapshot":
            let p = try c.decode(ActivityP.self, forKey: .payload)
            self = .activitySnapshot(version: p.version, snapshot: p.snapshot)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown surface envelope type: \(type)"
            )
        }
    }

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
    static func decode(_ data: Data) throws -> SurfaceEnvelope {
        try Self.decoder.decode(SurfaceEnvelope.self, from: data)
    }
}

// MARK: - SurfaceStore (phone-side mirror, read-only)

// Mirrors the Mac's surfaces snapshot. TransportService pumps every decoded
// SurfaceEnvelope through `ingest(_:)`. The UI observes @Published state
// directly, ChatStore-style.
@MainActor
final class SurfaceStore: ObservableObject {
    static let shared = SurfaceStore()

    @Published private(set) var snapshot: SurfacesSnapshotDTO?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var macVersion: Int = 0
    // Live swarm/Foundry activity mirror (wire v2). nil until the first
    // activitySnapshot lands; a v1 Mac never sends one.
    @Published private(set) var activity: ActivitySnapshotDTO?

    private init() {}

    func ingest(_ env: SurfaceEnvelope) {
        switch env {
        case .surfacesSnapshot(let version, let snap):
            AppModel.diag("surfaces: snapshot v\(version) reminders=\(snap.reminders.count) meetings=\(snap.meetings.count) notes=\(snap.notes.count) agenda=\(snap.agenda.count)")
            macVersion = version
            snapshot = snap
            lastUpdated = Date()
        case .activitySnapshot(let version, let snap):
            AppModel.diag("surfaces: activity v\(version) jobs=\(snap.jobs.count) pass=\(snap.foundryPass ?? "none")")
            macVersion = version
            activity = snap
        case .surfacesSubscribe, .surfacesRequest:
            // phone -> mac only; ignore echoes.
            break
        }
    }

    func clear() {
        snapshot = nil
        lastUpdated = nil
        macVersion = 0
        activity = nil
    }

    // Convenience projections for the UI ---------------------------------

    var pendingReminders: [SurfaceReminderDTO] {
        (snapshot?.reminders ?? []).filter { !$0.dismissed }
    }

    var agendaByDay: [(day: Date, events: [SurfaceAgendaEventDTO])] {
        let events = snapshot?.agenda ?? []
        let cal = Calendar.current
        let grouped = Dictionary(grouping: events) { cal.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.start < $1.start }) }
    }
}

// MARK: - Foundry install approvals (Phase C)

// BYTE-IDENTICAL wire copy of the Mac's Sources/Grux/Foundry/
// FoundryApprovals.swift envelope + DTO section. Keep in lockstep.
//
// FoundryApprovalEnvelope is a THIRD tagged-union riding the same 0x40
// CHAT_ENVELOPE frame (after ChatEnvelope and SurfaceEnvelope). The Mac
// never pushes approval cards until this phone sends approvalsSubscribe,
// which is the version-negotiation gate that keeps old builds on both
// sides safe.

enum FoundryApprovalWire {
    static let version: Int = 1
}

// One install-approval card. estCostLabel always carries the word
// "estimated" (the engine is subscription powered).
struct FoundryApprovalRequestDTO: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var proposalId: UUID
    var title: String
    var lane: String
    var domain: String
    var risk: String
    var estCostLabel: String
    var createdAt: Date = Date()
}

enum FoundryApprovalEnvelope: Codable {
    // phone -> mac
    case approvalsSubscribe(version: Int)
    case approvalResponse(version: Int, id: UUID, approved: Bool)
    // mac -> phone
    case approvalRequest(version: Int, request: FoundryApprovalRequestDTO)
    case approvalResolved(version: Int, id: UUID)

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

// Phone-side queue of pending install-approval cards. TransportService pumps
// every decoded FoundryApprovalEnvelope through `ingest(_:)`; SurfacesView
// renders `pending` and answers via TransportService.sendApproval.
@MainActor
final class ApprovalStore: ObservableObject {
    static let shared = ApprovalStore()

    @Published private(set) var pending: [FoundryApprovalRequestDTO] = []

    private init() {}

    func ingest(_ env: FoundryApprovalEnvelope) {
        switch env {
        case .approvalRequest(let version, let request):
            AppModel.diag("approvals: request v\(version) '\(request.title)'")
            guard !pending.contains(where: { $0.id == request.id }) else { return }
            pending.append(request)
        case .approvalResolved(_, let id):
            pending.removeAll { $0.id == id }
        case .approvalsSubscribe, .approvalResponse:
            // phone -> mac only; ignore echoes.
            break
        }
    }

    // Local optimistic removal after the user taps a decision; the Mac's
    // approvalResolved echo is then a no-op.
    func remove(id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func clear() {
        pending.removeAll()
    }
}
