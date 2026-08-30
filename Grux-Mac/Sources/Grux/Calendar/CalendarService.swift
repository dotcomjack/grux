import Foundation
import EventKit

// Read/write EventKit wrapper for the Calendar tab + Claude calendar tools.
//
// CalendarCorrelator (Ambient/) keeps its own private read-only EKEventStore
// for ambient correlation. This service owns a SEPARATE store because the
// correlator's store is intentionally private to that flow and EKEventStore
// instances are cheap enough to hold two of for the process lifetime. Both
// stores see the same underlying calendar database, so writes made here are
// visible to the correlator's reads immediately.
//
// Concurrency model mirrors CalendarCorrelator: EKEventStore and EKEvent are
// not Sendable, so every access is funneled through the main actor and only
// value-type EventSummary snapshots cross actor boundaries.
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()

    private init() {}

    // MARK: - Value-type snapshot (safe to pass across actors / into tools)

    struct EventSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
        let id: String              // EKEvent.eventIdentifier
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
        let calendarName: String
        let calendarId: String
    }

    struct CalendarSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
        let id: String              // EKCalendar.calendarIdentifier
        let title: String
        let allowsModifications: Bool
        let colorHex: String?
    }

    enum ServiceError: LocalizedError {
        case permissionDenied
        case eventNotFound(String)
        case noWritableCalendar
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Calendar permission not granted. Enable it in System Settings > Privacy & Security > Calendars."
            case .eventNotFound(let id):
                return "No calendar event found with id '\(id)'."
            case .noWritableCalendar:
                return "No writable calendar available."
            case .saveFailed(let why):
                return "Calendar save failed: \(why)"
            }
        }
    }

    // MARK: - Permission

    // Delegates the actual prompt to CalendarCorrelator.ensurePermission() so
    // there is exactly one permission flow (and one WakeLog trail) app-wide.
    @discardableResult
    func requestAccess() async -> Bool {
        await CalendarCorrelator.ensurePermission()
    }

    var hasAccess: Bool {
        CalendarCorrelator.currentPermissionState() == .granted
    }

    // MARK: - Calendars

    func calendars() -> [CalendarSummary] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).map { cal in
            CalendarSummary(
                id: cal.calendarIdentifier,
                title: cal.title,
                allowsModifications: cal.allowsContentModifications,
                colorHex: cal.cgColor.flatMap { Self.hexString(from: $0) }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // Resolve a calendar by id, exact title, or case-insensitive substring.
    // nil hint resolves to the default calendar for new events.
    func resolveCalendar(_ hint: String?) -> EKCalendar? {
        guard hasAccess else { return nil }
        let all = store.calendars(for: .event)
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else {
            return store.defaultCalendarForNewEvents ?? all.first { $0.allowsContentModifications }
        }
        if let byId = all.first(where: { $0.calendarIdentifier == hint }) { return byId }
        if let byTitle = all.first(where: { $0.title.caseInsensitiveCompare(hint) == .orderedSame }) { return byTitle }
        return all.first { $0.title.range(of: hint, options: .caseInsensitive) != nil }
    }

    // MARK: - Read

    func events(from windowStart: Date, to windowEnd: Date, calendarHint: String? = nil) -> [EventSummary] {
        guard hasAccess else { return [] }
        let calendars: [EKCalendar]
        if let hint = calendarHint, let resolved = resolveCalendar(hint) {
            calendars = [resolved]
        } else {
            calendars = store.calendars(for: .event)
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
        return store.events(matching: predicate)
            .compactMap { Self.summarize($0) }
            .sorted { $0.start < $1.start }
    }

    func event(withId id: String) -> EventSummary? {
        guard hasAccess, let ev = store.event(withIdentifier: id) else { return nil }
        return Self.summarize(ev)
    }

    // MARK: - Write

    @discardableResult
    func createEvent(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        calendarHint: String? = nil
    ) throws -> EventSummary {
        guard hasAccess else { throw ServiceError.permissionDenied }
        guard let calendar = resolveCalendar(calendarHint), calendar.allowsContentModifications else {
            throw ServiceError.noWritableCalendar
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(60))
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        WakeLog.shared.log("calendarService: created event '\(event.title ?? "")' \(start)")
        guard let summary = Self.summarize(event) else {
            throw ServiceError.saveFailed("event saved but summary unavailable")
        }
        return summary
    }

    @discardableResult
    func updateEvent(
        id: String,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool? = nil,
        location: String? = nil,
        notes: String? = nil
    ) throws -> EventSummary {
        guard hasAccess else { throw ServiceError.permissionDenied }
        guard let event = store.event(withIdentifier: id) else { throw ServiceError.eventNotFound(id) }
        if let title = title { event.title = title }
        if let start = start { event.startDate = start }
        if let end = end { event.endDate = end }
        if let isAllDay = isAllDay { event.isAllDay = isAllDay }
        if let location = location { event.location = location.isEmpty ? nil : location }
        if let notes = notes { event.notes = notes.isEmpty ? nil : notes }
        if let s = event.startDate, let e = event.endDate, e <= s {
            event.endDate = s.addingTimeInterval(3600)
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        WakeLog.shared.log("calendarService: updated event \(id)")
        guard let summary = Self.summarize(event) else {
            throw ServiceError.saveFailed("event saved but summary unavailable")
        }
        return summary
    }

    func deleteEvent(id: String) throws {
        guard hasAccess else { throw ServiceError.permissionDenied }
        guard let event = store.event(withIdentifier: id) else { throw ServiceError.eventNotFound(id) }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        WakeLog.shared.log("calendarService: deleted event \(id)")
    }

    // MARK: - ICS bridge

    // Import parsed ICS events into a calendar. Returns the created summaries.
    // RRULE strings are carried into the event when parseable by EventKit's
    // basic frequencies; unparseable rules import the base occurrence only.
    @discardableResult
    func importICSEvents(_ icsEvents: [ICSImportExport.ICSEvent], calendarHint: String? = nil) throws -> [EventSummary] {
        guard hasAccess else { throw ServiceError.permissionDenied }
        guard let calendar = resolveCalendar(calendarHint), calendar.allowsContentModifications else {
            throw ServiceError.noWritableCalendar
        }
        var created: [EventSummary] = []
        for ics in icsEvents {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = ics.summary.isEmpty ? "(untitled event)" : ics.summary
            event.startDate = ics.start
            event.endDate = ics.effectiveEnd
            event.isAllDay = ics.isAllDay
            event.location = ics.location
            event.notes = ics.description
            if let rrule = ics.rrule, let rule = Self.recurrenceRule(fromRRULE: rrule) {
                event.recurrenceRules = [rule]
            }
            do {
                try store.save(event, span: .thisEvent, commit: false)
            } catch {
                // Discard everything already staged with commit:false on this
                // long-lived store, or the orphaned events sit batched until
                // the NEXT commit (any createEvent/updateEvent/deleteEvent)
                // silently flushes them into the real calendar as phantom
                // events of a failed import.
                store.reset()
                throw ServiceError.saveFailed("'\(event.title ?? "")': \(error.localizedDescription)")
            }
            if let summary = Self.summarize(event) { created.append(summary) }
        }
        do {
            try store.commit()
        } catch {
            store.reset()
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        WakeLog.shared.log("calendarService: imported \(created.count) ICS event(s) into '\(calendar.title)'")
        return created
    }

    // Export a window of events as ICS value types ready for serialization.
    func exportICSEvents(from windowStart: Date, to windowEnd: Date, calendarHint: String? = nil) -> [ICSImportExport.ICSEvent] {
        events(from: windowStart, to: windowEnd, calendarHint: calendarHint).map { ev in
            ICSImportExport.ICSEvent(
                uid: ev.id.isEmpty ? UUID().uuidString : ev.id,
                summary: ev.title,
                start: ev.start,
                end: ev.end,
                isAllDay: ev.isAllDay,
                location: ev.location,
                description: ev.notes,
                rrule: nil
            )
        }
    }

    // MARK: - CommitmentScheduler seam

    // Writes a calendar block for a time-anchored commitment so it shows up in
    // the real macOS calendar, not just the in-app reminder toast. Safe to call
    // fire-and-forget: returns nil (and logs) instead of throwing when access
    // is missing or the save fails. Default block length 30 minutes.
    @discardableResult
    func addCommitmentEvent(title: String, at fireAt: Date, durationMinutes: Int = 30) -> EventSummary? {
        guard hasAccess else {
            WakeLog.shared.log("calendarService: skipped commitment event (no calendar access)")
            return nil
        }
        let clamped = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let safeTitle = clamped.isEmpty ? "Commitment" : clamped
        do {
            return try createEvent(
                title: safeTitle,
                start: fireAt,
                end: fireAt.addingTimeInterval(TimeInterval(max(5, durationMinutes) * 60)),
                notes: "Scheduled by Grux from an ambient commitment."
            )
        } catch {
            WakeLog.shared.log("calendarService: commitment event save failed \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func summarize(_ event: EKEvent) -> EventSummary? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let title = (event.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "(untitled event)"
        return EventSummary(
            id: event.eventIdentifier ?? "",
            title: title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil,
            calendarName: event.calendar?.title ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? ""
        )
    }

    // Minimal RRULE → EKRecurrenceRule mapping: FREQ + INTERVAL + COUNT/UNTIL.
    // Day-of-week and month-day refinements are out of scope for v1; the base
    // cadence is what matters for imported events showing up on the grid.
    private static func recurrenceRule(fromRRULE raw: String) -> EKRecurrenceRule? {
        var freq: EKRecurrenceFrequency?
        var interval = 1
        var end: EKRecurrenceEnd?
        for part in raw.uppercased().split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]); let value = String(kv[1])
            switch key {
            case "FREQ":
                switch value {
                case "DAILY": freq = .daily
                case "WEEKLY": freq = .weekly
                case "MONTHLY": freq = .monthly
                case "YEARLY": freq = .yearly
                default: break
                }
            case "INTERVAL":
                interval = max(1, Int(value) ?? 1)
            case "COUNT":
                if let n = Int(value), n > 0 { end = EKRecurrenceEnd(occurrenceCount: n) }
            case "UNTIL":
                if let date = ICSImportExport.parseICSDate(value, tzid: nil)?.date {
                    end = EKRecurrenceEnd(end: date)
                }
            default:
                break
            }
        }
        guard let frequency = freq else { return nil }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    private static func hexString(from cgColor: CGColor) -> String? {
        guard let components = cgColor.components, components.count >= 3 else { return nil }
        let r = Int(round(components[0] * 255))
        let g = Int(round(components[1] * 255))
        let b = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
