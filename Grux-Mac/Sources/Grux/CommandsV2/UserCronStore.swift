import Foundation

// MARK: - User cron jobs
//
// User-authored recurring schedules: "every weekday at 9am run the
// testflight-feedback workflow" or "every Sunday at 7pm have an agent
// draft my weekly recap".
//
// WHY A SELF-CONTAINED SCHEDULER: CommandV2Engine.register() happily
// accepts user definitions, but the V2 runtime has NO recurring trigger.
// Its scheduling primitives (scheduleResume / ScheduledFollowup +
// rearmScheduledRuns) are one-shot waits INSIDE an already-started run;
// nothing in the engine starts a run on a calendar. Teaching the engine
// recurrence would mean surgery on shared files (CommandV2Engine.swift),
// so per the roadmap constraint we run a standalone Timer-based
// UserCronScheduler here. It computes next-fire dates from weekday+time,
// fires a UNUserNotificationCenter banner, and triggers the action through
// existing seams: CommandV2Engine.start(definitionId:) for workflows,
// CommandV2AgentBridge.runSingleAgent for free-text agent prompts.

// What a cron job DOES when it fires.
enum UserCronAction: Codable, Equatable, Hashable {
    // Start a registered CommandsV2 workflow by definition id.
    case runCommand(definitionId: String)
    // Spawn a single Claude agent with this free-text prompt.
    case agentPrompt(String)

    private enum Kind: String, Codable { case runCommand, agentPrompt }
    private enum CodingKeys: String, CodingKey { case kind, definitionId, prompt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .runCommand:
            self = .runCommand(definitionId: try c.decode(String.self, forKey: .definitionId))
        case .agentPrompt:
            self = .agentPrompt(try c.decode(String.self, forKey: .prompt))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .runCommand(let id):
            try c.encode(Kind.runCommand, forKey: .kind)
            try c.encode(id, forKey: .definitionId)
        case .agentPrompt(let p):
            try c.encode(Kind.agentPrompt, forKey: .kind)
            try c.encode(p, forKey: .prompt)
        }
    }

    var summary: String {
        switch self {
        case .runCommand(let id): return "workflow → \(id)"
        case .agentPrompt(let p): return "agent → \(String(p.prefix(50)))"
        }
    }
}

struct UserCronJob: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var enabled: Bool
    // Calendar weekday numbers: 1 = Sunday ... 7 = Saturday
    // (matches Calendar.component(.weekday, from:)).
    var weekdays: Set<Int>
    var hour: Int       // 0-23 local time
    var minute: Int     // 0-59
    var action: UserCronAction
    var notifyOnFire: Bool
    var createdAt: Date
    var lastFiredAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        enabled: Bool = true,
        weekdays: Set<Int> = [2, 3, 4, 5, 6],  // weekdays Mon-Fri
        hour: Int = 9,
        minute: Int = 0,
        action: UserCronAction,
        notifyOnFire: Bool = true,
        createdAt: Date = Date(),
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.action = action
        self.notifyOnFire = notifyOnFire
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
    }

    // Next occurrence strictly after `reference`. nil when disabled or the
    // schedule shape is invalid (no weekdays, out-of-range time).
    func nextFire(after reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        return CronSchedule.nextFireDate(
            after: reference, weekdays: weekdays, hour: hour, minute: minute, calendar: calendar
        )
    }

    var scheduleSummary: String {
        let time = String(format: "%d:%02d %@", hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour), minute, hour >= 12 ? "PM" : "AM")
        return "\(CronSchedule.weekdaysLabel(weekdays)) at \(time)"
    }
}

// Pure next-fire-date math, kept free of singletons so tests can pin the
// calendar and time zone.
enum CronSchedule {
    // First instant strictly after `reference` that lands on an allowed
    // weekday at hour:minute. Walks at most 8 days, so it always terminates.
    static func nextFireDate(
        after reference: Date,
        weekdays: Set<Int>,
        hour: Int,
        minute: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard !weekdays.isEmpty,
              (0...23).contains(hour),
              (0...59).contains(minute),
              weekdays.allSatisfy({ (1...7).contains($0) })
        else { return nil }

        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: reference) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { continue }
            guard candidate > reference else { continue }
            if weekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }

    static func weekdaysLabel(_ weekdays: Set<Int>) -> String {
        if weekdays == Set(1...7) { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return weekdays.sorted().compactMap { names[$0] }.joined(separator: " ")
    }
}

extension Persistence {
    static var userCronURL: URL { supportDir.appendingPathComponent("user-cron.json") }
}

// MARK: - Store

@MainActor
final class UserCronStore: ObservableObject {
    static let shared = UserCronStore()

    @Published private(set) var jobs: [UserCronJob] = []

    private let storageURL: URL

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = Persistence.userCronURL) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        jobs = Persistence.load([UserCronJob].self, from: storageURL, fallback: [])
    }

    private func save() {
        Persistence.save(jobs, to: storageURL)
    }

    @discardableResult
    func create(
        title: String,
        weekdays: Set<Int> = [2, 3, 4, 5, 6],
        hour: Int = 9,
        minute: Int = 0,
        action: UserCronAction,
        notifyOnFire: Bool = true
    ) -> UserCronJob {
        let job = UserCronJob(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            weekdays: weekdays,
            hour: hour,
            minute: minute,
            action: action,
            notifyOnFire: notifyOnFire
        )
        jobs.insert(job, at: 0)
        save()
        return job
    }

    @discardableResult
    func update(_ job: UserCronJob) -> UserCronJob? {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return nil }
        jobs[idx] = job
        save()
        return jobs[idx]
    }

    func delete(id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func setEnabled(id: UUID, _ enabled: Bool) -> UserCronJob? {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        jobs[idx].enabled = enabled
        save()
        return jobs[idx]
    }

    // Roll a job's fire anchor forward. Called by the scheduler both when a
    // job actually fires and when a stale missed occurrence is skipped.
    func markFired(id: UUID, at date: Date = Date()) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].lastFiredAt = date
        save()
    }

    func job(id: UUID) -> UserCronJob? {
        jobs.first { $0.id == id }
    }
}

// MARK: - Scheduler

// Timer-based runner for user cron jobs. Mirrors CommitmentScheduler's
// lifecycle (start/stop + repeating tick on the main actor). State is
// persisted via UserCronStore.lastFiredAt so a relaunch never double-fires
// and never replays a whole missed week.
@MainActor
final class UserCronScheduler {
    static let shared = UserCronScheduler()

    private var tickTimer: Timer?
    // If Grux was closed or the Mac asleep past this window after a
    // scheduled occurrence, skip it instead of firing late.
    private let missedFireGrace: TimeInterval = 10 * 60

    private init() {}

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        WakeLog.shared.log("user cron: scheduler started (\(UserCronStore.shared.jobs.count) jobs)")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        WakeLog.shared.log("user cron: scheduler stopped")
    }

    // Visible for tests: evaluates one pass over all jobs at `now`.
    func tick(now: Date = Date(), calendar: Calendar = .current) {
        let store = UserCronStore.shared
        for job in store.jobs where job.enabled {
            // Oldest unfired occurrence: computed from the last fire anchor
            // (or creation time for never-fired jobs).
            let anchor = job.lastFiredAt ?? job.createdAt
            guard let due = job.nextFire(after: anchor, calendar: calendar) else { continue }
            guard due <= now else { continue }

            if now.timeIntervalSince(due) > missedFireGrace {
                // Stale (app was off): roll past it without firing. The
                // anchor moves to `now`, which collapses any backlog of
                // missed occurrences in one shot.
                store.markFired(id: job.id, at: now)
                WakeLog.shared.log("user cron: skipped stale occurrence of '\(job.title)' (was due \(due))")
                continue
            }

            store.markFired(id: job.id, at: now)
            fire(job)
        }
    }

    private func fire(_ job: UserCronJob) {
        WakeLog.shared.log("user cron: firing '\(job.title)' → \(job.action.summary)")

        if job.notifyOnFire {
            // The user explicitly opted in to a fire notification on this
            // job, so it must interrupt regardless of the triage matrix
            // (sendInfo lands in the .system bucket and gets batched).
            NotificationManager.shared.sendCategorized(
                .commandPhases,
                actionRequired: true,
                title: "Schedule: \(job.title)",
                body: "Running \(job.action.summary)"
            )
        }

        switch job.action {
        case .runCommand(let definitionId):
            Task { @MainActor in
                CommandV2Engine.shared.load()
                let result = await CommandV2Engine.shared.start(definitionId: definitionId)
                switch result {
                case .success(let runId):
                    WakeLog.shared.log("user cron: '\(job.title)' started run \(runId.uuidString.prefix(8))")
                case .failure(let err):
                    WakeLog.shared.log("user cron: '\(job.title)' failed to start workflow: \(err)")
                    NotificationManager.shared.sendInfo(
                        title: "Schedule failed: \(job.title)",
                        body: "Could not start workflow '\(definitionId)'."
                    )
                }
            }

        case .agentPrompt(let prompt):
            let title = job.title
            Task { @MainActor in
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let result = await CommandV2AgentBridge.runSingleAgent(
                    prompt: prompt,
                    cwd: home,
                    runId: UUID()
                )
                let outcome = result.success ? "done" : "had trouble"
                NotificationManager.shared.sendInfo(
                    title: "Schedule \(outcome): \(title)",
                    body: String(result.text.prefix(180))
                )
                WakeLog.shared.log("user cron: '\(title)' agent finished success=\(result.success) cost=$\(String(format: "%.4f", result.costUSD))")
            }
        }
    }
}
