import Foundation

// Rolling-summary compactor for long chat threads. Runs on the SAME backend the
// chat UI routes through, handed in by the caller - no new dependency, no cloud
// infra. Produces a short pack-it-all-in summary that ChatService prepends to
// the volatile system block so compacted turns still inform replies.
//
// TAKING THE BACKEND IS THE FIX. Both entry points used to take an apiKey and a
// model and call AmbientLLM, which is a different router: its local path keys off
// the companion-service settings (useLocalQwenForAmbient plus localLLMEndpoint)
// and its fallback constructs a ClaudeClient with the Anthropic key. Somebody
// running a local model through the MODEL router and holding no key matched
// neither, so the user with the smallest context window of anyone was the only
// user who never got compaction: the thread grew until the provider refused it,
// with an error about conversation length they could do nothing about. Titles
// failed the same way, leaving a sidebar of "New chat".
enum ChatCompactor {

    static let systemPrompt: String = """
    You are summarizing a chat transcript for context preservation. Produce a compact, \
    faithful recap that a future model turn can use in place of the original messages.

    RULES:
    - Keep all concrete facts: names, numbers, decisions, agreements, todos, file paths, \
      URLs, IDs, technical details.
    - Attribute the user's requests to them plainly: "the user wants X", "the user said Y".
    - Preserve open questions and unresolved threads so the assistant can pick them up.
    - Do NOT invent details. If something is unclear, say "unclear".
    - Do NOT include pleasantries, acknowledgments, or filler.
    - Keep under 400 words. Prefer bullets over prose.
    """

    // MARK: - Public API

    // Best-effort summary of `messages`, optionally folded into an existing
    // prior summary. Returns nil when the call fails (missing key, network,
    // non-2xx, etc.) - callers keep the old summary in that case.
    //
    // `backend`, `model` and `apiKey` are one routing decision, resolved
    // together by the caller from ModelRegistry.resolvedRouting so the three can
    // never disagree. An empty apiKey is normal and correct on a local route.
    static func summarize(
        messages: [ChatMessage],
        priorSummary: String?,
        backend: ModelBackend,
        model: String,
        apiKey: String
    ) async -> String? {
        let payload = buildUserPayload(messages: messages, priorSummary: priorSummary)
        let turn = [ClaudeMessage(role: "user", content: payload)]
        do {
            let reply = try await backend.complete(
                apiKey: apiKey,
                model: model,
                system: systemPrompt,
                messages: turn,
                maxTokens: 800,
                temperature: 0.2,
                spanName: "chat.compact",
                feature: "compaction"
            )
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // Generate a short, stable thread title from the first few turns. Fires
    // once when a fresh thread crosses 2 exchanges so the sidebar doesn't
    // sit on "New chat" forever. Bails out on failure - caller keeps the
    // placeholder title.
    static func generateTitle(
        messages: [ChatMessage],
        backend: ModelBackend,
        model: String,
        apiKey: String
    ) async -> String? {
        let payload = buildTitlePayload(messages: messages)
        let system = "Pick a crisp 2 to 5 word title for the chat below. Lowercase ok. No quotes, no trailing period. Output ONLY the title."

        do {
            let reply = try await backend.complete(
                apiKey: apiKey,
                model: model,
                system: system,
                messages: [ClaudeMessage(role: "user", content: payload)],
                maxTokens: 32,
                temperature: 0.3,
                spanName: "chat.title",
                feature: "compaction"
            )
            return cleanTitle(reply)
        } catch {
            return nil
        }
    }

    // MARK: - Pure helpers (extracted so unit tests can pin behavior without
    // standing up a live API call)

    // Render a transcript as "Speaker: text" lines, double-newline separated.
    // Speaker labels are stable: User for the person, Grux for assistant,
    // System for system messages. Used by summarize() and generateTitle().
    static func renderTranscript(messages: [ChatMessage]) -> String {
        return messages.map { m -> String in
            let who: String = {
                switch m.role {
                case .user: return "User"
                case .assistant: return "Grux"
                case .system: return "System"
                }
            }()
            return "\(who): \(m.content)"
        }.joined(separator: "\n\n")
    }

    // Build the `user` payload sent to the summarizer. When `priorSummary`
    // is non-empty, it's woven in so the rolling summary updates in place
    // instead of starting from scratch each cycle.
    static func buildUserPayload(messages: [ChatMessage], priorSummary: String?) -> String {
        let transcript = renderTranscript(messages: messages)
        if let priorSummary, !priorSummary.isEmpty {
            return """
            EXISTING SUMMARY OF EARLIER TURNS:
            \(priorSummary)

            NEW MESSAGES TO FOLD IN (oldest first):
            \(transcript)

            Produce a single updated summary that supersedes the existing one. Keep under 400 words.
            """
        } else {
            return """
            CHAT TRANSCRIPT (oldest first):
            \(transcript)

            Summarize per the rules. Output ONLY the summary.
            """
        }
    }

    // Build the title-prompt payload from the first 6 turns. Single-newline
    // separated so the model sees a tight conversation, not a sparse one.
    static func buildTitlePayload(messages: [ChatMessage]) -> String {
        let lines = messages.prefix(6).map { m -> String in
            let who = m.role == .user ? "User" : "Grux"
            return "\(who): \(m.content)"
        }.joined(separator: "\n")
        return "CHAT:\n\(lines)\n\nTitle:"
    }

    // Strip wrapping quotes / trailing periods, cap length at 60 chars, and
    // return nil on empty. Defensive even though the prompt forbids those.
    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "\"", with: "")
        title = title.replacingOccurrences(of: "'", with: "")
        if title.hasSuffix(".") { title = String(title.dropLast()) }
        if title.count > 60 { title = String(title.prefix(60)) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // Use Haiku-class for both ops even if the user's chat model is Sonnet -
    // summarization doesn't need deep reasoning and staying off Sonnet keeps
    // the compaction path cheap + fast.
    static func preferredSummarizerModel(default m: String) -> String {
        if m.contains("haiku") { return m }
        return "claude-haiku-4-5-20251001"
    }
}
