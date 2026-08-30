import Foundation
import Combine
import CryptoKit

// Cross-device continuity surfaces (roadmap items 25 + 28).
//
// Pushes read-only snapshots of the Mac's reminders, meeting summaries,
// notes, and the next-7-days calendar agenda to the paired iPhone, so the
// phone can show "what Grux knows" even when the user is away from the desk.
//
// WIRE STRATEGY (zero framing / encryption changes):
// SurfaceEnvelope rides INSIDE the existing 0x40 CHAT_ENVELOPE frame as a
// JSON tagged-union, exactly like ChatEnvelope, but with type names that no
// ChatEnvelope build has ever used ("surfacesSubscribe", "surfacesRequest",
// "surfacesSnapshot"). Both sides decode 0x40 payloads as ChatEnvelope first
// and fall back to SurfaceEnvelope. Compatibility matrix:
//
//   old phone + new Mac: the old phone never sends surfacesSubscribe, so the
//     Mac never pushes a single surface byte at it. Gate holds by default.
//   new phone + old Mac: the phone's surfacesSubscribe lands in the Mac's
//     `try? ChatEnvelope.decode(payload)` which returns nil on the unknown
//     type and is silently ignored. No teardown, no reconnect storm.
//
// That subscribe-before-push handshake IS the protocol-version negotiation:
// the phone announces the surface schema version it speaks, and the Mac
// replies with snapshots tagged with min(phoneVersion, macVersion). New
// fields are additive + optional so v1 phones decode v2 snapshots unchanged.
//
// Keep this file in sync with GruxPhone/GruxPhone/SurfaceModels.swift
// (byte-identical wire shapes, same date strategy).

// MARK: - Wire version

enum SurfaceWire {
    // Bump when the snapshot schema changes incompatibly. Additive optional
    // fields do NOT need a bump.
    //
    // v2: adds the "activitySnapshot" envelope (live swarm jobs + Foundry
    // cycle phase + estimated-cost label, mirroring the Mac activity strip).
    // A new envelope TYPE needs the bump: the Mac only sends activity
    // snapshots when the negotiated version is at least 2, so a v1 phone
    // never sees the unknown type and a v1 Mac never sends it.
    static let version: Int = 2
    // Minimum negotiated version required before activity pushes flow.
    static let activityMinVersion: Int = 2
}

// MARK: - DTOs (wire shapes; Codable, value-only, no app types)

struct SurfaceReminderDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: String            // GruxReminderKind.rawValue
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
    let id: String              // EKEvent.eventIdentifier
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

// MARK: - SurfaceEnvelope (tagged-union, rides the 0x40 frame)

enum SurfaceEnvelope: Codable {
    // phone -> mac
    case surfacesSubscribe(version: Int)    // capability announce; starts pushes
    case surfacesRequest                    // manual refresh (pull-to-refresh)
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

    // Same date strategy as ChatEnvelope so both unions share the 0x40 frame
    // without ambiguity.
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

// MARK: - Snapshot limits

enum SurfaceSnapshotLimits {
    static let reminders = 50
    static let meetings = 30
    static let notes = 50
    static let agendaDays = 7
    static let agendaEvents = 100
    static let previewChars = 140
}

// MARK: - SurfaceSyncEngine

// One engine for the (single) phone session. PhoneReceiverService activates
// it when the phone announces surface capability and deactivates it on
// teardown. Reminders + notes push reactively (Combine, debounced); meetings
// and the calendar agenda have no publishers, so they ride a 60s poll that
// only ships when the content digest actually changed.
@MainActor
final class SurfaceSyncEngine {
    static let shared = SurfaceSyncEngine()

    private(set) var isActive = false
    private(set) var peerVersion: Int = 0

    private var send: ((Data) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastDigest: String = ""
    // Activity strip mirror (wire v2) keeps its own debounce + digest so a
    // bursty orchestrator can't starve the surfaces snapshot, and vice versa.
    private var activityDebounceTask: Task<Void, Never>?
    private var lastActivityDigest: String = ""

    private var negotiatedVersion: Int { min(SurfaceWire.version, max(1, peerVersion)) }

    private let debounceNanos: UInt64 = 750_000_000
    private let pollSeconds: UInt64 = 60

    private init() {}

    // MARK: Lifecycle

    func activate(peerVersion: Int, send: @escaping (Data) -> Void) {
        self.peerVersion = peerVersion
        self.send = send
        guard !isActive else {
            // Re-subscribe from the same session: just refresh.
            pushNow()
            pushActivityNow()
            return
        }
        isActive = true
        observe()
        startPolling()
        pushNow()
        pushActivityNow()
        WakeLog.shared.log("surfaceSync: activated (phone v\(peerVersion), mac v\(SurfaceWire.version))")
    }

    func deactivate() {
        guard isActive || send != nil else { return }
        isActive = false
        send = nil
        peerVersion = 0
        debounceTask?.cancel(); debounceTask = nil
        pollTask?.cancel(); pollTask = nil
        activityDebounceTask?.cancel(); activityDebounceTask = nil
        cancellables.removeAll()
        lastDigest = ""
        lastActivityDigest = ""
    }

    // Manual pull (phone sent surfacesRequest) or initial subscribe.
    func pushNow() {
        guard let send else { return }
        let snapshot = Self.buildSnapshot()
        lastDigest = Self.digest(of: snapshot)
        let negotiated = min(SurfaceWire.version, max(1, peerVersion))
        guard let data = try? SurfaceEnvelope
            .surfacesSnapshot(version: negotiated, snapshot: snapshot)
            .encode() else { return }
        // Stay far under PhoneWire.maxPayloadBytes; limits above keep typical
        // snapshots in the tens of KB.
        guard data.count < PhoneWire.maxPayloadBytes else {
            WakeLog.shared.log("surfaceSync: snapshot too large (\(data.count)B), dropped")
            return
        }
        send(data)
    }

    // MARK: Activity strip mirror (wire v2)

    // Called by ActivityStripModel whenever the folded dot/cost state moves.
    // Debounced like the surfaces path; the digest gate below means a busy
    // orchestrator that refolds without visible change ships zero bytes.
    func notifyActivityChanged() {
        guard isActive, negotiatedVersion >= SurfaceWire.activityMinVersion else { return }
        activityDebounceTask?.cancel()
        activityDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanos)
            guard !Task.isCancelled, self.isActive else { return }
            self.pushActivityIfChanged()
        }
    }

    func pushActivityNow() {
        guard let send else { return }
        guard negotiatedVersion >= SurfaceWire.activityMinVersion else { return }
        let snapshot = ActivityStripModel.shared.activitySnapshotDTO()
        lastActivityDigest = Self.digest(ofActivity: snapshot)
        guard let data = try? SurfaceEnvelope
            .activitySnapshot(version: negotiatedVersion, snapshot: snapshot)
            .encode() else { return }
        guard data.count < PhoneWire.maxPayloadBytes else {
            WakeLog.shared.log("surfaceSync: activity snapshot too large (\(data.count)B), dropped")
            return
        }
        send(data)
    }

    private func pushActivityIfChanged() {
        guard isActive, negotiatedVersion >= SurfaceWire.activityMinVersion else { return }
        let snapshot = ActivityStripModel.shared.activitySnapshotDTO()
        guard Self.digest(ofActivity: snapshot) != lastActivityDigest else { return }
        pushActivityNow()
    }

    // MARK: Change observation (reminders + notes are @Published)

    private func observe() {
        GruxReminderState.shared.$reminders
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleDebouncedPush() }
            .store(in: &cancellables)
        NotesStore.shared.$notes
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleDebouncedPush() }
            .store(in: &cancellables)
    }

    private func scheduleDebouncedPush() {
        guard isActive else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanos)
            guard !Task.isCancelled, self.isActive else { return }
            self.pushIfChanged()
        }
    }

    // MARK: Polling (meetings index + calendar have no publishers)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.pollSeconds ?? 60) * 1_000_000_000)
                guard let self, self.isActive, !Task.isCancelled else { return }
                self.pushIfChanged()
            }
        }
    }

    private func pushIfChanged() {
        guard isActive else { return }
        let snapshot = Self.buildSnapshot()
        let digest = Self.digest(of: snapshot)
        guard digest != lastDigest else { return }
        pushNow()
    }

    // MARK: Snapshot assembly (reads the stores' public APIs only)

    static func buildSnapshot() -> SurfacesSnapshotDTO {
        SurfacesSnapshotDTO(
            generatedAt: Date(),
            reminders: reminderDTOs(),
            meetings: meetingDTOs(),
            notes: noteDTOs(),
            agenda: agendaDTOs()
        )
    }

    private static func reminderDTOs() -> [SurfaceReminderDTO] {
        GruxReminderState.shared.reminders
            .prefix(SurfaceSnapshotLimits.reminders)
            .map { r in
                SurfaceReminderDTO(
                    id: r.id,
                    kind: r.kind.rawValue,
                    title: r.title,
                    body: String(r.body.prefix(SurfaceSnapshotLimits.previewChars)),
                    createdAt: r.createdAt,
                    scheduledFor: r.scheduledFor,
                    firedAt: r.firedAt,
                    accepted: r.accepted,
                    dismissed: r.dismissed,
                    snoozedUntil: r.snoozedUntil
                )
            }
    }

    private static func meetingDTOs() -> [SurfaceMeetingDTO] {
        MeetingStore.shared.list(limit: SurfaceSnapshotLimits.meetings)
            .map { entry in
                SurfaceMeetingDTO(
                    id: entry.id,
                    title: entry.title?.isEmpty == false
                        ? entry.title!
                        : (entry.sourceAppName.map { "Meeting | \($0)" } ?? "Meeting"),
                    startedAt: entry.startedAt,
                    endedAt: entry.endedAt,
                    sourceAppName: entry.sourceAppName,
                    summaryExcerpt: entry.summaryExcerpt,
                    utteranceCount: entry.utteranceCount
                )
            }
    }

    private static func noteDTOs() -> [SurfaceNoteDTO] {
        NotesStore.shared.ordered
            .prefix(SurfaceSnapshotLimits.notes)
            .map { n in
                SurfaceNoteDTO(
                    id: n.id,
                    title: n.displayTitle,
                    preview: String(n.previewLine.prefix(SurfaceSnapshotLimits.previewChars)),
                    tags: n.tags,
                    pinned: n.pinned,
                    updatedAt: n.updatedAt
                )
            }
    }

    private static func agendaDTOs() -> [SurfaceAgendaEventDTO] {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(SurfaceSnapshotLimits.agendaDays) * 86_400)
        return CalendarService.shared.events(from: now, to: end)
            .prefix(SurfaceSnapshotLimits.agendaEvents)
            .map { ev in
                SurfaceAgendaEventDTO(
                    id: ev.id,
                    title: ev.title,
                    start: ev.start,
                    end: ev.end,
                    isAllDay: ev.isAllDay,
                    location: ev.location,
                    calendarName: ev.calendarName
                )
            }
    }

    // Content digest that ignores generatedAt so an unchanged world never
    // re-ships the same snapshot. Needs its own encoder: hashing requires
    // sorted keys (JSONEncoder key order is otherwise nondeterministic) and
    // the shared wire encoder must stay byte-compatible with ChatEnvelope.
    nonisolated private static let digestEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    nonisolated static func digest(of snapshot: SurfacesSnapshotDTO) -> String {
        let stable = SurfacesSnapshotDTO(
            generatedAt: Date(timeIntervalSince1970: 0),
            reminders: snapshot.reminders,
            meetings: snapshot.meetings,
            notes: snapshot.notes,
            agenda: snapshot.agenda
        )
        guard let data = try? digestEncoder.encode(stable) else { return UUID().uuidString }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // Activity counterpart: same generatedAt-blind digest so an unchanged
    // strip never re-ships the same snapshot.
    nonisolated static func digest(ofActivity snapshot: ActivitySnapshotDTO) -> String {
        let stable = ActivitySnapshotDTO(
            generatedAt: Date(timeIntervalSince1970: 0),
            jobs: snapshot.jobs,
            foundryPass: snapshot.foundryPass,
            estimatedCostLabel: snapshot.estimatedCostLabel
        )
        guard let data = try? digestEncoder.encode(stable) else { return UUID().uuidString }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - PhoneReceiverService hook

// Inbound dispatch for surface envelopes. PhoneReceiverService calls this
// from its 0x40 handler when ChatEnvelope decoding fails (see the
// integration snippet in the roadmap notes). Returns true when the payload
// was a surface envelope.
@MainActor
enum SurfaceSyncInbound {
    @discardableResult
    static func handle(_ payload: Data, send: @escaping (Data) -> Void) -> Bool {
        guard let env = try? SurfaceEnvelope.decode(payload) else { return false }
        switch env {
        case .surfacesSubscribe(let version):
            SurfaceSyncEngine.shared.activate(peerVersion: version, send: send)
        case .surfacesRequest:
            SurfaceSyncEngine.shared.pushNow()
            SurfaceSyncEngine.shared.pushActivityNow()
        case .surfacesSnapshot, .activitySnapshot:
            // Mac -> phone only; ignore an echo.
            break
        }
        return true
    }
}
