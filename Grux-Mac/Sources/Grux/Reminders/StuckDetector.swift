import Foundation
import AppKit
import CoreGraphics

// Silence/stuck detector. Catches the flow-state failure mode where the user
// is heads-down on a task but has gone silent + keyboard-idle for long enough
// to suggest they are actually stuck, not just thinking.
//
// Signals used (all available without special permissions on macOS):
//   1. CGEventSource.secondsSinceLastEventType(_:) - system idle time
//   2. AmbientState.recentChunks.last.timestamp - last voice activity
//   3. AppState.currentTask - must be set (active focus session)
//   4. AppState.config.ambientEnabled - ambient mode must be running
//
// Design cue from the Omi research: "advice doesn't change behavior; timing
// + context does." We fire at most once per 20 minutes and only when ALL
// four signals say he's actually stuck. Ignores short thinking pauses.
@MainActor
final class StuckDetector {
    static let shared = StuckDetector()

    private var tickTimer: Timer?
    private var lastFireAt: Date = .distantPast
    // Hard cooldown between stuck fires - prevents "you seem stuck" nag loops.
    private let cooldownSeconds: TimeInterval = 20 * 60
    // Minimum seconds of combined silence + idle before we fire. Default 8m.
    var stuckThresholdSeconds: TimeInterval {
        let minutes = AppState.shared.config.stuckThresholdMinutes
        return TimeInterval(max(3, minutes) * 60)
    }

    private init() {}

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        WakeLog.shared.log("stuck detector: started (threshold=\(Int(stuckThresholdSeconds/60))m, cooldown=\(Int(cooldownSeconds/60))m)")
    }

    // Force-fire a stuck nudge regardless of idle/silence timers. Used by
    // the ~/.grux/fire-stuck file trigger and by a menu-bar debug item.
    // Bypasses cooldown.
    func forceFire() async {
        let state = AppState.shared
        guard state.currentTask != nil else {
            WakeLog.shared.log("stuck forceFire: skipped (no current task)")
            return
        }
        lastFireAt = .distantPast
        await fireStuckNudge(idleSeconds: stuckThresholdSeconds, silentSeconds: stuckThresholdSeconds)
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func tick() async {
        let state = AppState.shared
        // Must be actively in a focus session: ambient on + current task set.
        guard state.config.ambientEnabled, state.currentTask != nil else { return }
        // Respect snooze / active hours
        guard state.isWithinActiveHours(), !state.isSnoozed() else { return }
        // Respect cooldown
        guard Date().timeIntervalSince(lastFireAt) >= cooldownSeconds else { return }

        // Signal 1: system idle
        let idle = Self.systemIdleSeconds()
        // Signal 2: last voice chunk
        let lastVoice = AmbientState.shared.recentChunks.last?.timestamp ?? .distantPast
        let silentFor = Date().timeIntervalSince(lastVoice)

        // Both must exceed threshold for the user to genuinely look stuck.
        guard idle >= stuckThresholdSeconds, silentFor >= stuckThresholdSeconds else {
            return
        }

        WakeLog.shared.log(String(format: "stuck: idle=%.0fs silent=%.0fs → firing", idle, silentFor))
        lastFireAt = Date()
        await fireStuckNudge(idleSeconds: idle, silentSeconds: silentFor)
    }

    // CGEventSource exposes system-wide idle time per-event-type. Take the
    // minimum across the relevant HID event types - that's time since the
    // user did *anything* (key, click, move, scroll). Zero permissions.
    private static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let values = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        return values.min() ?? 0
    }

    private func fireStuckNudge(idleSeconds: Double, silentSeconds: Double) async {
        let state = AppState.shared
        guard let task = state.currentTask else { return }

        let title = "Stuck on \"\(task.title)\"?"
        let idleMin = Int(min(idleSeconds, silentSeconds) / 60)

        // Optional personalized body via Claude - if no API key, use canned text.
        var body = "You've been quiet for \(idleMin) minutes on this. Want me to recap what you've tried, or pick a different angle?"
        // ROUTED. This gated the personalised body on AppState.anthropicKey and
        // composeBody built its own ClaudeClient, so a local-only or
        // custom-endpoint user always got the canned sentence. The gate now asks
        // the same question the call will ask: does the ROUTED provider have a
        // usable credential.
        if !ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil).apiKey.isEmpty {
            body = (await composeBody(task: task, idleMin: idleMin)) ?? body
        }

        let reminder = GruxReminder(
            kind: .stuck,
            title: title,
            body: body,
            project: task.project.isEmpty ? nil : task.project,
            scheduledFor: nil,
            taskId: task.id
        )
        GruxReminderState.shared.schedule(reminder)

        // Record it in the coach history too so the HUD can show "Grux checked
        // in" the same way coach nudges do.
        AmbientState.shared.addNudge(AmbientCoachNudge(
            text: body,
            currentTaskTitle: task.title,
            driftRationale: "stuck-detector (\(idleMin)m idle)"
        ))
    }

    // Short Claude prompt for a personalized "stuck" nudge body. Grounded
    // in the current task + any recent ambient transcript so it doesn't
    // read generic.
    private func composeBody(task: FocusTask, idleMin: Int) async -> String? {
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        let transcript = AmbientState.shared.transcriptWindow(minutes: 15)
        let sys = """
        The user has gone silent and keyboard-idle for \(idleMin) minutes on their current task. Write ONE short nudge (≤28 words) that:
        - Names the task they were on
        - Offers a concrete next step OR offers to recap what they have tried
        - Is warm, direct, never condescending
        - No greeting, no "I noticed", no emoji, no markdown
        """
        let user = """
        CURRENT_TASK: \(task.title)\(task.project.isEmpty ? "" : " (\(task.project))")
        IDLE_MINUTES: \(idleMin)

        RECENT_TRANSCRIPT (what they said in the last 15 min):
        \(transcript.isEmpty ? "(nothing)" : transcript)

        Respond with ONE short nudge line.
        """
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 120,
                temperature: 0.5,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "uncategorized"
            )
            let t = reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            return t.isEmpty ? nil : t
        } catch {
            WakeLog.shared.log("stuck compose FAILED: \(error.localizedDescription)")
            return nil
        }
    }
}
