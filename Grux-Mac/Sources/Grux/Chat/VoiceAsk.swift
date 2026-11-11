import Foundation

/// "How do I make you read your replies out loud?" (D184), live on
/// grux-local:2b in sense pass 23 (12:27 AM Nov 7): "I don't have the ability
/// to speak out loud or generate audio directly. You'll need to use a voice
/// assistant or a separate app for that." Grux reads its replies aloud, and the
/// model had nothing in front of it that said so. A question about Grux's own
/// voice is answered here, from the switch (Tuning, Talks back) and the
/// session mute (the speaker button at the top of Chat), with no model.
enum VoiceAsk {

    private static let leadIns: Set<String> = ["hi", "hey", "hello", "grux", "ok", "okay", "so", "please"]
    private static let closings: Set<String> = ["grux", "please"]

    /// "<how> <do>": "how do I make you" + "read your replies out loud".
    private static let hows = [
        "how do i make you", "how can i make you", "how do i get you to", "how can i get you to",
        "can you", "could you", "will you", "can i make you", "can i get you to",
    ]
    private static let dos = [
        "read your replies out loud", "read your replies aloud", "read your answers out loud",
        "read your answers aloud", "read your responses out loud", "read your responses aloud",
        "read replies out loud", "read replies aloud", "read your replies to me", "speak your replies out loud",
        "talk", "speak", "talk to me", "speak to me", "talk out loud", "speak out loud", "talk back",
        "read out loud", "read aloud", "talk to me out loud",
    ]
    /// "How do I" and "How can I" open every turn-on and turn-off form.
    private static let openers = ["how do i", "how can i"]
    /// Asks for quiet: answered on screen only, never read aloud (wave 62).
    /// Every opener with every ending, so a second wording cannot slip past
    /// to the model, whose reply would be read aloud (wave 62 round 2).
    private static let quietEndings = [
        "turn off your voice", "turn your voice off", "make you stop talking", "get you to stop talking",
        "stop you talking", "stop you from talking", "make you stop speaking", "get you to stop speaking",
        "stop you speaking", "stop you from speaking", "mute you", "silence you", "make you be quiet",
        "turn off voice replies", "turn voice replies off", "turn off spoken replies", "turn spoken replies off",
        "turn off the voice", "turn the voice off", "turn off read aloud", "make you stop reading your replies out loud",
        "make you stop reading your replies aloud", "stop you reading aloud", "stop you from reading aloud",
        "stop you reading out loud", "stop you from reading out loud",
        // D189: the Tuning card's own name, as sense pass 24 asked it.
        "turn off talks back", "turn talks back off", "make you stop talking back", "stop you talking back",
    ]
    private static let loudEndings = [
        "turn on your voice", "turn your voice on", "unmute you", "turn on voice replies", "turn on spoken replies",
        "hear you", "hear your replies", "turn on talks back", "turn talks back on",
    ]
    /// Whole sentences: turning the voice on or off, and having one at all.
    private static let wholes: Set<String> = Set(openers.flatMap { o in quietEndings.map { "\(o) \($0)" } })
        .union(openers.flatMap { o in loudEndings.map { "\(o) \($0)" } })
        .union(["do you have a voice", "can i hear you", "can i hear your replies", "do you talk", "do you speak"])
    /// What may follow "thanks" or "thank you" in a sentence of only thanks
    /// ("Thanks so much.", "Thank you in advance."); "Thanks for the summary"
    /// is a sentence about something else.
    private static let thanksTail: Set<String> = ["so", "much", "a", "lot", "very", "in", "advance", "again"]

    private static func isThanks(_ words: [String]) -> Bool {
        let rest: ArraySlice<String>
        if words.first == "thanks" { rest = words.dropFirst() }
        else if words.starts(with: ["thank", "you"]) { rest = words.dropFirst(2) }
        else { return false }
        return rest.allSatisfy { thanksTail.contains($0) }
    }
    private static let asks: Set<String> = wholes.union(hows.flatMap { h in dos.map { "\(h) \($0)" } })

    /// Whether the message is this ask: one sentence asks it, read word for
    /// word after a greeting or "Grux," and before a closing "Grux" or
    /// "please", and any other sentence is only a greeting. "Can you speak
    /// Spanish?" and "Can you talk to Sam for me?" ask something else.
    static func matches(_ text: String) -> Bool { askedSentences(text)?.isEmpty == false }

    /// Whether this ask is for quiet ("How do I make you stop talking?"): its
    /// answer says what is true now, not "Turn on".
    static func asksForQuiet(_ text: String) -> Bool { matches(text) && isQuietQuestion(text) }

    /// Messages this long are about something else that mentions quiet.
    static let quietWordLimit = 24

    /// Whether a short message is about quieting Grux, in any wording: the
    /// reply to it, from this fast path or from the model, is never read
    /// aloud (wave 62 round 3: lists of wordings kept missing one). Broad on
    /// purpose: a false match leaves one reply unread, the safe side.
    static func isQuietQuestion(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !words.isEmpty, words.count <= quietWordLimit else { return false }
        let t = " " + words.joined(separator: " ") + " "
        if [" mute ", " silence ", " quiet ", " shut up ", " shut you up ", " hush ", " you stop ", " stop you "]
            .contains(where: t.contains) { return true }
        // Round 4 added the Tuning card's own name ("Talks back") and plain words for sound.
        let voice = [" voice ", " spoken ", " speech ", " aloud ", " loud ", " talking ", " speaking ", " reading ",
                     " read ", " talk ", " talks ", " speak ", " speaks ", " saying ", " sound ", " audio ", " tts "]
        return [" stop ", " off ", " disable "].contains(where: t.contains) && voice.contains(where: t.contains)
    }

    /// Whether the reply to this ask is read aloud: only when replies are,
    /// and never to someone asking for quiet.
    static func speaksReply(to text: String, speaks: Bool, muted: Bool) -> Bool {
        speaks && !muted && !isQuietQuestion(text)
    }

    /// The sentences that ask it, after greetings and closings, or nil when
    /// any sentence asks something else.
    private static func askedSentences(_ text: String) -> [String]? {
        var asked: [String] = []
        for sentence in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { ".!?\n".contains($0) }) {
            var words = sentence.split { !$0.isLetter && $0 != "'" }.map(String.init)
            while let first = words.first, leadIns.contains(first) { words.removeFirst() }
            // "How do I mute you, thanks?": a closing thanks, "Grux" or "please".
            while let last = words.last {
                if closings.contains(last) || last == "thanks" { words.removeLast() }
                else if words.count > 2, words.suffix(2) == ["thank", "you"] { words.removeLast(2) }
                else { break }
            }
            guard !words.isEmpty, !isThanks(words) else { continue }
            let joined = words.joined(separator: " ")
            guard asks.contains(joined) else { return nil }
            asked.append(joined)
        }
        return asked
    }

    static let switchName = "\u{201C}Speak Grux's replies aloud\u{201D}"
    private static var whereSwitch: String { "in Tuning, under \(TuningCopy.Card.talks.title)" }

    /// The reply for this Mac now. `speaks` is the switch (`speakRepliesAloud`),
    /// `muted` the session mute, `silenced` `AudioOutput.isSilent`.
    /// Where the session mute is: Chat's header, right before Clear
    /// (`ChatView.heroHeader`, pinned by VoiceAskTests). It said "beside the
    /// message box", where Dictate and Send sit (wave 62).
    static let muteButton = "the speaker button at the top of Chat, beside Clear"

    /// `quiet` is `asksForQuiet` on the person's message.
    static func reply(speaks: Bool, muted: Bool, silenced: Bool, quiet: Bool = false) -> String {
        let voicePane = "Settings, \(SettingsPane.voiceAmbient.label)"
        if silenced {
            return "I read my replies aloud when \(switchName) is on \(whereSwitch), but this Mac keeps me silent "
                + "right now, so nothing is heard. \(voicePane) says why."
        }
        if quiet {
            guard speaks else {
                return "I am not reading my replies aloud now: \(switchName) \(whereSwitch) is off, and stays off "
                    + "until you turn it on."
            }
            if muted {
                return "My replies are muted for now, so nothing is read aloud. To stop for good, turn off "
                    + "\(switchName) \(whereSwitch)."
            }
            return "To quiet me for now, click \(muteButton); to stop for good, turn off \(switchName) "
                + "\(whereSwitch)."
        }
        guard speaks else {
            // Turning the switch on does not clear the session mute.
            let unmute = muted ? ", then click \(muteButton), to unmute," : ""
            return "Turn on \(switchName) \(whereSwitch)\(unmute) and I will read my replies aloud. \(TuningCopy.title) "
                + "is the first section of Settings, General; the voice I use is in \(voicePane)."
        }
        if muted {
            return "My replies are set to be read aloud, but they are muted for now: click \(muteButton) to hear "
                + "them again. The switch itself is \(switchName) \(whereSwitch)."
        }
        return "I read my replies aloud now. To quiet me for now, click \(muteButton); to stop for good, turn off "
            + "\(switchName) \(whereSwitch). The voice I use is in \(voicePane)."
    }
}
