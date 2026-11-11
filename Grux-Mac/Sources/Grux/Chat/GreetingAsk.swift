import Foundation

/// D211, sense pass 32 (8:12 PM Nov 9): a stranger's first message "hey" waited
/// 8.5 s on Grux Local 2B and came back "Hey. How's your Monday off starting?",
/// a day off nobody mentioned (the same reply at 5:40 AM, D205 item 2). A
/// message that is only a greeting is answered at once with no model, and says
/// nothing about the person: in a chat that has asked nothing yet it names the
/// one ask that shows what works on this Mac.
enum GreetingAsk {
    static let reply = "Hi. What can I help with?"
    static let firstReply = "Hi. Ask me anything, or ask \u{201C}What can you do?\u{201D} to see what works on this Mac."

    private static let greetings: Set<String> = [
        "hi", "hey", "hello", "yo", "hiya", "heya", "howdy", "hey hey", "hi hi", "hello hello",
        "hi there", "hey there", "hello there", "hiya there", "hey you", "hi again", "hey again", "hello again",
        "good morning", "good afternoon", "good evening", "good day",
        "greetings", "hola",
    ]
    // A bare "Morning" or "Evening" can answer Grux's own question ("morning
    // or evening?"), and "What's up?" mid-chat can ask what happened, so
    // neither is a greeting here.
    private static let tails: Set<String> = ["grux", "there", "friend", "buddy"]
    private static let waves: Set<Character> = ["\u{1F44B}"]

    /// Whether the whole message is a greeting, with "Grux" or the assistant's
    /// own name (`name`) before or after it: "Hey Jax!", "Good morning, Grux",
    /// "👋". "Hey, what's on my calendar?" asks something and stays with the
    /// rest of chat, and so does "How are you?", a question the model answers.
    static func matches(_ text: String, name: String = "") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let letters = trimmed.filter { $0.isLetter }
        if letters.isEmpty {
            // A wave on its own (any skin tone); ":)" or "?" is not a greeting.
            return trimmed.unicodeScalars.contains { waves.contains(Character($0)) }
                && trimmed.allSatisfy { $0.isWhitespace || $0.isPunctuation || $0.isSymbol
                    || $0.unicodeScalars.allSatisfy { $0.properties.isEmoji || $0.properties.isEmojiPresentation } }
        }
        var words = SelfAsk.normalized(trimmed)
            .split { !$0.isLetter && $0 != "'" }.map(String.init)
        if let bare = SelfAsk.withoutName(words, name: name), !bare.isEmpty { words = bare }
        while words.count > 1, let last = words.last, tails.contains(last),
              !greetings.contains(words.joined(separator: " ")) { words.removeLast() }
        while words.count > 1, words.first == "grux" { words.removeFirst() }
        return greetings.contains(words.joined(separator: " "))
    }

    /// The reply, or nil when the message is not only a greeting. `earlier` is
    /// the person's earlier messages in this chat (`CapabilityAsk.earlierTurns`):
    /// while every one of them was an opening too, the reply names "What can you
    /// do?".
    static func reply(for text: String, earlier: [String], name: String = "") -> String? {
        guard matches(text, name: name) else { return nil }
        return earlier.allSatisfy { CapabilityAsk.isOpening($0, name: name) } ? firstReply : reply
    }
}
