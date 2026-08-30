import Foundation
import GruxShellCore

// Assembles a WorkdayLog for a given dayKey by mining in-memory state +
// ~/.claude/projects JSONLs + git log + ambient-summaries NDJSON. Runs off
// the main actor; reads MainActor state via explicit awaits.
//
// Window semantics: half-open [windowStart, windowStart + 24h).
// `windowEnd` on the struct is 05:59:59.999 for DISPLAY only. All time
// filters internally use `windowEndExclusive` (windowStart + 24h).

enum WorkdayLogAssembler {

    // MARK: - Public entry

    static func build(forDayKey dayKey: String) async -> WorkdayLog {
        let cal = Calendar.current
        let (windowStart, windowEnd, windowEndExclusive) = windowDates(forDayKey: dayKey, calendar: cal)

        // MainActor reads - pulled once upfront so the rest of the job is off-main.
        let completedSnapshot = await MainActor.run { AppState.shared.completedTasks }
        let chatSnapshot      = await MainActor.run { AppState.shared.chat }
        let eventsSnapshot    = await MainActor.run { AppState.shared.events }
        let ambientMemoriesSnapshot = await MainActor.run { AmbientState.shared.memories }
        let ambientChunksSnapshot   = await MainActor.run { AmbientState.shared.recentChunks }
        let anthropicKey      = await MainActor.run { AppState.shared.anthropicKey }
        let gruxModel         = await MainActor.run { AppState.shared.config.model }
        // When the local Qwen toggle is on, we don't gate on the cloud key
        // because AmbientLLM will route through the companion service and only fall back
        // to Claude if the LAN endpoint is unreachable.
        let useLocalAmbient   = await MainActor.run { AppState.shared.config.useLocalQwenForAmbient }
        let canCallLLM        = useLocalAmbient || !anthropicKey.isEmpty

        // Category (a): completed tasks in window
        let loggedTasks = completedSnapshot
            .filter { t in
                guard let at = t.completedAt else { return false }
                return at >= windowStart && at < windowEndExclusive
            }
            .map { t in
                LoggedTask(title: t.title, project: t.project, completedAt: t.completedAt!, source: "manual")
            }

        // Category (b): Claude Code sessions in window + per-cwd git commits
        let sessionEntries = collectClaudeSessions(
            windowStart: windowStart, windowEndExclusive: windowEndExclusive
        )
        var shipmentsByProject: [String: CodeShipment] = [:]
        for (cwd, info) in sessionEntries {
            let projectName = (cwd as NSString).lastPathComponent
            var shipment = shipmentsByProject[projectName] ?? CodeShipment(
                project: projectName, gitBranch: info.branch, commits: [], claudeSessions: []
            )
            shipment.claudeSessions.append(contentsOf: info.sessions)
            shipment.claudeSessions.sort { $0.cwd < $1.cwd }

            let raws = GitWindowScanner.scan(
                repoPath: URL(fileURLWithPath: cwd),
                windowStart: windowStart,
                windowEnd: windowEndExclusive
            )
            let mapped = raws.map { r in
                LoggedCommit(
                    sha: r.sha, message: r.message, timestamp: r.timestamp,
                    filesChanged: r.filesChanged, insertions: r.insertions, deletions: r.deletions
                )
            }
            // Dedupe commits by sha (a cwd might overlap with subdirs)
            let existing = Set(shipment.commits.map { $0.sha })
            shipment.commits.append(contentsOf: mapped.filter { !existing.contains($0.sha) })
            shipment.commits.sort { $0.timestamp < $1.timestamp }
            shipmentsByProject[projectName] = shipment
        }
        var codeShipped = Array(shipmentsByProject.values).sorted { $0.project < $1.project }

        // Category (c): conversations (chat + ambient summaries)
        var conversations: [ConversationSummary] = []
        conversations.append(contentsOf: groupChatMessages(
            chatSnapshot, windowStart: windowStart, windowEndExclusive: windowEndExclusive
        ))
        conversations.append(contentsOf: groupAmbientSummaries(
            AmbientHourlySummarizer.loadSummaries(forDayKey: dayKey)
        ))
        conversations.sort { $0.timestamp < $1.timestamp }

        // Category (d): commitments breakdown
        let commitments = breakdownCommitments(
            memories: ambientMemoriesSnapshot,
            completedTitles: completedSnapshot.map { $0.title },
            windowStart: windowStart,
            windowEndExclusive: windowEndExclusive
        )

        // Category (e): focus stats
        let focusStats = computeFocusStats(
            events: eventsSnapshot,
            windowStart: windowStart,
            windowEndExclusive: windowEndExclusive,
            knownProjects: KnownProjects.displayNames()
        )

        // Category (f): calendar events the workday window overlaps,
        // correlated to ambient transcript sessions where available. No-op
        // when EventKit permission isn't granted (returns []) so older logs
        // keep building cleanly.
        let meetingsAttended: [LoggedMeeting] = await CalendarCorrelator.entries(
            forWindow: windowStart,
            windowEnd: windowEndExclusive,
            chunks: ambientChunksSnapshot
        ).map {
            LoggedMeeting(
                tsStart: $0.tsStart, tsEnd: $0.tsEnd,
                eventTitle: $0.eventTitle, calendarName: $0.calendarName,
                ambientSessionId: $0.ambientSessionId
            )
        }

        // LLM calls - outcome summaries first so codeShipped has them baked
        // in before narrative generation. Routes through AmbientLLM, which
        // prefers local Qwen when the toggle is on and falls back to Claude.
        if canCallLLM {
            codeShipped = await fillSessionOutcomes(
                shipments: codeShipped, apiKey: anthropicKey, model: gruxModel
            )
            conversations = await fillConversationSummaries(
                conversations: conversations, apiKey: anthropicKey, model: gruxModel
            )
        }

        // Activity-mix derivations. Built BEFORE the narrative call so the
        // executive-summary prompt can quote concrete percentages.
        //
        // Data source: ScreenTimeWatcher's NDJSON (polled every 10s, idle
        // excluded), NOT focusStats.perAppMinutes. FocusWatcher only emits
        // events on app switches AND requires screenAnalysisEnabled, so its
        // dwell data is sparse-to-empty in practice. ScreenTimeWatcher runs
        // unconditionally and produces dense, reliable per-app dwell, the
        // right truth for "where did the day go" bars. focusStats stays as
        // the verdict-weighted view (on-task / drift / off-task) for the
        // existing Focus card.
        //
        // We load the events array ONCE and reuse it for both per-app dwell
        // and per-project matching. perAppDwell would re-read the NDJSON
        // internally otherwise, doubling I/O on every build.
        let screentimeEvents = ScreenTimeWatcher.loadEvents(
            between: windowStart, and: windowEndExclusive
        )
        let perAppMinutesFromScreentime = perAppMinutesFrom(events: screentimeEvents)
        let appCategoryMinutes = computeAppCategoryMinutes(perAppMinutesFromScreentime)
        let projectMinutesFromScreentime = computeProjectMinutes(
            from: screentimeEvents,
            knownProjects: KnownProjects.displayNames()
        )
        let timeAllocation = computeTimeAllocation(
            categoryMinutes: appCategoryMinutes,
            meetings: meetingsAttended
        )

        // Notification-storm stats for this workday. NotificationWatcher
        // appends one NDJSON row per delivered notification; the helpers
        // here aggregate across the same 6am-anchored window the rest of
        // the recap uses. The narrative prompt + fallback both reference
        // the total so the daily recap can answer "how many times did we
        // get pulled out of flow today?" without a separate LLM call.
        let interrupts = NotificationStats(
            total: NotificationWatcher.interruptCount(
                between: windowStart, and: windowEndExclusive
            ),
            perApp: NotificationWatcher.perAppInterrupts(
                between: windowStart, and: windowEndExclusive
            )
        )

        let (narrative, insights, executiveSummary) = await composeNarrative(
            dayKey: dayKey,
            tasks: loggedTasks,
            shipments: codeShipped,
            conversations: conversations,
            commitments: commitments,
            focusStats: focusStats,
            meetings: meetingsAttended,
            timeAllocation: timeAllocation,
            interrupts: interrupts,
            apiKey: anthropicKey,
            model: gruxModel
        )

        let tags = computeTags(tasks: loggedTasks, shipments: codeShipped)
        let productive = focusStats.onTaskMinutes + focusStats.driftingMinutes

        return WorkdayLog(
            id: WorkdayLog.deterministicID(forDayKey: dayKey),
            dayKey: dayKey,
            windowStart: windowStart,
            windowEnd: windowEnd,
            generatedAt: Date(),
            schemaVersion: WorkdayLog.currentSchemaVersion,
            completedTasks: loggedTasks,
            codeShipped: codeShipped,
            conversations: conversations,
            commitments: commitments,
            focusStats: focusStats,
            insights: insights,
            meetingsAttended: meetingsAttended.isEmpty ? nil : meetingsAttended,
            executiveSummary: executiveSummary.isEmpty ? nil : executiveSummary,
            appCategoryMinutes: appCategoryMinutes.isEmpty ? nil : appCategoryMinutes,
            timeAllocation: timeAllocation,
            projectMinutesScreentime: projectMinutesFromScreentime.isEmpty ? nil : projectMinutesFromScreentime,
            narrative: narrative,
            tags: tags,
            totalProductiveMinutes: productive
        )
    }

    // MARK: - App-category lookup
    //
    // Static lookup table mapping known macOS app names to coarse activity
    // buckets. New apps default to "Other"; extend this table as new tools
    // get heavy use. Keys are matched case-insensitively against a substring
    // of focusStats.perAppMinutes' keys so "Google Chrome" matches "Chrome"
    // and "Visual Studio Code" matches "Code".
    //
    // Buckets used by the renderer and TimeAllocationBreakdown:
    //   IDE       → codingMinutes
    //   Terminal  → terminalMinutes
    //   Browser   → browsingMinutes
    //   Comms     → commsMinutes
    //   Meeting   → counted only via meetingsAttended (the calendar truth),
    //               not via app dwell, to avoid double-counting Zoom + cal.
    //   Design    → designMinutes
    //   Docs      → docsMinutes
    //   Music     → musicMinutes
    //   Other     → otherMinutes

    static func categorizeApp(_ appName: String) -> String {
        let key = appName.lowercased()
        // Exact-match short IDE process names. These short tokens would
        // produce false-positive substring matches if included in the
        // contains-needle list ("zed" inside "amazed", "code" inside
        // "QR Code Generator", "nova" inside "Casanova", etc).
        let exactIDE: Set<String> = ["code", "codium", "zed", "nova", "fleet"]
        if exactIDE.contains(key) { return "IDE" }

        let buckets: [(String, [String])] = [
            ("IDE", [
                "xcode", "visual studio code", "vscode",
                "cursor", "windsurf", "android studio",
                "intellij", "pycharm", "rubymine", "goland", "webstorm",
                "sublime text"
            ]),
            ("Terminal", [
                "terminal", "iterm", "iterm2", "warp", "alacritty",
                "ghostty", "kitty", "tabby", "wezterm"
            ]),
            ("Browser", [
                "google chrome", "chrome", "safari", "firefox", "arc",
                "brave browser", "brave", "vivaldi", "edge"
            ]),
            ("Comms", [
                "slack", "messages", "imessage", "mail", "outlook",
                "discord", "telegram", "whatsapp", "signal",
                "linear", "jira", "asana", "twist"
            ]),
            ("Meeting", [
                // Bare "meet" is omitted because it would match "Meetup"
                // and similar non-meeting apps.
                "zoom", "zoom.us", "google meet", "microsoft teams",
                "teams", "facetime", "webex", "around"
            ]),
            ("Design", [
                "figma", "sketch", "affinity designer", "affinity photo",
                "photoshop", "illustrator", "pixelmator", "blender",
                "framer", "rive"
            ]),
            ("Docs", [
                "notion", "obsidian", "bear", "craft", "notes",
                "pages", "google docs", "docs", "preview",
                "quip", "coda", "logseq", "drafts"
            ]),
            ("Music", [
                "music", "spotify", "apple music", "soundcloud",
                "youtube music", "amazon music"
            ]),
        ]
        for (cat, needles) in buckets {
            for n in needles where key.contains(n) { return cat }
        }
        return "Other"
    }

    // Per-app dwell minutes derived directly from a preloaded screentime
    // event array. Mirrors ScreenTimeWatcher.perAppDwell but takes the
    // events as input so build() can load the NDJSON once and reuse it.
    static func perAppMinutesFrom(events: [ScreenTimeEvent]) -> [String: Int] {
        let sampleSeconds = ScreenTimeWatcher.kSampleIntervalSeconds
        var totals: [String: Double] = [:]
        for ev in events where !ev.idle {
            let key = ev.appName.isEmpty ? ev.appBundle : ev.appName
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += sampleSeconds
        }
        var out: [String: Int] = [:]
        for (k, secs) in totals {
            let mins = Int((secs / 60).rounded())
            if mins > 0 { out[k] = mins }
        }
        return out
    }

    // Per-project minutes inferred from preloaded screentime events.
    // Matches each non-idle event's appName + windowTitle against the
    // KnownProjects haystack; the first match wins. Operates on the dense
    // 10s screentime stream instead of the sparse FocusEvent stream.
    static func computeProjectMinutes(
        from events: [ScreenTimeEvent], knownProjects: [String]
    ) -> [String: Int] {
        guard !knownProjects.isEmpty else { return [:] }
        let needles = knownProjects.filter { !$0.isEmpty }
            .map { (display: $0, needle: $0.lowercased()) }
        let sampleSeconds = ScreenTimeWatcher.kSampleIntervalSeconds
        var totalsSeconds: [String: Double] = [:]
        for ev in events where !ev.idle {
            let haystack = (ev.appName + " " + ev.windowTitle).lowercased()
            for entry in needles where haystack.contains(entry.needle) {
                totalsSeconds[entry.display, default: 0] += sampleSeconds
                break
            }
        }
        var out: [String: Int] = [:]
        for (k, secs) in totalsSeconds {
            let mins = Int((secs / 60).rounded())
            if mins > 0 { out[k] = mins }
        }
        return out
    }

    static func computeAppCategoryMinutes(_ perApp: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (app, mins) in perApp {
            let cat = categorizeApp(app)
            out[cat, default: 0] += mins
        }
        return out
    }

    static func computeTimeAllocation(
        categoryMinutes: [String: Int],
        meetings: [LoggedMeeting]
    ) -> TimeAllocationBreakdown {
        // Meeting time uses the calendar truth (sum of event durations,
        // capped per meeting at 8h to defend against an all-day event being
        // counted as a focused meeting). App-dwell minutes inside the
        // "Meeting" bucket are dropped from `other`; the calendar number
        // already represents that time more accurately.
        var meetingMinutes = 0
        for m in meetings {
            let dur = max(0, Int(m.tsEnd.timeIntervalSince(m.tsStart) / 60))
            meetingMinutes += min(dur, 480)
        }
        return TimeAllocationBreakdown(
            codingMinutes:    categoryMinutes["IDE"]      ?? 0,
            terminalMinutes:  categoryMinutes["Terminal"] ?? 0,
            browsingMinutes:  categoryMinutes["Browser"]  ?? 0,
            commsMinutes:     categoryMinutes["Comms"]    ?? 0,
            meetingsMinutes:  meetingMinutes,
            designMinutes:    categoryMinutes["Design"]   ?? 0,
            docsMinutes:      categoryMinutes["Docs"]     ?? 0,
            musicMinutes:     categoryMinutes["Music"]    ?? 0,
            otherMinutes:     categoryMinutes["Other"]    ?? 0
        )
    }

    // MARK: - Window math

    // Returns (windowStart, windowEnd display, windowEndExclusive).
    static func windowDates(forDayKey dayKey: String, calendar: Calendar)
        -> (Date, Date, Date)
    {
        let parts = dayKey.split(separator: "-").map { Int($0) ?? 0 }
        var comps = DateComponents()
        comps.year = parts.count > 0 ? parts[0] : 2026
        comps.month = parts.count > 1 ? parts[1] : 1
        comps.day = parts.count > 2 ? parts[2] : 1
        comps.hour = 6; comps.minute = 0; comps.second = 0
        let start = calendar.date(from: comps) ?? Date()
        let endExclusive = start.addingTimeInterval(24 * 3600)
        let endDisplay = endExclusive.addingTimeInterval(-1)
        return (start, endDisplay, endExclusive)
    }

    static func dayKey(forDate d: Date, calendar: Calendar) -> String {
        // A workday's dayKey = the calendar date of its 6am anchor. Times
        // before 6am on a calendar day belong to the PREVIOUS dayKey.
        let hr = calendar.component(.hour, from: d)
        let anchor = hr < 6 ? calendar.date(byAdding: .day, value: -1, to: d) ?? d : d
        let comps = calendar.dateComponents([.year, .month, .day], from: anchor)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    // MARK: - Claude Code session collection

    struct SessionGroupInfo {
        var sessions: [LoggedClaudeSession]
        var branch: String?
    }

    // Sample text cached at collect-time so we don't re-scan JSONLs when
    // filling outcome summaries downstream.
    private static var sessionSampleCache: [String: String] = [:]

    private static func collectClaudeSessions(windowStart: Date, windowEndExclusive: Date)
        -> [String: SessionGroupInfo]
    {
        sessionSampleCache = [:]
        // Use the existing index. Iterating recent session files and filtering
        // on entry timestamps is correct for sessions active during the window
        // (possibly started before). Cap at 60 to keep the job bounded - a
        // workday's active sessions comfortably fit.
        let descriptors = ClaudeSessionIndex.recentSessions(limit: 60)
        var byCwd: [String: SessionGroupInfo] = [:]

        for desc in descriptors {
            guard let data = try? Data(contentsOf: desc.fileURL, options: [.mappedIfSafe]),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: { $0 == "\n" }).map(String.init)
            let entries = lines.compactMap(ClaudeSessionJSONL.parseLine)

            // Filter: only entries in window. Simultaneously pick out sample
            // text for the outcome-generation Claude call (first user text +
            // last assistant text + distinct tool names).
            var inWindow: [ClaudeSessionEntry] = []
            var userTurns = 0
            var toolSet: Set<String> = []
            for entry in entries {
                switch entry {
                case .user(let ts, _, _, _):
                    if ts >= windowStart && ts < windowEndExclusive {
                        inWindow.append(entry); userTurns += 1
                    }
                case .assistant(let ts, _, let toolName, _, _, _, _, _):
                    if ts >= windowStart && ts < windowEndExclusive {
                        inWindow.append(entry)
                        if let tn = toolName { toolSet.insert(tn) }
                    }
                default: continue
                }
            }
            guard !inWindow.isEmpty else { continue }
            guard let snap = ClaudeSessionJSONL.snapshot(
                fromEntries: inWindow, sessionId: desc.sessionId
            ) else { continue }
            let cwd = snap.cwd ?? desc.cwd ?? ""
            guard !cwd.isEmpty else { continue }

            // NON-CONTENT ONLY, and this is the whole point of the line.
            //
            // This string is sent to a model. It used to carry the first 200
            // characters the USER typed and the last 200 the ASSISTANT wrote,
            // read straight out of ~/.claude/projects, which meant a workday log
            // shipped fragments of every Claude Code conversation on the machine
            // off it. `.claude` is in FilesystemTool's denylist precisely so the
            // model cannot read it; this path handed the same content over
            // anyway, around the boundary rather than through it.
            //
            // Tool NAMES are what the session did, not what anyone said. Keep
            // adding signals here only if they stay on that side of the line.
            let signals = "tools: \(toolSet.sorted().joined(separator: ","))"
            sessionSampleCache[desc.sessionId] = signals

            let logged = LoggedClaudeSession(
                sessionId: desc.sessionId,
                cwd: cwd,
                turns: userTurns,
                totalCost: snap.totalCostUSD,
                totalTokens: snap.totalInputTokens + snap.totalOutputTokens
                    + snap.totalCacheCreationTokens,
                outcomeSummary: "" // filled later by Claude
            )
            var info = byCwd[cwd] ?? SessionGroupInfo(sessions: [], branch: snap.gitBranch)
            info.sessions.append(logged)
            if info.branch == nil { info.branch = snap.gitBranch }
            byCwd[cwd] = info
        }
        return byCwd
    }

    // MARK: - Chat grouping

    static func groupChatMessages(_ chat: [ChatMessage], windowStart: Date, windowEndExclusive: Date)
        -> [ConversationSummary]
    {
        let inWin = chat
            .filter { $0.timestamp >= windowStart && $0.timestamp < windowEndExclusive }
            .sorted { $0.timestamp < $1.timestamp }
        guard !inWin.isEmpty else { return [] }

        // 30-min gap = new conversation boundary
        var groups: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var lastTs: Date? = nil
        for m in inWin {
            if let lt = lastTs, m.timestamp.timeIntervalSince(lt) > 1800 {
                groups.append(current); current = []
            }
            current.append(m); lastTs = m.timestamp
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { g -> ConversationSummary in
            let start = g.first!.timestamp
            let end = g.last!.timestamp
            let dur = max(1, Int(end.timeIntervalSince(start) / 60))
            let joined = g.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
            let preview = String(joined.prefix(280))
            return ConversationSummary(
                timestamp: start, source: .chat,
                durationMinutes: dur, summary: preview, topics: []
            )
        }
    }

    // MARK: - Ambient summary grouping

    static func groupAmbientSummaries(_ records: [AmbientHourlySummaryRecord])
        -> [ConversationSummary]
    {
        guard !records.isEmpty else { return [] }
        // Collapse consecutive hours (gap <= 1h) into groups of ≤ 3 hours.
        var groups: [[AmbientHourlySummaryRecord]] = []
        var current: [AmbientHourlySummaryRecord] = []
        for r in records {
            if let last = current.last {
                let gap = r.hourStart.timeIntervalSince(last.hourEnd)
                if gap > 3600 || current.count >= 3 {
                    groups.append(current); current = []
                }
            }
            current.append(r)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { g -> ConversationSummary in
            let start = g.first!.hourStart
            let end = g.last!.hourEnd
            let dur = Int(end.timeIntervalSince(start) / 60)
            // "quiet" hours are filler - drop them from the joined text but
            // keep them in the duration count.
            let nonQuiet = g.filter { $0.summary.lowercased() != "quiet" }
            let joined = nonQuiet.map { $0.summary }.joined(separator: " ")
            return ConversationSummary(
                timestamp: start, source: .ambient,
                durationMinutes: dur,
                summary: joined.isEmpty ? "(quiet hours)" : joined,
                topics: []
            )
        }
    }

    // MARK: - Commitments

    static func breakdownCommitments(
        memories: [AmbientMemory],
        completedTitles: [String],
        windowStart: Date,
        windowEndExclusive: Date
    ) -> CommitmentsBreakdown {
        let commitments = memories.filter { $0.kind == .commitment || $0.kind == .reminder }
        let completedLower = completedTitles.map { $0.lowercased() }

        func isKept(_ text: String) -> Bool {
            let lower = text.lowercased()
            return completedLower.contains { c in
                lower.contains(c) || c.contains(lower)
            }
        }

        var made: [String] = []
        var kept: [String] = []
        var stillOpen: [String] = []

        for m in commitments {
            let text = m.project.map { "\(m.text) · \($0)" } ?? m.text
            let introducedToday = m.timestamp >= windowStart && m.timestamp < windowEndExclusive
            if introducedToday {
                made.append(text)
                if isKept(m.text) { kept.append(text) }
            } else if isKept(m.text) {
                kept.append(text)
            } else {
                stillOpen.append(text)
            }
        }
        // Dedupe + cap for readability
        return CommitmentsBreakdown(
            made: Array(NSOrderedSet(array: made)) as? [String] ?? made,
            kept: Array(NSOrderedSet(array: kept)) as? [String] ?? kept,
            stillOpen: Array((Array(NSOrderedSet(array: stillOpen)) as? [String] ?? stillOpen).prefix(12))
        )
    }

    // MARK: - Focus stats

    static func computeFocusStats(
        events: [FocusEvent],
        windowStart: Date,
        windowEndExclusive: Date,
        knownProjects: [String]
    ) -> FocusStats {
        // Sort ascending. Events in AppState are inserted newest-first.
        let inWin = events
            .filter { $0.timestamp >= windowStart && $0.timestamp < windowEndExclusive }
            .sorted { $0.timestamp < $1.timestamp }

        // Sleep intervals in the window. Used both to subtract overlap from
        // per-event intervals (so suspended time doesn't count as drift) and
        // to surface a "system slept" row on the Focus card.
        let sleep = SleepWatcher.sleepIntervals(in: windowStart..<windowEndExclusive)
        var sleptSecs: Double = 0
        for s in sleep { sleptSecs += s.end.timeIntervalSince(s.start) }
        let systemSleptMinutes = Int((sleptSecs / 60).rounded())

        guard !inWin.isEmpty else {
            return FocusStats(onTaskMinutes: 0, driftingMinutes: 0, offTaskMinutes: 0,
                              perAppMinutes: [:], perProjectMinutes: [:],
                              systemSleptMinutes: systemSleptMinutes)
        }

        var onTask = 0, drift = 0, offTask = 0
        var perApp: [String: Int] = [:]
        var perProject: [String: Int] = [:]

        for (i, event) in inWin.enumerated() {
            let next = i + 1 < inWin.count ? inWin[i + 1].timestamp : windowEndExclusive
            var rawSecs = next.timeIntervalSince(event.timestamp)
            // Subtract any sleep overlap so the Mac being suspended doesn't
            // get credited to a focus verdict.
            for s in sleep {
                let lo = max(s.start, event.timestamp)
                let hi = min(s.end, next)
                if hi > lo { rawSecs -= hi.timeIntervalSince(lo) }
            }
            // Cap any single interval at 20 minutes to dampen the effect of
            // long idle gaps between events.
            let secs = min(rawSecs, 1200)
            guard secs > 0 else { continue }
            let mins = Int((secs / 60).rounded())
            switch event.verdict {
            case .onTask:    onTask += mins
            case .drifting:  drift  += mins
            case .offTask:   offTask += mins
            case .ambiguous: break
            }
            perApp[event.activeApp, default: 0] += mins

            // Project inference: match windowTitle against known project names.
            let haystack = (event.activeApp + " " + event.windowTitle).lowercased()
            for p in knownProjects where !p.isEmpty {
                if haystack.contains(p.lowercased()) {
                    perProject[p, default: 0] += mins
                    break
                }
            }
        }

        return FocusStats(
            onTaskMinutes: onTask, driftingMinutes: drift, offTaskMinutes: offTask,
            perAppMinutes: perApp, perProjectMinutes: perProject,
            systemSleptMinutes: systemSleptMinutes
        )
    }

    // MARK: - Tags

    private static func computeTags(tasks: [LoggedTask], shipments: [CodeShipment]) -> [String] {
        var set: Set<String> = []
        for t in tasks where !t.project.isEmpty { set.insert(t.project) }
        for s in shipments where !s.project.isEmpty { set.insert(s.project) }
        return Array(set).sorted()
    }

    // MARK: - Claude calls

    private static func fillSessionOutcomes(
        shipments: [CodeShipment], apiKey: String, model: String
    ) async -> [CodeShipment] {
        // Flatten all sessions needing outcomes.
        struct Pending { let idx: Int; let sIdx: Int; let sessionId: String; let cwd: String
                        let turns: Int; let sampleText: String }
        var pendings: [Pending] = []
        for (idx, s) in shipments.enumerated() {
            for (sIdx, session) in s.claudeSessions.enumerated() {
                // Try to grab the last assistant text + first user text as a sample
                let sample = sampleTextFor(sessionId: session.sessionId)
                pendings.append(Pending(
                    idx: idx, sIdx: sIdx, sessionId: session.sessionId,
                    cwd: session.cwd, turns: session.turns, sampleText: sample
                ))
            }
        }
        guard !pendings.isEmpty else { return shipments }

        let sys = """
        You are Grux condensing Claude Code sessions into one-sentence outcomes for the user's workday log. You are given ONLY the folder name, the turn count, and which tools ran. You are NOT given anything the user or the assistant wrote, deliberately. Describe only what the tools and folder support, and say "worked in <folder>" when they support nothing more specific. Do NOT invent a topic, a bug, a feature or a filename. ONE sentence per session id, 25 words or fewer. Output STRICT JSON: {"outcomes": {"<sessionId>": "sentence", ...}}. No prose, no markdown.
        """
        var userLines = ["SESSIONS:"]
        for p in pendings {
            userLines.append("- id: \(p.sessionId)")
            userLines.append("  cwd: \((p.cwd as NSString).lastPathComponent)")
            userLines.append("  turns: \(p.turns)")
            userLines.append("  signals: \(String(p.sampleText.prefix(500)))")
        }
        let user = userLines.joined(separator: "\n")
        _ = apiKey; _ = model // routed through AmbientLLM; kept for signature parity
        do {
            let reply = try await AmbientLLM.complete(
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 1200, temperature: 0.2,
                featureTag: "workday_session_outcomes"
            )
            if let outcomes = parseOutcomes(reply) {
                var mutated = shipments
                for p in pendings {
                    if let sentence = outcomes[p.sessionId], !sentence.isEmpty {
                        mutated[p.idx].claudeSessions[p.sIdx].outcomeSummary = sentence
                    }
                }
                return mutated
            }
        } catch {
            WakeLog.shared.log("workdayLog outcomes FAILED: \(error.localizedDescription)")
        }
        return shipments
    }

    private static func parseOutcomes(_ reply: String) -> [String: String]? {
        // Strip ```json fences if present
        var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcomes = obj["outcomes"] as? [String: String] else { return nil }
        return outcomes
    }

    private static func sampleTextFor(sessionId: String) -> String {
        // Populated during `collectClaudeSessions` so outcome-generation
        // doesn't cause an N² re-scan of every JSONL under ~/.claude/projects.
        sessionSampleCache[sessionId] ?? ""
    }

    private static func fillConversationSummaries(
        conversations: [ConversationSummary], apiKey: String, model: String
    ) async -> [ConversationSummary] {
        guard !conversations.isEmpty else { return conversations }

        let sys = """
        You are Grux summarizing conversation windows from the user's workday. For each INPUT block, return ONE sentence summary (≤30 words) + up to 4 topic tags. STRICT JSON: {"items":[{"index": N, "summary": "...", "topics": ["...","..."]}]}. No prose, no markdown.
        """
        var userLines = ["INPUTS:"]
        for (i, c) in conversations.enumerated() {
            userLines.append("- index: \(i)")
            userLines.append("  source: \(c.source.rawValue)")
            userLines.append("  minutes: \(c.durationMinutes)")
            userLines.append("  raw: \(String(c.summary.prefix(600)))")
        }
        let user = userLines.joined(separator: "\n")
        _ = apiKey; _ = model // routed through AmbientLLM; kept for signature parity
        do {
            let reply = try await AmbientLLM.complete(
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 1500, temperature: 0.3,
                featureTag: "workday_conversation_summaries"
            )
            var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("```") {
                cleaned = cleaned.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
            }
            guard let data = cleaned.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]] else {
                return conversations
            }
            var mutated = conversations
            for item in items {
                guard let idx = item["index"] as? Int, idx >= 0, idx < mutated.count else { continue }
                if let summary = item["summary"] as? String, !summary.isEmpty {
                    mutated[idx].summary = summary
                }
                if let topics = item["topics"] as? [String] {
                    mutated[idx].topics = topics
                }
            }
            return mutated
        } catch {
            WakeLog.shared.log("workdayLog conv summaries FAILED: \(error.localizedDescription)")
            return conversations
        }
    }

    private static func composeNarrative(
        dayKey: String,
        tasks: [LoggedTask],
        shipments: [CodeShipment],
        conversations: [ConversationSummary],
        commitments: CommitmentsBreakdown,
        focusStats: FocusStats,
        meetings: [LoggedMeeting],
        timeAllocation: TimeAllocationBreakdown,
        interrupts: NotificationStats,
        apiKey: String,
        model: String
    ) async -> (narrative: String, insights: [String], executiveSummary: String) {
        let useLocal = await MainActor.run { AppState.shared.config.useLocalQwenForAmbient }
        if apiKey.isEmpty && !useLocal {
            let fb = fallbackNarrative(
                tasks: tasks, shipments: shipments, focus: focusStats,
                meetings: meetings, interrupts: interrupts
            )
            let fbSummary = fallbackExecutiveSummary(
                tasks: tasks, shipments: shipments, meetings: meetings,
                allocation: timeAllocation
            )
            return (fb, [], fbSummary)
        }
        let sys = """
        You are Grux writing the user's canonical workday record. Produce THREE outputs:
          1) executive_summary: ONE plain-English paragraph, 60-100 words, that opens the day's report. It is the TL;DR a reader sees first. Concrete, factual, grounded in the DATA below. Lead with the day's biggest signal (shipped X, attended N meetings, drifted late afternoon, etc.). No greetings, no sign-offs.
          2) narrative: 200-400 word deeper read, first-person plural ("we shipped / we worked on"), warm but direct.
          3) insights: 3 to 7 single-sentence observations tying patterns together (shipping velocity, drift patterns, repeated themes, time-allocation surprises).
        No emoji, no markdown, no headings. STRICT JSON only: {"executive_summary": "...", "narrative": "...", "insights": ["...","..."]}.
        """
        let user = buildNarrativeUserPrompt(
            dayKey: dayKey, tasks: tasks, shipments: shipments,
            conversations: conversations, commitments: commitments,
            focus: focusStats, meetings: meetings, allocation: timeAllocation,
            interrupts: interrupts
        )
        _ = apiKey; _ = model // routed through AmbientLLM; kept for signature parity
        do {
            let reply = try await AmbientLLM.complete(
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                // 1500 was too tight after adding the executive_summary key;
                // a busy day's narrative + insights would routinely truncate
                // mid-JSON and collapse the whole response to the fallback.
                maxTokens: 2400, temperature: 0.45,
                featureTag: "workday_narrative"
            )
            var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("```") {
                cleaned = cleaned.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
            }
            guard let data = cleaned.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let fb = fallbackNarrative(
                    tasks: tasks, shipments: shipments, focus: focusStats,
                    meetings: meetings, interrupts: interrupts
                )
                let fbSummary = fallbackExecutiveSummary(
                    tasks: tasks, shipments: shipments, meetings: meetings,
                    allocation: timeAllocation
                )
                return (fb, [], fbSummary)
            }
            let narrative = (obj["narrative"] as? String) ?? ""
            let insights = (obj["insights"] as? [String]) ?? []
            let executive = (obj["executive_summary"] as? String) ?? ""
            let finalNarrative = narrative.isEmpty
                ? fallbackNarrative(
                    tasks: tasks, shipments: shipments, focus: focusStats,
                    meetings: meetings, interrupts: interrupts
                )
                : narrative
            let finalExecutive = executive.isEmpty
                ? fallbackExecutiveSummary(
                    tasks: tasks, shipments: shipments, meetings: meetings,
                    allocation: timeAllocation
                )
                : executive
            return (finalNarrative, insights, finalExecutive)
        } catch {
            WakeLog.shared.log("workdayLog narrative FAILED: \(error.localizedDescription)")
            let fb = fallbackNarrative(
                tasks: tasks, shipments: shipments, focus: focusStats,
                meetings: meetings, interrupts: interrupts
            )
            let fbSummary = fallbackExecutiveSummary(
                tasks: tasks, shipments: shipments, meetings: meetings,
                allocation: timeAllocation
            )
            return (fb, [], fbSummary)
        }
    }

    private static func buildNarrativeUserPrompt(
        dayKey: String,
        tasks: [LoggedTask],
        shipments: [CodeShipment],
        conversations: [ConversationSummary],
        commitments: CommitmentsBreakdown,
        focus: FocusStats,
        meetings: [LoggedMeeting],
        allocation: TimeAllocationBreakdown,
        interrupts: NotificationStats
    ) -> String {
        var lines: [String] = []
        lines.append("DAY_KEY: \(dayKey)")
        lines.append("")
        lines.append("COMPLETED_TASKS (\(tasks.count)):")
        for t in tasks { lines.append("- \(t.title)\(t.project.isEmpty ? "" : " · \(t.project)")") }
        if tasks.isEmpty { lines.append("- (none)") }
        lines.append("")
        lines.append("CODE_SHIPPED (\(shipments.count) projects):")
        for s in shipments {
            lines.append("  \(s.project): \(s.commits.count) commits, \(s.claudeSessions.count) Claude Code sessions")
            for c in s.commits.prefix(12) {
                lines.append("    - \(c.message) (+\(c.insertions)/-\(c.deletions))")
            }
            for sess in s.claudeSessions.prefix(6) {
                let outcome = sess.outcomeSummary.isEmpty ? "(no outcome)" : sess.outcomeSummary
                lines.append("    - session: \(outcome)")
            }
        }
        if shipments.isEmpty { lines.append("  (no code activity)") }
        lines.append("")
        lines.append("CONVERSATIONS (\(conversations.count)):")
        for c in conversations.prefix(20) {
            lines.append("- [\(c.source.rawValue) \(c.durationMinutes)m] \(c.summary)")
        }
        lines.append("")
        lines.append("COMMITMENTS: made=\(commitments.made.count) kept=\(commitments.kept.count) still_open=\(commitments.stillOpen.count)")
        for x in commitments.made.prefix(5)   { lines.append("  made: \(x)") }
        for x in commitments.kept.prefix(5)   { lines.append("  kept: \(x)") }
        for x in commitments.stillOpen.prefix(5) { lines.append("  open: \(x)") }
        lines.append("")
        lines.append("FOCUS: onTask=\(focus.onTaskMinutes)m drifting=\(focus.driftingMinutes)m offTask=\(focus.offTaskMinutes)m")
        let topApps = focus.perAppMinutes.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key)=\($0.value)m" }.joined(separator: " ")
        if !topApps.isEmpty { lines.append("TOP_APPS: \(topApps)") }
        lines.append("TIME_ALLOCATION: coding=\(allocation.codingMinutes)m terminal=\(allocation.terminalMinutes)m browsing=\(allocation.browsingMinutes)m comms=\(allocation.commsMinutes)m meetings=\(allocation.meetingsMinutes)m design=\(allocation.designMinutes)m docs=\(allocation.docsMinutes)m music=\(allocation.musicMinutes)m other=\(allocation.otherMinutes)m")
        lines.append("")
        let topNotify = interrupts.perApp.prefix(5)
            .map { "\($0.app)=\($0.count)" }.joined(separator: " ")
        lines.append("NOTIFICATIONS: total=\(interrupts.total)\(topNotify.isEmpty ? "" : " top: \(topNotify)")")
        lines.append("")
        lines.append("MEETINGS_ATTENDED (\(meetings.count)):")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        for m in meetings.prefix(20) {
            let dur = max(1, Int(m.tsEnd.timeIntervalSince(m.tsStart) / 60))
            let attended = m.ambientSessionId != nil ? " (ambient overlap)" : ""
            let cal = m.calendarName.isEmpty ? "" : " · \(m.calendarName)"
            lines.append("- [\(tf.string(from: m.tsStart))-\(tf.string(from: m.tsEnd)) \(dur)m] \(m.eventTitle)\(cal)\(attended)")
        }
        if meetings.isEmpty { lines.append("- (no meetings on calendar)") }
        lines.append("")
        lines.append("Produce the STRICT JSON now.")
        return lines.joined(separator: "\n")
    }

    // Deterministic TL;DR for the rare LLM-unreachable case. Stays short
    // and factual so the rendered header still gives a usable scan.
    private static func fallbackExecutiveSummary(
        tasks: [LoggedTask],
        shipments: [CodeShipment],
        meetings: [LoggedMeeting],
        allocation: TimeAllocationBreakdown
    ) -> String {
        let totalCommits = shipments.reduce(0) { $0 + $1.commits.count }
        let totalMins =
            allocation.codingMinutes + allocation.terminalMinutes
            + allocation.browsingMinutes + allocation.commsMinutes
            + allocation.meetingsMinutes + allocation.designMinutes
            + allocation.docsMinutes + allocation.musicMinutes
            + allocation.otherMinutes
        var parts: [String] = []
        if totalCommits > 0 {
            parts.append("\(totalCommits) commit\(totalCommits == 1 ? "" : "s") across \(shipments.count) project\(shipments.count == 1 ? "" : "s")")
        }
        if !tasks.isEmpty {
            parts.append("\(tasks.count) task\(tasks.count == 1 ? "" : "s") completed")
        }
        if !meetings.isEmpty {
            parts.append("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s") attended")
        }
        if allocation.codingMinutes > 0 {
            let hrs = Double(allocation.codingMinutes) / 60.0
            parts.append(String(format: "%.1fh coding", hrs))
        }
        if totalMins == 0 && parts.isEmpty {
            return "Quiet day, nothing tracked."
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func fallbackNarrative(
        tasks: [LoggedTask], shipments: [CodeShipment], focus: FocusStats,
        meetings: [LoggedMeeting], interrupts: NotificationStats
    ) -> String {
        let totalCommits = shipments.reduce(0) { $0 + $1.commits.count }
        let totalSessions = shipments.reduce(0) { $0 + $1.claudeSessions.count }
        let productive = focus.onTaskMinutes + focus.driftingMinutes
        var parts: [String] = []
        if tasks.isEmpty && totalCommits == 0 && productive == 0 && meetings.isEmpty && interrupts.total == 0 {
            return "Quiet day, no tracked shipments, conversations, meetings, or focus time recorded for this workday."
        }
        if !tasks.isEmpty { parts.append("Completed \(tasks.count) task\(tasks.count == 1 ? "" : "s").") }
        if totalCommits > 0 {
            parts.append("Landed \(totalCommits) commit\(totalCommits == 1 ? "" : "s") across \(shipments.count) project\(shipments.count == 1 ? "" : "s").")
        }
        if totalSessions > 0 { parts.append("Ran \(totalSessions) Claude Code session\(totalSessions == 1 ? "" : "s").") }
        if !meetings.isEmpty {
            let titles = meetings.prefix(4).map { $0.eventTitle }.joined(separator: ", ")
            let suffix = meetings.count > 4 ? ", and \(meetings.count - 4) more" : ""
            parts.append("Meetings attended: \(titles)\(suffix).")
        }
        if productive > 0 {
            let hrs = Double(productive) / 60.0
            parts.append(String(format: "Productive time: %.1f hours.", hrs))
        }
        if interrupts.total > 0 {
            let top = interrupts.perApp.prefix(3).map { $0.app }.joined(separator: ", ")
            let topNote = top.isEmpty ? "" : " (mostly \(top))"
            parts.append("Got pulled out of flow \(interrupts.total) time\(interrupts.total == 1 ? "" : "s")\(topNote).")
        }
        return parts.joined(separator: " ")
    }
}

// Aggregated notification-storm stats for one workday. Built by
// NotificationWatcher and consumed by the narrative + fallback paths so the
// daily recap can quote "you got pulled out of flow N times today."
struct NotificationStats {
    let total: Int
    let perApp: [(app: String, count: Int)]
}
