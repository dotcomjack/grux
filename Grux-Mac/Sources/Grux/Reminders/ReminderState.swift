import Foundation
import SwiftUI

// Kind of proactive nudge. Drives badge color + phrasing in the toast.
enum GruxReminderKind: String, Codable, Hashable {
    case commitment   // "You said you'd ship auth by 3pm, 3pm now."
    case drift        // Topic-drift / off-task (routed here instead of the OS banner)
    case mentor       // Trigger-phrase mentor ("what do you think?" → advice)
    case stuck        // Silence/stuck detector
    case dailyRecap   // 10pm full daily recap
    case energyRecap  // 8pm energy + focus recap (hours, top apps, focus breaks)
    case morningBrief // forward-looking morning launch brief (Home "Today" card)
    case info         // Generic info toast

    var label: String {
        switch self {
        case .commitment: return "COMMITMENT"
        case .drift: return "DRIFT"
        case .mentor: return "MENTOR"
        case .stuck: return "STUCK?"
        case .dailyRecap: return "DAILY RECAP"
        case .energyRecap: return "ENERGY RECAP"
        case .morningBrief: return "MORNING BRIEF"
        case .info: return "GRUX OS"
        }
    }

    var tone: GruxGlassTone {
        switch self {
        case .commitment: return .urgent
        case .drift: return .urgent
        case .stuck: return .urgent
        case .mentor: return .normal
        case .dailyRecap: return .normal
        case .energyRecap: return .normal
        case .morningBrief: return .normal
        case .info: return .normal
        }
    }

    var sfSymbol: String {
        switch self {
        case .commitment: return "alarm.fill"
        case .drift: return "figure.walk.arrival"
        case .mentor: return "sparkles"
        case .stuck: return "brain.head.profile"
        case .dailyRecap: return "moon.stars.fill"
        case .energyRecap: return "bolt.heart.fill"
        case .morningBrief: return "sun.max.fill"
        case .info: return "bell.fill"
        }
    }
}

// A live reminder (proactive nudge). Persists across relaunches so pending
// time-based commitments aren't lost when Grux restarts mid-day.
struct GruxReminder: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: GruxReminderKind
    var title: String
    var body: String
    var project: String?
    var createdAt: Date
    // When this reminder should FIRE. nil = fire immediately.
    var scheduledFor: Date?
    // Filled in when we actually fire it. nil = pending.
    var firedAt: Date?
    // User actions
    var accepted: Bool = false
    var dismissed: Bool = false
    var snoozedUntil: Date?
    // Optional: link back to a task or action
    var taskId: UUID?
    var sourceCommitmentText: String?

    init(
        id: UUID = UUID(),
        kind: GruxReminderKind,
        title: String,
        body: String,
        project: String? = nil,
        createdAt: Date = Date(),
        scheduledFor: Date? = nil,
        firedAt: Date? = nil,
        taskId: UUID? = nil,
        sourceCommitmentText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.project = project
        self.createdAt = createdAt
        self.scheduledFor = scheduledFor
        self.firedAt = firedAt
        self.taskId = taskId
        self.sourceCommitmentText = sourceCommitmentText
    }

    var isPending: Bool { firedAt == nil && !dismissed }
}

extension Persistence {
    static var remindersDir: URL {
        let d = supportDir.appendingPathComponent("reminders", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var remindersURL: URL { remindersDir.appendingPathComponent("reminders.json") }
}

@MainActor
final class GruxReminderState: ObservableObject {
    static let shared = GruxReminderState()

    // All reminders (pending + fired), bounded.
    @Published var reminders: [GruxReminder] = []
    // Currently-visible toast (top of the stack). Drives the panel.
    @Published var activeToast: GruxReminder?

    private let maxHistory = 200

    private init() {
        load()
    }

    func load() {
        reminders = Persistence.load([GruxReminder].self, from: Persistence.remindersURL, fallback: [])
    }

    func save() {
        if reminders.count > maxHistory { reminders = Array(reminders.prefix(maxHistory)) }
        Persistence.save(reminders, to: Persistence.remindersURL)
    }

    // Scheduled reminders whose fire time hasn't arrived yet.
    var pendingScheduled: [GruxReminder] {
        reminders.filter { r in
            r.firedAt == nil && !r.dismissed && (r.scheduledFor ?? .distantFuture) > Date()
        }
    }

    // Schedule a new reminder. If scheduledFor is nil or in the past, fires
    // immediately. Otherwise waits for CommitmentScheduler's tick to catch it.
    func schedule(_ reminder: GruxReminder) {
        reminders.insert(reminder, at: 0)
        save()
        if reminder.scheduledFor == nil || (reminder.scheduledFor ?? .distantPast) <= Date() {
            fire(reminder.id)
        }
    }

    // Mark a reminder as fired and push it onto the toast stack.
    func fire(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].firedAt = Date()
        save()
        activeToast = reminders[idx]
        WakeLog.shared.log("reminder fired: \(reminders[idx].kind.rawValue): \(reminders[idx].title)")
        // Item 35 webhook seam: identifiers + display fields only.
        NotificationCenter.default.post(name: .gruxReminderFired, object: nil, userInfo: [
            "reminderId": reminders[idx].id.uuidString,
            "title": reminders[idx].title,
            "kind": reminders[idx].kind.rawValue
        ])
        GruxReminderPanelController.shared.present(reminders[idx])
    }

    func accept(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].accepted = true
        save()
        if activeToast?.id == id { activeToast = nil }
        GruxReminderPanelController.shared.dismiss(animated: true)
    }

    func dismiss(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].dismissed = true
        save()
        if activeToast?.id == id { activeToast = nil }
        GruxReminderPanelController.shared.dismiss(animated: true)
    }

    func snooze(_ id: UUID, minutes: Int) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        reminders[idx].firedAt = nil  // re-fires when snooze expires
        reminders[idx].scheduledFor = reminders[idx].snoozedUntil
        save()
        if activeToast?.id == id { activeToast = nil }
        GruxReminderPanelController.shared.dismiss(animated: true)
    }
}
