import Foundation
import EventKit
import CryptoKit

// Reads macOS Calendar via EventKit and correlates scheduled events to
// ambient transcript chunks captured during the same time window. Output is a
// flat list of annotated timeline entries the WorkdayLog flow can surface as
// "meetings attended".
//
// Permission model: EventKit on macOS 14+ exposes two paths. requestFullAccess
// (preferred) and the deprecated requestAccess (used as fallback so the build
// stays clean against the SDK floor). Permission is requested on first launch
// via CalendarCorrelator.ensurePermission(), wired from GruxApp.
//
// "Ambient session" definition: a contiguous run of AmbientState chunks whose
// adjacent timestamps are within `ambientSessionGapSeconds` of each other.
// The session ID is a deterministic UUID derived from the first chunk's
// timestamp so re-runs against the same transcript produce stable IDs.

enum CalendarCorrelator {

    // MARK: - Tunables

    // Treat ambient chunks > 5 min apart as belonging to separate sessions.
    static let ambientSessionGapSeconds: TimeInterval = 300

    // MARK: - Shared store

    // Single shared EKEventStore for the whole process. Per-call allocation
    // is wasteful (each new store loads the full local calendar database)
    // and EKEventStore is not Sendable, so a shared instance also avoids
    // any cross-actor confusion. All accesses are funneled through the
    // main actor via storeAccess() below.
    private static let sharedStore = EKEventStore()

    @MainActor
    private static func storeAccess<T>(_ body: (EKEventStore) -> T) -> T {
        body(sharedStore)
    }

    // MARK: - Result shape (matches the spec: ts_start, ts_end, event_title,
    // calendar_name, ambient_session_id?).

    struct TimelineEntry: Codable, Equatable, Hashable {
        let tsStart: Date
        let tsEnd: Date
        let eventTitle: String
        let calendarName: String
        let ambientSessionId: String?
    }

    // MARK: - Permission

    enum PermissionState {
        case granted
        case denied
        case notDetermined
    }

    static func currentPermissionState() -> PermissionState {
        let status = EKEventStore.authorizationStatus(for: .event)
        // writeOnly is NOT treated as granted: we need read access to fetch
        // events for correlation. authorized is the deprecated pre-macOS-14
        // value, fullAccess is the macOS-14+ replacement.
        switch status {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // Idempotent. Safe to call on every launch. Logs outcome via WakeLog.
    @discardableResult
    @MainActor
    static func ensurePermission() async -> Bool {
        switch currentPermissionState() {
        case .granted:
            WakeLog.shared.log("calendarCorrelator: permission already granted")
            return true
        case .denied:
            WakeLog.shared.log("calendarCorrelator: permission denied (user)")
            return false
        case .notDetermined:
            break
        }

        let store = sharedStore
        do {
            if #available(macOS 14.0, *) {
                let ok = try await store.requestFullAccessToEvents()
                WakeLog.shared.log("calendarCorrelator: requestFullAccessToEvents → \(ok)")
                return ok
            } else {
                let ok: Bool = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { granted, error in
                        if let error = error { cont.resume(throwing: error) }
                        else { cont.resume(returning: granted) }
                    }
                }
                WakeLog.shared.log("calendarCorrelator: requestAccess → \(ok)")
                return ok
            }
        } catch {
            WakeLog.shared.log("calendarCorrelator: permission request FAILED \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Event fetch

    // Pulls every EKEvent from every calendar in [windowStart, windowEnd).
    // Returns an empty array (without throwing) when permission is missing so
    // callers can treat a "no calendar" day as the normal no-meetings path.
    //
    // MainActor-isolated: EKEventStore is not Sendable and Apple's guidance
    // is to use a dedicated store per thread. Funneling all reads through
    // the main actor keeps the shared store safe.
    @MainActor
    static func eventsInWindow(
        windowStart: Date, windowEnd: Date
    ) -> [EKEvent] {
        guard currentPermissionState() == .granted else { return [] }
        let store = sharedStore
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(
            withStart: windowStart, end: windowEnd, calendars: calendars
        )
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    // MARK: - Ambient session inference

    struct AmbientSession: Equatable {
        let id: String
        let start: Date
        let end: Date
    }

    // Group chunks into contiguous sessions (gap-based clustering).
    // Single-chunk sessions get a 1-second duration so overlap math still
    // works against zero-length transcript blips.
    static func ambientSessions(from chunks: [AmbientChunk]) -> [AmbientSession] {
        guard !chunks.isEmpty else { return [] }
        let sorted = chunks.sorted { $0.timestamp < $1.timestamp }

        var sessions: [AmbientSession] = []
        var sessionStart = sorted[0].timestamp
        var lastTs = sorted[0].timestamp

        for chunk in sorted.dropFirst() {
            let gap = chunk.timestamp.timeIntervalSince(lastTs)
            if gap > ambientSessionGapSeconds {
                sessions.append(makeSession(start: sessionStart, end: lastTs))
                sessionStart = chunk.timestamp
            }
            lastTs = chunk.timestamp
        }
        sessions.append(makeSession(start: sessionStart, end: lastTs))
        return sessions
    }

    private static func makeSession(start: Date, end: Date) -> AmbientSession {
        let safeEnd = end > start ? end : start.addingTimeInterval(1)
        return AmbientSession(id: deterministicID(forStart: start), start: start, end: safeEnd)
    }

    // Stable UUID from "ambient-session|<epoch>" so the same transcript boundary
    // always yields the same ID across re-runs.
    private static func deterministicID(forStart start: Date) -> String {
        let seed = "ambient-session|\(Int(start.timeIntervalSince1970))"
        return UUID.fromSHA1(seed: seed).uuidString
    }

    // MARK: - Correlate

    // Match each calendar event to the FIRST ambient session whose interval
    // overlaps the event window. If multiple sessions overlap, take the one
    // with the largest overlap. Events with no overlapping session still get
    // emitted (ambientSessionId = nil); the user may have attended but ambient
    // wasn't running.
    static func correlate(
        events: [EKEvent], ambientSessions: [AmbientSession]
    ) -> [TimelineEntry] {
        events.compactMap { event -> TimelineEntry? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let title = (event.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "(untitled event)"
            let calName = event.calendar?.title ?? ""

            // Find the ambient session with maximum overlap.
            var bestSession: AmbientSession? = nil
            var bestOverlap: TimeInterval = 0
            for s in ambientSessions {
                let lo = max(start, s.start)
                let hi = min(end, s.end)
                let overlap = hi.timeIntervalSince(lo)
                if overlap > 0 && overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSession = s
                }
            }

            return TimelineEntry(
                tsStart: start,
                tsEnd: end,
                eventTitle: title,
                calendarName: calName,
                ambientSessionId: bestSession?.id
            )
        }
    }

    // MARK: - Public one-shot

    // Convenience used by WorkdayLogAssembler + the fire-trigger smoke test.
    // Caller hands in the chunks (grabbed on MainActor from AmbientState).
    // EventKit read AND correlation happen inside MainActor.run so the
    // non-Sendable EKEvent array never crosses actors; only the pure
    // TimelineEntry value-type array is returned.
    static func entries(
        forWindow windowStart: Date,
        windowEnd: Date,
        chunks: [AmbientChunk]
    ) async -> [TimelineEntry] {
        let sessions = ambientSessions(from: chunks)
        return await MainActor.run {
            let events = eventsInWindow(windowStart: windowStart, windowEnd: windowEnd)
            return correlate(events: events, ambientSessions: sessions)
        }
    }
}

private extension UUID {
    static func fromSHA1(seed: String) -> UUID {
        let digest = Array(Insecure.SHA1.hash(data: Data(seed.utf8)).prefix(16))
        let tuple: uuid_t = (
            digest[0],  digest[1],  digest[2],  digest[3],
            digest[4],  digest[5],  digest[6],  digest[7],
            digest[8],  digest[9],  digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: tuple)
    }
}
