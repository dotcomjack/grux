import Foundation

// Scans ambient memories for time-anchored commitments, parses a target
// Date out of natural-language time expressions, and schedules a
// GruxReminder to fire at that moment. Fires via GruxReminderState →
// glass Reminder Toast + optional voice read-out.
//
// Pure local - no LLM round trip for the extraction. Uses NSDataDetector
// for date parsing (system-level, no dependency).
@MainActor
final class CommitmentScheduler {
    static let shared = CommitmentScheduler()

    private var tickTimer: Timer?
    // Track which memories we've already scheduled so we don't double-fire
    // when the scheduler re-scans.
    private var scheduledFromMemoryIds: Set<UUID> = []

    private init() {
        // THE SEED USED TO BE A NO-OP LOOP. It read the existing reminders into `existing`
        // and then ran `for _ in existing { }` with a comment promising the real check
        // happened at scan time. It did not: `scheduledFromMemoryIds` is in memory and starts
        // empty on every launch, and GruxReminderState.schedule has no dedupe of its own.
        //
        // So a memory reading "I'll ship it at 9 PM", parsed at 2 PM, produced one reminder
        // and one real event in the person's Calendar. Relaunching at 4 PM parsed the same
        // sentence, found it still in the future, and produced a second of each. At 9 PM they
        // got N glass toast panels and their calendar showed the same commitment N times,
        // once per launch that day.
        //
        // The set is now seeded from what is genuinely on disk, and the scan re-reads it
        // rather than trusting a snapshot taken at init, because reminders scheduled during
        // this session have to count too.
    }

    func start() {
        guard tickTimer == nil else { return }
        // Scan memories every 10s for new commitments with time anchors; also
        // fire any scheduled reminders whose fire time has passed.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick() // initial pass
        WakeLog.shared.log("commitment scheduler: started")
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
        WakeLog.shared.log("commitment scheduler: stopped")
    }

    private func tick() {
        scanMemoriesForNewCommitments()
        firePendingDueReminders()
    }

    // MARK: - Commitment scanning

    /// Whether this exact commitment, at this exact minute, is already on the books.
    ///
    /// Pure and given the existing rows rather than reading the store, so a test can drive
    /// the relaunch case that produced the duplicates without a Calendar, a reminder file or
    /// a second launch.
    ///
    /// Matched on text AND time to the minute rather than text alone: somebody who genuinely
    /// says "I'll ship it at 9 PM" today and again tomorrow means two different commitments,
    /// and collapsing those would lose the second one.
    nonisolated static func isAlreadyScheduled(text: String, firingAt: Date,
                                               existing: [(text: String?, at: Date?)]) -> Bool {
        existing.contains { row in
            guard row.text == text, let at = row.at else { return false }
            return abs(at.timeIntervalSince(firingAt)) < 60
        }
    }

    private func scanMemoriesForNewCommitments() {
        // READ HERE, not at the launch call site. Ambient memories are the only thing this
        // reads, so with ambient off there is nothing legitimate to act on: somebody who
        // tried ambient once and turned it back off kept getting toasts and Calendar events
        // built out of the memories left behind. Reading it per scan rather than per launch
        // also means turning ambient ON mid-session starts this within ten seconds instead
        // of at the next launch.
        guard AppState.shared.config.ambientEnabled else { return }
        let memories = AmbientState.shared.memories
        // Read once per scan, not once per launch. Covers both the reminders restored from
        // disk and anything scheduled earlier in this same session.
        let onTheBooks = GruxReminderState.shared.reminders
            .filter { $0.firedAt == nil }
            .map { (text: $0.sourceCommitmentText, at: $0.scheduledFor) }
        for mem in memories {
            guard !scheduledFromMemoryIds.contains(mem.id) else { continue }
            // Only care about commitments / intents / reminders - facts are
            // durable truths, not time-anchored actions.
            guard mem.kind == .commitment || mem.kind == .intent || mem.kind == .reminder else {
                scheduledFromMemoryIds.insert(mem.id)
                continue
            }
            if let fireAt = Self.parseTargetDate(from: mem.text) {
                // Sanity: don't schedule something in the distant past or
                // way in the future (>72h).
                let now = Date()
                let secondsAhead = fireAt.timeIntervalSince(now)
                guard secondsAhead > 30, secondsAhead < 72 * 3600 else {
                    scheduledFromMemoryIds.insert(mem.id)
                    continue
                }
                // The relaunch guard. Without it the same sentence is parsed again on every
                // launch and produces another reminder and another Calendar event.
                guard !Self.isAlreadyScheduled(text: mem.text, firingAt: fireAt,
                                               existing: onTheBooks) else {
                    scheduledFromMemoryIds.insert(mem.id)
                    continue
                }
                let reminder = GruxReminder(
                    kind: .commitment,
                    title: mem.text,
                    body: "You said you'd handle this \(ReminderToastView.formatRelative(date: fireAt).lowercased()). Grux has it on the schedule.",
                    project: mem.project,
                    scheduledFor: fireAt,
                    sourceCommitmentText: mem.text
                )
                GruxReminderState.shared.schedule(reminder)
                // Mirror the commitment onto the calendar. Fire-and-forget:
                // returns nil and logs instead of throwing when calendar
                // access has not been granted.
                _ = CalendarService.shared.addCommitmentEvent(title: mem.text, at: fireAt)
                scheduledFromMemoryIds.insert(mem.id)
                WakeLog.shared.log("scheduler: queued commitment for \(fireAt) - \(mem.text.prefix(80))")
            } else {
                // No time anchor → skip, don't rescan forever
                scheduledFromMemoryIds.insert(mem.id)
            }
        }
    }

    // MARK: - Firing due reminders

    private func firePendingDueReminders() {
        let now = Date()
        let dueIds = GruxReminderState.shared.reminders
            .filter { $0.firedAt == nil && !$0.dismissed && ($0.scheduledFor ?? .distantFuture) <= now }
            .map { $0.id }
        for id in dueIds {
            GruxReminderState.shared.fire(id)
        }
    }

    // MARK: - Date parsing

    // Uses NSDataDetector for natural-language time parsing. Handles:
    //   "at 3pm", "by 10:30am", "tomorrow at 9", "in 20 minutes",
    //   "next Tuesday", "Friday morning", etc.
    // Returns nil if no time expression detected.
    static func parseTargetDate(from text: String) -> Date? {
        let lower = text.lowercased()
        // First pass: NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
            if let m = matches.first, let d = m.date, d.timeIntervalSinceNow > 30 {
                return d
            }
        }
        // Second pass: catch simple "in N minutes/hours" the detector sometimes misses.
        if let inMatch = Self.inNDurationRegex.firstMatch(
            in: lower, options: [], range: NSRange(lower.startIndex..<lower.endIndex, in: lower)
        ), inMatch.numberOfRanges >= 3,
           let numRange = Range(inMatch.range(at: 1), in: lower),
           let unitRange = Range(inMatch.range(at: 2), in: lower),
           let n = Int(lower[numRange]) {
            let unit = String(lower[unitRange])
            var seconds: TimeInterval = 0
            if unit.hasPrefix("sec") { seconds = Double(n) }
            else if unit.hasPrefix("min") { seconds = Double(n * 60) }
            else if unit.hasPrefix("hour") || unit == "hr" || unit == "hrs" { seconds = Double(n * 3600) }
            else if unit.hasPrefix("day") { seconds = Double(n * 86400) }
            if seconds > 0 {
                return Date().addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static let inNDurationRegex: NSRegularExpression = {
        let pattern = #"\bin\s+(\d+)\s+(seconds?|minutes?|mins?|hours?|hrs?|days?)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
}
