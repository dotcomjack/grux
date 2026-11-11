import XCTest
@testable import Grux

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// D157 items 5 and 6 (sense pass 19, `settings-general-page1.png`, Data &
/// Capabilities): Settings described a first run Grux no longer has ("the two
/// longer paths", "the tier picker", a first gate that asks for a model key),
/// said "Hand setup to your agent" had moved beside its own live button, and
/// showed "Let Grux answer questions by searching the web" switched on while
/// offline mode or a missing Brave key stopped every search. Each line is now
/// read from what the code does.
@MainActor
final class StrangerSettingsCopyTests: XCTestCase {

    /// Restart onboarding says what the first run is now: the question first,
    /// then what it picks, the name, a model, and setup for what was picked.
    func test_restartOnboardingDescribesTheFirstRunThereIs() throws {
        XCTAssertEqual(OnboardingModel.State.initial.stage, .prompt)
        XCTAssertEqual(OnboardingModel.questionStages.first, .prompt)
        for stage in [OnboardingModel.Stage.identity, .modelKey, .setup] {
            XCTAssertTrue(OnboardingModel.questionStages.contains(stage), "\(stage) left the first run")
        }
        let detail = OnboardingModel.restartDetail
        XCTAssertTrue(detail.hasPrefix("The main window switches to the first-run screens immediately"), detail)
        XCTAssertTrue(detail.contains("\u{201C}" + FirstPrompt.question + "\u{201D}"), detail)
        XCTAssertTrue(detail.contains("With a model key already saved, Connect a model offers \u{201C}Keep the key I have\u{201D}"), detail)
        XCTAssertFalse(OnboardingModel.restartSummary.isEmpty)
        // The button the copy names is still on the model key screen, behind a saved key.
        let screen = try macSource("Sources/Grux/Onboarding/OnboardingView.swift")
        XCTAssertTrue(screen.contains("if hasStoredKey {\n                    Button(\"Keep the key I have\")"),
                      "the copy names a button the model key screen no longer shows")

        let settings = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("Text(OnboardingModel.restartSummary)"), "Settings writes its own restart line")
        XCTAssertGreaterThanOrEqual(settings.components(separatedBy: "Text(OnboardingModel.restartDetail)").count - 1, 2,
                                    "the Settings caption and the question say different things")
        // What Settings puts on screen (a comment may name Models' own tier picker).
        let shown = settings.split(separator: "\n").filter { $0.contains("Text(") }.joined(separator: "\n")
        for stale in ["tier picker", "two longer paths", "one minute path", "The first gate asks for a model key",
                      "Now under Optimize Grux"] {
            XCTAssertFalse(shown.contains(stale), "Settings still says \(stale)")
            XCTAssertFalse(OnboardingModel.restartDetail.contains(stale) || OnboardingModel.restartSummary.contains(stale), stale)
        }
    }

    /// "Hand setup to your agent" says what its button does in the panel:
    /// opens Optimize Grux, where the door of that name writes the prompt.
    func test_handSetupToYourAgentSaysWhatTheButtonDoes() throws {
        let line = SettingsHandoff.panelLine
        XCTAssertTrue(line.contains("\u{201C}" + OptimizeDoor.handOver.title + "\u{201D}"), line)
        XCTAssertTrue(line.hasPrefix("Opens Optimize Grux"), line)
        let settings = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("Text(SettingsHandoff.panelLine)"))
        // The bundle that door writes carries the setup prompt the line promises.
        XCTAssertTrue(try macSource("Sources/Grux/Optimize/HandoffBundle.swift").contains("setup-prompt.md"))
    }

    /// The switch and the search read one gate, in research's own order.
    func test_webResearchSaysWhatStopsItInResearchsOwnOrder() throws {
        typealias B = WebResearch.Blocker
        for offline in [false, true] {
            for enabled in [false, true] {
                for key in [false, true] {
                    let expected: B? = offline ? .offline : !enabled ? .disabled : !key ? .noSearchKey : nil
                    XCTAssertEqual(WebResearch.blocker(offline: offline, enabled: enabled, hasSearchKey: key), expected,
                                   "offline \(offline) enabled \(enabled) key \(key)")
                }
            }
        }
        let offline = try XCTUnwrap(WebResearch.settingsLine(.offline, chatMovesToClaude: true))
        XCTAssertTrue(offline.contains("offline mode is on"), offline)
        let noKey = try XCTUnwrap(WebResearch.settingsLine(.noSearchKey, chatMovesToClaude: true))
        XCTAssertTrue(noKey.contains("Brave Search key") && noKey.contains("Credentials"), noKey)
        // W51-FIX P2 2: Credentials sits above the switch on this page.
        XCTAssertEqual(noKey, "Not searching yet: it needs a Brave Search key, under Credentials above.")
        let settings0 = try macSource("Sources/Grux/SettingsView.swift")
        let credentials = try XCTUnwrap(settings0.range(of: ".id(\"data.credentials\")"))
        let web = try XCTUnwrap(settings0.range(of: ".id(\"data.web\")"))
        XCTAssertLessThan(credentials.lowerBound, web.lowerBound, "Credentials moved below the switch; the line says above")
        XCTAssertNil(WebResearch.settingsLine(.disabled, chatMovesToClaude: true), "the switch already reads off")
        XCTAssertNil(WebResearch.settingsLine(nil, chatMovesToClaude: true))
        // research() refuses with the words it always used, from the same gate.
        let src = try macSource("Sources/Grux/WebResearch.swift")
        XCTAssertTrue(src.contains("switch blocker(offline: state.offlineMode, enabled: state.config.webResearchEnabled,"),
                      "research() no longer reads the shared gate")
        XCTAssertTrue(src.contains("\"error: web research unavailable in offline mode.\""))
        let settings = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("WebResearch.settingsLine(offline: state.offlineMode, enabled: webResearchEnabled,"),
                      "the switch does not say what stops it")
    }

    /// D179 item 8: the sending key is only ever a Resend key (`ResendClient` is the
    /// one outbound path), yet the row read "Email sending API key" and "Add your email
    /// provider API key ... Grux has no SMTP client.", naming no provider, so a stranger
    /// could paste a Gmail or SMTP password. The row names the service and where to get it.
    func test_theSendingKeyNamesTheServiceItIsFor() {
        let req = SetupRequirement.keyResend
        XCTAssertEqual(req.label, "Resend API key")
        let line = CapabilityCredentialsSection.rowLine(req)
        XCTAssertTrue(line.contains("Resend") && line.contains("resend.com"), line)
        XCTAssertFalse(line.contains("email provider"), "names no provider: \(line)")
        XCTAssertFalse(line.contains("SMTP"), "jargon a stranger cannot act on: \(line)")
        XCTAssertLessThanOrEqual(req.remediation.count, 140)
    }

    /// D157 item 16 lives in WeatherClaimGuardTests: every weather pointer
    /// says what Open-Meteo is.

    /// D192 item 7: the Classic sidebar line promised removal "in the release
    /// after this one" from 3.0 on; 3.1 kept it, and the line names no release.
    func testTheClassicSidebarLineMakesNoUnnamedRemovalPromise() {
        let line = SettingsView.classicSidebarCaption
        XCTAssertFalse(line.contains("release after this one"), line)
        XCTAssertEqual(line, "Every tab listed down the left of the window, the way Grux looked before 3.0, in place of the Command Panel. Switches right away.")
    }
}
