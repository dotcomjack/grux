import Foundation
import WhisperKit

// Builds an "initial prompt" for Whisper that biases decoding toward the terms
// this user actually says. Whisper uses the prompt as context for token
// probabilities: any word the decoder might confuse with a common bigram gets
// pulled toward the in-vocabulary variant (e.g. "Grux" stays intact instead of
// collapsing to "Grox" or "Grooks").
//
// This list used to carry one specific person's brand roster and his name. That
// is not a cosmetic problem: a name in the ASR prompt changes what the
// microphone is WILLING TO HEAR, so a stranger dictating an ordinary sentence
// got it bent toward somebody else's product names. What remains is the set any
// Grux user benefits from, and everything person-specific now arrives from that
// person's own learned slang.
//
// The prompt is capped to ~220 tokens (Whisper's prompt buffer is 224 - slack
// for special tokens) and rebuilt lazily when profile slang changes.
@MainActor
enum WhisperVocab {
    // Terms every Grux user says: the app itself, the models it talks to, the
    // services it integrates, and its own feature vocabulary. Nothing here
    // belongs to a particular person, which is the bar for adding to it.
    static let baseTerms: [String] = [
        "Grux",
        "Anthropic", "Claude", "Opus", "Sonnet", "Haiku",
        "Render", "Stripe", "Cloudflare", "ElevenLabs",
        "WhisperKit", "SwiftUI", "TypeScript", "SQLite",
        "focus", "ambient", "wake word",
    ]

    // Build the single English prompt sentence. Style matters - Whisper's
    // prompt should read like plausible preceding transcript, not a list.
    static func buildPrompt() -> String {
        // Keep the ASR biasing prompt SHORT and CLEAN. We deliberately do NOT
        // feed KnownProjects.displayNames() here anymore: those names are
        // auto-derived from agent-registry descriptions and come out garbled
        // ("IOS Describedesign V2"), which (a) bloated the prompt and (b) biased
        // Whisper to mis-hear normal speech as brand/project tokens, hurting
        // general accuracy and echoing the roster back on quiet captures. The
        // curated baseTerms already cover the real brands; a tight prompt is the
        // accurate one (Whisper's own guidance: short, natural, not a long list).
        let slangTerms = ProfileMemoryStore.shared.slang.prefix(15).map { $0.term }
        let combined = baseTerms + slangTerms
        // De-duplicate case-insensitively, preserve order.
        var seen = Set<String>()
        let deduped = combined.filter { term in
            let k = term.lowercased()
            if seen.contains(k) { return false }
            seen.insert(k); return true
        }
        // One natural-sounding sentence so the decoder biases toward these
        // spellings without the prompt itself being echoed into the output.
        // Deliberately nameless: naming the speaker in the ASR prompt is how
        // one person's name ended up seeded into every stranger's transcript.
        return "We were talking about \(deduped.joined(separator: ", "))."
    }

    // The set of individual lowercased WORDS that make up the vocab roster
    // (brand terms, project display names, slang), split apart. Used to detect
    // when Whisper regurgitates the prompt roster verbatim on a silent/noisy
    // capture ("IOS Describedesign V2, Northwind"), so that echo can be rejected
    // before it is auto-sent as a chat message. Common single English words the
    // roster happens to contain ("focus", "ambient", "claude") are excluded so
    // an ordinary sentence is never mistaken for an echo.
    static func rosterWordSet() -> Set<String> {
        let slangTerms = ProfileMemoryStore.shared.slang.prefix(25).map { $0.term }
        let combined = baseTerms + KnownProjects.displayNames() + slangTerms
        // Drop only words that ALSO occur in ordinary English, so a normal
        // sentence never registers as roster. Version/platform tokens like "v2"
        // or "ios" stay in (they signal the project-name list echoing through).
        let stop: Set<String> = ["focus", "ambient", "wake", "word", "ai", "the", "of", "and", "city", "command", "deep", "render", "claude", "opus", "sonnet", "haiku"]
        var words = Set<String>()
        for term in combined {
            for w in term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let s = String(w)
                if s.count >= 2 && !stop.contains(s) { words.insert(s) }
            }
        }
        return words
    }

    // Token IDs, capped under Whisper's 224-token prompt buffer.
    static func buildPromptTokens(tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer else { return nil }
        let text = buildPrompt()
        let tokens = tokenizer.encode(text: text)
        // Whisper's prompt context is 224 tokens; leave slack for prefill.
        // If we overflow, drop slang tail (base terms stay).
        if tokens.count <= 200 { return tokens }
        return Array(tokens.prefix(200))
    }
}
