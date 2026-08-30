import Foundation

// 8pm "Daily energy + focus recap" scheduler. Coexists with DailyRecapScheduler
// (10pm task wrap-up). The two surfaces are intentionally separated so the
// numbers-driven attention report doesn't get blurred into the warmer
// good-night recap two hours later.
//
// Phone broadcast: when ElevenLabs TTS is the active speech path,
// SpeechEngine routes audio through TTSBroadcaster which the paired
// GruxPhone subscribes to. On the system-AVSpeech fallback path the
// audio plays locally only (same behavior as DailyRecapScheduler).

@MainActor
final class EnergyRecapScheduler {
    static let shared = EnergyRecapScheduler()

    private var tickTimer: Timer?
    private var lastFiredDayKey: String?

    private init() {
        lastFiredDayKey = UserDefaults.standard.string(forKey: "grux.energyRecap.lastFiredDayKey")
    }

    func start() {
        guard tickTimer == nil else { return }
        // Poll every minute, same cadence as DailyRecapScheduler.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
        checkAndFire()
        WakeLog.shared.log("energyRecap scheduler: started")
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
    }

    // Bypasses the "already fired today" guard. Used by Settings + the
    // fire-energy-recap-test smoke trigger.
    func fireRecapNow() async {
        await fireRecap()
    }

    private func checkAndFire() {
        let target = AppState.shared.config.energyRecapHour
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .year, .month, .day], from: now)
        guard let hour = comps.hour else { return }
        let dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        // Fire within a 2-hour window after target so a laptop opened at
        // 21:30 still surfaces today's recap, but a 6am open the next morning
        // doesn't pop yesterday's by surprise.
        let windowOk = hour >= target && hour < target + 2
        guard windowOk, lastFiredDayKey != dayKey else { return }
        lastFiredDayKey = dayKey
        UserDefaults.standard.set(dayKey, forKey: "grux.energyRecap.lastFiredDayKey")
        Task { @MainActor in await self.fireRecap() }
    }

    private func fireRecap() async {
        WakeLog.shared.log("energyRecap: generating…")
        let dayKey = WorkdayLogScheduler.currentDayKey()
        let recap = await EnergyRecapBuilder.build(forDayKey: dayKey)
        WakeLog.shared.log("energyRecap: built dayKey=\(dayKey) hours=\(recap.hoursWorked) breaks=\(recap.focusBreakCount) longest=\(recap.longestFocusBlockMinutes)m provider=\(recap.provider)")

        EnergyRecapPanelController.shared.present(recap)
        if AppState.shared.config.speakRepliesAloud {
            // Polite-queue so a recap doesn't cut into an active chat. Phone
            // broadcast rides on SpeechEngine -> TTSBroadcaster automatically.
            SpeechEngine.shared.speakAfterCurrent(recap.summaryText, maxWaitSeconds: 60)
        }

        // Pre-stamp firedAt so the recap doesn't pollute the "scheduled but
        // not yet fired" filter at ReminderState.swift:135. Calling fire()
        // would also surface the standard reminder toast panel on top of
        // this view, which is not what we want for a recap.
        let reminder = GruxReminder(
            kind: .energyRecap,
            title: "Energy + Focus Recap",
            body: recap.summaryText,
            scheduledFor: nil,
            firedAt: Date()
        )
        GruxReminderState.shared.reminders.insert(reminder, at: 0)
        GruxReminderState.shared.save()
    }
}
