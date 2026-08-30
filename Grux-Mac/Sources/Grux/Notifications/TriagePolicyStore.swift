import Foundation
import SwiftUI

// Per-category notification policy + quiet hours + the batch queue that
// folds non-interrupt notifications into the hourly/daily recap stores.
//
// Three actions:
//   interrupt - current behavior: a real UNNotification banner, plus
//               optional speech when the category opts in.
//   batch     - no banner. The item queues in TriageBatchQueue, which writes
//               one digest NDJSON line per hour into the same
//               ambient-summaries/<dayKey>.ndjson file the
//               AmbientHourlySummarizer appends to (so WorkdayLogAssembler
//               and the daily recap pick it up for free), and exposes
//               todaysDigestLines() as a seam for DailyRecapScheduler.
//   silent    - timeline log only (TriagePolicyStore.logTriage records every
//               routed notification regardless of action).

enum TriageAction: String, Codable, CaseIterable, Identifiable {
    case interrupt
    case batch
    case silent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .interrupt: return "Interrupt"
        case .batch: return "Batch"
        case .silent: return "Silent"
        }
    }
}

// MARK: - Quiet hours

struct TriageQuietHours: Codable, Equatable {
    var enabled: Bool
    // Minutes from midnight, local time. start may be later than end, which
    // means the window wraps midnight (22:00 -> 07:00).
    var startMinute: Int
    var endMinute: Int

    static let `default` = TriageQuietHours(enabled: false, startMinute: 22 * 60, endMinute: 7 * 60)

    // Pure window math, unit-tested. Start is inclusive, end exclusive.
    // start == end is a zero-length window (never contains anything).
    nonisolated static func windowContains(minuteOfDay m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end {
            return m >= start && m < end
        }
        // Wraps midnight.
        return m >= start || m < end
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return Self.windowContains(minuteOfDay: m, start: startMinute, end: endMinute)
    }
}

// MARK: - Timeline log entry

// Every routed notification leaves one of these, whatever the action. For
// silent items this log IS the delivery.
struct TriageLogEntry: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var category: TriageCategory
    var action: TriageAction
    var title: String

    init(id: String = UUID().uuidString, date: Date = Date(),
         category: TriageCategory, action: TriageAction, title: String) {
        self.id = id
        self.date = date
        self.category = category
        self.action = action
        self.title = title
    }
}

// MARK: - Policy store

@MainActor
final class TriagePolicyStore: ObservableObject {
    static let shared = TriagePolicyStore()

    @Published var policies: [TriageCategory: TriageAction] {
        didSet { scheduleSave() }
    }
    // Categories that also speak the notification title aloud on interrupt.
    @Published var speakOnInterrupt: Set<TriageCategory> {
        didSet { scheduleSave() }
    }
    @Published var quietHours: TriageQuietHours {
        didSet { scheduleSave() }
    }
    // Haiku escalation seam master switch (see TriageClassifier).
    @Published var llmEscalationEnabled: Bool {
        didSet { scheduleSave() }
    }
    // Rolling log of routed notifications, newest first, capped.
    @Published private(set) var recentLog: [TriageLogEntry] = []

    static let logCap = 300

    // Sensible defaults per the blueprint: commitment reminders interrupt,
    // agent completions batch, info silent. Meetings are time-critical so
    // they interrupt; foundry already mirrors into its own timeline.
    nonisolated static let defaultPolicies: [TriageCategory: TriageAction] = [
        .reminders: .interrupt,
        .agentLifecycle: .batch,
        .commandPhases: .batch,
        .emailTriage: .batch,
        .meeting: .interrupt,
        .foundry: .silent,
        .system: .silent
    ]

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var policies: [String: String]
        var speakOnInterrupt: [String]
        var quietHours: TriageQuietHours
        var llmEscalationEnabled: Bool
        var recentLog: [TriageLogEntry]
    }

    init(storageURL: URL = Persistence.supportDir.appendingPathComponent("notification-triage.json")) {
        self.storageURL = storageURL
        let snap = Persistence.load(Snapshot?.self, from: storageURL, fallback: nil)
        var loaded = Self.defaultPolicies
        if let snap {
            for (k, v) in snap.policies {
                if let cat = TriageCategory(rawValue: k), let act = TriageAction(rawValue: v) {
                    loaded[cat] = act
                }
            }
            self.policies = loaded
            self.speakOnInterrupt = Set(snap.speakOnInterrupt.compactMap(TriageCategory.init(rawValue:)))
            self.quietHours = snap.quietHours
            self.llmEscalationEnabled = snap.llmEscalationEnabled
            self.recentLog = snap.recentLog
        } else {
            self.policies = loaded
            self.speakOnInterrupt = []
            self.quietHours = .default
            self.llmEscalationEnabled = true
        }
    }

    func action(for category: TriageCategory) -> TriageAction {
        policies[category] ?? Self.defaultPolicies[category] ?? .batch
    }

    // MARK: - Resolution (pure core, unit-tested)

    // The resolution table:
    //   1. Start from the per-category base action.
    //   2. actionRequired (blockers: paused jobs, rejections) upgrades
    //      batch/silent to interrupt. A blocker silenced by category policy
    //      must still surface, or a paused swarm waits forever.
    //   3. Quiet hours downgrade interrupt to batch, including blockers.
    //      Nothing banners or speaks overnight; the hourly digest
    //      and morning recap carry it instead.
    nonisolated static func resolve(base: TriageAction, actionRequired: Bool, inQuietHours: Bool) -> TriageAction {
        var out = base
        if actionRequired && out != .interrupt { out = .interrupt }
        if inQuietHours && out == .interrupt { out = .batch }
        return out
    }

    func resolve(category: TriageCategory, actionRequired: Bool, at date: Date = Date()) -> TriageAction {
        Self.resolve(
            base: action(for: category),
            actionRequired: actionRequired,
            inQuietHours: quietHours.contains(date)
        )
    }

    // MARK: - Timeline log

    func logTriage(category: TriageCategory, action: TriageAction, title: String) {
        recentLog.insert(TriageLogEntry(category: category, action: action, title: title), at: 0)
        if recentLog.count > Self.logCap {
            recentLog.removeLast(recentLog.count - Self.logCap)
        }
        WakeLog.shared.log("triage: [\(category.rawValue)] \(action.rawValue) - \(title.prefix(80))")
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        let snap = Snapshot(
            policies: Dictionary(uniqueKeysWithValues: policies.map { ($0.key.rawValue, $0.value.rawValue) }),
            speakOnInterrupt: speakOnInterrupt.map(\.rawValue).sorted(),
            quietHours: quietHours,
            llmEscalationEnabled: llmEscalationEnabled,
            recentLog: recentLog
        )
        Persistence.save(snap, to: storageURL)
    }
}

// MARK: - Batch queue (the hourly/daily fold)

struct TriageBatchedItem: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var category: TriageCategory
    var title: String
    var body: String

    init(id: String = UUID().uuidString, date: Date = Date(),
         category: TriageCategory, title: String, body: String) {
        self.id = id
        self.date = date
        self.category = category
        self.title = title
        self.body = body
    }
}

@MainActor
final class TriageBatchQueue: ObservableObject {
    static let shared = TriageBatchQueue()

    @Published private(set) var pending: [TriageBatchedItem] = []
    // Items already folded today; kept so DailyRecapScheduler can include
    // them in the 10pm narrative via todaysDigestLines().
    @Published private(set) var flushedToday: [TriageBatchedItem] = []

    static let flushedCap = 200

    private let storageURL: URL
    private var timer: Timer?

    private struct Snapshot: Codable {
        var pending: [TriageBatchedItem]
        var flushedToday: [TriageBatchedItem]
    }

    init(storageURL: URL = Persistence.supportDir.appendingPathComponent("notification-triage-batch.json")) {
        self.storageURL = storageURL
        let snap = Persistence.load(Snapshot?.self, from: storageURL, fallback: nil)
        if let snap {
            pending = snap.pending
            flushedToday = snap.flushedToday
        }
    }

    func enqueue(category: TriageCategory, title: String, body: String) {
        pending.append(TriageBatchedItem(category: category, title: title, body: body))
        save()
    }

    // Align to the top of the next hour, then fold every 3600s. Mirrors
    // AmbientHourlySummarizer.start() so both writers land on the same
    // hour boundaries in the NDJSON file.
    func start() {
        guard timer == nil else { return }
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0; comps.second = 0
        let thisHour = cal.date(from: comps) ?? now
        let nextHour = thisHour.addingTimeInterval(3600)
        let delay = max(1, nextHour.timeIntervalSince(now))
        let t = Timer(fire: Date().addingTimeInterval(delay),
                      interval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushHour() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        WakeLog.shared.log("triageBatchQueue: scheduled, first fold in \(Int(delay))s")
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    // Folds everything pending at the time of the call into one NDJSON line
    // appended to ambient-summaries/<dayKey>.ndjson. The line uses the same
    // hourStart/hourEnd/summary/chunkCount shape AmbientHourlySummarizer
    // writes, so loadSummaries / WorkdayLogAssembler / the daily recap read
    // it with zero changes. chunkCount stays 0: these are notifications, not
    // transcript chunks.
    func flushHour(now: Date = Date()) {
        // Day rollover: drop yesterday's flushed items at 6am boundary.
        pruneFlushed(now: now)
        guard !pending.isEmpty else { return }
        let items = pending
        pending = []
        flushedToday.append(contentsOf: items)
        if flushedToday.count > Self.flushedCap {
            flushedToday.removeFirst(flushedToday.count - Self.flushedCap)
        }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0; comps.second = 0
        let hourEnd = cal.date(from: comps) ?? now
        let hourStart = hourEnd.addingTimeInterval(-3600)
        appendDigestLine(
            summary: Self.digestSummary(for: items),
            hourStart: hourStart,
            hourEnd: hourEnd
        )
        save()
    }

    // Seam for DailyRecapScheduler: human-readable lines for everything
    // batched today (already-folded plus still-pending), for the 10pm
    // narrative prompt.
    func todaysDigestLines() -> [String] {
        let all = flushedToday + pending
        guard !all.isEmpty else { return [] }
        return all.suffix(20).map { "\($0.category.label): \($0.title)" }
    }

    // MARK: - Pure fold (unit-tested)

    // One compact sentence per fold: counts per category in taxonomy order,
    // with up to two example titles per category.
    nonisolated static func digestSummary(for items: [TriageBatchedItem]) -> String {
        guard !items.isEmpty else { return "Notifications digest: none." }
        var parts: [String] = []
        for cat in TriageCategory.allCases {
            let inCat = items.filter { $0.category == cat }
            guard !inCat.isEmpty else { continue }
            let examples = inCat.prefix(2).map(\.title).joined(separator: "; ")
            parts.append("\(cat.label.lowercased()) \(inCat.count) (\(examples))")
        }
        return "Notifications digest (\(items.count)): " + parts.joined(separator: ", ") + "."
    }

    // MARK: - NDJSON append (same file the hourly summarizer writes)

    private func appendDigestLine(summary: String, hourStart: Date, hourEnd: Date) {
        guard !Persistence.writesSuspended else { return }
        let dayKey = AmbientHourlySummarizer.dayKey(forHourStart: hourStart, calendar: Calendar.current)
        let url = Persistence.ambientSummariesDir.appendingPathComponent("\(dayKey).ndjson")
        let iso = ISO8601DateFormatter()
        let line: [String: Any] = [
            "hourStart": iso.string(from: hourStart),
            "hourEnd": iso.string(from: hourEnd),
            "summary": summary,
            "chunkCount": 0
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: line),
              let str = String(data: json, encoding: .utf8) else { return }
        let payload = (str + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } catch {
                    WakeLog.shared.log("triageBatchQueue: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
        WakeLog.shared.log("triageBatchQueue: folded digest into \(dayKey).ndjson")
    }

    private func pruneFlushed(now: Date) {
        let cal = Calendar.current
        // Same 6am-anchored workday convention as the summarizer.
        let todayKey = AmbientHourlySummarizer.dayKey(forHourStart: now, calendar: cal)
        flushedToday.removeAll {
            AmbientHourlySummarizer.dayKey(forHourStart: $0.date, calendar: cal) != todayKey
        }
    }

    private func save() {
        Persistence.save(Snapshot(pending: pending, flushedToday: flushedToday), to: storageURL)
    }
}
