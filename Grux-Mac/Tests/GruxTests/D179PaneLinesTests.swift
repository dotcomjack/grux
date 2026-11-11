import XCTest
@testable import Grux

/// D179 (sense pass 22): Settings lines that were not true of the Mac they sat on.
@MainActor
final class D179PaneLinesTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Item 14: the stage caption named Claude on a Mac without it

    /// "Claude decides when a beat deserves it" (`settings-appearance-page1.png`)
    /// on a Mac whose chat runs on Grux Local. The stage tool is offered to
    /// whichever model chat runs on, so the line names no provider.
    func test_theStageCaptionNamesNoProvider() {
        let line = AppearanceSettingsView.brandCaption
        for provider in ["Claude", "Anthropic", "OpenAI", "Grux Local", "Ollama"] {
            XCTAssertFalse(line.contains(provider), "\(provider): \(line)")
        }
        XCTAssertTrue(line.contains("the model your chat runs on decides when a moment deserves it"), line)
        XCTAssertFalse(line.contains("beat"), "a beat is jargon: \(line)")
    }

    func test_theAppearancePaneDrawsTheTestedCaption() throws {
        let src = try source("Sources/Grux/DesignSystem/AppearanceSettingsView.swift")
        XCTAssertTrue(src.contains("Text(Self.brandCaption)"), "the pane draws the tested line")
        XCTAssertFalse(src.contains("Claude decides"), "no second copy of the old line")
    }

    // MARK: - Item 13: the hue caption read as refusing what the pane kept

    /// "Choices that drop chip text under 3:1, or accent text and rims below
    /// WCAG AA, are previewed but refused" sat under "Below WCAG AA: chip text
    /// on accent, 4.2:1 (needs 4.5:1)" for a hue the pane KEPT
    /// (`settings-appearance-1.png`). The caption is built from the audit's own
    /// floors, says which band is kept with a warning and which is refused, and
    /// the rule it states agrees with `requestAccentHue` on every whole hue.
    func test_theHueCaptionSaysWhatIsKeptAndWhatIsRefused() {
        let line = AppearanceSettingsView.hueCaption
        let chip = ThemeConfig.previewAudit(forHue: ThemeConfig.canonicalAccentHue).checks
            .first { $0.name == ThemeConfig.chipTextPairName }!
        let aa = ThemeWCAGAuditResult.shown(chip.wcagAA), floor = ThemeWCAGAuditResult.shown(chip.required)
        XCTAssertTrue(line.contains("kept"), line)
        XCTAssertTrue(line.contains("refused"), line)
        XCTAssertTrue(line.contains("\(aa):1") && line.contains("\(floor):1"),
                      "the caption names the chip text's AA bar and Grux's floor: \(line)")
        XCTAssertFalse(line.contains("previewed but refused"), "the old line: \(line)")
        // The kept-with-a-warning band exists on this palette, or the caption would describe nothing.
        let kept = (0..<360).map { ThemeConfig.previewAudit(forHue: Double($0)) }.filter { $0.passes && !$0.meetsAA }
        XCTAssertFalse(kept.isEmpty, "control: no hue is kept below AA, so the caption's middle band is false")
    }

    func test_theAppearancePaneDrawsTheTestedHueCaption() throws {
        let src = try source("Sources/Grux/DesignSystem/AppearanceSettingsView.swift")
        XCTAssertTrue(src.contains("Text(Self.hueCaption)"), "the pane draws the tested line")
        XCTAssertFalse(src.contains("previewed but refused"), "no second copy of the old line")
    }
}

/// D179 item 12 (`settings-capabilities-page1.png`): "Not searching now: offline
/// mode is on ..." on a Mac with no Brave key, so turning offline mode off
/// still would not search and nothing said why. Every combination, against
/// the rule in plain words: each thing that stops a search is named.
@MainActor
final class D179WebSearchLineTests: XCTestCase {

    func test_everyBlockerIsNamedInEveryCombination() {
        for offline in [false, true] {
            for enabled in [false, true] {
                for key in [false, true] {
                    let line = WebResearch.settingsLine(offline: offline, enabled: enabled, hasSearchKey: key, chatMovesToClaude: true)
                    let label = "offline \(offline) enabled \(enabled) key \(key)"
                    guard enabled else { XCTAssertNil(line, "the switch already reads off: \(label)"); continue }
                    XCTAssertEqual(line?.contains("offline mode is on") ?? false, offline, "\(label): \(line ?? "nil")")
                    XCTAssertEqual(line?.contains("Brave Search key") ?? false, !key, "\(label): \(line ?? "nil")")
                    XCTAssertEqual(line == nil, !offline && key, label)
                }
            }
        }
        XCTAssertEqual(WebResearch.settingsLine(offline: true, enabled: true, hasSearchKey: false, chatMovesToClaude: true),
                       "Not searching now: offline mode is on, and a search sends your question to Brave Search. "
                       + "Turn offline mode off in Settings, Models to use it; turning it off also moves chat to Claude. Web search also needs a Brave Search key, under Credentials above.")
    }

    func test_theSwitchReadsTheWholeState() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("WebResearch.settingsLine(offline: state.offlineMode,"), "the switch reads one blocker only")
    }
}

/// D179 item 11 (`settings-ambient-1.png`): "The microphone stays closed until
/// you choose Allow listening, then Turn it on." sat beside a switch titled
/// "Listen on this Mac's microphone" shown on, and no "Turn it on" anywhere on
/// screen. The note says where Turn it on appears, and the switch says it
/// picks which microphone listening uses, not whether Grux listens.
final class D179ListeningLinesTests: XCTestCase {

    func test_theClosedNoteSaysWhereTurnItOnIs() {
        XCTAssertEqual(ListeningSection.closedNote,
                       "The microphone stays closed until you choose Allow listening, then Turn it on in the box that opens.")
    }

    /// Wave 61 review: "this Mac's own microphone" is false on a Mac mini,
    /// Studio or Pro, which has none; `ListeningMicPolicy.inputToUse` then
    /// stays put. The switch says what it avoids, true on every Mac.
    func test_theMicrophoneSwitchSaysItPicksWhichMicrophone() {
        let copy = ListeningSection.micCopy
        XCTAssertNotEqual(copy.title, "Listen on this Mac's microphone", "reads as listening being on")
        // Round 2: a wired headset is left alone (only wireless and phone
        // microphones drop to call quality), and `inputToUse` falls back to
        // the built-in microphone or the one chosen for Grux, never to any
        // other plugged-in one.
        XCTAssertEqual(copy.title, "When listening, keep off wireless headphone and phone microphones")
        XCTAssertFalse(copy.title.contains("own microphone"), copy.title)
        XCTAssertFalse(copy.body.contains("stays on the Mac's own"), copy.body)
        XCTAssertFalse(copy.body.contains("plugged into this Mac"), copy.body)
        XCTAssertTrue(copy.body.contains("listening moves to this Mac's built-in microphone, or to the microphone you chose for Grux, and stays where it is when there is neither."), copy.body)
    }
}
