import Foundation

/// A thread title is the one piece of a conversation a person sees in a list
/// for months. It must never be the app's internal account of what went wrong.
///
/// Measured 2026-09-20 on the running app: two of the eight visible threads
/// were titled from error text, because the title generator is handed the
/// whole thread including the notice bubbles and dutifully summarises the
/// failure. The fix is in two halves: notices never reach the generator, and
/// whatever does come back is checked before it is shown.
enum ChatTitleHygiene {
    static let maxLength = 60
    static let neutralDefault = "New chat"

    /// A number that reads as a status code: three digits in the 100 to 599
    /// range sitting next to a word that frames it as one. A bare "400 unit
    /// run" is a quantity and must survive, which is why this is not simply
    /// a search for three digits.
    private static let statusPattern = try? NSRegularExpression(
        pattern: "(?i)\\b(http|https|status|code|error|err|rate.?limited|timeout|malformed)\\b[^a-z0-9]{0,12}[1-5][0-9]{2}\\b"
            + "|\\b[1-5][0-9]{2}\\b[^a-z0-9]{0,12}(?i)\\b(error|status|response|returned|rate.?limited|timed?.?out|too many)\\b")

    static func isFitToShow(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        guard let re = statusPattern else { return true }
        return re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)) == nil
    }

    /// The generated title when it is fit, the person's own opening line when
    /// it is not, and the neutral default when there is nothing to fall back
    /// on. Never returns something unfit.
    static func clean(generated: String, firstUserLine: String) -> String {
        if isFitToShow(generated) { return trimmed(generated) }
        // The first line only: a first message can be a pasted log or several
        // paragraphs, and a title is one line in the rail.
        let fallback = firstUserLine.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !fallback.isEmpty, isFitToShow(fallback) else { return neutralDefault }
        return trimmed(fallback.prefix(1).uppercased() + fallback.dropFirst())
    }

    /// The generated title when it is fit AND shares a word with what the
    /// person wrote; otherwise the person's first fit line that is not only a
    /// greeting (their first fit line when every line is one); otherwise the
    /// neutral default.
    ///
    /// Sense pass 31 (2026-11-09, grux-local:2b) measured "weather and task
    /// assistant" over a person who asked "What can you do?" and "whats your
    /// name" over one who asked "Who are you?": the model named Grux's reply,
    /// or guessed. A title is a label for what the person asked, so it must be
    /// built from their words.
    static func clean(generated: String, userLines: [String]) -> String {
        if isFitToShow(generated), isGrounded(generated, in: userLines) { return trimmed(generated) }
        let fit = userLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isFitToShow($0) }
        guard let line = fit.first(where: { !isOnlyGreeting($0) }) ?? fit.first else { return neutralDefault }
        return trimmed(line.prefix(1).uppercased() + line.dropFirst())
    }

    /// Small words say nothing about what a chat is about, so they neither
    /// count for a title nor against it.
    private static let smallWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "for", "in", "on", "at", "by", "with", "about",
        "from", "into", "my", "your", "you", "me", "i", "im", "we", "our", "us", "it", "its", "is", "are",
        "was", "be", "this", "that", "what", "whats", "how", "why", "who", "whos", "when", "where", "which",
        "can", "could", "would", "should", "do", "does", "did", "will", "please", "tell", "some", "any",
        "chat", "question", "questions", "hi", "hello", "hey", "there", "thanks", "thank",
    ]

    private static let greetingWords: Set<String> = [
        "hi", "hello", "hey", "hiya", "yo", "there", "good", "morning", "afternoon", "evening",
        "thanks", "thank", "you", "ok", "okay", "cool", "great",
    ]

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Two words match when they are the same, or when both have at least
    /// four letters and share their first four ("trip" and "trips", "plan"
    /// and "planning"). A three-letter word matches only itself, so "api"
    /// never matches "apiary".
    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.prefix(4) == b.prefix(4)
    }

    static func isGrounded(_ title: String, in userLines: [String]) -> Bool {
        let titleWords = words(title).filter { !smallWords.contains($0) }
        guard !titleWords.isEmpty else { return false }
        let said = userLines.flatMap(words)
        return titleWords.contains { t in said.contains { sameWord(t, $0) } }
    }

    private static func isOnlyGreeting(_ line: String) -> Bool {
        words(line).allSatisfy { greetingWords.contains($0) }
    }

    private static func trimmed(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLength else { return t }
        return String(t.prefix(maxLength - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }
}
