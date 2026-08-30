import Foundation

// On-stop summarization. Hands the full flat transcript to Claude via the
// same ClaudeClient the chat service uses, asks for a short TL;DR plus
// action items. Output writes back to the MeetingRecord on disk.
@MainActor
enum MeetingSummarizer {
    struct Summary {
        let tldr: String
        let actionItems: [String]
    }

    static func summarize(_ record: MeetingRecord) async -> Summary? {
        await summarize(
            transcript: record.flatText(),
            durationSeconds: record.durationSeconds,
            sourceName: record.sourceAppName
        )
    }

    // Transcript-string variant. Used by the live path (diarized utterances via
    // record.flatText()) AND by the companion whisper-queue offload, which re-runs
    // the summary against the cleaner large-v3_turbo transcript.
    static func summarize(transcript: String, durationSeconds: TimeInterval, sourceName: String?) async -> Summary? {
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user got no
        // meeting summary at all, logged once and then silent. Resolved ONCE per
        // summary.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            WakeLog.shared.log("meeting-summarizer: no key for the active provider, skipping summary")
            return nil
        }
        guard !transcript.isEmpty else { return nil }

        // The empty-model fallback is unchanged: an unset model id is a 404 on
        // any provider, so the historical default still stands in.
        let model = routing.modelId.isEmpty ? "claude-haiku-4-5-20251001" : routing.modelId
        let system = """
        You are a meeting-notes assistant. The user will paste a live \
        transcript of a meeting that was just captured on-device by Grux. \
        Channels are labeled "Me" (the user) and "Them" (other participants). \
        Ignore filler, false starts, and transcription noise.
        Output STRICT JSON with exactly these keys:
          {"tldr": <string>, "action_items": [<string>, ...]}
        - tldr: 2-4 sentence summary of what was decided / discussed. No \
          headings. No bullet points. Plain prose, a casual voice.
        - action_items: 0-8 concrete next steps, each 3-10 words, starting \
          with a verb. ONLY include items that are clearly committed to in \
          the transcript. No meta notes, no "schedule follow-up" unless \
          literally discussed.
        No prose outside the JSON. No markdown fences.
        """
        let userText = """
        Transcript (duration \(Int(durationSeconds))s, source: \(sourceName ?? "unknown")):
        ---
        \(transcript)
        ---
        Respond with JSON only.
        """

        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: model,
                system: system,
                messages: [ClaudeMessage(role: "user", content: userText)],
                maxTokens: 700,
                temperature: 0.2,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "uncategorized"
            )
            return parse(reply)
        } catch {
            WakeLog.shared.log("meeting-summarizer: failed \(error.localizedDescription)")
            return nil
        }
    }

    private static func parse(_ raw: String) -> Summary? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive: strip markdown fences if Claude ignored the instruction.
        let stripped: String = {
            var s = trimmed
            if s.hasPrefix("```") {
                if let newline = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: newline)...])
                }
                if s.hasSuffix("```") {
                    s.removeLast(3)
                }
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        guard let data = stripped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            WakeLog.shared.log("meeting-summarizer: JSON parse failed - raw prefix='\(raw.prefix(120))'")
            return nil
        }
        let tldr = (obj["tldr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (obj["action_items"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tldr.isEmpty || !items.isEmpty else { return nil }
        return Summary(tldr: tldr, actionItems: items)
    }
}
