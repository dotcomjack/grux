import Foundation

// Scans ambient memories for time-anchored commitments, parses a target
// Date out of natural-language time expressions, and schedules a
// GruxReminder to fire at that moment. Fires via GruxReminderState →
// glass Reminder Toast + optional voice read-out. The person's Calendar is
// only ever ASKED about: each commitment files one card in Approvals that
// replays the gated `create_event` tool when they tap it (D60).
//
// Pure local - no LLM round trip for the extraction. Uses NSDataDetector
// for date parsing (system-level, no dependency).
@MainActor
final class CommitmentScheduler {
    static let shared = CommitmentScheduler()

    private var tickTimer: Timer?
    // Track which memories we've already scheduled so we don't double-fire
    // when the scheduler re-scans. Keyed on the id AND the text: an edited memory
    // keeps its id, and its new time is asked at the next tick, not the next launch.
    private var scannedMemories: Set<String> = []
    private static func scanKey(_ mem: AmbientMemory) -> String { "\(mem.id.uuidString)|\(mem.text)" }

    // Where a parsed commitment goes. Seams so a test can drive a scan without
    // the person's reminder file or approval queue.
    private let scheduleReminder: @MainActor (GruxReminder) -> Void
    private let askToAddToCalendar: @MainActor (ProposedAction) -> Void

    init(scheduleReminder: @escaping @MainActor (GruxReminder) -> Void = { GruxReminderState.shared.schedule($0) },
         askToAddToCalendar: @escaping @MainActor (ProposedAction) -> Void = {
             ApprovalQueue.shared.enqueue($0, reason: CommitmentScheduler.calendarAskReason)
         }) {
        self.scheduleReminder = scheduleReminder
        self.askToAddToCalendar = askToAddToCalendar
        // THE SEED USED TO BE A NO-OP LOOP. It read the existing reminders into `existing`
        // and then ran `for _ in existing { }` with a comment promising the real check
        // happened at scan time. It did not: the scanned set (`scannedMemories`) is in memory and starts
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
        // Read once per scan, not once per launch. Covers both the reminders restored from
        // disk and anything scheduled earlier in this same session.
        let all = GruxReminderState.shared.reminders
        let onTheBooks = all
            .filter { $0.firedAt == nil }
            .map { (text: $0.sourceCommitmentText, at: $0.scheduledFor) }
        scan(AmbientState.shared.memories, onTheBooks: onTheBooks, alreadyAskedBy: all, now: Date())
    }

    /// Whether a reminder was ever made from this heard sentence, fired or not.
    ///
    /// The text-and-minute match above is not enough after a relaunch: "in 2 hours" is
    /// parsed from the clock at scan time, so five minutes later it lands five minutes
    /// later, misses the match, and filed a second reminder and a second calendar card,
    /// once per launch while the memory was kept (wave 15 review).
    ///
    /// By id AND text, because an edited memory keeps its id: "call Sam Friday at 3 PM",
    /// edited from "call Sam in 2 hours", is a new commitment. A reminder saved before
    /// the id existed matches on text when it was made at or after the sentence was
    /// heard, so the launch that installs this asks nothing again, while the same words
    /// said on a later day still ask.
    nonisolated static func isHandled(_ mem: AmbientMemory, by reminders: [GruxReminder]) -> Bool {
        reminders.contains { r in
            guard r.sourceCommitmentText == mem.text else { return false }
            if let id = r.sourceMemoryId { return id == mem.id }
            return r.createdAt >= mem.timestamp
        }
    }

    /// One pass over `memories`: a dated commitment becomes a reminder and ONE calendar ask.
    /// Separate from the flag read above so a test can run it.
    func scan(_ memories: [AmbientMemory], onTheBooks: [(text: String?, at: Date?)],
              alreadyAskedBy reminders: [GruxReminder] = [], now: Date) {
        for mem in memories {
            guard !scannedMemories.contains(Self.scanKey(mem)) else { continue }
            guard !Self.isHandled(mem, by: reminders) else {
                scannedMemories.insert(Self.scanKey(mem))
                continue
            }
            // Only care about commitments / intents / reminders - facts are
            // durable truths, not time-anchored actions.
            guard mem.kind == .commitment || mem.kind == .intent || mem.kind == .reminder else {
                scannedMemories.insert(Self.scanKey(mem))
                continue
            }
            if let fireAt = Self.parseTargetDate(from: mem.text) {
                // Sanity: don't schedule something in the distant past or
                // way in the future (>72h).
                let secondsAhead = fireAt.timeIntervalSince(now)
                guard secondsAhead > 30, secondsAhead < 72 * 3600 else {
                    scannedMemories.insert(Self.scanKey(mem))
                    continue
                }
                // The relaunch guard. Without it the same sentence is parsed again on every
                // launch and produces another reminder and another Calendar event.
                guard !Self.isAlreadyScheduled(text: mem.text, firingAt: fireAt,
                                               existing: onTheBooks) else {
                    scannedMemories.insert(Self.scanKey(mem))
                    continue
                }
                let reminder = GruxReminder(
                    kind: .commitment,
                    title: mem.text,
                    body: "You said you'd handle this \(ReminderToastView.formatRelative(date: fireAt).lowercased()). Grux has it on the schedule.",
                    project: mem.project,
                    scheduledFor: fireAt,
                    sourceCommitmentText: mem.text,
                    sourceMemoryId: mem.id
                )
                scheduleReminder(reminder)
                // THIS USED TO SAVE THE EVENT. It called CalendarService straight from this
                // timer, titled with whatever the extractor heard, so a sentence overheard
                // from a TV or a half-finished thought ("If I don't...") landed in the
                // person's real Calendar and Reactor promoted it as their next event. The chat
                // `create_event` tool was always gated; this path never reached the gate.
                // Now it only asks: approving the card replays `create_event`.
                askToAddToCalendar(Self.calendarAsk(text: mem.text, at: fireAt))
                scannedMemories.insert(Self.scanKey(mem))
                WakeLog.shared.log("scheduler: queued commitment for \(fireAt), calendar asked in Approvals - \(mem.text.prefix(80))")
            } else {
                // No time anchor → skip, don't rescan forever
                scannedMemories.insert(Self.scanKey(mem))
            }
        }
    }

    // MARK: - The calendar ask

    static let calendarAskReason = "Heard while listening. Grux asks before it puts anything on your calendar."
    static let calendarBlockMinutes = 30

    /// The Approvals card for one heard commitment. It carries a replay of `create_event`
    /// with exactly the title and times the card shows, so a yes adds that one event
    /// and nothing else.
    nonisolated static func calendarAsk(text: String, at fireAt: Date) -> ProposedAction {
        let clamped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let title = clamped.isEmpty ? "Commitment" : clamped
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let input: [String: Any] = [
            "title": title,
            "start": iso.string(from: fireAt),
            "end": iso.string(from: fireAt.addingTimeInterval(TimeInterval(calendarBlockMinutes * 60))),
            "notes": "Heard by Grux while listening, added after you approved it."
        ]
        var detail: [String: String] = ["__replay_tool": "create_event", "source": "ambient commitment"]
        if let json = JaxToolGate.encodeInput(input) { detail["__replay_input"] = json }
        let when = fireAt.formatted(date: .abbreviated, time: .shortened)
        return ProposedAction(kind: .other, summary: "Add \"\(title)\" to your calendar, \(when)?",
                              target: "create_event", detail: detail)
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
