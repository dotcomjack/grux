import XCTest
@testable import Grux

/// Wave 70 review round 1 (`logs/wave70-review.txt`): five sentences on screen that the
/// build did not keep.
@MainActor
final class Wave70FixTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: P1, the wake word is not Whisper and can send audio to Apple

    func test_theWhisperRowsDoNotClaimTheWakeWord() {
        XCTAssertFalse(WhisperDeployment.dictation.title.contains("wake word"), WhisperDeployment.dictation.title)
        let footer = WhisperDeployment.footer
        XCTAssertFalse(footer.contains("nothing you say is sent anywhere"), footer)
        XCTAssertEqual(footer, "Dictation and ambient listening are transcribed by Whisper on this Mac, not sent anywhere for that. The wake word is different: it uses Apple's speech recognition, which can send what it hears to Apple. Grux picks each model, so there is nothing to set here.")
        XCTAssertFalse(WhisperDeployment.dictation.detail.contains("the first time you dictate"),
                       "the model also loads at launch once the microphone is allowed")
    }

    // MARK: P2, one saved switch: the Engine picker and the ElevenLabs switch are the same choice

    func test_theVoiceSwitchHasNoSecondCopy() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertFalse(settings.contains("@State private var useEleven"),
                       "a pane copy the Engine picker does not write")
        XCTAssertFalse(settings.contains("c.useElevenLabs = useEleven"), "Save would undo the Engine picker")
        XCTAssertTrue(settings.contains("Toggle(VoiceEngineLogic.elevenToggleLabel, isOn: elevenSwitch)"))
    }

    // MARK: P2, the engine plays the macOS voice until the microphone question is answered

    func test_everyReadoutKnowsTheMicrophoneFallback() {
        XCTAssertFalse(SpeechEngine.speaksWithElevenLabs(choice: true, hasKey: true, offline: false, wouldAskForMic: true))
        XCTAssertTrue(SpeechEngine.speaksWithElevenLabs(choice: true, hasKey: true, offline: false, wouldAskForMic: false))
        XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: true, hasKey: true, offline: false,
                                               wouldAskForMic: true, silencedBy: []), "macOS")
        XCTAssertEqual(VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: true, offline: false,
                                                     wouldAskForMic: true, silencedBy: []),
                       .system(fallbackReason: "the microphone question is not answered yet"))
        XCTAssertEqual(VoiceEngineLogic.elevenSectionCaption(useElevenLabs: true, hasKey: true, offline: false, wouldAskForMic: true),
                       "None of these voices is in use yet: Grux speaks with the macOS voice until macOS has asked about the microphone, the first time you dictate or allow listening.")

        // The oracle, in plain words: the caption says a voice here speaks exactly when the
        // speech engine would play ElevenLabs.
        for on in [false, true] { for key in [false, true] { for offline in [false, true] { for ask in [false, true] {
            let speaks = on && key && !offline && !ask
            XCTAssertEqual(SpeechEngine.speaksWithElevenLabs(choice: on, hasKey: key, offline: offline, wouldAskForMic: ask), speaks)
            let line = VoiceEngineLogic.elevenSectionCaption(useElevenLabs: on, hasKey: key, offline: offline, wouldAskForMic: ask)
            XCTAssertEqual(line.hasPrefix("Grux speaks your replies with the voice"), speaks, "\(on) \(key) \(offline) \(ask)")
            XCTAssertEqual(line.hasPrefix("None of these voices is in use"), !speaks)
            XCTAssertEqual(VoiceEngineLogic.vendor(useElevenLabs: on, hasKey: key, offline: offline,
                                                   wouldAskForMic: ask, silencedBy: []) == "ElevenLabs", speaks)
        } } } }
    }

    func test_theEngineAndTheReadoutsShareTheRule() throws {
        let engine = try source("Sources/Grux/SpeechEngine.swift")
        XCTAssertEqual(engine.components(separatedBy: "Self.speaksWithElevenLabs(").count - 1, 2,
                       "both speak paths should ask the one rule")
        XCTAssertFalse(engine.contains("&& !AudioOutput.outputWouldAskForMic"), "a second copy of the rule")
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("wouldAskForMic: AudioOutput.outputWouldAskForMic"))
        let chat = try source("Sources/Grux/ChatView.swift")
        XCTAssertTrue(chat.contains("wouldAskForMic: AudioOutput.outputWouldAskForMic"))
        let picker = try source("Sources/Grux/Audio/VoiceEnginePickerView.swift")
        XCTAssertTrue(picker.contains("wouldAskForMic: AudioOutput.outputWouldAskForMic"))
    }

    // MARK: P2, the proxy caption names exactly what the switch sends and reads the switch

    private let routes: [PrivacyAsk.Route] = [
        .thisMac(model: "Grux Local 2B"),
        .otherMachine(model: "qwen3.5:4b", host: "studio.local"),
        .anthropic,
        .custom(name: "OpenRouter", host: "openrouter.ai"),
        .none(step: "Connect a model"),
    ]

    func test_theProxyCaptionListsOnlyWhatTheSwitchSends() {
        for route in routes { for on in [false, true] {
            let text = AmbientProxyCopy.caption(route: route, proxyOn: on)
            XCTAssertFalse(text.contains("and the rest"), text)
            XCTAssertTrue(text.contains(AmbientProxyCopy.proxyJobs), text)
            XCTAssertTrue(text.contains("Other jobs, such as meeting summaries, ambient memories, the voice coach, dictation clean-up and thread titles, do not use this switch."), text)
        } }
    }

    func test_theProxyCaptionReadsTheSwitch() throws {
        for route in routes {
            let on = AmbientProxyCopy.caption(route: route, proxyOn: true)
            XCTAssertTrue(on.hasPrefix("On: Grux's background jobs (\(AmbientProxyCopy.proxyJobs)) go to your proxy."), on)
            XCTAssertFalse(on.contains("leave this off"), on)
            XCTAssertFalse(on.contains("already"), on)
            let off = AmbientProxyCopy.caption(route: route, proxyOn: false)
            XCTAssertFalse(off.contains("go to your proxy"), off)
        }
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("proxyOn: state.config.useLocalQwenForAmbient && !state.config.localLLMEndpoint.isEmpty"))
    }
}
