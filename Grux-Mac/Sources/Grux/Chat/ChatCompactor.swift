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

    // What a thread keeps once its summary is in (D144): everything it holds
    // NOW except the messages the summary folded. A summary on a local model
    // can take most of a minute, and a list chosen before it started would
    // write over every turn sent while it ran.
    static func kept(afterSummary latest: [ChatMessage], folded: [ChatMessage]) -> [ChatMessage] {
        let foldedIDs = Set(folded.map(\.id))
        return latest.filter { !foldedIDs.contains($0.id) }
    }

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
    // sit on "New chat" forever. Nil when the call failed (network, a model
    // still loading): the caller keeps the placeholder and asks again next
    // reply. An empty string when the model answered with no title, which a
    // retry would only repeat: the caller names the thread from what the
    // person said instead. Measured 2026-10-27 on a 16 GB Mac mini, before
    // that difference existed: no title came back on 49 of 50 turns and the
    // call ran again after every reply, 1.27 s of the local model each time.
    // The title names what the person asked about, in their own words. It is
    // handed only their lines (`buildTitlePayload`), because handed Grux's
    // replies it named those: "weather and task assistant" over a person who
    // asked "What can you do?" (sense pass 31, 2026-11-09).
    static let titleSystemPrompt = "Pick a crisp 2 to 5 word title naming what the person asked about, using their own words. Lowercase ok. No quotes, no trailing period. Output ONLY the title."
    static func generateTitle(
        messages: [ChatMessage],
        backend: ModelBackend,
        model: String,
        apiKey: String
    ) async -> String? {
        let payload = buildTitlePayload(messages: messages)
        let system = titleSystemPrompt

        do {
            let reply = try await backend.completeShortAnswer(
                apiKey: apiKey,
                model: model,
                system: system,
                messages: [ClaudeMessage(role: "user", content: payload)],
                maxTokens: 32,
                temperature: 0.3,
                spanName: "chat.title",
                feature: "compaction"
            )
            return cleanTitle(reply) ?? ""
        } catch ClaudeError.http(200, let message) where message == OpenAICompatBackend.thinkingBudgetMessage {
            return ""
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

    // Build the title-prompt payload from the person's first 6 messages, and
    // only theirs: a title names what they asked, never Grux's reply. Single
    // newline separated so the model sees a tight list, not a sparse one.
    static func buildTitlePayload(messages: [ChatMessage]) -> String {
        let lines = messages.filter { $0.role == .user }.prefix(6).map { m -> String in
            "User: \(m.content)"
        }.joined(separator: "\n")
        return "THE PERSON WROTE:\n\(lines)\n\nTitle:"
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
