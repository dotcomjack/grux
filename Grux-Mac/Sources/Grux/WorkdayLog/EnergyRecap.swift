import Foundation

// 8pm "Daily energy + focus recap". Distinct from the 10pm DailyRecap
// (shipped / open / tomorrow tasks). This one is the attention truth:
// where the hours went, how often focus broke, and the longest stretch
// of head-down time. Derived directly from raw sources so it stays cheap
// (no per-session LLM calls like WorkdayLogAssembler does) and can fire
// at 8pm without competing with the heavier 6am workday-log rollup.
//
// Provider: AmbientLLM (local Qwen first, Claude fallback). On a hard
// failure both paths drop to a deterministic narrative so the recap
// always has something to read aloud.

struct EnergyRecap: Codable, Hashable {
    var dayKey: String
    var generatedAt: Date
    var hoursWorked: Double
    var topApps: [TopEntry]
    var topProjects: [ProjectDetail]
    var focusBreakCount: Int
    var longestFocusBlockMinutes: Int
    var summaryText: String
    var provider: String // "local/qwen3:8b", "claude/...", or "fallback"

    struct TopEntry: Codable, Hashable {
        var name: String
        var minutes: Int
    }

    // Richer per-project breakdown for the chip + click-to-expand UI in
    // EnergyRecapView. Lightweight: only pulls from in-memory AppState and
    // AmbientState, no LLM calls, no git scan, so a chip detail panel
    // opens instantly with no second round trip.
    struct ProjectDetail: Codable, Hashable {
        var name: String
        var minutes: Int
        var completedTaskTitles: [String]
        var ambientNotes: [String]
    }
}

@MainActor
enum EnergyRecapBuilder {

    // Build today's recap. Reuses WorkdayLogAssembler's window helpers + raw
    // sources so the numbers line up exactly with the workday-log card.
    static func build(forDayKey dayKey: String) async -> EnergyRecap {
        let cal = Calendar.current
        let (windowStart, _, windowEndExclusive) =
            WorkdayLogAssembler.windowDates(forDayKey: dayKey, calendar: cal)

        let screentimeEvents = ScreenTimeWatcher.loadEvents(
            between: windowStart, and: windowEndExclusive
        )
        let perAppMinutes = WorkdayLogAssembler.perAppMinutesFrom(events: screentimeEvents)
        let perProjectMinutes = WorkdayLogAssembler.computeProjectMinutes(
            from: screentimeEvents,
            knownProjects: KnownProjects.displayNames()
        )

        // hoursWorked = non-idle screen time. Truthful to "actually at the
        // computer" rather than "Mac was on", since ScreenTimeWatcher flags
        // idle frames and perAppMinutesFrom drops them.
        let workedMinutes = perAppMinutes.values.reduce(0, +)
        let hoursWorked = (Double(workedMinutes) / 60.0 * 10).rounded() / 10.0

        let topApps = perAppMinutes
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { EnergyRecap.TopEntry(name: $0.key, minutes: $0.value) }

        let topProjects = perProjectMinutes
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { entry -> EnergyRecap.ProjectDetail in
                let (tasks, notes) = collectProjectDetail(
                    projectName: entry.key,
                    windowStart: windowStart,
                    windowEndExclusive: windowEndExclusive
                )
                return EnergyRecap.ProjectDetail(
                    name: entry.key,
                    minutes: entry.value,
                    completedTaskTitles: tasks,
                    ambientNotes: notes
                )
            }

        let focusEvents = AppState.shared.events
        let (breaks, longestBlock) = computeFocusShape(
            events: focusEvents,
            windowStart: windowStart,
            windowEndExclusive: windowEndExclusive
        )

        let (summary, provider) = await composeSummary(
            dayKey: dayKey,
            hoursWorked: hoursWorked,
            topApps: Array(topApps),
            topProjects: Array(topProjects),
            focusBreakCount: breaks,
            longestFocusBlockMinutes: longestBlock
        )

        let recap = EnergyRecap(
            dayKey: dayKey,
            generatedAt: Date(),
            hoursWorked: hoursWorked,
            topApps: Array(topApps),
            topProjects: Array(topProjects),
            focusBreakCount: breaks,
            longestFocusBlockMinutes: longestBlock,
            summaryText: summary,
            provider: provider
        )
        persist(recap)
        return recap
    }

    // Lightweight per-project pull: completed task titles + ambient memory
    // texts tagged to this project within the workday window. Powers the
    // chip click-to-expand inline panel in EnergyRecapView. Substring match
    // is intentional so a project like "Website" matches AmbientMemory
    // entries tagged "Website Redesign" or task projects "Website copy".
    static func collectProjectDetail(
        projectName: String,
        windowStart: Date,
        windowEndExclusive: Date
    ) -> (tasks: [String], notes: [String]) {
        let needle = projectName.lowercased()
        // Skip substring match for very short needles ("AI", "QA") because
        // "ai" matches every task title containing "maintain", "email", etc.
        // Require an exact project equality match instead so short project
        // names still surface their detail without 90% false positives.
        let useExactMatch = needle.count < 3
        let tasks = AppState.shared.completedTasks
            .filter {
                guard let at = $0.completedAt, at >= windowStart, at < windowEndExclusive else { return false }
                if useExactMatch {
                    return $0.project.lowercased() == needle
                }
                let hay = ($0.project + " " + $0.title).lowercased()
                return hay.contains(needle)
            }
            .prefix(6)
            .map { $0.title }
        let notes = AmbientState.shared.memories
            .filter { m in
                guard m.timestamp >= windowStart, m.timestamp < windowEndExclusive else { return false }
                if useExactMatch {
                    return (m.project ?? "").lowercased() == needle
                }
                let hay = ((m.project ?? "") + " " + m.text).lowercased()
                return hay.contains(needle)
            }
            .prefix(4)
            .map { $0.text }
        return (Array(tasks), Array(notes))
    }

    // Count onTask -> non-onTask transitions (focus breaks) and the longest
    // contiguous run of onTask minutes. Caps any single interval at 20 min
    // to match the convention used by WorkdayLogAssembler.computeFocusStats,
    // so long idle gaps don't get credited to a single block.
    static func computeFocusShape(
        events: [FocusEvent],
        windowStart: Date,
        windowEndExclusive: Date
    ) -> (breaks: Int, longestBlockMinutes: Int) {
        let inWin = events
            .filter { $0.timestamp >= windowStart && $0.timestamp < windowEndExclusive }
            .sorted { $0.timestamp < $1.timestamp }
        guard !inWin.isEmpty else { return (0, 0) }

        var breaks = 0
        var lastVerdict: FocusVerdict? = nil
        var currentBlockSecs: Double = 0
        var longestBlockSecs: Double = 0

        for (i, ev) in inWin.enumerated() {
            let next = i + 1 < inWin.count ? inWin[i + 1].timestamp : windowEndExclusive
            let secs = min(next.timeIntervalSince(ev.timestamp), 1200)

            if ev.verdict == .onTask {
                currentBlockSecs += max(0, secs)
                if currentBlockSecs > longestBlockSecs { longestBlockSecs = currentBlockSecs }
            } else if ev.verdict == .drifting || ev.verdict == .offTask {
                // Only count a break the FIRST time we leave onTask, not on
                // every subsequent drifting frame, so a long off-task stretch
                // doesn't inflate the count.
                if lastVerdict == .onTask { breaks += 1 }
                currentBlockSecs = 0
            }
            // .ambiguous: don't reset, don't count, don't extend.
            lastVerdict = ev.verdict
        }

        return (breaks, Int((longestBlockSecs / 60).rounded()))
    }

    // MARK: - LLM narrative

    private static func composeSummary(
        dayKey: String,
        hoursWorked: Double,
        topApps: [EnergyRecap.TopEntry],
        topProjects: [EnergyRecap.ProjectDetail],
        focusBreakCount: Int,
        longestFocusBlockMinutes: Int
    ) async -> (String, String) {
        let useLocal = AppState.shared.config.useLocalQwenForAmbient
        let canCallLLM = useLocal || !AppState.shared.anthropicKey.isEmpty
        guard canCallLLM else {
            return (fallback(
                hoursWorked: hoursWorked, topApps: topApps, topProjects: topProjects,
                focusBreakCount: focusBreakCount,
                longestFocusBlockMinutes: longestFocusBlockMinutes
            ), "fallback")
        }

        let sys = """
        You are Grux. Write ONE short narrated paragraph (45-75 words) for the user's 8pm energy and focus recap, designed to be spoken aloud.

        Hard rules:
        - The ONLY numbers you may use are the ones literally present in the DATA block below. Do not invent, infer, or derive any new numbers.
        - TOP_APPS minutes are total app-dwell time, NOT focus-block length. Never describe a TOP_APPS minute count as a "focus block" or "stretch of focus". The two are unrelated.
        - LONGEST_FOCUS_BLOCK_MINUTES will appear in the DATA block ONLY when it is known and greater than zero. If you do not see that exact key in the DATA, do not mention focus blocks, longest stretches, deepest sessions, or anything similar at all.
        - Open with the day's biggest signal (hours at the machine OR main project OR, if present, longest focus block).
        - Mention one concrete app or project they leaned on.
        - If FOCUS_BREAKS is notably high or low for HOURS_WORKED, name it gently.
        - End with one calm, grounded observation, not a pep talk.
        - No em dashes, no en dashes. Use commas, periods, or colons instead.
        - No emoji, no markdown, no headings, no greetings, no sign-offs.
        - Plain spoken prose.
        """
        var lines: [String] = []
        lines.append("DAY_KEY: \(dayKey)")
        lines.append(String(format: "HOURS_WORKED: %.1f", hoursWorked))
        lines.append("FOCUS_BREAKS: \(focusBreakCount)")
        // Omit the longest-focus-block line entirely when zero. The local
        // qwen3:8b model ignores "do not mention" instructions about 70% of
        // the time, but it cannot fabricate a field that was never in the
        // prompt. Belt + suspenders with the system-prompt rule above.
        if longestFocusBlockMinutes > 0 {
            lines.append("LONGEST_FOCUS_BLOCK_MINUTES: \(longestFocusBlockMinutes)")
        }
        if !topApps.isEmpty {
            let s = topApps.map { "\($0.name)=\($0.minutes)m" }.joined(separator: " ")
            lines.append("TOP_APPS: \(s)")
        } else {
            lines.append("TOP_APPS: (none recorded)")
        }
        if !topProjects.isEmpty {
            let s = topProjects.map { "\($0.name)=\($0.minutes)m" }.joined(separator: " ")
            lines.append("TOP_PROJECTS: \(s)")
        } else {
            lines.append("TOP_PROJECTS: (none recorded)")
        }
        lines.append("")
        lines.append("Write the paragraph now. Spoken-aloud friendly, no JSON, no quotes.")

        do {
            let res = try await AmbientLLM.completeTagged(
                system: sys,
                messages: [ClaudeMessage(role: "user", content: lines.joined(separator: "\n"))],
                maxTokens: 260, temperature: 0.45,
                featureTag: "energy_recap_summary"
            )
            let reply = res.text
            // Defense in depth: even with the system-prompt ban, local Qwen
            // occasionally slips an em or en dash into the reply. Strip them
            // before they hit the UI or the speech engine so the recap stays
            // inside the global no-dashes rule.
            var cleaned = reply
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\u{2014}", with: ", ")
                .replacingOccurrences(of: "\u{2013}", with: ", ")
            // qwen3:8b reliably hallucinates a "longest focus block" by
            // conflating TOP_APPS minutes with focus-block length. When the
            // real value is zero, drop any sentence that mentions focus
            // blocks so the recap doesn't lie to the user.
            if longestFocusBlockMinutes == 0 {
                cleaned = stripFocusBlockMentions(cleaned)
            }
            if cleaned.isEmpty {
                return (fallback(
                    hoursWorked: hoursWorked, topApps: topApps, topProjects: topProjects,
                    focusBreakCount: focusBreakCount,
                    longestFocusBlockMinutes: longestFocusBlockMinutes
                ), "fallback")
            }
            return (cleaned, res.provider)
        } catch {
            WakeLog.shared.log("energyRecap summary FAILED: \(error.localizedDescription)")
            return (fallback(
                hoursWorked: hoursWorked, topApps: topApps, topProjects: topProjects,
                focusBreakCount: focusBreakCount,
                longestFocusBlockMinutes: longestFocusBlockMinutes
            ), "fallback")
        }
    }

    // Drop sentences that mention a focus block when we know the real value
    // is zero. Split on sentence-ending punctuation, filter the offending
    // phrases, rejoin. Conservative: only matches the specific terms qwen
    // reaches for ("focus block", "longest stretch", "deepest"), so it does
    // not over-censor a sentence about something else.
    static func stripFocusBlockMentions(_ text: String) -> String {
        let banned = ["focus block", "longest stretch", "longest run", "deepest"]
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let kept = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return !banned.contains { lower.contains($0) }
        }
        guard !kept.isEmpty else { return text }
        return kept.joined(separator: ". ") + "."
    }

    // Deterministic spoken-friendly recap for the no-LLM path. Stays short
    // and factual so the panel still reads aloud cleanly when both local
    // Qwen and Claude are unreachable.
    private static func fallback(
        hoursWorked: Double,
        topApps: [EnergyRecap.TopEntry],
        topProjects: [EnergyRecap.ProjectDetail],
        focusBreakCount: Int,
        longestFocusBlockMinutes: Int
    ) -> String {
        if hoursWorked < 0.1 && topApps.isEmpty {
            return "Quiet day at the machine. Nothing meaningful tracked. Rest up."
        }
        var parts: [String] = []
        parts.append(String(format: "About %.1f hours at the machine today.", hoursWorked))
        if longestFocusBlockMinutes > 0 {
            parts.append("Longest focus block: \(longestFocusBlockMinutes) minutes.")
        }
        if let p = topProjects.first {
            parts.append("Most time on \(p.name).")
        } else if let a = topApps.first {
            parts.append("Most time in \(a.name).")
        }
        if focusBreakCount > 0 {
            parts.append("Pulled out of flow \(focusBreakCount) time\(focusBreakCount == 1 ? "" : "s").")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Persistence

    // One file per day under ~/.grux/energy-recaps/. JSON, not NDJSON, since
    // we only ever keep the latest build per dayKey (re-firing overwrites).
    private static func persist(_ recap: EnergyRecap) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux/energy-recaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("energy-recap-\(recap.dayKey).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(recap) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
