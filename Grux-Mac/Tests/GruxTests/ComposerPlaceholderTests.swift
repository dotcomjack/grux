import XCTest
@testable import Grux

/// The placeholder is the one line that tells a person the thing that is new
/// about 3.0. It has to be honest about the microphone.
final class ComposerPlaceholderTests: XCTestCase {

    func test_itInvitesSpeechOnlyWhenGruxIsActuallyListening() {
        for tell in [ListeningTell.armed, .speaking, .thinking] {
            XCTAssertTrue(ComposerPlaceholder.text(for: tell).lowercased().contains("out loud"),
                          "\(tell) does not invite speech")
        }
    }

    func test_itNeverInvitesSpeechIntoAMicrophoneThatIsNotListening() {
        for tell in [ListeningTell.muted, .off] {
            let t = ComposerPlaceholder.text(for: tell).lowercased()
            XCTAssertFalse(t.contains("say it out loud"),
                           "\(tell) invites speech at a microphone that is not on")
        }
    }

    func test_eachStateSaysWhatIsActuallyGoingOn() {
        XCTAssertTrue(ComposerPlaceholder.text(for: .muted).lowercased().contains("muted"))
        // The listening mode moved to Tuning in P-E-2, so that is where it says.
        XCTAssertTrue(ComposerPlaceholder.text(for: .off).lowercased().contains("tuning"),
                      "listening off does not say where to turn it on")
    }

    func test_everyStateStillSaysYouCanType() {
        for tell in ListeningTell.allCases {
            XCTAssertTrue(ComposerPlaceholder.text(for: tell).lowercased().contains("ask me anything"),
                          "\(tell) forgot that typing is still the main way in")
        }
    }
}

/// The chip beside it says what Grux's voice is DOING. The vendor that
/// produces it is a supplier, and suppliers live behind the glyph.
final class VoiceStateChipTests: XCTestCase {

    func test_voiceOffOutranksEverything() {
        let c = VoiceStateChip.resolve(speakRepliesAloud: false, muted: true, isSpeaking: true)
        XCTAssertEqual(c.label, "REPLIES SILENT")
    }

    func test_mutedBeatsSpeaking() {
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: true, isSpeaking: true).label,
                       "REPLIES MUTED")
    }

    func test_speakingAndIdleReadDifferently() {
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: true).label,
                       "SPEAKING REPLY")
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: false).label,
                       "REPLIES ALOUD")
    }

    /// Beside "MIC MUTED", "VOICE ON" read as the microphone being on (W4
    /// pass 2). No state of this chip may read as voice input.
    func test_noStateReadsAsTheMicrophone() {
        for (on, muted, speaking) in [(false, false, false), (true, true, false), (true, false, true), (true, false, false)] {
            let label = VoiceStateChip.resolve(speakRepliesAloud: on, muted: muted, isSpeaking: speaking).label
            XCTAssertFalse(label.hasPrefix("VOICE"), "\(label) reads as voice input")
            XCTAssertFalse(label.contains("MIC"), label)
        }
    }

    func test_noChipNamesAVendor() {
        let labels = [
            VoiceStateChip.resolve(speakRepliesAloud: false, muted: false, isSpeaking: false).label,
            VoiceStateChip.resolve(speakRepliesAloud: true, muted: true, isSpeaking: false).label,
            VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: true).label,
            VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: false).label,
        ]
        for l in labels {
            XCTAssertFalse(l.lowercased().contains("eleven"), "the chip is naming a vendor again: \(l)")
            XCTAssertFalse(l.lowercased().contains("tts"), "the chip is naming a subsystem again: \(l)")
        }
        XCTAssertEqual(Set(labels).count, 4, "two voice states share a word: \(labels)")
    }
}

/// Audit 2026-10-13, item 10, and the PR 34 review: the Return key, the Send
/// button and the composer's chips.
final class ChatComposerTests: XCTestCase {
    func test_returnAndSendShareOneRule() {
        XCTAssertTrue(ChatComposerSend.allowed(draft: "hi", hasImage: false, readiness: .ready))
        XCTAssertTrue(ChatComposerSend.allowed(draft: "  ", hasImage: true, readiness: .ready), "an image alone sends")
        XCTAssertFalse(ChatComposerSend.allowed(draft: " \n ", hasImage: false, readiness: .ready))
        for blocked in [ChatReadiness.needsModel, .localModelFoundButNotRouted, .offlinePinnedButNoLocalModel] {
            XCTAssertFalse(ChatComposerSend.allowed(draft: "hi", hasImage: true, readiness: blocked),
                           "\(blocked) lets a turn out that cannot succeed")
            let why = try? XCTUnwrap(ChatComposerSend.refusal(blocked))
            XCTAssertNotNil(why, "\(blocked) holds Return back without saying why")
            XCTAssertTrue(why?.hasPrefix("Not sent: ") == true, why ?? "")
        }
        XCTAssertNil(ChatComposerSend.refusal(.ready))
    }

    func test_theReturnKeyAndTheButtonBothAskTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
        let key = try XCTUnwrap(chat.components(separatedBy: ".onKeyPress(keys: [.return], phases: .down)").dropFirst().first).prefix(900)
        XCTAssertTrue(key.contains("ChatComposerSend.allowed("), "Return sends without the Send button's check")
        XCTAssertTrue(chat.contains(".disabled(!canSendDraft)"), "the button and Return use different rules")
        let send = try XCTUnwrap(chat.components(separatedBy: "private func send() {").dropFirst().first).prefix(300)
        XCTAssertTrue(send.contains("guard canSendDraft else"), "send() itself can still go out unready")
        XCTAssertTrue(chat.contains("ChatComposerSend.refusal(readiness)"), "the composer never says why")
    }

    /// PR 35 review: the chip that replaced VendorGlyph lost its accessibility
    /// label, so VoiceOver read "VOICE OFF" with no vendor.
    func test_theVoiceChipTellsVoiceOverWhoSpeaks() throws {
        XCTAssertEqual(ChatComposerSend.voiceChipLabel(state: "VOICE OFF", vendor: "macOS"),
                       "Grux's voice, voice off, by macOS")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
        let chip = try XCTUnwrap(chat.components(separatedBy: "private var speakIndicator: some View {").dropFirst().first).prefix(700)
        XCTAssertTrue(chip.contains(".accessibilityLabel(ChatComposerSend.voiceChipLabel("),
                      "the voice chip has no accessibility label of its own")
    }

    func test_theComposerOpensAtTwoLines() {
        XCTAssertEqual(ChatView.composerLines.lowerBound, 2)
        XCTAssertGreaterThan(ChatView.composerLines.upperBound, 2, "it must still grow")
    }

    func test_everyChipNamesItsNoun() {
        for tell in ListeningTell.allCases where tell != .speaking && tell != .thinking {
            let p = tell.phrase.uppercased()
            XCTAssertTrue(p.contains("LISTENING") || p.contains("MIC"), p)
        }
        for (speaks, muted, speaking) in [(false, false, false), (true, true, false), (true, false, true), (true, false, false)] {
            let label = VoiceStateChip.resolve(speakRepliesAloud: speaks, muted: muted, isSpeaking: speaking).label
            // The noun is the reply, not "VOICE", which read as voice input (W4).
            XCTAssertTrue(label.contains("REPL"), label)
        }
    }
}
