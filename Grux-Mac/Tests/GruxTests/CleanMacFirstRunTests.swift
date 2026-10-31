import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Grux

/// The clean-Mac walk of the notarized 3.1.0 (W4, 2026-10-13): what a stranger
/// met in their first minutes, one class per finding.
private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

private func body(of marker: String, in src: String, length: Int = 2500) throws -> Substring {
    try XCTUnwrap(src.components(separatedBy: marker).dropFirst().first).prefix(length)
}

/// 1. The first-run window opened at the panel's 420pt, so every step was
/// clipped on both edges and Continue sat off the window.
@MainActor
final class FirstRunWindowSizeTests: XCTestCase {
    func test_firstRunOpensAtTheFlowsOwnSizeOverItsMinimum() {
        let size = AppDelegate.launchContentSize(legacy: false, onboarding: true)
        XCTAssertEqual(size.minimum, NSSize(width: GruxLayout.onboardingMinWidth, height: GruxLayout.onboardingMinHeight))
        XCTAssertEqual(size.minimum, NSSize(width: 640, height: 520), "the flow's minimum moved; re-run the onboarding fit sweep")
        XCTAssertEqual(size.initial, NSSize(width: 720, height: 640))
        XCTAssertGreaterThanOrEqual(size.initial.width, size.minimum.width)
        XCTAssertGreaterThanOrEqual(size.initial.height, size.minimum.height)
        XCTAssertEqual(AppDelegate.launchContentSize(legacy: true, onboarding: true).initial, size.initial,
                       "the classic sidebar's first run is the same flow and needs the same room")
    }

    func test_afterFirstRunThePanelOpensAtRest() {
        let size = AppDelegate.launchContentSize(legacy: false, onboarding: false)
        XCTAssertEqual(size.initial.width, GruxLayout.panelWidth)
        XCTAssertEqual(size.minimum, AppDelegate.launchWindowFloor(legacy: false))
    }

    /// The window is built at that size and centred, and the panel's own
    /// asks wait for the window rather than being dropped before it exists.
    func test_theWindowIsBuiltAtThatSizeAndAsksWaitForIt() throws {
        let app = try macSource("Sources/Grux/GruxApp.swift")
        let open = try body(of: "func openLaunchWindow(tab: String = \"chat\") {", in: app, length: 6000)
        let sized = try XCTUnwrap(open.range(of: "Self.launchContentSize(legacy: legacy, onboarding: onboarding).initial"))
        let centred = try XCTUnwrap(open.range(of: "win.center()"))
        XCTAssertLessThan(sized.lowerBound, centred.lowerBound, "the window is centred before it has its size")
        XCTAssertTrue(open.contains("let onboarding = OnboardingModel.shared.isPresenting"))
        let panel = try macSource("Sources/Grux/Shell/CommandPanelRoot.swift")
        XCTAssertTrue(panel.contains("sizeWindow(GruxLayout.onboardingIdealWidth, GruxLayout.onboardingMinWidth)"),
                      "the panel asks for less than the window was built at")
        XCTAssertEqual(panel.components(separatedBy: "AppDelegate.withLaunchWindow").count - 1, 3,
                       "a panel sizer reads launchWindow directly again, and drops its ask when it is nil")
    }
}

/// 2. A fresh install showed a developer's chore as CURRENT FOCUS.
@MainActor
final class NoSeededTaskTests: XCTestCase {
    func test_aFreshConfigHasNoSeededTask() {
        let state = AppState.shared
        let saved = state.tasks
        defer { state.tasks = saved }
        state.tasks = []
        Bootstrap.ensureConfig()
        XCTAssertEqual(state.tasks.map(\.title), [], "a fresh install was handed a task it never asked for")
    }

    func test_theSeedIsGoneFromTheSource() throws {
        XCTAssertFalse(try macSource("Sources/Grux/GruxApp.swift").contains("Wire up Grux and confirm focus reminders fire"))
    }
}

/// 3. macOS asked for the microphone at launch, before any Grux window, while
/// the first screen said listening is off until later.
@MainActor
final class MicrophoneAskTests: XCTestCase {
    private var asked = 0
    private var savedStatus: (() -> AVAuthorizationStatus)!
    private var savedRequest: (() async -> Bool)!
    private var savedConfig: GruxConfig!

    override func setUp() async throws {
        savedStatus = MicController.authorizationStatus
        savedRequest = MicController.requestAccess
        savedConfig = AppState.shared.config
        asked = 0
        MicController.authorizationStatus = { .notDetermined }
        MicController.requestAccess = { [weak self] in self?.asked += 1; return false }
        MicController.resetUserAskForTests()
        AppState.shared.config.ambientConsentAcknowledged = false
        AppState.shared.config.wakeWordConsentAcknowledged = false
    }

    override func tearDown() async throws {
        MicController.authorizationStatus = savedStatus
        MicController.requestAccess = savedRequest
        MicController.resetUserAskForTests()
        AppState.shared.config = savedConfig
    }

    func test_anUndecidedMicIsNotAskedAboutUntilSomeoneAsksForIt() async {
        let granted = await MicController.ensureAuthorized()
        XCTAssertFalse(granted)
        XCTAssertEqual(asked, 0, "macOS was asked for the microphone with nobody asking for it")
        MicController.userWantsMicrophone()
        _ = await MicController.ensureAuthorized()
        XCTAssertEqual(asked, 1, "a press of a mic button must still reach the macOS prompt")
    }

    func test_listeningTheyAgreedToMayAsk() async {
        AppState.shared.config.ambientConsentAcknowledged = true
        _ = await MicController.ensureAuthorized()
        XCTAssertEqual(asked, 1, "listening the person agreed to could not get the microphone")
    }

    /// First paint of the first-run flow and of the menu bar ask for nothing.
    func test_firstPaintAsksForNothing() async throws {
        OnboardingModel.shared.reset()
        XCTAssertTrue(OnboardingModel.shared.isPresenting, "the suite could not put onboarding on screen")
        defer { OnboardingModel.shared.finish(skippedFirstLook: true) }
        for view in [AnyView(OnboardingView().environmentObject(AppState.shared)),
                     AnyView(MenuBarView().environmentObject(AppState.shared))] {
            let host = NSHostingView(rootView: view.frame(width: 720, height: 640))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            PaneFitHarness.pump(0.5)
            window.contentView = nil
        }
        XCTAssertEqual(asked, 0, "first paint asked macOS for the microphone")
    }

    /// THE PROMPT THE WALK ACTUALLY HIT. The W4 tccd log shows coreaudiod, not
    /// Grux, requesting the microphone 80 ms after launch: reading input
    /// devices from CoreAudio was enough. Launch's mic whitelist scan, building
    /// VoiceInput (the first-run screen observes it) and first paint of the
    /// first-run flow and the menu bar must make no input query before access.
    func test_nothingReadsAnInputDeviceBeforeAccess() async throws {
        let saved = MicDevices.inputQueriesAllowed
        defer { MicDevices.inputQueriesAllowed = saved }
        MicDevices.inputQueriesAllowed = { false }
        let before = MicDevices.inputQueriesMade
        MicWhitelist.applyPreferredInputIfPossible()
        MicWhitelist.autoWhitelistKnownExternalMics()
        _ = VoiceInput(prewarm: { _ in })
        XCTAssertEqual(MicDevices.listInputs(), [])
        XCTAssertNil(MicDevices.systemDefaultInputUID())
        XCTAssertNil(MicDevices.builtInMicUID())
        XCTAssertEqual(MicDevices.listeningCandidates().count, 0)
        XCTAssertNil(MicDevices.deviceID(forUID: "BuiltInMicrophoneDevice"))
        try await test_firstPaintAsksForNothing()
        XCTAssertEqual(MicDevices.inputQueriesMade, before, "an input device was read before microphone access")
        // Control: with access, the same call does reach CoreAudio, so the
        // count above can fail.
        MicDevices.inputQueriesAllowed = { true }
        _ = MicDevices.listInputs()
        XCTAssertEqual(MicDevices.inputQueriesMade, before + 1, "the counter cannot see a query")
    }

    func test_onlyMicDevicesReadsCoreAudioInputsAndDictationBuildsNoEngineEarly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var readers: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("AudioObjectGetPropertyData") || text.contains("kAudioHardwarePropertyDefaultInputDevice") {
                readers.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(readers, ["MicDevices.swift"], "a second file reads CoreAudio devices around the access gate")
        let devices = try macSource("Sources/Grux/MicDevices.swift")
        XCTAssertEqual(devices.components(separatedBy: "guard inputQueriesAllowed() else").count - 1, 4,
                       "listInputs, systemDefaultInputUID, setSystemDefaultInput and deviceID must each check access first")
        // deviceID enumerates every device and has callers of its own
        // (bindInput, boundInputName): the guard is its first line.
        let resolve = try body(of: "static func deviceID(forUID uid: String) -> AudioDeviceID? {", in: devices, length: 120)
        XCTAssertTrue(resolve.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("guard inputQueriesAllowed() else { return nil }"),
                      "deviceID(forUID:) enumerates devices without checking access")
        let voice = try macSource("Sources/Grux/VoiceInput.swift")
        XCTAssertTrue(voice.contains("private lazy var audioEngine = AudioFactory.engine(\"dictation\")"), "VoiceInput builds an engine at init again")
        let canDictate = try body(of: "init(canDictate: @MainActor () -> Bool = {", in: voice, length: 400)
        let auth = try XCTUnwrap(canDictate.range(of: "authorizationStatus"))
        let list = try XCTUnwrap(canDictate.range(of: "MicDevices.listInputs()"))
        XCTAssertLessThan(auth.lowerBound, list.lowerBound, "VoiceInput lists input devices before checking access")
    }

    /// THE PROMPT BUILD 10 STILL HIT. The W4 log: 1.5 s after launch Grux
    /// built an output-only AUHAL ("Selecting device 67 from constructor"),
    /// and coreaudiod asked for the microphone while it opened that I/O
    /// context. The speech engine wired its playback graph in `init`, and the
    /// HUD, the panel and the menu bar observe it from first paint. Building
    /// the speech engine, the calls launch makes on it, dictation and first
    /// paint of every surface build no audio engine; the first thing that
    /// plays does.
    @MainActor
    func test_launchAndFirstPaintBuildNoAudioEngine() async throws {
        let saved = AudioFactory.makeEngine
        defer { AudioFactory.makeEngine = saved }
        var injected = 0
        AudioFactory.makeEngine = { injected += 1; return AVAudioEngine() }
        let before = AudioFactory.enginesBuilt
        let speech = SpeechEngine()
        speech.applyPlaybackRate(1.5)
        speech.stop(reason: "launch")
        _ = SpeechEngine.shared
        _ = VoiceInput(prewarm: { _ in })
        try await test_firstPaintAsksForNothing()
        let views: [AnyView] = [
            AnyView(AmbientHUDRoot()),
            AnyView(PanelHead(onOpen: { _ in }, onOptimize: {}).environmentObject(AppState.shared)),
            AnyView(PanelFoot(onOpen: { _ in }, onSettings: {}).environmentObject(AppState.shared)),
        ]
        for view in views {
            let host = NSHostingView(rootView: view.frame(width: 720, height: 640))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
            host.layoutSubtreeIfNeeded()
            PaneFitHarness.pump(0.3)
        }
        XCTAssertEqual(injected, 0, "built an audio engine (\(AudioFactory.lastPurpose)) before anything played")
        XCTAssertEqual(AudioFactory.enginesBuilt, before)
        // Control: a build through the factory is counted, so the zero above can fail.
        _ = AudioFactory.engine("control")
        XCTAssertEqual(injected, 1, "the injected factory cannot see a build")
    }

    /// The class, not the instance: every AVAudioEngine in the app comes from
    /// the factory the test above counts, and the speech graph is not a
    /// stored property built with its owner.
    func test_everyAudioEngineComesFromTheCountedFactory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var builders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("AVAudioEngine()") { builders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(builders, ["AudioFactory.swift"], "an audio engine is built outside the counted factory")
        let speech = try macSource("Sources/Grux/SpeechEngine.swift")
        XCTAssertFalse(speech.contains("private let engine"), "the speech engine builds its graph with itself again")
        let afterInit = try body(of: "override init() {", in: speech, length: 200)
        let initBody = afterInit.prefix(upTo: try XCTUnwrap(afterInit.firstIndex(of: "}")))
        XCTAssertFalse(initBody.contains("setup") || initBody.contains("graph"), "the speech engine wires its graph in init again")
    }

    /// Only person-started paths mark an ask: a dictation button, a meeting
    /// start, the orb or the panel mic.
    func test_onlyPersonStartedPathsMarkAnAsk() throws {
        let callers = ["Sources/Grux/ChatView.swift", "Sources/Grux/Onboarding/FirstRunScreens.swift",
                       "Sources/Grux/Meeting/MeetingCaptureService.swift", "Sources/Grux/MicController.swift"]
        for rel in callers {
            XCTAssertTrue(try macSource(rel).contains("userWantsMicrophone()"), "\(rel) no longer marks its ask")
        }
        let launch = try body(of: "func applicationDidFinishLaunching", in: try macSource("Sources/Grux/GruxApp.swift"), length: 30000)
        for ask in ["userWantsMicrophone", "requestAccess(for: .audio)", "ensureAuthorized("] {
            XCTAssertFalse(launch.contains(ask), "launch reaches the microphone ask (\(ask))")
        }
    }
}

/// 4. With no key and no Ollama, Continue stayed disabled and nothing else
/// led out of the model step.
@MainActor
final class ModelStepWayOutTests: XCTestCase {
    func test_theStepOffersSkipAndAnOllamaLinkAndSaysWhatIsTrue() throws {
        let step = try body(of: "struct ModelKeyStep: View {", in: try macSource("Sources/Grux/Onboarding/OnboardingView.swift"), length: 16000)
        XCTAssertTrue(step.contains("Button(ModelGate.skip) { model.completeModelKey() }"), "no way past the step without a model")
        XCTAssertTrue(step.contains("Link(ModelGate.ollamaLink, destination: ModelGate.ollamaURL)"))
        XCTAssertEqual(ModelGate.ollamaURL.absoluteString, "https://ollama.com")
        XCTAssertTrue(ModelGate.localLine.contains("With Ollama running"), "the line promises a model with nothing running")
        XCTAssertFalse(ModelGate.localLine.contains("If there is no model here yet"))
    }

    func test_nowSaysConnectAModelAndChatsGapIsNotListedTwice() {
        var s = RelevanceState()
        s.chatNeedsModel = true
        s.setupGaps = [SetupGap(featureId: "chat", label: "Chat", missing: "Anthropic key", brandScoped: false)]
        let items = Relevance.now(s)
        XCTAssertEqual(items.first?.title, PanelCopy.connectModel)
        XCTAssertEqual(items.first?.action, .connectModel)
        XCTAssertFalse(items.contains { $0.id == "setup.chat" }, "Chat's gap and Connect a model are the same row twice")
        s.chatNeedsModel = false
        XCTAssertFalse(Relevance.now(s).contains { $0.action == .connectModel })
    }

    func test_connectAModelGoesWhereChatsOwnNoticeGoes() {
        let saved = AppState.shared.requestedSettingsTab
        defer { AppState.shared.requestedSettingsTab = saved }
        let m = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { _, _ in }, floorHeight: { _ in }, floorWidth: { _ in })
        m.perform(.connectModel)
        // Item 5 of the W4 pass 2 walk: Models, at the section that gets a
        // model, the place Chat's own notice sends people too.
        XCTAssertEqual(AppState.shared.requestedSettingsTab, "connect", "Now and Chat send the person to different places")
    }
}

/// 5. During setup the menu bar's Chat and Drafts, and Open Tuning, did nothing visible.
@MainActor
final class SetupFirstNoticeTests: XCTestCase {
    func test_aHeldRequestIsSaidOutLoud() throws {
        XCTAssertEqual(OnboardingModel.setupFirstNotice(for: "Chat"), "Finish setup first. Chat opens when you are done.")
        let open = try body(of: "func openLaunchWindow(tab: String = \"chat\") {", in: try macSource("Sources/Grux/GruxApp.swift"), length: 900)
        XCTAssertTrue(open.contains("OnboardingModel.shared.isPresenting, tab != PanelKeys.none, launchWindow != nil"))
        XCTAssertTrue(open.contains("OnboardingModel.shared.setupFirstNotice = "))
        XCTAssertTrue(try macSource("Sources/Grux/Onboarding/OnboardingView.swift").contains("if let notice = model.setupFirstNotice {"))
    }
}

/// 6. "Watching" and "Enable screen analysis" read ON with no screen access granted.
final class WatchingTruthTests: XCTestCase {
    func test_watchingWithoutScreenAccessSaysSo() {
        XCTAssertEqual(PanelCopy.watchingState(watching: true, screenAccess: false), .needsScreenAccess)
        XCTAssertEqual(PanelCopy.watchingState(watching: true, screenAccess: true), .watching)
        XCTAssertEqual(PanelCopy.watchingState(watching: false, screenAccess: false), .paused)
    }

    func test_everySurfaceAsksTheOneRule() throws {
        for rel in ["Sources/Grux/MenuBarView.swift", "Sources/Grux/Shell/CommandPanel/PanelFoot.swift"] {
            XCTAssertTrue(try macSource(rel).contains("PanelCopy.watchingState(watching: state.watching, screenAccess: state.screenPermissionGranted)"), rel)
        }
        let settings = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("get: { screen && state.screenPermissionGranted }"), "screen analysis reads ON without access")
    }

    /// D3 (3.2 sense pass): the Focus Log pane read a green "Watching" beside
    /// "Needs screen recording permission", said "Grux samples your active
    /// window every 8s", and left 0 events under a blank list. The menu bar and
    /// the foot already asked the one rule; these two surfaces read the switch.
    func test_noSurfaceReadsWatchingFromTheSwitchAlone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        // Any receiver, either case: the focus overlay's `appState.watching ?
        // "watching"` slipped past a scan that knew only `state.` and "Watching".
        let pattern = try NSRegularExpression(pattern: #"\b\w+\.watching \? ("[Ww]atching"|Color\.green|GruxTheme\.successMint|1\.0)"#)
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "scan found no sources")
        for url in files {
            let src = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil {
                hits.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(hits, [], "a watching status chosen from the switch alone reads Watching with no screen access")
    }

    /// D47 (sense pass 3): the banner read "After 2 checks consecutive off-task samples, Grux
    /// nudges", because the drift label already carries its unit. Every state reads it once.
    func test_theDriftSentenceReadsAsEnglish() {
        for shown in [PanelCopy.WatchingState.watching, .needsScreenAccess, .paused] {
            for drift in ["1 check", "2 checks"] {
                let line = FocusLogView.samplingLine(shown, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                                     model: "vision", drift: drift, cooldown: "15m")
                XCTAssertFalse(line.contains("checks consecutive") || line.contains("check consecutive"), line)
                XCTAssertTrue(line.contains("After \(drift) in a row that read off task, Grux nudges you"), line)
            }
        }
    }

    func test_theFocusLogSaysNothingIsSampledWithoutScreenAccess() {
        let line = FocusLogView.samplingLine(.needsScreenAccess, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                             model: "vision", drift: "2 checks", cooldown: "15m")
        XCTAssertTrue(line.hasPrefix("Nothing is sampled until macOS allows screen recording."), line)
        XCTAssertFalse(line.contains("Grux samples your active window"), line)
        XCTAssertTrue(FocusLogView.samplingLine(.watching, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                                model: "vision", drift: "2 checks", cooldown: "15m")
            .hasPrefix("Grux samples your active window every 8s during 9:00 AM to 5:00 PM."))
        XCTAssertEqual(FocusLogView.statusTitle(.needsScreenAccess), PanelCopy.needsScreenAccess)
        XCTAssertEqual(FocusLogView.statusTitle(.watching), PanelCopy.watching)
        XCTAssertEqual(FocusLogView.statusTitle(.paused), PanelCopy.paused)
        XCTAssertEqual(FocusLogView.emptyLine(.needsScreenAccess, interval: "every 8s"),
                       "No samples. Grux needs screen recording to see your active window; Grant asks macOS.")
        // A fact, not a promise: the local prescreen and the daily ceiling can
        // skip a check without a sample (wave 8 review round 4).
        XCTAssertEqual(FocusLogView.emptyLine(.watching, interval: "every 8s"),
                       "No samples yet. Grux checks every 8s.")
        // Watch alone may not start sampling, and the pane has no Watch button
        // (wave 8 review round 5): the line says only what is true.
        XCTAssertEqual(FocusLogView.emptyLine(.paused, interval: "every 8s"), "Paused, so nothing is sampled.")
        // On and allowed, but the watcher skips every tick (no task set is the
        // fresh-Mac case): the line names why instead of promising a sample.
        XCTAssertEqual(FocusLogView.emptyLine(.watching, interval: "every 8s", skip: .noTask), "No samples yet.")
    }

    /// The old guard short-circuited, so the Keychain key and the screen
    /// preflight were read only when every earlier check passed. A failed
    /// Keychain read is not cached, so reading it on every tick of a Mac that
    /// never set Focus up could ask for the Keychain every few seconds (wave 8
    /// review round 2). The gate reads each input only when it gets that far.
    func test_theFocusGateReadsNothingPastTheFirstMissingThing() {
        var accessRead = false, keyRead = false, taskRead = false
        let skip = FocusWatcher.skipReason(screenAnalysisEnabled: true, featureOn: true, firstFrameReviewed: false,
                                           exclusionsConfirmed: true,
                                           screenAccess: { accessRead = true; return true }(),
                                           withinActiveHours: true, snoozed: false,
                                           hasTask: { taskRead = true; return true }(),
                                           hasKey: { keyRead = true; return true }())
        XCTAssertEqual(skip, .firstFrame)
        XCTAssertFalse(accessRead, "screen access read past a missing setup step")
        XCTAssertFalse(taskRead, "the task read past a missing setup step")
        XCTAssertFalse(keyRead, "the Keychain key read past a missing setup step")
        let src = try? macSource("Sources/Grux/FocusWatcher.swift")
        let start = src?.components(separatedBy: "    func start() {").dropFirst().first?.prefix(400) ?? ""
        XCTAssertTrue(start.contains("AppState.shared.focusSkip = nil"), "a restart shows the last run's reason until the first tick")
    }

    func test_theBannerSaysNothingIsSampledWhileTheTickSkips() {
        let line = FocusLogView.samplingLine(.watching, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                             model: "vision", drift: "2 checks", cooldown: "15m", skip: .noTask)
        XCTAssertTrue(line.hasPrefix("Nothing is sampled right now. No task is set as Now, so there is nothing to compare against. When nothing stands in the way, Grux samples your active window every 8s"), line)
        // Every reason, not only the one that happened to read right: "When it
        // is, Grux samples" after "Focus is snoozed." said it samples while
        // snoozed (wave 8 review round 3).
        for skip in FocusWatcher.Skip.allCases {
            let l = FocusLogView.samplingLine(.watching, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                              model: "vision", drift: "2 checks", cooldown: "15m", skip: skip)
            XCTAssertEqual(l, "Nothing is sampled right now. \(skip.line) When nothing stands in the way, Grux samples your active window every 8s during 9:00 AM to 5:00 PM. Each sample is classified against your current task using vision analysis. After 2 checks in a row that read off task, Grux nudges you (respecting a 15m cooldown per app).")
            XCTAssertFalse(l.contains("When it is"), l)
            XCTAssertFalse(l.contains("Once that changes"), "reads wrong after a line that is an instruction: \(l)")
            // Without screen access the tick still knows what else is missing;
            // "Then Grux will sample" promised a sample after the grant alone
            // (wave 8 review round 4).
            let a = FocusLogView.samplingLine(.needsScreenAccess, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                              model: "vision", drift: "2 checks", cooldown: "15m", skip: skip)
            let extra = skip == .noScreenAccess ? "" : " \(skip.line)"
            XCTAssertTrue(a.hasPrefix("Nothing is sampled until macOS allows screen recording.\(extra) When nothing stands in the way, Grux will sample your active window every 8s"), a)
            XCTAssertFalse(a.contains("Then Grux will sample"), a)
            // The banner names the reason; the empty list does not say it twice.
            XCTAssertEqual(FocusLogView.emptyLine(.watching, interval: "every 8s", skip: skip), "No samples yet.")
        }
        for shown in [PanelCopy.WatchingState.watching, .needsScreenAccess, .paused] {
            let l = FocusLogView.samplingLine(shown, interval: "every 8s", hours: "9:00 AM to 5:00 PM",
                                              model: "vision", drift: "2 checks", cooldown: "15m")
            XCTAssertFalse(l.contains("Then Grux will sample"), l)
            XCTAssertFalse(l.contains("nothing is missing"), "a snooze is not a missing thing: \(l)")
            XCTAssertFalse(FocusLogView.emptyLine(shown, interval: "every 8s").contains("starts it again"))
        }
    }

    /// The tick's gate, as one function the pane also asks, in the tick's order.
    func test_theFocusGateNamesTheFirstThingMissing() throws {
        func reason(analysis: Bool = true, feature: Bool = true, frame: Bool = true, exclusions: Bool = true,
                    access: Bool = true, hours: Bool = true, snoozed: Bool = false, task: Bool = true,
                    key: Bool = true) -> FocusWatcher.Skip? {
            FocusWatcher.skipReason(screenAnalysisEnabled: analysis, featureOn: feature, firstFrameReviewed: frame,
                                    exclusionsConfirmed: exclusions, screenAccess: access, withinActiveHours: hours,
                                    snoozed: snoozed, hasTask: task, hasKey: key)
        }
        XCTAssertNil(reason())
        XCTAssertEqual(reason(analysis: false), .screenAnalysisOff)
        XCTAssertEqual(reason(feature: false), .focusOff)
        XCTAssertEqual(reason(frame: false), .firstFrame)
        XCTAssertEqual(reason(exclusions: false), .exclusions)
        XCTAssertEqual(reason(access: false), .noScreenAccess)
        XCTAssertEqual(reason(hours: false), .outsideHours)
        XCTAssertEqual(reason(snoozed: true), .snoozed)
        XCTAssertEqual(reason(task: false), .noTask)
        XCTAssertEqual(reason(key: false), .noKey)
        XCTAssertEqual(reason(analysis: false, key: false), .screenAnalysisOff, "the first missing thing wins")
        // Neighbours in the tick's order, so a swap of two checks fails.
        XCTAssertEqual(reason(feature: false, frame: false), .focusOff)
        XCTAssertEqual(reason(frame: false, exclusions: false), .firstFrame)
        XCTAssertEqual(reason(exclusions: false, access: false), .exclusions)
        XCTAssertEqual(reason(access: false, hours: false), .noScreenAccess)
        XCTAssertEqual(reason(hours: false, snoozed: true), .outsideHours)
        XCTAssertEqual(reason(snoozed: true, task: false), .snoozed)
        XCTAssertEqual(reason(task: false, key: false), .noTask)
        let src = try macSource("Sources/Grux/FocusWatcher.swift")
        XCTAssertTrue(src.contains("let skip = Self.skipReason(screenAnalysisEnabled: state.config.screenAnalysisEnabled,"),
                      "the tick no longer asks the shared gate")
        XCTAssertTrue(src.contains("if state.focusSkip != skip { state.focusSkip = skip }"), "the tick's answer is not published")
        XCTAssertTrue(src.contains("        if let skip {\n"), "the tick samples whatever the gate said")
        let pane = try macSource("Sources/Grux/LaunchRootView.swift")
        XCTAssertTrue(pane.contains("skip: state.focusSkip))"), "the empty line does not read what the tick found")
    }
}

/// 7. The app menu had no Settings… and Cmd-comma did nothing.
final class AppMenuSettingsTests: XCTestCase {
    func test_theAppMenuHasSettingsOnCommandComma() throws {
        let app = try macSource("Sources/Grux/GruxApp.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(app.contains("Button(AppMenu.settingsTitle) { WindowOpener.openSettings() }"))
        XCTAssertTrue(app.contains(".keyboardShortcut(AppMenu.settingsKey, modifiers: .command)"))
        XCTAssertEqual(AppMenu.settingsKey, ",")
    }
}

/// 8. The menu bar's focus time counted from the last check, so it restarted.
@MainActor
final class FocusTimeTests: XCTestCase {
    func test_focusTimeCountsFromWhenTheTaskBecameCurrent() throws {
        let state = AppState.shared
        let saved = state.currentTaskId
        defer { state.currentTaskId = saved }
        state.currentTaskId = UUID()
        let since = try XCTUnwrap(state.currentTaskSince)
        XCTAssertLessThan(abs(since.timeIntervalSinceNow), 2)
        let again = state.currentTaskSince
        state.currentTaskId = state.currentTaskId
        XCTAssertEqual(state.currentTaskSince, again, "setting the same task restarted its time")
        let menu = try macSource("Sources/Grux/MenuBarView.swift")
        XCTAssertTrue(menu.contains("let since = state.currentTaskSince"))
        XCTAssertFalse(menu.contains("Text(tick, style: .relative)"), "the menu counts from the last check again")
    }
}
