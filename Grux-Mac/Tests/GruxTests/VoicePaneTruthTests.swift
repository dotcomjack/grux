import XCTest
@testable import Grux

/// D200 items 8 and 9 (sense pass 28): Settings, Voice read as if an ElevenLabs voice was
/// speaking on a Mac with the switch on by default and no key saved (the voice picker, a
/// "Jarvis-grade" switch, Test voice greyed out, the chat chip saying "by ElevenLabs"),
/// while `SpeechEngine` spoke with the macOS voice. The Whisper rows showed raw model ids
/// and a developer's reasons. Every line below reads the same gate the speech engine does.
final class VoicePaneTruthTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: who speaks, as the chat chip says it

    func test_theChipNamesTheVoiceThatActuallySpeaks() {
        // A fresh Mac: the switch defaults on, no key.
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: true, hasKey: false, offline: false, wouldAskForMic: false, silencedBy: []), "macOS")
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: true, hasKey: true, offline: true, wouldAskForMic: false, silencedBy: []), "macOS")
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: false, hasKey: true, offline: false, wouldAskForMic: false, silencedBy: []), "macOS")
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: true, hasKey: true, offline: false, wouldAskForMic: false, silencedBy: []), "ElevenLabs")
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: true, hasKey: true, offline: false, wouldAskForMic: false, silencedBy: ["HEADLESS"]),
                       "nobody, Grux is silenced on this Mac")
    }

    func test_theChatChipAsksTheEngineGateNotTheSwitch() throws {
        let chat = try source("Sources/Grux/ChatView.swift")
        XCTAssertFalse(chat.contains("state.config.useElevenLabs ? \"ElevenLabs\""),
                       "the chip still names ElevenLabs from the switch alone")
        let calls = chat.components(separatedBy: "VoiceEngineLogic.vendor(").dropFirst()
        XCTAssertEqual(calls.count, 1, "the chip's vendor should come from VoiceEngineLogic.vendor")
        XCTAssertTrue(calls.first?.prefix(300).contains("silencedBy: AudioOutput.silencedBy") ?? false)
    }

    // MARK: the ElevenLabs section says whether its voices are in use

    func test_theElevenLabsCaptionForEveryState() {
        func line(_ on: Bool, _ key: Bool, _ offline: Bool) -> String {
            VoiceEngineLogic.elevenSectionCaption(useElevenLabs: on, hasKey: key, offline: offline, wouldAskForMic: false)
        }
        let inUse = "Grux speaks your replies with the voice and model chosen here. Each reply is sent to ElevenLabs to be spoken."
        let noKeyOn = "None of these voices is in use: Grux speaks with the macOS voice until an ElevenLabs API key is saved here."
        let noKeyOff = "None of these voices is in use: Grux speaks with the macOS voice. To use one, save an ElevenLabs API key here and turn on Use ElevenLabs voice above."
        let keyOff = "None of these voices is in use: Use ElevenLabs voice is off above, so Grux speaks with the macOS voice."
        let offlineLine = "None of these voices is in use while offline mode is on: Grux speaks with the macOS voice."

        XCTAssertEqual(line(true, true, false), inUse)
        XCTAssertEqual(line(true, false, false), noKeyOn)
        XCTAssertEqual(line(false, false, false), noKeyOff)
        XCTAssertEqual(line(false, true, false), keyOff)
        XCTAssertEqual(line(true, true, true), offlineLine)
        // Offline with no key: the key is the first thing missing, and offline still wins
        // only once a key would otherwise make it speak.
        XCTAssertEqual(line(true, false, true), noKeyOn)
        XCTAssertEqual(line(false, false, true), noKeyOff)
        XCTAssertEqual(line(false, true, true), keyOff)

        // The oracle, in plain words: the caption says a voice here is in use exactly when
        // the speech engine would use ElevenLabs.
        for on in [false, true] { for key in [false, true] { for offline in [false, true] {
            let speaks = SpeechEngine.usesElevenLabs(choice: on, hasKey: key, offline: offline)
            XCTAssertEqual(line(on, key, offline).hasPrefix("Grux speaks your replies with the voice"), speaks,
                           "on \(on) key \(key) offline \(offline)")
            XCTAssertEqual(line(on, key, offline).hasPrefix("None of these voices is in use"), !speaks)
        } } }
    }

    func test_theSpokenRepliesSectionDropsTheJargonAndTheDeadTestButton() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertEqual(VoiceEngineLogic.elevenToggleLabel, "Use ElevenLabs voice")
        XCTAssertFalse(settings.contains("Jarvis-grade"))
        XCTAssertTrue(settings.contains("Toggle(VoiceEngineLogic.elevenToggleLabel"))
        // The engine falls back to the macOS voice with no key, so Test voice always speaks.
        XCTAssertFalse(settings.contains(".disabled(useEleven && elevenKey.isEmpty)"),
                       "Test voice is greyed out on a fresh Mac although the macOS voice would speak")
        XCTAssertFalse(settings.contains("Grux ships with one built-in voice"))
        XCTAssertTrue(settings.contains("VoiceEngineLogic.elevenSectionCaption("))
        // The preview plays only when an ElevenLabs voice would; otherwise it would speak
        // the macOS voice under the name of the voice picked.
        XCTAssertTrue(settings.contains(".disabled(!elevenSpeaks)"))
    }

    // MARK: item 8, the Whisper rows in words a person reads

    func test_theWhisperRowsCarryNoRawIdsOrDeveloperReasons() throws {
        let banned = ["openai_whisper", "medium.en", "WhisperKit", "Neural Engine", "in code",
                      "latency", "MB", "chunking", "instance", "+"]
        let lines = WhisperDeployment.all.flatMap { [$0.title, $0.detail] } + [WhisperDeployment.footer]
        for text in lines {
            for word in banned {
                XCTAssertFalse(text.contains(word), "\"\(word)\" in: \(text)")
            }
        }
        // Wave 70 P1: the first wording, "nothing you say is sent anywhere to be
        // transcribed", was false for the wake word (Apple's server recognition).
        XCTAssertEqual(WhisperDeployment.footer,
                       "Dictation and ambient listening are transcribed by Whisper on this Mac, not sent anywhere for that. The wake word is different: it uses Apple's speech recognition, which can send what it hears to Apple. Grux picks each model, so there is nothing to set here.")
        let view = try source("Sources/Grux/Audio/VoiceEnginePickerView.swift")
        XCTAssertFalse(view.contains("Text(dep.modelName)"), "the raw model id is still on screen")
        XCTAssertFalse(view.contains("Model choice is fixed in code"))
        XCTAssertTrue(view.contains("Text(WhisperDeployment.footer)"))
    }
}
