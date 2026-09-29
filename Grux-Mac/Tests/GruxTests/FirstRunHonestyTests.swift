import XCTest
@testable import Grux

/// P-F-1: what a stranger sees before they have agreed to anything, and the
/// doors they are told about.
///
/// Three findings from the 2026-09-21 first-run render and audit, each pinned:
/// a fresh install read ARMED while no microphone was open, the Developer door
/// had no switch anywhere so a fresh install could never show it, and the
/// flow named neither door nor the command palette.
@MainActor
final class FirstRunHonestyTests: XCTestCase {

    // One test here finishes the flow, which moves process-wide state a later class
    // would inherit: onboarding's stage and file, the Optimize hub, the requested tab.
    private var savedStage: OnboardingModel.Stage = .done
    private var savedSkippedFirstLook = false
    private var savedOnboardingBytes: Data?
    private var savedHubExpanded = false
    private var savedRequest = ""
    private let onboardingURL = Persistence.supportDir.appendingPathComponent("onboarding.json")

    override func setUp() async throws {
        savedStage = OnboardingModel.shared.stage
        savedSkippedFirstLook = OnboardingModel.shared.skippedFirstLook
        savedOnboardingBytes = try? Data(contentsOf: onboardingURL)
        savedHubExpanded = OptimizeHubState.shared.isExpanded
        savedRequest = AppState.shared.requestedTab
    }

    override func tearDown() async throws {
        // Onboarding first: finishing it writes the hub and the requested tab.
        let onboarding = OnboardingModel.shared
        if savedStage == .done {
            if onboarding.stage != .done || onboarding.skippedFirstLook != savedSkippedFirstLook {
                onboarding.finish(skippedFirstLook: savedSkippedFirstLook, sendFirstExchange: false)
            }
        } else if onboarding.stage != savedStage {
            onboarding.reset()
            var hops = 0
            while onboarding.stage != savedStage, onboarding.stage != .done, hops < 20 {
                onboarding.advance(from: onboarding.stage)
                hops += 1
            }
        }
        if let savedOnboardingBytes {
            try? savedOnboardingBytes.write(to: onboardingURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: onboardingURL)
        }
        OptimizeHubState.shared.isExpanded = savedHubExpanded
        AppState.shared.requestedTab = savedRequest
        XCTAssertEqual(onboarding.stage, savedStage, "this class left onboarding on another stage")
        XCTAssertEqual(onboarding.skippedFirstLook, savedSkippedFirstLook, "this class left another first-look answer")
        XCTAssertEqual(OptimizeHubState.shared.isExpanded, savedHubExpanded, "this class left the Optimize hub moved")
    }

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: sourcesRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - ARMED only once listening has been agreed to

    func test_aFreshInstallDoesNotReadArmed() {
        let fresh = GruxConfig.default
        XCTAssertEqual(fresh.listeningMode, .alwaysOn, "the decision is listening on by default")
        XCTAssertFalse(fresh.ambientConsentAcknowledged)
        XCTAssertEqual(fresh.listeningModeInEffect, .off, "no consent means no microphone, so nothing is listening")
        XCTAssertEqual(ListeningTell.resolve(mode: fresh.listeningModeInEffect, micMuted: false,
                                             isSpeaking: false, isThinking: false), .off)
    }

    func test_theModeInEffectFollowsTheConsentForThatMode() {
        var c = GruxConfig.default
        c.listeningMode = .alwaysOn; c.ambientConsentAcknowledged = true
        XCTAssertEqual(c.listeningModeInEffect, .alwaysOn)
        c.listeningMode = .wakeWord
        XCTAssertEqual(c.listeningModeInEffect, .off, "ambient consent is not wake word consent")
        c.wakeWordConsentAcknowledged = true
        XCTAssertEqual(c.listeningModeInEffect, .wakeWord)
        c.listeningMode = .off
        XCTAssertEqual(c.listeningModeInEffect, .off)
    }

    /// Every surface that shows the tell reads the mode in effect, never the
    /// raw preference. A new surface passing the preference would bring ARMED
    /// back before consent, so this reads the source.
    func test_noSurfaceResolvesTheTellFromTheRawPreference() throws {
        let fm = FileManager.default
        let root = sourcesRoot()
        var callers = 0
        let files = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = Substring(text)
            while let r = rest.range(of: "ListeningTell.resolve(") {
                callers += 1
                let call = rest[r.upperBound...].prefix(160)
                let mode = call.prefix { $0 != "," }
                XCTAssertFalse(mode.contains("config.listeningMode") && !mode.contains("listeningModeInEffect"),
                               "\(file.lastPathComponent) resolves the tell from the raw preference: \(mode)")
                rest = rest[r.upperBound...]
            }
        }
        XCTAssertGreaterThanOrEqual(callers, 7, "the scan found fewer surfaces than exist, so it is not reading them")
    }

    // MARK: - The Developer door has a switch

    func test_theDeveloperDoorHasAWriterInSettings_withItsOffStateExplained() throws {
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains("state.config.developerSurfacesUnlocked = "),
                      "nothing in Settings writes the Developer door switch")
        XCTAssertTrue(settings.contains("DoorsCopy.developer.body"), "the switch carries no explanation")
        let body = DoorsCopy.developer.body.lowercased()
        for word in ["commands", "agents", "local models", "compare"] {
            XCTAssertTrue(body.contains(word), "the explanation does not say \(word) is behind the door")
        }
        XCTAssertTrue(body.contains("off"), "the off state is not explained")
        XCTAssertTrue(SettingsSearchRegistry.entries.contains { $0.id == "general.doors" },
                      "the switch cannot be found by search")
        XCTAssertEqual(SettingsTabAliases.map["developer"]?.anchor, "general.doors")
    }

    func test_theSwitchNamesExactlyTheRowsBehindTheDoor() {
        let behind = SidebarIA.behind(.developer).map { $0.label.lowercased() }
        let body = DoorsCopy.developer.body.lowercased()
        for label in behind { XCTAssertTrue(body.contains(label), "\(label) is behind the door and not named") }
    }

    // MARK: - Named during the flow (Task F4)

    func test_theFlowNamesThePaletteAndBothDoors() {
        let copy = HowItWorksStep.wayfinding.map { "\($0.title) \($0.body)" }.joined(separator: " ").lowercased()
        XCTAssertTrue(copy.contains("command palette"))
        XCTAssertTrue(copy.contains(PaletteHotkeyConfig.spokenShortcut.lowercased()),
                      "the palette is named without the way to open it")
        XCTAssertTrue(copy.contains("developer door"))
        XCTAssertTrue(copy.contains("labs door"))
        XCTAssertEqual(PaletteHotkeyConfig.spokenShortcut, "Command-Shift-P", "the default shortcut changed")
    }

    func test_theHowItWorksScreenRendersTheWayfinding() throws {
        let steps = try source("Onboarding/OnboardingSteps.swift")
        XCTAssertTrue(steps.contains("ForEach(Self.wayfinding"), "the wayfinding copy exists and is not on screen")
    }

    // MARK: - The first question (Task F1, the model the view will read)

    func test_theFirstScreenAsksExactlyOneQuestion_andNamesListeningWithItsOffState() {
        XCTAssertEqual(FirstPrompt.question, "What do you want to do with Grux?")
        XCTAssertEqual(FirstPrompt.question.filter { $0 == "?" }.count, 1)
        XCTAssertEqual(FirstPrompt.decisions, 1, "the first screen carries more than the one question")
        XCTAssertEqual(FirstPrompt.listening.title, ListeningSection.copy.title, "second copy for the same feature")
        XCTAssertTrue(FirstPrompt.listening.body.contains(ListeningMode.off.explanation),
                      "the off state is not explained in the words Settings uses")
        XCTAssertTrue(FirstPrompt.listening.body.contains(ListeningSection.copy.body))
    }

    // MARK: - The flow can be walked again (Task F5)

    func test_thereIsAFirstRunResetTrigger() throws {
        let triggers = try source("Triggers/AppTriggers.swift")
        XCTAssertTrue(triggers.contains("\"fire-first-run-reset\""), "no fire-first-run-reset trigger")
        guard let r = triggers.range(of: "\"fire-first-run-reset\"") else { return }
        let body = triggers[r.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("OnboardingModel.shared.reset()"), "the trigger does not put the flow back")
        XCTAssertTrue(body.contains("FeatureSelection.clear()"), "the trigger keeps the last answer's selection")
    }
    /// The other half of walking it again: a script can end the flow. An
    /// install left on the setup screen showed no tab to any command, and the
    /// only way past it was a click nobody at the keyboard could make. The
    /// scripted finish must never send the person's first-run answer to Chat:
    /// that answer is theirs to send, and "help me ship code" is a phrase a
    /// shipping workflow listens for.
    func test_thereIsAFirstRunFinishTrigger_thatSendsNothing() throws {
        let triggers = try source("Triggers/AppTriggers.swift")
        guard let r = triggers.range(of: "\"fire-first-run-finish\"") else {
            return XCTFail("no fire-first-run-finish trigger")
        }
        let body = triggers[r.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("finish(skippedFirstLook: true, sendFirstExchange: false)"),
                      "the trigger does not end the flow, or ends it by sending a chat turn")
    }

    func test_finishingWithoutTheFirstExchange_leavesTheShellShowing() {
        OnboardingModel.shared.reset()
        XCTAssertTrue(OnboardingModel.shared.isPresenting)
        OnboardingModel.shared.finish(skippedFirstLook: true, sendFirstExchange: false)
        XCTAssertEqual(OnboardingModel.shared.stage, .done)
        XCTAssertFalse(OnboardingModel.shared.isPresenting)
        XCTAssertTrue(OnboardingModel.shared.skippedFirstLook, "a scripted finish showed nobody a frame")
    }
}
