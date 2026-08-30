import Foundation

// 6am-anchored archival rollup. Polls every minute; fires once per dayKey
// when local hour ∈ [6, 10). 4-hour grace window tolerates a closed laptop.
// Mirrors DailyRecapScheduler.

@MainActor
final class WorkdayLogScheduler {
    static let shared = WorkdayLogScheduler()

    private var tickTimer: Timer?
    private var lastFiredDayKey: String?

    private init() {
        lastFiredDayKey = UserDefaults.standard.string(forKey: "grux.workdayLog.lastFiredDayKey")
    }

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
        checkAndFire()
        WakeLog.shared.log("workdayLog scheduler: started")
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func checkAndFire() {
        // THE OFF SWITCH, read here rather than only at start(), so switching it off stops
        // the run already scheduled by the 60 second timer as well as the next launch.
        // `stop()` had zero call sites before this; the Settings toggle now calls it.
        guard WorkdayLogStore.isEnabled else { return }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .year, .month, .day], from: now)
        guard let hour = comps.hour else { return }
        // Window closed at 6am - we log for the PREVIOUS calendar day
        // (the workday that just ended).
        guard hour >= 6 && hour < 10 else { return }

        let prior = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let priorComps = cal.dateComponents([.year, .month, .day], from: prior)
        let dayKey = String(format: "%04d-%02d-%02d",
                            priorComps.year ?? 0, priorComps.month ?? 0, priorComps.day ?? 0)

        guard lastFiredDayKey != dayKey else { return }
        lastFiredDayKey = dayKey
        UserDefaults.standard.set(dayKey, forKey: "grux.workdayLog.lastFiredDayKey")

        WakeLog.shared.log("workdayLog scheduler: firing for \(dayKey)")
        Task {
            let log = await WorkdayLogAssembler.build(forDayKey: dayKey)
            WorkdayLogStore.save(log)
        }
    }

    // Manual trigger - bypasses the one-fire-per-day guard. Useful for
    // "Generate today's log now" from the menu, or a voice macro.
    @discardableResult
    func generateWorkdayLogNow(forDayKey dayKey: String) async -> WorkdayLog {
        WakeLog.shared.log("workdayLog manual: \(dayKey)")
        let log = await WorkdayLogAssembler.build(forDayKey: dayKey)
        WorkdayLogStore.save(log)
        return log
    }

    // Convenience: today's dayKey per workday-window semantics.
    static func currentDayKey() -> String {
        WorkdayLogAssembler.dayKey(forDate: Date(), calendar: Calendar.current)
    }

    static func previousDayKey() -> String {
        let d = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return WorkdayLogAssembler.dayKey(forDate: d, calendar: Calendar.current)
    }
}
