import Foundation

// Runs the support-email triage sweep on an hourly cadence, aligned to the top
// of the next hour, mirroring AmbientHourlySummarizer. Each tick reads the open
// Outlook tab(s) and stages brand-voice reply drafts; nothing sends.
//
// Fallback posture (global rule 5): the underlying engine routes LLM calls
// through AmbientLLM (local-first, Claude fallback). If Chrome has no Outlook
// tab open or Apple-Events JavaScript is disabled, OutlookReader returns empty
// and the sweep stages nothing rather than erroring. The Mac being awake is the
// only hard precondition; an asleep machine simply skips the tick.
@MainActor
final class SupportTriageScheduler {
    static let shared = SupportTriageScheduler()
    private init() {}

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0; comps.second = 0
        let thisHour = cal.date(from: comps) ?? now
        let nextHour = thisHour.addingTimeInterval(3600)
        let delay = max(60, nextHour.timeIntervalSince(now))

        let t = Timer(fire: Date().addingTimeInterval(delay), interval: 3600, repeats: true) { _ in
            Task { @MainActor in await EmailTriageEngine.shared.runHourly() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        WakeLog.shared.log("supportTriageScheduler: scheduled, first sweep in \(Int(delay))s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
