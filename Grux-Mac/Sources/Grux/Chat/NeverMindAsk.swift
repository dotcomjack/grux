import Foundation

/// D170 item 6, sense pass 21 (12:29 AM Nov 5): "Actually never mind" after
/// three note asks waited 9.5 s on Grux Local 2B and came back "I hear you.
/// What's up?", as if the person had started a new conversation. A message
/// that only takes back the last ask is answered at once with no model, and
/// says what still waits in Approvals, since that is the one thing an earlier
/// ask may have left behind.
enum NeverMindAsk {
    static let reply = "Okay, I'll leave it."

    private static let leadIns: Set<String> = [
        "actually", "oh", "ok", "okay", "um", "uh", "hmm", "wait", "no", "sorry", "hey", "grux", "so", "oops", "ah",
    ]
    private static let tails: Set<String> = ["grux", "then", "thanks", "please"]
    private static let asks: Set<String> = [
        "never mind", "nevermind", "nvm", "forget it", "forget that", "forget about it", "cancel that",
        "scratch that", "don't worry about it", "dont worry about it", "no need", "ignore that",
        "disregard that", "skip it", "not now", "never mind that", "never mind then",
    ]

    /// Whether the whole message only takes back what was asked, after a
    /// lead-in ("Actually", "Oh, Grux") and before "then" or "thanks".
    /// "Never mind the weather, what's on my calendar?" asks something else
    /// and stays with the rest of chat.
    static func matches(_ text: String) -> Bool {
        var words = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: ".,!?;:").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
        while let last = words.last, tails.contains(last), words.count > 1 { words.removeLast() }
        // A lead-in can open an ask itself ("no need"), so each shape is tried
        // before the next lead-in comes off (W57-FIX round 2).
        while true {
            if asks.contains(words.joined(separator: " ")) { return true }
            guard let first = words.first, leadIns.contains(first), words.count > 1 else { return false }
            words.removeFirst()
        }
    }

    /// The reply, with what Approvals holds when anything waits there.
    /// `waiting` is the summaries of what waits now.
    /// `cancelled` is the title of a card whose undo window this message closed.
    @MainActor
    static func reply(for text: String, waiting: [String], cancelled: String? = nil) -> String? {
        guard matches(text) else { return nil }
        // W57-FIX 2: "I'll leave it" would be false of a card still counting down.
        let first = cancelled.map { "Okay, I cancelled \u{201C}\($0)\u{201D} before it ran." } ?? reply
        guard !waiting.isEmpty else { return first }
        return first + "\n\n" + ActionClaimGuard.approvalsLine(waiting)
    }
}
