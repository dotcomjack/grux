import Foundation

// 10pm daily recap. Generated at a configurable local time (22:00 default),
// assembled from:
//   - Today's completed tasks (from AppState)
//   - Today's open commitments (from AmbientState.memories kind=commitment)
//   - Tomorrow's top 3 (from active task stack - NOW > NEXT > LATER)
//   - Claude-generated one-paragraph narrative observation grounded in the
//     day's ambient transcript + focus events
//
// Surfaces as a full-screen glass takeover card (DailyRecapPanelController),
// speaks the narrative aloud, and records itself as a GruxReminder so the
// user's recap history is preserved.

struct DailyRecapData: Codable, Hashable {
    var date: Date
    var narrative: String           // Claude-generated, ~60-80 words
    var shippedToday: [String]      // completed task titles
    var openCommitments: [String]   // commitment memory texts not yet acted on
    var tomorrowTop3: [String]      // active tasks, NOW first
}

@MainActor
final class DailyRecapScheduler {
    static let shared = DailyRecapScheduler()

    private var tickTimer: Timer?
    // Avoid firing the same day twice. Stored YYYY-MM-DD string.
    private var lastFiredDayKey: String?

    private init() {
        // Seed from UserDefaults so we don't double-fire after a relaunch on
        // the same day.
        lastFiredDayKey = UserDefaults.standard.string(forKey: "grux.dailyRecap.lastFiredDayKey")
    }

    func start() {
        guard tickTimer == nil else { return }
        // Poll every minute - cheap, and drift doesn't matter for a human-scale
        // daily event.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
        // Immediate check on boot so a missed-window recap from earlier today
        // can still surface if we were quit during the scheduled time.
        checkAndFire()
        WakeLog.shared.log("dailyRecap scheduler: started")
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func checkAndFire() {
        let target = AppState.shared.config.dailyRecapHour
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .year, .month, .day], from: now)
        guard let hour = comps.hour else { return }
        let dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        // Fire if we've reached the target hour, haven't fired yet today, and
        // it's not more than 90 min past target (so a laptop just waking up
        // at 23:45 doesn't surprise the user).
        let windowOk = hour >= target && hour < target + 2
        guard windowOk, lastFiredDayKey != dayKey else { return }
        lastFiredDayKey = dayKey
        UserDefaults.standard.set(dayKey, forKey: "grux.dailyRecap.lastFiredDayKey")
        Task { @MainActor in await self.fireRecap() }
    }

    // Manually trigger from menu / settings. Bypasses the "already fired today"
    // guard so the user can preview the recap at any time.
    func fireRecapNow() async {
        await fireRecap()
    }

    private func fireRecap() async {
        WakeLog.shared.log("dailyRecap: generating…")
        let data = await generateData()
        // Show the takeover
        DailyRecapPanelController.shared.present(data)
        // Speak the narrative - polite-queue it so a scheduled recap never
        // cuts into an active chat. 60s wait is generous for a recap; if
        // they are still deep in conversation after that, the HUD panel is
        // already up so the info isn't lost.
        if AppState.shared.config.speakRepliesAloud {
            SpeechEngine.shared.speakAfterCurrent(data.narrative, maxWaitSeconds: 60)
        }
        // Record into reminder history so the day's recap is recoverable
        let reminder = GruxReminder(
            kind: .dailyRecap,
            title: "Daily Recap",
            body: data.narrative,
            scheduledFor: nil
        )
        GruxReminderState.shared.reminders.insert(reminder, at: 0)
        GruxReminderState.shared.save()
    }

    // MARK: - Data assembly

    private func generateData() async -> DailyRecapData {
        let state = AppState.shared
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)

        // Today's completed tasks
        let shipped: [String] = state.completedTasks
            .filter { ($0.completedAt ?? .distantPast) >= startOfDay }
            .prefix(10)
            .map { t in t.project.isEmpty ? t.title : "\(t.title) · \(t.project)" }

        // Today's commitments - anything still-pending of kind .commitment or
        // .reminder recorded today. Heuristic filter: commitments we haven't
        // yet matched against a completed task title.
        let shippedLower = shipped.map { $0.lowercased() }
        let commitmentsToday = AmbientState.shared.memories
            .filter { ($0.kind == .commitment || $0.kind == .reminder) && $0.timestamp >= startOfDay }
        let open: [String] = commitmentsToday
            .filter { m in
                let lower = m.text.lowercased()
                return !shippedLower.contains(where: { lower.contains($0) || $0.contains(lower) })
            }
            .prefix(6)
            .map { m in
                if let p = m.project, !p.isEmpty { return "\(m.text) · \(p)" }
                return m.text
            }

        // Tomorrow's top 3 - NOW first, then NEXT by insertion order
        let nows = state.activeTasks.filter { $0.priority == .now }
        let nexts = state.activeTasks.filter { $0.priority == .next }
        let combined = (nows + nexts).prefix(3)
        let top3: [String] = combined.map { t in
            t.project.isEmpty ? t.title : "\(t.title) · \(t.project)"
        }

        // Ask Claude for a short narrative observation
        let narrative = await composeNarrative(
            shipped: shipped, open: open, top3: top3
        )
        return DailyRecapData(
            date: now, narrative: narrative,
            shippedToday: shipped, openCommitments: open, tomorrowTop3: top3
        )
    }

    private func composeNarrative(shipped: [String], open: [String], top3: [String]) async -> String {
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user was
        // skipped here forever while the Chat tab worked. Resolved ONCE per
        // run, on the main actor, never inside a loop.

        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            return defaultNarrative(shipped: shipped, open: open, top3: top3)
        }

        // Grab today's ambient transcript for context
        let transcript = AmbientState.shared.transcriptWindow(minutes: 600) // whole day

        // Today's listening, if anything was captured. Top 3 artists by
        // listen-seconds. Quiet days (less than ~5 minutes total) get omitted
        // entirely so the prompt doesn't waste tokens on noise.
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let listenSeconds = MusicWatcher.totalListenSeconds(between: startOfDay, and: now)
        let topArtists: [String] = listenSeconds >= 300
            ? MusicWatcher.perArtistDwell(between: startOfDay, and: now)
                .prefix(3)
                .map { "\($0.artist) (\($0.seconds / 60)m)" }
            : []

        // Batched (non-interrupt) notification digests folded hourly by the
        // triage queue. Gives the recap visibility into what Grux chose NOT
        // to interrupt the user with during the day.
        let notifLines = TriageBatchQueue.shared.todaysDigestLines()

        let sys = """
        You are Grux wrapping up the user's day. Write ONE short narrative paragraph (55-85 words) that:
        - Acknowledges what they actually shipped today (use task titles, be specific)
        - Gently flags any open commitments (not nagging, just naming them)
        - If MUSIC_TODAY is populated, optionally weave in one brief observation about what they listened to (one clause, not a full sentence, only when it adds texture)
        - Lands on one genuine sentence of encouragement or insight grounded in their actual day (not generic)
        - Warm, direct, like a friend who respects their grind. No emoji, no markdown, no bullet lists, no "great job!"
        - Plain spoken prose. This will be read aloud via TTS.
        """

        let user = """
        TODAY_DATE: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))

        SHIPPED (completed today, \(shipped.count) items):
        \(shipped.isEmpty ? "(nothing marked complete today)" : shipped.map { "- \($0)" }.joined(separator: "\n"))

        OPEN_COMMITMENTS (the user said they'd do these, still pending):
        \(open.isEmpty ? "(none tracked)" : open.map { "- \($0)" }.joined(separator: "\n"))

        TOMORROW_TOP3 (from task stack, priority order):
        \(top3.isEmpty ? "(stack is light)" : top3.map { "- \($0)" }.joined(separator: "\n"))

        MUSIC_TODAY (top artists by listen-seconds, only if substantial):
        \(topArtists.isEmpty ? "(none)" : topArtists.joined(separator: ", "))

        NOTIFICATIONS_TODAY (batched, Grux held these instead of interrupting):
        \(notifLines.isEmpty ? "(none batched)" : notifLines.map { "- \($0)" }.joined(separator: "\n"))

        TRANSCRIPT_SNAPSHOT (recent things the user said today, trimmed):
        \(String(transcript.prefix(2000)))

        Your one-paragraph recap (55-85 words, spoken-aloud friendly):
        """
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 220,
                temperature: 0.55,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "uncategorized"
            )
            let cleaned = reply
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            if cleaned.isEmpty { return defaultNarrative(shipped: shipped, open: open, top3: top3) }
            // Fact-grounding vet: a recap that drifted a product fact falls back
            // to the deterministic narrative rather than speaking an invented number.
            let verdict = await MainActor.run { GroundingGate.vet(draft: cleaned, brief: user) }
            if !verdict.surfaceable {
                WakeLog.shared.log("dailyRecap: grounding vet blocked a drifted fact; using deterministic fallback")
                return defaultNarrative(shipped: shipped, open: open, top3: top3)
            }
            return cleaned
        } catch {
            WakeLog.shared.log("dailyRecap narrative FAILED: \(error.localizedDescription)")
            return defaultNarrative(shipped: shipped, open: open, top3: top3)
        }
    }

    // Offline fallback so the recap always has a narrative even without network.
    private func defaultNarrative(shipped: [String], open: [String], top3: [String]) -> String {
        if shipped.isEmpty && open.isEmpty && top3.isEmpty {
            return "Quiet day, boss. Nothing on the books, nothing hanging. Get some rest and we'll hit it fresh tomorrow."
        }
        var parts: [String] = []
        if !shipped.isEmpty {
            parts.append("You closed \(shipped.count) thing\(shipped.count == 1 ? "" : "s") today.")
        } else {
            parts.append("Nothing marked done today.")
        }
        if !open.isEmpty {
            parts.append("Still \(open.count) commitment\(open.count == 1 ? "" : "s") open - we'll pick them up tomorrow.")
        }
        if !top3.isEmpty {
            parts.append("First up in the morning: \(top3[0]).")
        }
        return parts.joined(separator: " ") + " Rest up."
    }
}
