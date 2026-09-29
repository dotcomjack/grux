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
        let fallback = firstUserLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, isFitToShow(fallback) else { return neutralDefault }
        return trimmed(fallback.prefix(1).uppercased() + fallback.dropFirst())
    }

    private static func trimmed(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLength else { return t }
        return String(t.prefix(maxLength - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }
}
