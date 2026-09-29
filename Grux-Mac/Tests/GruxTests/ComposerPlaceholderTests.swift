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
        XCTAssertEqual(c.label, "VOICE OFF")
    }

    func test_mutedBeatsSpeaking() {
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: true, isSpeaking: true).label,
                       "MUTED")
    }

    func test_speakingAndIdleReadDifferently() {
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: true).label,
                       "SPEAKING")
        XCTAssertEqual(VoiceStateChip.resolve(speakRepliesAloud: true, muted: false, isSpeaking: false).label,
                       "WILL SPEAK")
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

/// The vendor still shows. It is just smaller, and readable by anything that
/// cannot hover.
final class VendorGlyphTests: XCTestCase {
    func test_theCollapsedFormIsAMarkNotAWord() {
        XCTAssertEqual(VendorGlyph.collapsed, "ai")
        XCTAssertEqual(VendorGlyph.collapsed, VendorGlyph.collapsed.lowercased())
    }

    func test_theVendorNameIsAlwaysAvailableToSomethingThatCannotHover() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/DesignSystem/VendorGlyph.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 300, "VendorGlyph did not load")
        XCTAssertTrue(t.contains(".accessibilityLabel(vendor)"), "the glyph is unreadable to VoiceOver")
        XCTAssertTrue(t.contains(".help(vendor)"), "the glyph has no tooltip")
    }
}
