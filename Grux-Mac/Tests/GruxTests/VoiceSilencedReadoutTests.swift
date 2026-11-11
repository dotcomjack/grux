import XCTest
@testable import Grux

/// D115 item 3: Settings, Voice drew a green "Active: system voice" while `~/.grux/SILENT`
/// or `~/.grux/HEADLESS` silenced every voice, so the pane promised speech that never
/// played. A silenced Mac is its own state of `EffectiveTTS`, ahead of every engine
/// choice, so each readout that switches on it has to say so.
final class VoiceSilencedReadoutTests: XCTestCase {
    func test_aSilencedMacReadsSilenced_whateverTheEngine() {
        for eleven in [true, false] {
            for key in [true, false] {
                for offline in [true, false] {
                    XCTAssertEqual(
                        VoiceEngineLogic.effectiveTTS(useElevenLabs: eleven, hasKey: key, offline: offline,
                                                      wouldAskForMic: false, silencedBy: ["HEADLESS"]),
                        .silenced(by: ["HEADLESS"]),
                        "eleven \(eleven) key \(key) offline \(offline)")
                }
            }
        }
    }

    func test_noSentinelLeavesTheEngineChoiceAsItWas() {
        XCTAssertEqual(VoiceEngineLogic.effectiveTTS(useElevenLabs: true, hasKey: true, offline: false, wouldAskForMic: false, silencedBy: []),
                       .elevenLabs)
        XCTAssertEqual(VoiceEngineLogic.effectiveTTS(useElevenLabs: false, hasKey: true, offline: false, wouldAskForMic: false, silencedBy: []),
                       .system(fallbackReason: nil))
    }

    func test_theStatusLineNamesTheFilesAndNeverSaysActive() {
        let one = VoiceEngineLogic.silencedLine(["HEADLESS"])
        XCTAssertEqual(one, "Silent (~/.grux/HEADLESS): Grux speaks nothing aloud and logs each reply it would have read.")
        let both = VoiceEngineLogic.silencedLine(["SILENT", "HEADLESS"])
        XCTAssertEqual(both, "Silent (~/.grux/SILENT and ~/.grux/HEADLESS): Grux speaks nothing aloud and logs each reply it would have read.")
        XCTAssertFalse(one.contains("Active"))
    }

    func test_thePaneAndTheCapabilityReadoutAskAboutSilence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["Sources/Grux/Audio/VoiceEnginePickerView.swift", "Sources/Grux/Onboarding/GruxControlTools+Model.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            let calls = text.components(separatedBy: "VoiceEngineLogic.effectiveTTS(").dropFirst()
            XCTAssertFalse(calls.isEmpty, "\(rel) no longer reads effectiveTTS; point this test at its readout")
            for call in calls {
                XCTAssertTrue(call.prefix(300).contains("silencedBy: AudioOutput.silencedBy"),
                              "\(rel) asks effectiveTTS without the files that silence Grux")
            }
        }
    }
}
