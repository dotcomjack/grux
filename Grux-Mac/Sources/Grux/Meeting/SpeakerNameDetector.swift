import Foundation

// Cheap transcript-based name detector, modeled after Omi's
// SPEAKER_IDENTIFICATION_PATTERNS. Looks for self-introduction phrases and
// emits a candidate name the diarizer can attach to the cluster that uttered
// them. Does NOT auto-enroll - the UI surfaces the hint and the user confirms.
//
// English-only for v2. Adding localized patterns is a drop-in expansion of
// the `patterns` array (see Omi's multilingual table).
enum SpeakerNameDetector {

    struct Hint: Equatable {
        let name: String
        let sourceText: String   // the matched phrase, for UI debuggability
    }

    // First capture group is the candidate name. `\\p{Lu}` catches any
    // capitalized letter so the "John" in "My name is John Doe" is picked up
    // regardless of UTF-8 class; NSRegularExpression handles unicode.
    private static let patterns: [NSRegularExpression] = {
        let rawPatterns = [
            #"(?i)\bmy\s+name\s+is\s+([A-Z][a-zA-Z'’\-]{1,24})\b"#,
            #"(?i)\bi\s+am\s+([A-Z][a-zA-Z'’\-]{1,24})\b"#,
            #"(?i)\bi['’]m\s+([A-Z][a-zA-Z'’\-]{1,24})\b"#,
            #"(?i)\bthis\s+is\s+([A-Z][a-zA-Z'’\-]{1,24})\s+(?:speaking|here)\b"#,
            #"(?i)\b([A-Z][a-zA-Z'’\-]{1,24})\s+speaking\b"#,
            #"(?i)\b([A-Z][a-zA-Z'’\-]{1,24})\s+here\b"#,
            #"(?i)\bcall\s+me\s+([A-Z][a-zA-Z'’\-]{1,24})\b"#
        ]
        return rawPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // Common English words that pattern-match but aren't names. Filtered out
    // so "I'm Tired" doesn't enroll a contact named "Tired".
    private static let blacklist: Set<String> = [
        "a", "an", "the", "sorry", "not", "sure", "good", "fine", "okay", "ok",
        "tired", "happy", "sad", "done", "here", "back", "home", "busy",
        "listening", "going", "thinking", "ready", "waiting", "working",
        "trying", "saying", "talking", "running", "calling", "just"
    ]

    static func detect(in text: String) -> Hint? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for re in patterns {
            guard let match = re.firstMatch(in: text, range: range) else { continue }
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let candidate = String(text[nameRange])
            let canonical = candidate.prefix(1).uppercased() + candidate.dropFirst().lowercased()
            guard !blacklist.contains(canonical.lowercased()) else { continue }
            guard canonical.count >= 2 else { continue }
            let full = match.range(at: 0)
            let source = Range(full, in: text).map { String(text[$0]) } ?? candidate
            return Hint(name: canonical, sourceText: source)
        }
        return nil
    }
}
