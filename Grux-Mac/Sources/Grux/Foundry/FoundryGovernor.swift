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
        guard let activeId = state.activeAccountId,
              let hitAt = state.perAccount[activeId]?.lastLimitHitAt
        else { return false }
        return now.timeIntervalSince(hitAt) < cooldownHours * 3600
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

    // Start the scheduler tick. Safe to call repeatedly.
    func start(tickSeconds: TimeInterval = 60) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        guard let pass = FoundryGovernorDecision.nextPass(snapshot: snapshot, config: config) else {
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
