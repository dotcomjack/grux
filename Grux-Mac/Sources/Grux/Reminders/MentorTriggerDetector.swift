import Foundation

// Detects explicit mentor-mode trigger phrases in ambient transcript chunks.
// Same pattern Omi uses ("what do you think", "any advice") - fires only on
// explicit asks so Grux never nags unsolicited. Hard-rate-limited to prevent
// nag fatigue (the universal complaint about every wearable we studied).
@MainActor
final class MentorTriggerDetector {
    static let shared = MentorTriggerDetector()

    private var lastFireAt: Date = .distantPast
    private var inFlight = false
    private let cooldownSeconds: TimeInterval = 90

    private init() {}

    // Loose regex - any of these phrasings. Kept conservative so we don't
    // false-trigger on overheard casual questions.
    private static let mentorTriggerRegex: NSRegularExpression = {
        let pattern = #"\b(?:what do you think|any advice|any thoughts|help me out|what should i do|what would you do|i(?:'m| am) stuck|hit a wall|don't know what to do|need your (?:take|advice|input)|talk me through|what's your take|(?:quick|any) gut check)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    @discardableResult
    func evaluate(chunk: String) -> Bool {
        guard AppState.shared.config.ambientCoachEnabled else { return false }
        let range = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
        guard Self.mentorTriggerRegex.firstMatch(in: chunk, options: [], range: range) != nil else {
            return false
        }
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) >= cooldownSeconds, !inFlight else {
            WakeLog.shared.log("mentor trigger: matched but in cooldown")
            return false
        }
        inFlight = true
        lastFireAt = now
        Task { @MainActor in
            defer { inFlight = false }
            await self.fireMentor(for: chunk)
        }
        return true
    }

    private func fireMentor(for askChunk: String) async {
        let state = AppState.shared
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user was
        // skipped here forever while the Chat tab worked. Resolved ONCE per
        // run, on the main actor, never inside a loop.

        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else { return }

        let transcript = AmbientState.shared.transcriptWindow(minutes: 8)
        let memoriesPrefix = Array(AmbientState.shared.memories.prefix(10))
        let relevantMemories = memoriesPrefix.filter { $0.kind == .intent || $0.kind == .commitment }
        let intentLines: [String] = relevantMemories.map { m in "- [\(m.kind.rawValue)] \(m.text)" }
        let intents = intentLines.joined(separator: "\n")
        let currentTask = state.currentTask?.title ?? "(none)"
        let slang = ProfileMemoryStore.shared.asSystemContext()

        let sys = """
        You are Grux in mentor mode. The user just explicitly asked for your take. Give them ONE concrete, useful answer - not a list, not a process, not a disclaimer. Max 2 sentences, 40 words total.
        - Ground the answer in their actual current task and what they just said.
        - If multiple angles exist, PICK ONE - the strongest. They didn't ask for a landscape survey.
        - Zero preamble. No "great question" / "I think that's an interesting point". Open with the answer.
        - Plain spoken English. No markdown.

        \(slang)
        """

        let user = """
        USER_CURRENT_TASK: \(currentTask)
        USER_RECENT_INTENTS_COMMITMENTS:
        \(intents.isEmpty ? "(none)" : intents)

        USER_RECENT_TRANSCRIPT (last 8 minutes):
        \(transcript.isEmpty ? "(empty)" : transcript)

        THE ASK (trigger chunk):
        \(askChunk)

        Your ONE concrete answer:
        """

        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 140,
                temperature: 0.6,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "uncategorized"
            )
            let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            guard !answer.isEmpty else { return }

            WakeLog.shared.log("mentor fire: \(answer.prefix(120))")
            // 1) Glass reminder toast (visual)
            let reminder = GruxReminder(
                kind: .mentor,
                title: "Grux's take",
                body: answer,
                project: state.currentTask?.project,
                scheduledFor: nil
            )
            GruxReminderState.shared.schedule(reminder)
            // 2) Speak it (voice)
            if state.config.speakRepliesAloud {
                SpeechEngine.shared.speak(answer)
            }
            // 3) Record into ambient coach log for HUD history
            AmbientState.shared.addNudge(AmbientCoachNudge(
                text: answer,
                currentTaskTitle: currentTask,
                driftRationale: "mentor-trigger"
            ))
        } catch {
            WakeLog.shared.log("mentor FAILED: \(error.localizedDescription)")
        }
    }
}
