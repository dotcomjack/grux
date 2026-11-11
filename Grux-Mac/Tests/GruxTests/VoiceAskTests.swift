import XCTest
@testable import Grux

/// D184, live 2026-11-07 12:27 AM on grux-local:2b (sense pass 23): "How do I
/// make you read your replies out loud?" came back "I don't have the ability to
/// speak out loud or generate audio directly. You'll need to use a voice
/// assistant or a separate app for that." Grux reads its replies aloud: the
/// switch is Tuning, Talks back, "Speak Grux's replies aloud", and the speaker
/// button at the top of Chat, beside Clear, mutes it for the session. A question about
/// Grux's own voice is answered from those settings, with no model.
@MainActor
final class VoiceAskTests: XCTestCase {

    static let asks = [
        "How do I make you read your replies out loud?",
        "how do i make you read your replies aloud",
        "Can you read your replies out loud?",
        "Grux, can you talk?",
        "Can you speak?",
        "How do I get you to talk?",
        "How do I turn on your voice?",
        "How can I make you speak out loud?",
        "Hey Grux, can you read your answers aloud?",
        "Do you have a voice?",
        "How do I make you stop talking?",
        "How do I turn your voice off?",
        "How do I mute you?",
        "Can you talk to me?",
    ]

    /// Asks about something else that share the words: left with the model.
    static let notAsks = [
        "Can you speak Spanish?",
        "Can you talk me through setting up Notion?",
        "How do I make you read my emails?",
        "Read this out loud: hello there",
        "How do I make a speech sound confident?",
        "Can you talk to Sam for me?",
        "How do I mute my microphone?",
        "Write a toast I can read out loud",
        "How do I turn on my Mac's voice control?",
    ]

    func testAnAskAboutGruxsVoiceMatchesAndNothingElseDoes() {
        for ask in Self.asks { XCTAssertTrue(VoiceAsk.matches(ask), ask) }
        for ask in Self.notAsks { XCTAssertFalse(VoiceAsk.matches(ask), ask) }
    }

    /// Every state of the two switches, and the silenced Mac: each reply names
    /// where the switch is, and never says Grux cannot speak.
    func testTheReplySaysWhatIsTrueNowAndWhereTheSwitchIs() {
        let off = VoiceAsk.reply(speaks: false, muted: false, silenced: false)
        XCTAssertTrue(off.contains("Speak Grux's replies aloud"), off)
        XCTAssertTrue(off.contains("Tuning"), off)
        XCTAssertTrue(off.contains("Talks back"), off)
        XCTAssertTrue(off.contains("Turn on"), off)
        // Off with the session mute on too: turning the switch on does not
        // clear the mute, so the reply names both steps (wave 62 P3).
        let offMuted = VoiceAsk.reply(speaks: false, muted: true, silenced: false)
        XCTAssertTrue(offMuted.contains("Turn on"), offMuted)
        XCTAssertTrue(offMuted.contains("unmute"), offMuted)
        XCTAssertTrue(offMuted.contains(VoiceAsk.muteButton), offMuted)

        let on = VoiceAsk.reply(speaks: true, muted: false, silenced: false)
        XCTAssertTrue(on.hasPrefix("I read my replies aloud now."), on)
        XCTAssertTrue(on.contains("speaker button"), on)
        XCTAssertTrue(on.contains("Speak Grux's replies aloud"), on)

        let muted = VoiceAsk.reply(speaks: true, muted: true, silenced: false)
        XCTAssertTrue(muted.contains("muted"), muted)
        XCTAssertTrue(muted.contains("speaker button"), muted)
        XCTAssertFalse(muted.hasPrefix("I read my replies aloud now."), muted)

        for (speaks, isMuted) in [(true, false), (true, true), (false, false)] {
            let quiet = VoiceAsk.reply(speaks: speaks, muted: isMuted, silenced: true)
            XCTAssertTrue(quiet.contains("silent"), quiet)
            XCTAssertTrue(quiet.contains("Settings, Voice & Ambient"), quiet)
            XCTAssertFalse(quiet.hasPrefix("I read my replies aloud now."), quiet)
        }
        for reply in [off, on, muted, offMuted] {
            XCTAssertFalse(reply.lowercased().contains("can't speak"), reply)
            XCTAssertFalse(reply.contains("\u{2014}") || reply.contains("\u{2013}"), reply)
        }
    }

    /// The names the reply sends a person to are the ones on screen.
    func testTheNamesAreTheOnesOnScreen() {
        XCTAssertEqual(TuningCopy.Card.talks.title, "Talks back")
        XCTAssertEqual(SettingsPane.voiceAmbient.label, "Voice & Ambient")
        XCTAssertEqual(TuningCopy.title, "Tuning")
    }

    /// Wave 62 P2: the reply sent people to "the speaker button beside the
    /// message box", where Dictate and Send sit; a stranger who followed it
    /// started listening. The mute button is in Chat's header, right before
    /// Clear, and the reply names it from one constant.
    func testTheMuteButtonIsWhereTheReplySays() throws {
        XCTAssertEqual(VoiceAsk.muteButton, "the speaker button at the top of Chat, beside Clear")
        for speaks in [true, false] { for muted in [true, false] { for quiet in [true, false] {
            let r = VoiceAsk.reply(speaks: speaks, muted: muted, silenced: false, quiet: quiet)
            XCTAssertFalse(r.contains("message box"), r)
        } } }
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Grux/ChatView.swift"), encoding: .utf8)
        let header = try XCTUnwrap(src.range(of: "private var heroHeader: some View {"))
        let rest = src[header.upperBound...]
        let mute = try XCTUnwrap(rest.range(of: "muteVoiceButton"))
        let after = rest[mute.upperBound...].prefix(600)
        XCTAssertTrue(after.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Button {"), String(after))
        XCTAssertTrue(after.contains("Label(\"Clear\""), "the button after mute must be Clear: \(after)")
    }

    /// Wave 62 P2: "How do I make you stop talking?" was answered aloud, all of
    /// it, to the person asking for quiet. A quiet ask is answered on screen
    /// only, and the reply says what is true now instead of "Turn on".
    func testAnAskForQuietIsNeverReadAloud() {
        let quiet = ["How do I make you stop talking?", "How do I mute you?", "How do I silence you?",
                     "How do I make you be quiet?", "How do I turn your voice off?", "how do i turn off your voice",
                     "Grux, how do I stop you from talking?"]
        let loud = ["How do I make you read your replies out loud?", "Can you talk?", "How do I unmute you?",
                    "Do you have a voice?"]
        for ask in quiet {
            XCTAssertTrue(VoiceAsk.matches(ask), ask)
            XCTAssertTrue(VoiceAsk.asksForQuiet(ask), ask)
            for muted in [true, false] {
                XCTAssertFalse(VoiceAsk.speaksReply(to: ask, speaks: true, muted: muted), ask)
            }
        }
        for ask in loud {
            XCTAssertFalse(VoiceAsk.asksForQuiet(ask), ask)
            XCTAssertTrue(VoiceAsk.speaksReply(to: ask, speaks: true, muted: false), ask)
            XCTAssertFalse(VoiceAsk.speaksReply(to: ask, speaks: true, muted: true), ask)
            XCTAssertFalse(VoiceAsk.speaksReply(to: ask, speaks: false, muted: false), ask)
        }
        // Wave 62 round 2: the quiet forms were an exact list, so "How can I
        // mute you?" went to the model and its reply was read aloud. Every
        // opener with every quiet ending is a quiet ask, and a closing
        // "Thanks." does not send the message to the model.
        for ask in ["How can I make you stop talking?", "How can I mute you?", "How do I turn off voice replies?",
                    "How do I turn off spoken replies?", "How do I mute you? Thanks.", "How can I turn your voice off?",
                    "How do I mute you? Thank you, Grux.", "How do I make you stop speaking?"] {
            XCTAssertTrue(VoiceAsk.asksForQuiet(ask), ask)
            XCTAssertFalse(VoiceAsk.speaksReply(to: ask, speaks: true, muted: false), ask)
        }
        for ask in ["How can I turn on your voice?", "How can I unmute you?", "Can you talk? Thanks."] {
            XCTAssertTrue(VoiceAsk.matches(ask), ask)
            XCTAssertFalse(VoiceAsk.asksForQuiet(ask), ask)
        }
        XCTAssertFalse(VoiceAsk.matches("Thanks."))
        XCTAssertFalse(VoiceAsk.matches("How do I mute you? Thanks for the summary."))
        let offMuted = VoiceAsk.reply(speaks: false, muted: true, silenced: false)
        XCTAssertTrue(offMuted.contains("beside Clear, to unmute"), offMuted)
        let offQuiet = VoiceAsk.reply(speaks: false, muted: false, silenced: false, quiet: true)
        XCTAssertFalse(offQuiet.contains("Turn on"), offQuiet)
        XCTAssertTrue(offQuiet.hasPrefix("I am not reading my replies aloud now"), offQuiet)
        let onQuiet = VoiceAsk.reply(speaks: true, muted: false, silenced: false, quiet: true)
        XCTAssertTrue(onQuiet.contains(VoiceAsk.muteButton), onQuiet)
        XCTAssertTrue(onQuiet.contains("turn off"), onQuiet)
        let mutedQuiet = VoiceAsk.reply(speaks: true, muted: true, silenced: false, quiet: true)
        XCTAssertTrue(mutedQuiet.hasPrefix("My replies are muted for now"), mutedQuiet)
        XCTAssertFalse(mutedQuiet.contains("hear them again"), mutedQuiet)
    }

    /// Wave 62 round 3: wordings no list held ("How do I stop you reading
    /// aloud?", "turn off the voice", "Thanks so much.") went to the model and
    /// its reply was read aloud. Any short message about quieting Grux keeps
    /// every reply off the speaker, the model's too; a false match only
    /// leaves one reply unread, which is the safe side.
    func testAnyQuietQuestionKeepsTheReplyOffTheSpeaker() throws {
        let quiet = ["How do I make you stop reading your replies out loud?", "How do I stop you reading aloud?",
                     "How do I turn off the voice?", "How do I turn the voice off?", "How do I turn off read aloud?",
                     "How do I mute you? Thanks so much.", "How do I mute you? Thanks in advance.",
                     "How do I mute you, thanks?", "Please be quiet", "Stop talking", "how can i shut you up",
                     "Is there a way to silence Grux?", "Can I turn off spoken replies"]
        for ask in quiet {
            XCTAssertTrue(VoiceAsk.isQuietQuestion(ask), ask)
            XCTAssertFalse(VoiceAsk.speaksReply(to: ask, speaks: true, muted: false), ask)
        }
        for ask in ["How do I make you stop reading your replies out loud?", "How do I turn off the voice?",
                    "How do I mute you? Thanks so much.", "How do I mute you, thanks?"] {
            XCTAssertTrue(VoiceAsk.matches(ask), ask)
            XCTAssertTrue(VoiceAsk.asksForQuiet(ask), ask)
        }
        let loud = ["Can you talk?", "How do I make you read your replies out loud?", "Turn off the lights",
                    "What's the weather tomorrow?", "How do I unmute you?",
                    String(repeating: "This paragraph is long and mentions a quiet morning walk. ", count: 4)]
        for ask in loud {
            XCTAssertFalse(VoiceAsk.isQuietQuestion(ask), ask)
            XCTAssertTrue(VoiceAsk.speaksReply(to: ask, speaks: true, muted: false), ask)
        }
        // Wave 62 round 4: the Tuning card's own name and plain words for
        // sound were not voice words.
        for ask in ["How do I turn off Talks back?", "How do I turn off the sound?", "How do I turn the audio off?",
                    "How do I disable TTS?", "How can I make you stop?", "Stop saying it out loud"] {
            XCTAssertTrue(VoiceAsk.isQuietQuestion(ask), ask)
        }
        // The model's reply is gated by the same function, and read again at
        // every speech site, so muting mid-reply keeps the rest quiet (round
        // 4: it was a value taken once when the turn started). Every other
        // spoken reply in ChatService uses the same gate.
        let chat = try source("ChatService.swift")
        XCTAssertTrue(chat.contains("func speakAloud() -> Bool { VoiceAsk.speaksReply(to: userText, speaks: state.config.speakRepliesAloud,"),
                      "the model path must read VoiceAsk.speaksReply at each speech site")
        XCTAssertFalse(chat.contains("let speakAloud ="), "speakAloud must not be a value taken once per turn")
        XCTAssertFalse(chat.contains("speakRepliesAloud && !state.voiceMuted"), "every spoken reply goes through VoiceAsk.speaksReply")
    }

    /// Wave 62 round 3: SpeechEngine.stop tears down ElevenLabs only, so the
    /// system voice (a stranger's default, no key) kept reading after a quiet
    /// ask or the mute button. Both call `silenceNow`, which stops it too.
    func testQuietAndMuteStopTheSystemVoiceToo() throws {
        let engine = try source("SpeechEngine.swift")
        let body = try XCTUnwrap(engine.range(of: "func silenceNow(reason: String) {"))
        let rest = String(engine[body.upperBound...].prefix(400))
        XCTAssertTrue(rest.contains("stop(reason: reason)"), rest)
        XCTAssertTrue(rest.contains("Speaker.shared.stop()"), rest)
        XCTAssertTrue(rest.contains("cancelPendingPoliteSpeak()"), rest)
        let view = try source("ChatView.swift")
        let mute = try XCTUnwrap(view.range(of: "private var muteVoiceButton: some View {"))
        XCTAssertTrue(view[mute.upperBound...].prefix(500).contains("speech.silenceNow(reason: \"user voice-mute toggle\")"))
        let chat = try source("ChatService.swift")
        XCTAssertTrue(chat.contains("SpeechEngine.shared.silenceNow(reason: \"voice-ask asked for quiet\")"))
    }

    /// Wave 62 round 5 P3 (a regression from round 4): the stream was ended
    /// only inside `if speakAloud()`, so turning the switch off mid-reply left
    /// the streaming loop polling, `isSpeaking` true and the wake word off.
    /// A stream that started is always ended; only the fallback speak asks.
    func testAStreamThatStartedIsAlwaysEnded() throws {
        let chat = try source("ChatService.swift")
        XCTAssertFalse(chat.contains("if speakAloud() {\n                if streamSpeechActive {"),
                       "ending the stream must not depend on the switch read at the end of the turn")
        let site = try XCTUnwrap(chat.range(of: "if streamSpeechActive {\n                // A stream that started is always ended"))
        let after = chat[site.upperBound...].prefix(400)
        XCTAssertTrue(after.contains("SpeechEngine.shared.endStreaming()"), String(after))
        XCTAssertTrue(after.contains("} else if speakAloud() {"), String(after))
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Grux/\(name)"), encoding: .utf8)
    }

    /// The live turn, through the send path, with no model attached at all:
    /// no model could have written this reply.
    func testTheSendPathAnswersWithoutAModel() async {
        let state = AppState.shared
        let saved = (state.chat, state.config.speakRepliesAloud, state.offlineMode)
        defer { state.chat = saved.0; state.config.speakRepliesAloud = saved.1; state.offlineMode = saved.2 }
        state.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        state.chat = []
        state.config.speakRepliesAloud = false
        XCTAssertFalse(ChatReadiness.current().canSend, "control: chat must have no model for this to prove anything")
        await ChatService.shared.send(userText: "How do I make you read your replies out loud?")
        XCTAssertEqual(state.chat.map(\.role), [.user, .assistant])
        XCTAssertEqual(state.chat.last?.content, VoiceAsk.reply(speaks: false, muted: state.voiceMuted, silenced: true))
    }
}
