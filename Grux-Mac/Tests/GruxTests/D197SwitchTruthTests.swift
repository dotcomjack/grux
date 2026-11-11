import XCTest
import AVFoundation
@testable import Grux

/// D197 item 9 (sense pass 27): Appearance read "Animate window edges red/green
/// when I drift or re-focus" on with screen analysis never running, and Ambient's
/// crash-safe capture read on under a caption in jargon ("PCM through Whisper")
/// with a file path, on a Mac where nothing had ever been recorded.
@MainActor
final class D197SwitchTruthTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The red and green edges come only from screen analysis verdicts
    /// (`FocusWatcher.handleTransition`), so the switch reads on only while it runs.
    func test_driftGlowReadsOnOnlyWhileScreenAnalysisRuns() {
        for choice in [true, false] {
            for analysis in [true, false] {
                for granted in [true, false] {
                    let runs = analysis && granted
                    XCTAssertEqual(DriftGlowToggleTruth.shown(choice: choice, analysisOn: analysis, granted: granted),
                                   choice && runs, "choice \(choice) analysis \(analysis) granted \(granted)")
                    XCTAssertEqual(DriftGlowToggleTruth.usable(analysisOn: analysis, granted: granted), runs)
                    let line = DriftGlowToggleTruth.line(analysisOn: analysis, granted: granted)
                    if runs {
                        XCTAssertNil(line)
                    } else {
                        // Wave 68 round 1: the line names exactly what is missing.
                        XCTAssertEqual(line?.contains("turn on screen analysis") == true, !analysis, line ?? "nil")
                        XCTAssertEqual(line?.contains("Screen Recording") == true, !granted, line ?? "nil")
                        // Round 2: the screen analysis switch is greyed until
                        // Screen Recording is allowed, so that step comes first.
                        if !analysis, !granted {
                            let rec = line?.range(of: "Screen Recording")
                            let an = line?.range(of: "turn on screen analysis")
                            XCTAssertNotNil(rec, line ?? "nil")
                            XCTAssertNotNil(an, line ?? "nil")
                            if let rec, let an { XCTAssertLessThan(rec.lowerBound, an.lowerBound, line ?? "nil") }
                        }
                    }
                }
            }
        }
    }

    /// Wave 68 round 1: the cyan speaking pulse went through the same gate as the
    /// drift edges, so greying the drift switch (read off) could hide a pulse whose
    /// own switch read on. Each kind of edge follows its own switch.
    func test_eachGlowFollowsItsOwnSwitch() {
        for drift in [true, false] {
            for speaking in [true, false] {
                XCTAssertEqual(GlowOverlayController.allows(.distracted, driftEdges: drift, speakingPulse: speaking), drift)
                XCTAssertEqual(GlowOverlayController.allows(.focused, driftEdges: drift, speakingPulse: speaking), drift)
                XCTAssertEqual(GlowOverlayController.allows(.speaking, driftEdges: drift, speakingPulse: speaking), speaking)
            }
        }
    }

    func test_theGlowControllerAsksTheRuleNotTheDriftSwitchAlone() throws {
        let controller = try source("Sources/Grux/GlowOverlayController.swift")
        XCTAssertFalse(controller.contains("guard AppState.shared.config.glowOverlayEnabled else"),
                       "a glow is still gated on the drift switch alone")
        XCTAssertTrue(controller.contains("Self.allows(colorMode"), "the controller does not ask the rule")
    }

    func test_appearanceTogglesThroughTheRule() throws {
        let view = try source("Sources/Grux/DesignSystem/AppearanceSettingsView.swift")
        guard let at = view.range(of: "Toggle(\"Animate window edges red/green") else {
            return XCTFail("the drift glow toggle moved; point this test at it")
        }
        let around = String(view[at.lowerBound...].prefix(900))
        XCTAssertTrue(around.contains("DriftGlowToggleTruth.shown("), "the toggle reads the config value alone")
        XCTAssertTrue(around.contains("DriftGlowToggleTruth.usable("), "the toggle stays live while it cannot act")
        XCTAssertTrue(around.contains("DriftGlowToggleTruth.line("), "no line says why it is off")
    }

    /// Plain words for every microphone state: no path, no jargon, honest that
    /// nothing is kept until a meeting is recorded, and (wave 68 round 1) true
    /// that the same switch keeps the WHOLE meeting's audio for Export WAV until
    /// the meeting is deleted (`AudioExportStore`), not only a rolling buffer.
    func test_crashSafeCaptionIsPlainAndSaysWhenItApplies() {
        let states: [AVAuthorizationStatus] = [.notDetermined, .denied, .restricted, .authorized]
        for on in [true, false] {
            for status in states {
                let line = CrashSafeAudioCaption.line(on: on, micStatus: status)
                for jargon in ["PCM", "Whisper", "~/", "Application Support", "audio-wal", "finalize", "utterances", "bloat", "safety-net"] {
                    XCTAssertFalse(line.contains(jargon), "\(status.rawValue): \(jargon) in \(line)")
                }
                XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
                XCTAssertFalse(line.contains("deleted when the meeting ends"), line)
                XCTAssertFalse(line.contains("loses nothing"), line)
                // Round 2: a promised delete must exist. D198 added one, in
                // Meetings (`MeetingStore.delete`), so a delete the caption
                // names is that one and no other.
                if line.lowercased().contains("delete") {
                    XCTAssertTrue(line.contains("delete its meeting in Meetings"), line)
                    XCTAssertFalse(line.contains("until you delete the meeting"), line)
                }
                // Round 3: the folder is inside the hidden Library, which Finder
                // search skips, so the caption names the button that opens it.
                XCTAssertTrue(line.contains(CrashSafeAudioCaption.showButton + ", below,"), line)
                XCTAssertTrue(line.contains("Finder"), line)
                if on {
                    XCTAssertTrue(line.contains("whole meeting"), line)
                    XCTAssertTrue(line.contains("crash"), line)
                } else {
                    // Off keeps the transcript and its notes (summary, action items).
                    XCTAssertTrue(line.contains("transcript and its notes"), line)
                    XCTAssertFalse(line.contains("only the transcript"), line)
                    // Round 3: true on a fresh Mac too, where nothing was kept.
                    XCTAssertTrue(line.contains("Any audio kept earlier"), line)
                }
            }
            for status in [AVAuthorizationStatus.notDetermined, .denied, .restricted] {
                let line = CrashSafeAudioCaption.line(on: on, micStatus: status)
                XCTAssertTrue(line.contains("Nothing is recorded"), "\(status.rawValue): \(line)")
                XCTAssertTrue(line.contains("microphone"), "\(status.rawValue): \(line)")
            }
            XCTAssertFalse(CrashSafeAudioCaption.line(on: on, micStatus: .authorized).contains("Nothing is recorded"))
            XCTAssertNotEqual(CrashSafeAudioCaption.line(on: on, micStatus: .notDetermined),
                              CrashSafeAudioCaption.line(on: on, micStatus: .denied),
                              "a refused microphone needs a different next step than an undecided one")
        }
    }

    func test_ambientCaptionComesFromTheRule() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Toggle(\"Keep meeting audio on this Mac\"") else {
            return XCTFail("the crash-safe toggle moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(600))
        XCTAssertTrue(around.contains("CrashSafeAudioCaption.line(on: state.config.crashSafeAudioEnabled"), "the caption is written by hand again")
        XCTAssertFalse(around.contains("PCM through Whisper"))
        // Round 3: the button the caption names is under it and opens the folder.
        let section = String(settings[at.lowerBound...].prefix(1200))
        XCTAssertTrue(section.contains("Button(CrashSafeAudioCaption.showButton)"), "the caption names a button that is not there")
        XCTAssertTrue(section.contains("NSWorkspace.shared.open(AudioExportStore.meetingAudioDir)"), "the button does not open the kept audio folder")
    }

    /// Wave 68 round 1: Remove in Credentials wrote an empty value, which left the
    /// item in place, so `exists` (attributes only) read a removed key as present.
    /// The suite's store now answers `exists` as the real Keychain does (the item
    /// is there or not), and an empty value removes the item.
    func test_anEmptiedKeyIsGone() {
        let slot = KeychainStore.Key.resendApiKey
        defer { KeychainStore.delete(slot) }
        XCTAssertTrue(KeychainStore.set(slot, "re_test_value"))
        XCTAssertTrue(KeychainStore.exists(slot))
        _ = KeychainStore.set(slot, "")
        XCTAssertFalse(KeychainStore.exists(slot), "an emptied key still reads as saved")
        XCTAssertEqual(KeychainStore.get(slot), "")
    }

    func test_theSuitesKeychainAnswersExistsLikeTheRealOne() throws {
        let store = try source("Sources/Grux/KeychainStore.swift")
        guard let at = store.range(of: "static func exists(") else { return XCTFail("exists moved") }
        let body = String(store[at.lowerBound...].prefix(300))
        XCTAssertTrue(body.contains("testItems[key.rawValue] != nil"),
                      "the suite's exists reads the value, so it cannot see an item left with an empty value")
    }
}
