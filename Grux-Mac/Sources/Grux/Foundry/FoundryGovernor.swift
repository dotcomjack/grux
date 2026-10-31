import Foundation
import CoreGraphics
import IOKit.ps

// The Foundry's cycle scheduler and budget governor (blueprint section 01,
// "Cadence and the budget governor").
//
// Cadence:
//   - Nightly light pass inside the 02:00 to 06:00 local-time window
//     (sense + synthesize + tier-appropriate small builds).
//   - Weekly deep pass Sunday 23:00 (full swarm with adversarial review).
//   - Manual trigger any time ("Grux, upgrade yourself") via triggerManual().
//   - Idle-time opportunistic work only on AC power after 30 minutes idle.
//
// Budget:
//   - All money figures are ESTIMATED API-equivalent spend computed from
//     token counts at the rates table below. The engine runs on
//     subscriptions, so every rendered figure carries the word "estimated".
//   - Session-limit yielding: when the active claude.ai account recently hit
//     its usage limit (the AccountSwitcher seam AgentService stamps via
//     recordLimitHitOnActiveAccount), the governor schedules nothing and an
//     in-flight opportunistic pass should stand down.
//   - Hard token cap per cycle: once a cycle's recorded tokens cross the
//     cap, the cycle must stop filing work.
//
// All window math is DST-safe: every calculation goes through a Calendar
// pinned to the machine's own time zone, never through raw hour arithmetic on
// Date.

// MARK: - Pass kinds

enum FoundryCyclePass: String, Codable, CaseIterable, Sendable {
    case nightlyLight = "nightly-light"
    case weeklyDeep = "weekly-deep"
    case manual
    case opportunistic

    var displayName: String {
        switch self {
        case .nightlyLight: return "Nightly light pass"
        case .weeklyDeep: return "Weekly deep pass"
        case .manual: return "Manual"
        case .opportunistic: return "Opportunistic"
        }
    }
}

// MARK: - Window math (pure, unit tested, DST-safe)

enum FoundryGovernorWindow {

    // The governor thinks in the user's own wall-clock time, which is the
    // machine's time zone. Boundaries are computed by Calendar, so whatever DST
    // rules that zone has are absorbed: the spring-forward skip and the
    // fall-back repeat both come out right.
    static var timeZoneID: String { TimeZone.current.identifier }

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return cal
    }

    // Nightly window: 02:00 <= local time < 06:00. On the spring-forward
    // night 02:xx does not exist; the window effectively opens at 03:00,
    // which the hour-component check handles for free.
    static func isInNightlyWindow(_ date: Date, calendar: Calendar = calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 2 && hour < 6
    }

    // Deep pass slot: Sunday, 23:00 <= local time < 24:00.
    static func isInDeepPassWindow(_ date: Date, calendar: Calendar = calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday
        let hour = calendar.component(.hour, from: date)
        return weekday == 1 && hour == 23
    }

    // Next nightly window opening strictly after `date`. Calendar's
    // nextTimePreservingSmallerComponents policy makes the spring-forward
    // night resolve to 03:00 instead of skipping the day.
    static func nextNightlyStart(after date: Date, calendar: Calendar = calendar) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 2, minute: 0),
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) ?? date.addingTimeInterval(86_400)
    }

    // Next Sunday 23:00 strictly after `date`.
    static func nextDeepPassStart(after date: Date, calendar: Calendar = calendar) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 23, minute: 0, weekday: 1),
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) ?? date.addingTimeInterval(7 * 86_400)
    }

    // Once-per-window guard: true when both dates fall on the same local
    // calendar day.
    static func sameLocalDay(_ a: Date, _ b: Date, calendar: Calendar = calendar) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }
}

// MARK: - Estimated cost accounting

struct FoundryTokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    static func + (lhs: FoundryTokenUsage, rhs: FoundryTokenUsage) -> FoundryTokenUsage {
        FoundryTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens
        )
    }
}

// Token counts x API-equivalent rates. The engine never bills these
// dollars (subscription powered); the table exists so cycles can report a
// truthful "what this would have cost at API rates" figure, ALWAYS rendered
// with the word "estimated".
enum FoundryCostMeter {

    struct Rates: Equatable, Sendable {
        // USD per million tokens.
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    // Delegates to the canonical ModelRates table so the Foundry cycle
    // accounting, the in-app Usage card, and the session-JSONL replay can never
    // drift apart on the same model. ModelRates preserves this function's old
    // behavior: the opus/sonnet family fallbacks and the same cheapest-known
    // policy for unknown ids, now at the corrected Haiku 4.5 price (1.00/5.00,
    // this used to carry a stale 0.80/4.00). Public shape and the label
    // rendering below are unchanged.
    static func rates(forModelID modelID: String) -> Rates {
        let r = ModelRates.rates(forModelID: modelID)
        return Rates(input: r.input, output: r.output, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite)
    }

    static func estimatedUSD(usage: FoundryTokenUsage, modelID: String) -> Double {
        let r = rates(forModelID: modelID)
        return Double(usage.inputTokens) * r.input / 1_000_000
            + Double(usage.outputTokens) * r.output / 1_000_000
            + Double(usage.cacheReadTokens) * r.cacheRead / 1_000_000
            + Double(usage.cacheCreationTokens) * r.cacheWrite / 1_000_000
    }

    // The only label renderer. Delegates to FoundryFormat so every cost
    // string in the app shares one shape, and that shape always carries
    // the word "estimated".
    static func label(usd: Double) -> String {
        FoundryFormat.estimatedCostLabel(usd: usd)
    }

    static func label(usage: FoundryTokenUsage, modelID: String) -> String {
        label(usd: estimatedUSD(usage: usage, modelID: modelID))
    }
}

// MARK: - Per-cycle budget (hard token cap)

struct FoundryCycleBudget: Sendable, Equatable {
    var pass: FoundryCyclePass
    var tokenCap: Int
    private(set) var usage = FoundryTokenUsage()
    private(set) var spendByModel: [String: FoundryTokenUsage] = [:]

    init(pass: FoundryCyclePass, tokenCap: Int) {
        self.pass = pass
        self.tokenCap = tokenCap
    }

    var tokensUsed: Int { usage.total }
    var capExceeded: Bool { tokensUsed >= tokenCap }

    // Record one call's usage. Returns true while the cycle may continue,
    // false once the hard cap is crossed (the caller must stop filing work).
    @discardableResult
    mutating func record(_ delta: FoundryTokenUsage, modelID: String) -> Bool {
        usage = usage + delta
        spendByModel[modelID, default: FoundryTokenUsage()] = spendByModel[modelID, default: FoundryTokenUsage()] + delta
        return !capExceeded
    }

    var estimatedUSD: Double {
        spendByModel.reduce(0) { acc, pair in
            acc + FoundryCostMeter.estimatedUSD(usage: pair.value, modelID: pair.key)
        }
    }

    // Always carries the word estimated, via the single shared renderer.
    var estimatedCostLabel: String {
        FoundryCostMeter.label(usd: estimatedUSD)
    }
}

// MARK: - The schedule the person chose (saved in config.json)

// Which self-upgrade passes run by themselves. Every one is OFF until the person turns
// it on in Self-Upgrade. This used to live only in FoundryGovernorConfig, in memory,
// with all three ON, so turning self-upgrade on (or pressing "Look for upgrades now")
// also armed a nightly, a weekly and an idle pass that nobody chose.
struct FoundrySchedule: Codable, Equatable, Sendable {
    var nightly = false
    var weeklyDeep = false
    var whenIdle = false

    init(nightly: Bool = false, weeklyDeep: Bool = false, whenIdle: Bool = false) {
        self.nightly = nightly
        self.weeklyDeep = weeklyDeep
        self.whenIdle = whenIdle
    }

    // A hand-edited schedule missing a pass reads that pass as off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nightly = try c.decodeIfPresent(Bool.self, forKey: .nightly) ?? false
        weeklyDeep = try c.decodeIfPresent(Bool.self, forKey: .weeklyDeep) ?? false
        whenIdle = try c.decodeIfPresent(Bool.self, forKey: .whenIdle) ?? false
    }

    var anyOn: Bool { nightly || weeklyDeep || whenIdle }

    // What the governor may schedule: nothing at all while self-upgrade is off.
    static func effective(enabled: Bool, schedule: FoundrySchedule) -> FoundrySchedule {
        enabled ? schedule : FoundrySchedule()
    }

    // The one line the Self-Upgrade pane shows above the toggles.
    static func line(enabled: Bool, schedule: FoundrySchedule) -> String {
        guard enabled else {
            return "Self-upgrade is off. Turn it on in Settings, or ask Grux to upgrade itself."
        }
        var when: [String] = []
        if schedule.nightly { when.append("nightly between 2 and 6 AM") }
        if schedule.weeklyDeep { when.append("Sundays at 11 PM") }
        if schedule.whenIdle { when.append("when your Mac is idle on power") }
        guard let last = when.popLast() else {
            return "Self-upgrade is on. It runs only when you ask."
        }
        let joined = when.isEmpty ? last : when.joined(separator: ", ") + " and " + last
        return "Self-upgrade is on. It also runs \(joined)."
    }
}

// The pane's second line: when a pass last ran and when the next one will, from the
// same window math the governor schedules with, so a quiet schedule reads differently
// from a broken one.
extension FoundrySchedule {
    static func timesLine(enabled: Bool, schedule: FoundrySchedule, lastRanAt: Date?,
                          lastNightlyAt: Date?, lastDeepAt: Date?, lastOpportunisticAt: Date?,
                          paused: Bool, ticking: Bool, running: Bool, limitClearsAt: Date?, now: Date,
                          calendar: Calendar = FoundryGovernorWindow.calendar,
                          opportunisticSpacingHours: Double = FoundryGovernorConfig().opportunisticSpacingHours) -> String {
        let last = "Last pass: " + (lastRanAt.map { when($0, now: now, calendar: calendar) } ?? "none yet") + "."
        guard enabled else { return last }
        if paused { return last + " Next: none, self-upgrade paused itself after a crash loop." }
        // tick() returns at once while a pass runs, so nothing else starts before it ends.
        if running { return last + " Next: after the pass running now." }
        // A limit holds every pass, scheduled or asked for, until it clears; the windows are
        // read from that moment, and the line says why.
        let held = limitClearsAt.flatMap { $0 > now ? $0 : nil }
        // Grux's own cooldown after a limit hit (limitCooldownHours), not Claude's reset time.
        let hold = held.map { " After a Claude session limit, Grux waits until " + when($0, now: now, calendar: calendar) + " to run a pass." } ?? ""
        guard schedule.anyOn else { return last + " Next: when you ask." + hold }
        // Only a running tick starts a scheduled pass; one turned on after launch from
        // Settings or the command line waits for the next launch.
        guard ticking else { return last + " Next: once Grux relaunches." + hold }
        let from = held ?? now

        // Each timed pass is due inside its window unless it already ran that day, else at
        // its next window start.
        func due(inWindow: Bool, lastAt: Date?, next: Date) -> Date {
            let ranToday = lastAt.map { FoundryGovernorWindow.sameLocalDay($0, from, calendar: calendar) } ?? false
            return inWindow && !ranToday ? from : next
        }
        var timed: [Date] = []
        if schedule.nightly {
            timed.append(due(inWindow: FoundryGovernorWindow.isInNightlyWindow(from, calendar: calendar),
                             lastAt: lastNightlyAt,
                             next: FoundryGovernorWindow.nextNightlyStart(after: from, calendar: calendar)))
        }
        if schedule.weeklyDeep {
            timed.append(due(inWindow: FoundryGovernorWindow.isInDeepPassWindow(from, calendar: calendar),
                             lastAt: lastDeepAt,
                             next: FoundryGovernorWindow.nextDeepPassStart(after: from, calendar: calendar)))
        }
        // The idle pass has no clock time, only the spacing after the last one (and the hold).
        let idleFrom = lastOpportunisticAt.map { $0.addingTimeInterval(opportunisticSpacingHours * 3600) }
        let idleAfter = [idleFrom.flatMap { $0 > now ? $0 : nil }, held].compactMap { $0 }.max()
        let idleTail = idleAfter.map { " after " + clock($0, calendar: calendar) } ?? ""

        guard let next = timed.min() else {
            return last + " Next: when your Mac is idle on power" + (idleAfter.map { ", after " + clock($0, calendar: calendar) } ?? "") + "." + hold
        }
        if next <= now { return last + " Next: within a minute." }
        var line = last + " Next: " + when(next, now: now, calendar: calendar)
        if schedule.whenIdle, (idleAfter ?? now) < next {
            line += ", or sooner when your Mac is idle on power" + idleTail
        }
        return line + "." + hold
    }

    // "today at 3:48 AM", "yesterday at", "tomorrow at", a weekday within the coming
    // week, else "Jun 13 at 9:00 AM".
    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let day: String
        switch days {
        case 0: day = "today"
        case -1: day = "yesterday"
        case 1: day = "tomorrow"
        case 2...6: day = format(date, "EEEE", calendar: calendar)
        default: day = format(date, "MMM d", calendar: calendar)
        }
        return day + " at " + clock(date, calendar: calendar)
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        format(date, "h:mm a", calendar: calendar)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

// MARK: - Scheduling decision (pure, unit tested)

struct FoundryGovernorConfig: Codable, Equatable, Sendable {
    var nightlyEnabled = true
    var deepPassEnabled = true
    var opportunisticEnabled = true
    // Idle-time opportunistic work only after this much idle, on AC power.
    var idleMinutes: Double = 30
    // Minimum spacing between opportunistic passes. A cycle generates no
    // HID events, so without this an idle desktop Mac on AC would launch a
    // fresh opportunistic pass on every 60s tick, all night.
    var opportunisticSpacingHours: Double = 4
    // Yield window after the active account hits its session limit.
    var limitCooldownHours: Double = 6
    // Hard token caps per cycle kind.
    var nightlyTokenCap = 2_000_000
    var deepTokenCap = 10_000_000
    var opportunisticTokenCap = 500_000
    var manualTokenCap = 10_000_000

    // The pass switches come from the saved FoundrySchedule on every live tick;
    // the defaults above only serve the pure decision tests.
    func scheduled(_ schedule: FoundrySchedule) -> FoundryGovernorConfig {
        var c = self
        c.nightlyEnabled = schedule.nightly
        c.deepPassEnabled = schedule.weeklyDeep
        c.opportunisticEnabled = schedule.whenIdle
        return c
    }

    func tokenCap(for pass: FoundryCyclePass) -> Int {
        switch pass {
        case .nightlyLight: return nightlyTokenCap
        case .weeklyDeep: return deepTokenCap
        case .opportunistic: return opportunisticTokenCap
        case .manual: return manualTokenCap
        }
    }
}

// Everything the decision needs, sampled by the live governor and built by
// hand in tests.
struct FoundryGovernorSnapshot: Sendable {
    var now: Date
    var idleSeconds: TimeInterval
    var onACPower: Bool
    var sessionLimited: Bool
    var lastNightlyAt: Date?
    var lastDeepAt: Date?
    var cycleRunning: Bool
    var lastOpportunisticAt: Date? = nil
}

enum FoundryGovernorDecision {

    // The scheduling brain. Deterministic and side-effect free so the DST
    // tests can sweep it across the calendar.
    static func nextPass(
        snapshot: FoundryGovernorSnapshot,
        config: FoundryGovernorConfig,
        calendar: Calendar = FoundryGovernorWindow.calendar
    ) -> FoundryCyclePass? {
        // One cycle at a time, and the governor yields entirely while the
        // active account is rate-limited (the user's own work comes first).
        guard !snapshot.cycleRunning, !snapshot.sessionLimited else { return nil }

        // Deep pass outranks everything in its Sunday 23:00 slot, at most
        // once per local day.
        if config.deepPassEnabled,
           FoundryGovernorWindow.isInDeepPassWindow(snapshot.now, calendar: calendar),
           !(snapshot.lastDeepAt.map { FoundryGovernorWindow.sameLocalDay($0, snapshot.now, calendar: calendar) } ?? false) {
            return .weeklyDeep
        }

        // Nightly light pass inside 02:00 to 06:00, at most once per local day.
        if config.nightlyEnabled,
           FoundryGovernorWindow.isInNightlyWindow(snapshot.now, calendar: calendar),
           !(snapshot.lastNightlyAt.map { FoundryGovernorWindow.sameLocalDay($0, snapshot.now, calendar: calendar) } ?? false) {
            return .nightlyLight
        }

        // Opportunistic: AC power, a genuinely idle machine, and at least
        // opportunisticSpacingHours since the last opportunistic pass (the
        // cycle itself generates no HID events, so idleSeconds alone would
        // re-fire on every tick of an idle night).
        if config.opportunisticEnabled,
           snapshot.onACPower,
           snapshot.idleSeconds >= config.idleMinutes * 60,
           snapshot.lastOpportunisticAt.map({
               snapshot.now.timeIntervalSince($0) >= config.opportunisticSpacingHours * 3600
           }) ?? true {
            return .opportunistic
        }

        return nil
    }

    // Mid-cycle yield check. Opportunistic work stands down the moment the
    // user touches the machine; every pass stands down on a session limit.
    static func shouldYield(
        pass: FoundryCyclePass,
        idleSeconds: TimeInterval,
        sessionLimited: Bool
    ) -> Bool {
        if sessionLimited { return true }
        if pass == .opportunistic && idleSeconds < 60 { return true }
        return false
    }

    // Session-limit predicate over the AccountSwitcher state shape: the
    // active account hit its limit within the cooldown window. Pure so the
    // tests build AuthState fixtures directly.
    static func sessionLimited(
        state: AuthState,
        now: Date,
        cooldownHours: Double
    ) -> Bool {
        sessionLimitClearsAt(state: state, now: now, cooldownHours: cooldownHours) != nil
    }

    // When the limit above stops holding passes, or nil when it holds none now.
    static func sessionLimitClearsAt(
        state: AuthState,
        now: Date,
        cooldownHours: Double
    ) -> Date? {
        guard let activeId = state.activeAccountId,
              let hitAt = state.perAccount[activeId]?.lastLimitHitAt
        else { return nil }
        return now.timeIntervalSince(hitAt) < cooldownHours * 3600
            ? hitAt.addingTimeInterval(cooldownHours * 3600) : nil
    }
}

// MARK: - The live governor

@MainActor
final class FoundryGovernor: ObservableObject {

    static let shared = FoundryGovernor()

    enum Phase: Equatable {
        case idle
        case running(FoundryCyclePass)
        case yielded(String)  // reason
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastNightlyAt: Date?
    @Published private(set) var lastDeepAt: Date?
    @Published private(set) var lastOpportunisticAt: Date?
    @Published private(set) var currentBudget: FoundryCycleBudget?
    @Published var config = FoundryGovernorConfig()

    // The cycle runner seam: the integrator installs the actual Foundry
    // cycle (sense -> synthesize -> build -> verify -> land) here. The
    // governor only decides WHEN; it never knows how a cycle works.
    var runCycle: ((FoundryCyclePass) async -> Void)?

    // Environment seams, replaceable in tests.
    var now: () -> Date = { Date() }
    var idleSeconds: () -> TimeInterval = FoundryGovernor.systemIdleSeconds
    var onACPower: () -> Bool = FoundryGovernor.isOnACPower
    var sessionLimited: (() -> Bool)?
    // The saved schedule, read on every tick so a change in the Self-Upgrade pane (or in
    // config.json on disk) takes effect without a relaunch, and turning self-upgrade off
    // stops every scheduled pass at once.
    var schedule: @MainActor () -> FoundrySchedule = {
        FoundrySchedule.effective(enabled: AppState.shared.config.foundryEnabled,
                                  schedule: AppState.shared.config.foundrySchedule)
    }

    private var timer: Timer?
    private let stateURL: URL

    private struct PersistedState: Codable {
        var lastNightlyAt: Date?
        var lastDeepAt: Date?
        var lastOpportunisticAt: Date?
    }

    init(stateURL: URL = FoundryPaths.dir.appendingPathComponent("governor-state.json")) {
        self.stateURL = stateURL
        let persisted = Persistence.load(PersistedState.self, from: stateURL, fallback: PersistedState())
        self.lastNightlyAt = persisted.lastNightlyAt
        self.lastDeepAt = persisted.lastDeepAt
        self.lastOpportunisticAt = persisted.lastOpportunisticAt
    }

    // MARK: Lifecycle

    // Whether the scheduler tick runs, so the pane promises a time only when it does.
    @Published private(set) var isTicking = false

    // Start the scheduler tick. Safe to call repeatedly.
    func start(tickSeconds: TimeInterval = 60) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        isTicking = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isTicking = false
    }

    // When the session limit stops holding passes, from the same state tick() reads.
    func sessionLimitClearsAt(now date: Date) -> Date? {
        FoundryGovernorDecision.sessionLimitClearsAt(
            state: AccountSwitcher.shared.state,
            now: date,
            cooldownHours: config.limitCooldownHours
        )
    }

    // Manual trigger seam: "Grux, upgrade yourself." Skips the window math
    // but still honors the session-limit yield and the one-at-a-time rule.
    func triggerManual() {
        guard case .idle = phase else { return }
        if GruxUpdater.shared.isAutoLandPaused() {
            phase = .yielded("auto-land paused after a crash loop; clear the pause to resume")
            return
        }
        if isSessionLimited() {
            phase = .yielded("session limit active on the current claude.ai account")
            return
        }
        launch(pass: .manual)
    }

    // One scheduler heartbeat. Exposed for tests (they call tick() with
    // injected seams instead of waiting on the Timer).
    func tick() {
        if case .running = phase { return }
        // Crash-loop breaker: a tripped auto-land pause stops the governor
        // from scheduling any cycle until a human clears it.
        if GruxUpdater.shared.isAutoLandPaused() {
            if case .yielded = phase {} else {
                phase = .yielded("auto-land paused after a crash loop; clear the pause to resume")
            }
            return
        }
        let snapshot = FoundryGovernorSnapshot(
            now: now(),
            idleSeconds: idleSeconds(),
            onACPower: onACPower(),
            sessionLimited: isSessionLimited(),
            lastNightlyAt: lastNightlyAt,
            lastDeepAt: lastDeepAt,
            cycleRunning: false,
            lastOpportunisticAt: lastOpportunisticAt
        )
        guard let pass = FoundryGovernorDecision.nextPass(snapshot: snapshot,
                                                          config: config.scheduled(schedule())) else {
            if case .yielded = phase { phase = .idle }
            return
        }
        launch(pass: pass)
    }

    private func launch(pass: FoundryCyclePass) {
        phase = .running(pass)
        currentBudget = FoundryCycleBudget(pass: pass, tokenCap: config.tokenCap(for: pass))
        let startedAt = now()
        switch pass {
        case .nightlyLight: lastNightlyAt = startedAt
        case .weeklyDeep: lastDeepAt = startedAt
        case .opportunistic: lastOpportunisticAt = startedAt
        case .manual: break
        }
        persistState()

        let runner = runCycle
        Task { @MainActor [weak self] in
            await runner?(pass)
            guard let self else { return }
            if case .running = self.phase { self.phase = .idle }
        }
    }

    // MARK: Mid-cycle controls

    // Cycle workers call this after every model call. Returns false once
    // the hard token cap is crossed or a yield condition appears; the
    // caller must stop filing new work and wind down.
    func recordUsage(_ delta: FoundryTokenUsage, modelID: String) -> Bool {
        guard case .running(let pass) = phase, var budget = currentBudget else { return false }
        let underCap = budget.record(delta, modelID: modelID)
        currentBudget = budget
        if !underCap {
            phase = .yielded("hard token cap reached: \(budget.tokensUsed) of \(budget.tokenCap) tokens, \(budget.estimatedCostLabel)")
            return false
        }
        if FoundryGovernorDecision.shouldYield(
            pass: pass, idleSeconds: idleSeconds(), sessionLimited: isSessionLimited()
        ) {
            phase = .yielded(pass == .opportunistic ? "user activity detected" : "session limit hit mid-cycle")
            return false
        }
        return true
    }

    // The pass's running figure for the Self-Upgrade tab ticker. Always
    // carries the word estimated.
    var currentEstimatedCostLabel: String {
        currentBudget?.estimatedCostLabel ?? FoundryCostMeter.label(usd: 0)
    }

    // MARK: Seams

    private func isSessionLimited() -> Bool {
        if let sessionLimited { return sessionLimited() }
        return FoundryGovernorDecision.sessionLimited(
            state: AccountSwitcher.shared.state,
            now: now(),
            cooldownHours: config.limitCooldownHours
        )
    }

    private func persistState() {
        Persistence.save(PersistedState(
            lastNightlyAt: lastNightlyAt,
            lastDeepAt: lastDeepAt,
            lastOpportunisticAt: lastOpportunisticAt
        ), to: stateURL)
    }

    // MARK: System probes

    // Same CGEventSource pattern StuckDetector uses: minimum time since the
    // user did anything across the relevant HID event types. Zero
    // permissions required.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let values = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return values.min() ?? 0
    }

    // IOKit power-source check: true when the providing source is AC. A
    // desktop Mac reports no battery sources and provides AC, and on any
    // failure we assume AC (a Mac mini or Studio must never be starved of
    // opportunistic cycles by a missing battery API).
    nonisolated static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        // Get (not Copy) rule: the providing-type CFString is not owned by us.
        guard let typeCF = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (typeCF as String) == kIOPMACPowerKey
    }
}
