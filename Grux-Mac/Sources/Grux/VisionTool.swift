import AppKit
import Foundation

// Grux's "look at my screen and answer" capability.
//
// Unlike FocusWatcher (which runs a structured focus-judgement pipeline and
// takes ~5-15s), VisionTool does a single direct vision round-trip: capture
// the main display, send it + the user's question to Claude Haiku, return the
// answer plain. Round-trip is typically ~1.5-3s on a broadband connection.
//
// Use when the user says:
//   - "look at my screen"
//   - "what's on my screen right now"
//   - "grab those usernames off the page"
//   - "remember the X on my screen"
//   - "read that to me"
//
// Requires Screen Recording permission (same as FocusWatcher) and a valid
// Anthropic API key. Both are checked up front with actionable error strings.

@MainActor
enum VisionTool {
    static func readScreen(question: String) async -> String {
        let state = AppState.shared
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQ = q.isEmpty
            ? "Describe what's currently on the screen in 2-3 sentences."
            : q

        guard ScreenCapturer.shared.hasPermission() else {
            return "error: screen recording permission not granted. Grant it in System Settings → Privacy & Security → Screen Recording → Grux."
        }
        let apiKey = state.anthropicKey
        guard !apiKey.isEmpty else {
            return "error: Anthropic API key not set. Add it in Settings → Model & API."
        }

        do {
            // Reuse a recent capture when the question isn't freshness-sensitive
            // (cuts a full render+encode on a quick "what's that / read it again"
            // pair). Explicit rescan phrasing forces a fresh frame. The bare word
            // "now" is intentionally NOT a trigger (it appears in benign
            // questions); the short cache TTL is the safety net for a missed
            // phrase, and any app/window switch invalidates the cache anyway.
            let lowerQ = effectiveQ.lowercased()
            let rescanPhrases = ["rescan", "scan again", "fresh", "refresh", "right now", "just now", "look again", "recapture", "re-capture", "current screen", "as of now"]
            let forceFresh = rescanPhrases.contains { lowerQ.contains($0) }
            let (snap, wasCached) = try await ScreenCapturer.shared.cachedOrCapture(forceFresh: forceFresh)
            // Higher quality than the focus-watcher path - we only fire on
            // explicit user requests, so the extra ~80-150KB is worth it for
            // readability of small on-screen text (usernames, prices, etc.).
            guard let jpeg = ScreenCapturer.jpegData(
                from: snap.image,
                maxDimension: 1600,
                quality: 0.7
            ) else {
                return "error: failed to encode screenshot"
            }

            let system = """
            You are Grux's vision helper. The user just asked a question about what is currently on their screen; the image attached is a fresh screenshot of their main display. Answer accurately from the image.

            Rules:
            - Plain spoken English. No markdown, no bullets, no headers.
            - If they asked to EXTRACT specific values (usernames, handles, prices, names, addresses, numbers, emails, codes), return EXACTLY those values, one per line, with no commentary, no "Sure!", no wrapping text. Preserve capitalization and punctuation exactly as shown.
            - If they asked an open-ended question ("what am I looking at", "describe this"), answer in 2-3 short sentences: app, main content, anything notable.
            - If the thing they asked about is NOT visible in the screenshot, say exactly: "not visible on this screen" and stop.
            - Never invent content that isn't actually in the image. Never paraphrase literal values.
            - If you see API keys, passwords, credit-card numbers, or other clearly-secret strings, refuse to echo them - say "there are secrets on this screen; not repeating them" instead.
            """

            // PINNED TO ANTHROPIC, DELIBERATELY. Read-my-screen is a vision
            // call, most local models cannot serve one, and OpenAICompatBackend's
            // NOTE: routing is pinned to "anthropic" below, so
            // OpenAICompatBackend.completeVision is not reachable from here
            // and the degrade described next is not currently observed.
            // completeVision degrades to an error on purpose (400/422 shape
            // rejections only; 401, 403, 429 and 5xx pass through with their
            // own status). Routing this would replace a working answer with
            // "error: vision unsupported by local backend" for the very user
            // the backend sweep exists for, which is worse than honestly
            // staying on Anthropic. It goes through the registry with the
            // provider pinned so there is one shared client and one credential
            // lookup instead of a fresh URLSession per look.
            let routing = ModelRegistry.shared.resolvedRouting(
                provider: "anthropic", modelOverride: "claude-haiku-4-5-20251001")
            let answer = try await routing.backend.completeVision(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: system,
                userText: effectiveQ,
                imageJPEG: jpeg,
                mediaType: "image/jpeg",
                maxTokens: 600,
                temperature: 0.1,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.completeVision",
                feature: "vision"
            )

            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "error: vision returned an empty answer - try rephrasing the question"
            }
            WakeLog.shared.log("read_screen[\(wasCached ? "cached" : "fresh")]: q='\(effectiveQ.prefix(60))' → \(trimmed.prefix(80))")
            return "ok: \(trimmed)"
        } catch let blocked as CaptureBlocked {
            // Deliberately not an `error:`. The model treats that prefix as
            // something to retry or work around, and there is nothing to work
            // around here: this is a rule the user set. Saying so plainly is
            // what stops it trying another route to the same pixels.
            WakeLog.shared.log("read_screen blocked: \(blocked.appName) (\(blocked.reason))")
            return "ok: I can't look at that one. \(blocked.errorDescription ?? "") You can change which apps are excluded in Settings, Privacy and capture."
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}
