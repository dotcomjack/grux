import XCTest
@testable import Grux

final class VoiceEngineLogicTests: XCTestCase {

    // The effective-TTS function must mirror SpeechEngine.speak()'s gate:
    // useElevenLabs && key present && !offline. Everything else falls back to
    // the system voice, with a reason only when the user asked for ElevenLabs.

    func testElevenLabsActiveWhenToggledKeyedAndOnline() {
        XCTAssertEqual(
            VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: true, offline: false),
            .elevenLabs
        )
    }

    func testSystemByChoiceHasNoFallbackReason() {
        XCTAssertEqual(
            VoiceEngineLogic.effectiveTTS(useElevenLabs: false, hasKey: true, offline: false),
            .system(fallbackReason: nil)
        )
        // Toggle off wins regardless of key or offline state.
        XCTAssertEqual(
            VoiceEngineLogic.effectiveTTS(useElevenLabs: false, hasKey: false, offline: true),
            .system(fallbackReason: nil)
        )
    }

    func testOfflineForcesSystemWithReason() {
        let result = VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: true, offline: true)
        guard case .system(let reason) = result else {
            return XCTFail("expected system fallback, got \(result)")
        }
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("offline"))
    }

    func testMissingKeyForcesSystemWithReason() {
        let result = VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: false, offline: false)
        guard case .system(let reason) = result else {
            return XCTFail("expected system fallback, got \(result)")
        }
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("key"))
    }

    func testOfflineReasonTakesPriorityOverMissingKey() {
        // Both conditions true: the offline explanation is the more useful one
        // because fixing the key would not change the outcome.
        let result = VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: false, offline: true)
        guard case .system(let reason) = result, let r = reason else {
            return XCTFail("expected system fallback with reason, got \(result)")
        }
        XCTAssertTrue(r.contains("offline"))
    }

    func testElevenModelLabels() {
        XCTAssertEqual(VoiceEngineLogic.elevenModelLabel("eleven_turbo_v2_5"), "Turbo v2.5")
        XCTAssertEqual(VoiceEngineLogic.elevenModelLabel("eleven_multilingual_v2"), "Multilingual v2")
        XCTAssertEqual(VoiceEngineLogic.elevenModelLabel("eleven_flash_v2_5"), "Flash v2.5")
        XCTAssertEqual(VoiceEngineLogic.elevenModelLabel("eleven_future_v9"), "eleven_future_v9")
    }

    // Guard against the read-only display drifting from the real constants in
    // VoiceInput.swift / AmbientListener.swift. Those are private, so this
    // pins the mirrored strings to the values audited at authoring time; if a
    // model upgrade lands, this test points straight at the row to update.

    func testWhisperDeploymentsMirrorSourceConstants() {
        // Updated from "openai_whisper-medium.en" after checking which side was
        // stale, because making a mirror test pass by editing the assertion is
        // exactly how a real drift gets hidden. The real constant at
        // VoiceInput.swift:130 and this display mirror BOTH say
        // large-v3_turbo, so the model upgrade landed in the code and only the
        // test was left behind, which is the case its comment above describes.
        XCTAssertEqual(WhisperDeployment.dictation.modelName, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(WhisperDeployment.ambient.modelName, "openai_whisper-small.en")
        XCTAssertEqual(WhisperDeployment.all.count, 2)
        XCTAssertEqual(Set(WhisperDeployment.all.map(\.id)).count, 2, "deployment ids must be unique")
    }
}
