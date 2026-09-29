import SwiftUI
import AppKit
import UserNotifications
import Combine

@main
struct GruxApp: App {
    @StateObject private var state = AppState.shared
    // Items 23+26: theme revision bumps on every committed accent/appearance
    // change; keying scene roots on it repaints every GruxTheme call-site live.
    @ObservedObject private var theme = ThemeConfig.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state).id(theme.revision)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Grux Chat", id: "chat") {
            ChatView().environmentObject(state).id(theme.revision)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // New: iPhone pairing window. Shows a QR that the Grux Phone iOS app
        // scans to join the pipeline. See Sources/Grux/iPhone/.
        Window("Pair iPhone", id: "pair-iphone") {
            PhonePairingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Right-click → Expand on a job row opens the JobDetailView in a
        // standalone window. WindowGroup(for: String.self) lets multiple
        // jobs be expanded into separate windows simultaneously, each keyed
        // by jobId.
        WindowGroup("Agent Job", id: "agent-job", for: String.self) { $jobId in
            AgentJobWindow(jobId: jobId).environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var wake = WakeWordListener.shared

    var body: some View {
        HStack(spacing: 5) {
            Text("GRUX OS")
                .font(.system(size: 12, weight: .black, design: .default))
                .kerning(0.5)
                .opacity(state.watching ? 1.0 : 0.45)

            // Energy-mode glyph. Blank in NORMAL to keep the menu bar clean.
            let glyph = state.config.currentMode.menuBarGlyph
            if !glyph.isEmpty {
                Text(glyph)
                    .font(.system(size: 10, weight: .heavy, design: .default))
                    .foregroundStyle(modeColor(state.config.currentMode))
            }

            if wake.isListening {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.purple)
            }

            if let v = state.lastVerdict {
                Circle()
                    .fill(verdictColor(v))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func verdictColor(_ v: FocusVerdict) -> Color {
        switch v {
        case .offTask: return .red
        case .drifting: return .yellow
        case .onTask: return .green
        case .ambiguous: return .gray
        }
    }

    private func modeColor(_ m: GruxMode) -> Color {
        switch m {
        case .chill:  return .cyan
        case .normal: return .secondary
        case .grind:  return .orange
        case .sheesh: return .red
        }
    }
}

@MainActor
enum WindowOpener {
    static func openChat() {
        WindowFacade.activateGrux()
        AppDelegate.shared?.openLaunchWindow(tab: "chat")
    }
    /// Grux Settings is its own window in the Command Panel shell (spec
    /// 3.6); the classic shell keeps opening it on its sidebar tab. The
    /// `settings` key through fire-open-tab, --open-tab and the palette still
    /// renders in the pane either way: that is the trigger contract.
    static func openSettings() {
        openSettings(legacy: AppState.shared.config.legacyShell, delegate: AppDelegate.shared)
    }

    static func openSettings(legacy: Bool, delegate: AppDelegate?) {
        WindowFacade.activateGrux()
        if legacy {
            delegate?.openLaunchWindow(tab: "settings")
        } else {
            delegate?.openSettingsWindow()
        }
    }
    static func openTasks() {
        WindowFacade.activateGrux()
        AppDelegate.shared?.openLaunchWindow(tab: "tasks")
    }
    // Opens the launch window focused on the Workflows tab. Used by the
    // menu bar phase ribbon to deep-link into the active V2 run.
    static func openWorkflows() {
        WindowFacade.activateGrux()
        AppDelegate.shared?.openLaunchWindow(tab: "workflows")
    }
    // Opens the staged support drafts. Per the approved UI/UX design (decision
    // 1A + 5), drafts now live inside Jax HQ rather than a floating window, so
    // this navigates to the Jax HQ tab (which carries the Drafts section).
    static func openSupportDrafts() {
        WindowFacade.activateGrux()
        AppDelegate.shared?.openLaunchWindow(tab: "jaxHQ")
    }
    // Opens the cold-outreach composer with a blank, editable draft.
    static func composeOutreach() {
        WindowFacade.activateGrux()
        ColdEmailEngine.shared.startManualCompose()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var openWindowAction: ((String) -> Void)?

    /// Internal, not private, so LaunchWindowSizingTests can hand it a window.
    var launchWindow: NSWindow?
    /// The launch window's title bar button, hidden in the classic shell.
    private var paneToggleAccessory: NSTitlebarAccessoryViewController?
    private var floorObserver: NSObjectProtocol?
    private var floorCheck: DispatchWorkItem?
    /// Set when the panel shell opened its window with `--win-w`: the panel's
    /// first sizing pass keeps that width unless it is under the minimum, and
    /// clears this. Every later pass sizes the window to the pane state.
    var explicitLaunchWidthPending = false

    /// True when the main window is on screen and Grux is the active app, so
    /// a surface can skip a banner for something the person can already see
    /// land in front of them.
    var launchWindowIsFrontmost: Bool {
        NSApp.isActive && (launchWindow?.isVisible ?? false)
    }
    private var empireDashboardWindow: NSWindow?
    private var speakingGlowSub: AnyCancellable?
    // Held only while the first-run flow is on screen. Released the moment it
    // finishes, which is also the moment the consent-gated work starts.
    private var onboardingGateSub: AnyCancellable?

    // Throttle for the re-auth observer: applicationDidBecomeActive fires on
    // every focus return, so we rate-limit the `claude auth status` probe to
    // at most once per 20s. Re-engaging a paused job is the goal; spawning the
    // CLI on every window focus is not.
    private var lastReauthProbeAt: Date = .distantPast

    /// Before any window exists: with ~/.grux/HEADLESS present nothing Grux
    /// opens may appear on, take focus on, or float above the physical display.
    func applicationWillFinishLaunching(_ notification: Notification) {
        WindowFacade.startGuard()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // A write into a pipe whose reader died (crashed MCP server, exited
        // shell child) raises SIGPIPE, which by default terminates the whole
        // app. Ignore it process-wide so those writes surface as catchable
        // EPIPE errors instead. URLSession sockets already set SO_NOSIGPIPE;
        // this covers Pipe/FileHandle plumbing.
        signal(SIGPIPE, SIG_IGN)
        // Shell commands that would make sound obey ~/.grux/SILENT like every other sound.
        _ = AudioOutput.wireShellDoors
        // An agent run that fails on an expired Claude sign-in says so in Now.
        _ = ClaudeSignInState.wireAgentRunners
        // The decision key is read off the main actor now, so it is ready for the
        // first decision and an access prompt for it can never stall a door (A29).
        _ = KeychainStore.getWithoutWaiting(.typesafeApiKey)
        // Items 23+26: apply the persisted appearance (dark/light/auto) before
        // the first window renders. ThemeConfig loads theme.json in its init.
        ThemeConfig.shared.applyAppearance()
        let args = CommandLine.arguments
        let isSmokeTest = args.contains("--smoke-test")

        // Hidden dev mode: `--test-play "Song|Artist"` runs MusicTool.play
        // end-to-end (library → catalog cascade) under Grux's TCC grants and
        // exits. Writes result to ~/.grux/test-play-result.txt and stderr so
        // a parent process can capture it. Keeps activation policy accessory
        // so it doesn't steal focus or surface windows.
        // Hidden dev mode: `--dump-music-ax` lists every AXButton inside
        // Music.app's main window with its role/title/description so we can
        // identify the Play button Grux should press.
        if args.contains("--dump-music-ax") {
            WindowFacade.setActivationPolicy(.accessory)
            Task { @MainActor in
                let dump = MusicTool.dumpMusicAXButtons()
                let outPath = Persistence.gruxDir.appendingPathComponent("music-ax-dump.txt").path
                try? dump.write(toFile: outPath, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data((dump + "\n").utf8))
                try? await Task.sleep(nanoseconds: 250_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--overlay-demo` exercises the Glow / HUD
        // overlay surfaces (OrbHintBus, StageController) then
        // exits. Runs as a fresh process so the production /Applications/Grux.app
        // keeps running; the two menu bar icons briefly coexist. Used for CLI
        // end-to-end verification without popping TCC dialogs - skips all of
        // the FocusWatcher / Ambient / Mic init paths.
        if args.contains("--overlay-demo") {
            WindowFacade.setActivationPolicy(.regular)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                // 1. Push a tool-style status hint.
                OrbHintBus.shared.show(
                    message: "ORB + GLOW + HUD READY",
                    state: .thinking,
                    duration: 10.0
                )
                try? await Task.sleep(nanoseconds: 400_000_000)
                // 3. Cinematic stage - long hold so the harness screencapture
                // lands after the 0.35s fade-in and before auto-dismiss.
                StageController.shared.show(
                    message: "Orb · Glow · HUD\nOne commit ahead of Omi.",
                    state: .speaking,
                    duration: 7.0
                )
                // 4. Breadcrumb for the timing harness.
                let flag = URL(fileURLWithPath: "/tmp/grux-demo-ready.flag")
                try? "ready".write(to: flag, atomically: true, encoding: .utf8)
                // 5. Hold long enough for the stage to stay on-screen during capture.
                try? await Task.sleep(nanoseconds: 8_500_000_000)
                exit(0)
            }
            return
        }
        if let idx = args.firstIndex(of: "--test-play"), idx + 1 < args.count {
            let query = args[idx + 1]
            let parts = query.split(separator: "|", maxSplits: 1).map(String.init)
            let song = parts.first ?? ""
            let artist = parts.count > 1 ? parts[1] : ""
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let result = await MusicTool.play(song: song, artist: artist)
                let dir = Persistence.gruxDir.path
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
                let outPath = dir + "/test-play-result.txt"
                try? result.write(toFile: outPath, atomically: true, encoding: .utf8)
                if let data = "\(result)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }
        // Hidden dev mode: `--jax-retrieve "<query>"` runs the exact corpus
        // retrieval path Jax uses each turn (HybridRetriever over the .corpus
        // lane) and prints the surfaced block. Proves the you-ness corpus is
        // actually wired into reasoning. Writes ~/.grux/jax-retrieve-result.txt.
        if let idx = args.firstIndex(of: "--jax-retrieve"), idx + 1 < args.count {
            let query = args[idx + 1]
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                for _ in 0..<60 where !SemanticMemory.shared.isReady {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                let total = SemanticMemory.shared.entries.filter { $0.kind == .corpus }.count
                let block = HybridRetriever.shared.retrievedAsSystemBlock(
                    query: query, topK: 8, kinds: [.corpus]
                ) ?? "(no corpus hits)"
                let out = "corpus entries in store: \(total)\nquery: \(query)\n\n\(block)\n"
                FileHandle.standardError.write(out.data(using: .utf8)!)
                let dir = Persistence.gruxDir.path
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? out.write(toFile: dir + "/jax-retrieve-result.txt", atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--jax-seed "<path>"` distills a JaxProfile identity
        // from a seed JSON ({heuristics:[{rule,domain}], values:[{text,kind}]})
        // through the real addHeuristic/addValue (dedupe + caps), saves, and
        // prints the resulting JAX_IDENTITY block. This is how the corpus-derived
        // identity lands in the stable system block.
        // Deterministic Design Studio smoke: create a project, run one real API
        // generation, verify artifact files landed, write a verdict file, exit.
        // Same early-exit dev-mode shape as --jax-seed; reusable by Foundry.
        // A developer flag, and it returns rather than continuing. It lives in
        // its own function because everything in it runs BEFORE the window
        // exists, and one of its lines builds a store whose library is under
        // ~/Documents: at launch that is what left a wiped Mac with no window
        // at all. Keeping it out of the launch function keeps that rule flat.
        if args.contains("--studio-smoke") {
            runStudioSmoke()
            return
        }

        if let idx = args.firstIndex(of: "--jax-seed"), idx + 1 < args.count {
            let path = args[idx + 1]
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            Task { @MainActor in
                JaxProfile.shared.load()
                var added = 0
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for h in (obj["heuristics"] as? [[String: Any]]) ?? [] {
                        let rule = (h["rule"] as? String) ?? ""
                        guard !rule.isEmpty else { continue }
                        JaxProfile.shared.addHeuristic(rule: rule, domain: (h["domain"] as? String) ?? "")
                        added += 1
                    }
                    for v in (obj["values"] as? [[String: Any]]) ?? [] {
                        let text = (v["text"] as? String) ?? ""
                        guard !text.isEmpty else { continue }
                        let kind = JaxValue.Kind(rawValue: (v["kind"] as? String) ?? "value") ?? .value
                        JaxProfile.shared.addValue(text, kind: kind)
                        added += 1
                    }
                }
                let block = JaxProfile.shared.asSystemContext()
                let out = "jax-seed: added \(added) entries (heuristics=\(JaxProfile.shared.heuristics.count), values=\(JaxProfile.shared.values.count))\n\n\(block)\n"
                FileHandle.standardError.write(out.data(using: .utf8)!)
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--jax-test-comms` drives the REAL Jax comms send
        // pipeline (CommsPersona.prepareSend + DecisionGate + ResendClient) from
        // a JSON spec and writes a scored report. Reads ~/.grux/jax/test-comms.json
        // {to, subject, body, live}; live=true sends only on a PROCEED verdict.
        if args.contains("--jax-test-comms") {
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let dir = Persistence.gruxDir.appendingPathComponent("jax").path
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let specURL = URL(fileURLWithPath: dir + "/test-comms.json")
                var to = "", subject = "", body = ""
                var live = false
                if let data = try? Data(contentsOf: specURL),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    to = (obj["to"] as? String) ?? ""
                    subject = (obj["subject"] as? String) ?? ""
                    body = (obj["body"] as? String) ?? ""
                    live = (obj["live"] as? Bool) ?? false
                }
                let comms = await JaxTestHarness.runCommsTest(to: to, subject: subject, body: body, live: live)
                let blog = await JaxTestHarness.dryRunContentPipeline(kind: "blog", brief: "A short blog post for a body wash. Brand voice: direct, observational, never aspirational. No medical claims, no em dashes, dollars as $N.")
                let social = await JaxTestHarness.dryRunContentPipeline(kind: "social", brief: "A social post announcing a new body wash scent. Product is the pitch, no hype, no em dashes.")
                let prod = await JaxTestHarness.dryRunContentPipeline(kind: "production", brief: "Plan a production change: add a Subscribe and Save 15% badge to a product page. Describe the concrete steps a Claude Code session would take.")
                let report = [comms, "", "===== CONTENT DRY-RUN: BLOG =====", blog, "", "===== CONTENT DRY-RUN: SOCIAL =====", social, "", "===== CONTENT DRY-RUN: PRODUCTION =====", prod].joined(separator: "\n")
                FileHandle.standardError.write(Data((report + "\n").utf8))
                try? report.write(toFile: dir + "/test-comms-result.txt", atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--jax-confidence-test` runs the labeled confidence
        // stress battery (ConfidenceStressTest) through the SAME never-guess gate
        // path the app uses, including the ungrounded-fact check that catches an
        // invented product number (the $18 class). Scores ask-decision
        // precision/recall and writes ~/.grux/jax/confidence-test-result.txt.
        if args.contains("--jax-confidence-test") {
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let dir = Persistence.gruxDir.appendingPathComponent("jax").path
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let report = await ConfidenceStressTest.run()
                FileHandle.standardError.write(Data((report + "\n").utf8))
                try? report.write(toFile: dir + "/confidence-test-result.txt", atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--feature-review-export` seeds the Feature Review
        // (this session's main features + anything staged), has Grux generate a
        // live pitch for each, and writes the Chrome export to
        // ~/Documents/Grux/exports/grux-feature-review.html.
        if args.contains("--feature-review-export") {
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                FeatureReviewEngine.shared.bootstrap()
                await FeatureReviewEngine.shared.generateMissingPitches()
                let html = FeatureReviewExport.html(features: FeatureReviewEngine.shared.features)
                let out = Persistence.makeExportsDir().appendingPathComponent("grux-feature-review.html").path
                try? html.write(toFile: out, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data(("wrote \(out) (\(FeatureReviewEngine.shared.features.count) features)\n").utf8))
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--quality-gate-run` is the headless equivalent of the
        // Feature Review tab's "Run quality gate" button. It runs the LIVE
        // QualityGate engine (adversarial multi-dimension review + dup scan) on
        // every staged feature, prints each verdict to stderr, and writes a Chrome
        // report to ~/Documents/Grux/exports/. Lets the gate be driven from
        // the CLI without clicking, and is how a feature is run "through the gate".
        if args.contains("--quality-gate-run") {
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let engine = FeatureReviewEngine.shared
                engine.bootstrap()
                let staged = engine.features.filter { $0.status == .staged }
                for f in staged {
                    // A staged feature's diff is keyed by its immutable sha, so a
                    // pass/fail verdict is permanent. Skip re-gating it on every
                    // launch (the gate is 5 Claude calls over the full diff); only
                    // (re)review features that are unreviewed or errored.
                    let s = engine.verdicts[f.id]?.status
                    if s == .pass || s == .fail { continue }
                    await engine.runGate(for: f.id)
                }
                let html = QualityGateExport.html(features: engine.features, verdicts: engine.verdicts)
                let out = Persistence.makeExportsDir().appendingPathComponent("grux-quality-gate.html").path
                try? html.write(toFile: out, atomically: true, encoding: .utf8)
                for f in staged {
                    let v = engine.verdicts[f.id]
                    FileHandle.standardError.write(Data("gate \(f.id.prefix(8)) [\(v?.status.rawValue ?? "n/a")] \(f.title): \(v?.summary ?? "")\n".utf8))
                }
                FileHandle.standardError.write(Data("wrote \(out) (\(staged.count) staged)\n".utf8))
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--email-preview[=<voice>]` renders a brand support
        // reply through BrandEmailTemplate (the real HTML format) and writes it to
        // ~/Documents/Grux/exports/ so the formatted email can be eyeballed
        // in a browser without sending anything.
        if let pv = args.first(where: { $0.hasPrefix("--email-preview") }) {
            WindowFacade.setActivationPolicy(.accessory)
            // Safe parse: handles "--email-preview", "--email-preview=<voice>", and the
            // empty "--email-preview=" (which split-drop-empties would crash on).
            // With no voice given, preview the first configured brand. With no
            // brands configured there is no default to fall back on, so the
            // voice is blank and BrandEmailTemplate renders its unbranded
            // format, which is exactly what a fresh install would send.
            let voice: String = {
                let fallback = BrandRoster.brands.first?.id ?? ""
                guard let eq = pv.firstIndex(of: "=") else { return fallback }
                let v = String(pv[pv.index(after: eq)...])
                return v.isEmpty ? fallback : v
            }()
            let sample = "Hi there, I'm sorry to hear you're having trouble locating your order. I'll look up your order using your email address and get back to you with the status as soon as possible. Thank you for your patience."
            let html = BrandEmailTemplate.html(voice: voice, replyText: sample)
            let out = Persistence.makeExportsDir().appendingPathComponent("grux-email-preview.html").path
            try? html.write(toFile: out, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("wrote \(out) (voice=\(voice))\n".utf8))
            exit(0)
        }

        // Menu-bar / dock policy only matters for interactive launches. During
        // CLI smoke-test runs we stay accessory so nothing steals focus.
        WindowFacade.setActivationPolicy(isSmokeTest ? .accessory : .regular)
        // Notification authorization is NOT requested here. It raises a system
        // permission dialog, and on a first launch this line runs roughly 380
        // lines before the consent gate, so a stranger got prompted before the
        // onboarding flow had asked them for anything. That is the exact
        // trust-account problem the flow was written to avoid, and it is the
        // same class of defect as the ambient watchers below. Deferred into
        // startConsentGatedWork() so every permission prompt sits behind the
        // same gate.
        AppState.shared.screenPermissionGranted = ScreenCapturer.shared.hasPermission()
        Bootstrap.ensureConfig()
        AppState.shared.load()

        // If the user marked a mic as "permanent default" (e.g. DJI Mic Mini),
        // force the system default input to that device on launch. No-op
        // when the mic isn't connected - CoreAudio falls back to whatever
        // the system last selected.
        MicWhitelist.applyPreferredInputIfPossible()

        // Warm TCC attribution from a known-good launched-from-/Applications
        // state, before FocusWatcher / Ambient / Meeting detectors fire. This
        // pins the responsible process so coreaudiod's SecCode lookup binds
        // subsequent grants to THIS signed bundle, not to a stale
        // LaunchServices copy that might otherwise win the race.
        if !isSmokeTest { MicController.prewarmAtLaunch() }

        // --open-tab=<name>: auto-open the launch window on boot on a specific
        // tab. Used by verification scripts to land on Meetings/Tasks/etc.
        // without driving UI clicks through the macOS menu bar. Matches the
        // same tab keys applyTab() recognizes in LaunchRootView.
        let openTabArg: String? = {
            for a in args {
                if a.hasPrefix("--open-tab=") {
                    return String(a.dropFirst("--open-tab=".count))
                }
            }
            return nil
        }()
        if let tab = openTabArg, !tab.isEmpty {
            // AppState hasn't been fully loaded yet in all code paths, but
            // requestedTab is observed onChange in LaunchRootView so setting
            // it here guarantees the initial tab renders correctly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                // The panel counts this open as the command line's. The
                // classic shell counts nothing, so it is left no door.
                if !AppState.shared.config.legacyShell { OpensLog.shared.nextVia = .cli }
                AppState.shared.requestedTab = tab
                self.openLaunchWindow(tab: tab)
                WindowFacade.activateGrux()
            }
        }

        // --open-settings-tab=<name>: parallel hook for the Settings panes.
        // Opens the launch window on the Settings sidebar tab and selects the
        // named sub-tab (general/focus/terminal/ambient/appearance/voice/
        // presets/upgrades/backup/api/security/about). Matches the .tag()
        // keys on SettingsView's TabView; used by verification scripts.
        let openSettingsTabArg: String? = {
            for a in args {
                if a.hasPrefix("--open-settings-tab=") {
                    return String(a.dropFirst("--open-settings-tab=".count))
                }
            }
            return nil
        }()
        if let sub = openSettingsTabArg, !sub.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                AppState.shared.requestedSettingsTab = sub
                AppState.shared.requestedTab = "settings"
                self.openLaunchWindow(tab: "settings")
                WindowFacade.activateGrux()
            }
        }

        // --smoke-test: run the in-process assertion harness, write results to
        // ~/.grux/smoke-test-results.txt, then exit. Does NOT start ambient,
        // wake listener, focus watcher, or any window - pure headless run.
        if isSmokeTest {
            Task { @MainActor in
                // Give load() + keychain migration a tick to settle.
                KeychainServiceMigrator.runOnce()
                KeychainMigrator.runOnce()
                VoiceMacroRegistry.shared.load()
                CommandV2Engine.shared.load()
                await SmokeTest.runAndWriteReport()
                // Small delay so any pending async writes flush before exit.
                try? await Task.sleep(nanoseconds: 250_000_000)
                exit(0)
            }
            return
        }

        // Arm the machine-load sources, which nothing had ever done.
        //
        // `MachineLoad.current` reads thermal state and low power mode
        // nonisolated, so those two are live on every swarm start whether or
        // not this line runs. Memory pressure is the one input that genuinely
        // needs a running DispatchSource, and with no caller for
        // `startIfNeeded()` that source was never created: `memoryPressure`
        // read `.normal` for the entire life of every process, and the
        // published properties on the observable never moved once. So the type
        // that exists to say what the machine can afford was reporting a
        // constant, which is worse than reporting nothing because it looks
        // like a measurement.
        //
        // Started here rather than from a view's `.onAppear` because the
        // consumer that most needs it, `SessionConcurrency`, runs on paths that
        // have no view at all, and a ceiling that depended on somebody having
        // opened a settings pane first would be a different number on the same
        // machine depending on where the user had clicked. Idempotent, prompts
        // for nothing, opens no window, and touches no network, so it does not
        // belong behind the consent gate below.
        MachineLoad.shared.startIfNeeded()

        // Live workspace awareness MOVED TO startConsentGatedWork(). It records the same
        // two facts ScreenTimeWatcher is held back for, the frontmost app and its window
        // title, and it started here about 550 lines above that gate. snapshot() still
        // answers a chat turn on demand, so nothing is lost while the gate is shut.

        // Warm the app-launcher catalog so the first "open X" voice command
        // doesn't pay the scan cost inline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Task { @MainActor in AppCatalog.shared.buildIfNeeded() }
        }

        // One-shot: seed pre-existing local semantic memory into the companion RAG store so
        // facts captured before the memory-unification shipped become
        // search_memory-findable. Runs once (guarded by a flag), best-effort and
        // off the launch path; future stores mirror live via store().
        if !UserDefaults.standard.bool(forKey: "miniMirrorBackfilled") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                Task { @MainActor in
                    for _ in 0..<40 where !SemanticMemory.shared.isReady {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    let result = await SemanticMemory.shared.backfillMiniMirror()
                    // Only mark the one-shot done on a clean run. If the companion
                    // was offline (chunks failed), leave the guard unset so a later
                    // launch retries instead of permanently stranding the backlog.
                    if result.failed == 0 {
                        UserDefaults.standard.set(true, forKey: "miniMirrorBackfilled")
                    }
                }
            }
        }

        // Load (and seed if first launch) voice macros so the system prompt
        // can list them and run_macro can dispatch them.
        VoiceMacroRegistry.shared.load()

        // Commands V2 engine - restores any in-flight runs from disk and
        // re-arms scheduled wakeups. Builtins (smoke-hello-world,
        // check-asc-status, ship-ios-app) are registered on first load().
        CommandV2Engine.shared.load()
        // A workflow waiting on the person asks in Chat, where the answer is
        // taken (`ChatService.answerWaitingWorkflow`).
        NotificationCenter.default.addObserver(forName: .gruxCommandV2GateWaiting, object: nil, queue: .main) { note in
            guard let question = note.userInfo?["question"] as? String else { return }
            MainActor.assumeIsolated { ChatService.postGateQuestion(question) }
        }

        // Global App Store Connect submission watcher - sweeps every 12h
        // across all ~/Projects/*/.grux/ship-config.json, surfaces state in
        // the Empire dashboard, and speaks + posts a system notification on
        // any project flipping into REJECTED. Independent of any V2 workflow
        // run, so rejections during idle periods are caught.
        // GATED OFF BY DEFAULT. Until 2026-08-17 this ran unconditionally, and
        // `start()` sweeps immediately and then every 12h forever. The sweep scans
        // the filesystem for any `~/Projects/*/.grux/ship-config.json` and, if it
        // finds one ANYWHERE, mints a JWT from the `.p8` it names and calls
        // Apple's API. So a credential file left behind by some other tool was
        // enough to make Grux start talking to App Store Connect on the user's
        // behalf, unasked. Same defect shape as the GoDaddy file source and the
        // digest-inbox listener.
        //
        // The cost argument in the comment above ("~1 GET per app, ~5 apps") is
        // the original author's app count. For an install with no iOS apps the
        // whole sweep is a filesystem scan that finds nothing, twice a day.
        //
        // Nothing here is tied to any particular account: there are no hardcoded
        // App IDs, issuer ids or keys. It reads a key the user supplies. That is
        // why this is gated rather than deleted.
        if AppState.shared.config.ascMonitorEnabled {
            ASCStateMonitor.shared.start()
        }

        // Install audio ducker so Apple Music gently drops to 50% while Grux
        // speaks, then restores. Hooks the existing speech-start/stop
        // notifications - no SpeechEngine changes needed.
        //
        // install() is inert on a virgin Mac, which is what made this easy to miss: what it
        // does is wire duck() to EVERY speech-start notification, and Grux speaks in the
        // built-in macOS voice with nothing configured. So the first time it said anything
        // with Music open, an Apple event went to Music, macOS put "Grux wants access to
        // control Music" over whatever the person was doing, and approving it set another
        // app's volume to 50. Nothing in Grux ever said it touches Music.
        if AppState.shared.config.musicDuckingEnabled {
            AudioDucker.shared.install()
        }

        // Auto-bypass VPIO for external mics with their own DSP (DJI Mic,
        // Shure MV-series, etc.). macOS otherwise flips the whole output
        // chain into narrow-band comm-mode, nerfing Music/YouTube the
        // (DISPROVEN 2026-09-23: output is unaffected; what VPIO really costs is
        // another app's microphone capture. See VoiceProcessingPolicy.)
        // moment ambient listening starts. Runs once on launch; listener
        // start re-runs it for mid-session reconnects.
        MicWhitelist.autoWhitelistKnownExternalMics()

        // Song quick-select library - powers the dropdown in the playMusic
        // action editor. First launch seeds with the tracks already used in
        // the default macros.
        SongLibraryStore.shared.load()

        // Structured inbox - captures the user's "remember this" items so Grux
        // can resurface unreviewed ones in PENDING_MEMORIES. Loads from disk
        // if a prior session already wrote entries.
        InboxStore.shared.load()

        // Nightly open-PR digest (built by the companion digest service). Restore
        // the last cached digest so the Empire Dashboard has something to show
        // before the first push/pull lands this session.
        PRDigestStore.shared.load()

        // Nightly test report (built by the companion nightly service). Restore
        // the last cached report so the Empire Dashboard's Nightly Tests section
        // has something to show before the first push/pull lands this session.
        TestDigestStore.shared.load()

        // Empire-wide ops snapshot (built hourly by the companion snapshot service).
        // Restore the last cached snapshot so the Empire Dashboard's Ops grid has
        // data before the first live pull this session.
        EmpireSnapshotStore.shared.load()

        // Social Ops Cockpit grid (per-brand x per-platform health, built by the
        // companion social-ops service). Restore the last cached grid so the
        // Empire Dashboard's Social Ops section has data before the first pull,
        // and instantiate the coordinator so inbound change-events (routed
        // through PRInboxServer for kind=="social-ops") have a live target.
        SocialOpsStore.shared.load()
        _ = SocialOpsCoordinator.shared
        // Live brands-poster posting status (the companion poster service).
        // Poll at launch, not just when the Empire dashboard is open, so the
        // needs_reauth / circuit-open alerts catch the silent-darkness failure
        // mode even with the dashboard closed (mirrors SocialOps wiring above).
        BrandsPosterStore.shared.load()
        BrandsPosterStore.shared.startPolling()
        // Daily health digest + weekly reach-trend cards (native notification +
        // chat card + compact phone push). 15-minute tick with yyyy-MM-dd /
        // yyyy-Www UserDefaults guards so each fires once per period and a tick
        // missed to sleep/restart just fires on the next wake.
        SocialOpsCoordinator.shared.startSchedulers()

        // Self-build roadmap (Tier S/A/B/C). Seeds from the 2026-04-24 Omi
        // parity review on first launch, then persists the user's edits.
        RoadmapStore.shared.load()

        // Foundry (Self-Upgrade tab): wire ProposalStore + TrustLedger into
        // the dashboard display layer and install the Accept/Reject hooks
        // (transition + trust records + audit records + local timeline).
        // Idempotent; safe to call once on launch.
        FoundryViewBridge.activate()

        // Foundry engine (Phase B/C): rollback keeper heartbeat + resume any
        // pending 24h watch, approval-to-install hook, governor cycle runner
        // + 60s scheduler tick, and the Accept-card build kick. Must run
        // AFTER FoundryViewBridge.activate() so the engine can wrap (not
        // replace) the bridge's onAccept transition + audit hook.
        //
        // OFF BY DEFAULT, and the contract said so before the flag existed:
        // `grux.foundry.enabled` is declared "CR-20, the self-upgrade loop, off by
        // default" and nothing read it, so the governor's 60 second tick ran on every
        // launch and scheduled a nightly pass that harvests signals and spends model
        // tokens on the first night of any install.
        if AppState.shared.config.foundryEnabled {
            FoundryEngine.shared.activate()
        }

        // Backstop the swarm-worker confinement: catch any UNTRACKED file an
        // agent drops into the LIVE build tree's Sources/ and quarantine it
        // before Foundry can relaunch onto a broken tree.
        LiveTreeTripwire.shared.activate()

        // MCP servers (Items 14+15): start every enabled server and pull its
        // tool list so ChatService.allTools() picks them up on first send.
        MCPManager.shared.bootstrap()
        DesignStudioIntegration.wireSeams()

        // Jax (the user's cognitive clone fused into Grux).
        // Warm the persona / learned heuristics + values so the first chat turn's
        // system prompt is fully built (lazy load from ~/Library/Application Support/Grux/jax/).
        _ = JaxProfile.shared
        // Real product-facts catalog (grounding source for content generation).
        // Self-seeds product-catalog.json on first access so generated copy
        // retrieves real prices/sizes/SKUs, never invents them.
        _ = ProductCatalog.shared
        // Load the persisted decision-gate approval queue from ~/.grux/jax/approvals.json
        // so Jax HQ renders any items waiting from a prior session.
        _ = ApprovalQueue.shared
        // P-R-6: a NEW task gets its priority and project judged once, both
        // on one call, raise only. Tasks already on the stack at launch are
        // marked seen and never asked about.
        TaskJudgments.shared.start()
        // MOVED TO startConsentGatedWork(). The comment here used to say the probe was
        // cheap, and it was not: probing Notes sent an Apple event, which raised
        // "Grux OS wants access to control Notes.app" on a first launch before any Grux
        // window was guaranteed to be up. See the call site down there for the rest.

        // FIRST CONTACT GETS A STATUS FILE BEFORE ANYTHING CAN BLOCK.
        //
        // Measured on a Mac that had never run Grux: the app launched, logged three lines,
        // and stopped. `~/.grux/setup-status.json` was still absent four minutes later and
        // the fire-setup-status trigger produced nothing either, so every read in the CLI
        // answered "Grux has not written its setup status yet, open Grux once and run this
        // again" to somebody who had just done exactly that. Permanently.
        //
        // The migration below enumerates Keychain items, which needs the login keychain
        // unlocked, and macOS raised a modal naming `grux-vault`, one of the service strings
        // in `KeychainServiceMigrator.renames`. On a Mac whose account password was ever
        // reset through an Apple ID the login keychain keeps the OLD password, so that
        // dialog cannot be answered and the launch never gets past it.
        //
        // ONLY WHEN THE FILE DOES NOT EXIST, which is what keeps the ordering below honest.
        // A machine that has run Grux before already has an accurate document on disk, so it
        // keeps the migrate-then-write order exactly as it was and never publishes a stale
        // one. A machine that has never run Grux has nothing to migrate, so writing now is
        // as accurate as writing later, and it is the difference between a usable CLI and a
        // command line that can never be reached.
        if !FileManager.default.fileExists(atPath: SetupStatusFile.url.path) {
            SetupStatusFile.write()
        }

        // Move any Keychain items still filed under a previous service name.
        // Must run BEFORE KeychainMigrator, and before anything reads a key:
        // the service string is part of a Keychain item's primary key, so
        // until this has run, every credential stored under the old name is
        // present on the machine and invisible to the app.
        KeychainServiceMigrator.runOnce()

        // One-time migration of any legacy plaintext API keys out of
        // config.json and into the macOS Keychain. Idempotent; safe to call
        // on every launch. Must run AFTER load() so state.config reflects
        // what's on disk, and BEFORE anything tries to read a key.
        KeychainMigrator.runOnce()

        // Terminal Focus was removed; its Claude Code hook ran after every tool call in
        // every session on this Mac. Uninstall exactly what it wrote, once, off the main thread.
        TerminalFocusRemoval.runOnceAtLaunch()

        // The setup surface, written once the credentials are actually readable.
        //
        // ORDER IS LOAD BEARING. Both migrators above move credentials into the names the
        // app reads, and until they have run every key stored under an old service string
        // is present on the machine and invisible. Writing the status file before them
        // would publish a document saying nine credentials are missing, which is exactly
        // the class of stale answer that mic-status.json shipped with.
        //
        // AND IT HAS TO BE THIS CALL SITE. The first attempt anchored on the same line of
        // source with less indentation and landed inside the `if isSmokeTest` branch, so a
        // normal launch never wrote the file at all. Nothing failed: the trigger path still
        // worked and every test still passed. The only way to see it was to install the
        // build and look for a file that was not there.
        SetupStatusFile.write()

        // The control plane. MCP over a Unix domain socket at 0600 in the same directory,
        // which is the MCP specification's own guidance for a local server that cannot use
        // stdio: a restricted IPC mechanism rather than loopback HTTP. Grux opens no
        // network port, and ControlSocketTests asserts that with lsof.
        //
        // After the status write on purpose, so a client that connects the instant the
        // socket appears finds a status file already on disk rather than racing it.
        //
        // The flag defaults to ON, so nothing changes for anybody who has the CLI working.
        // It exists because there was no answer to "can this be turned off": stop() had no
        // caller, and any process running as this person can speak MCP to the app, including
        // one tool that activates Grux and puts a permission dialog on screen.
        if AppState.shared.config.controlSocketEnabled {
            GruxControlSocket.shared.start()
        }

        // NO PERMISSION PRECONDITION HERE, and removing it is the point.
        //
        // `tick()` already checks `ScreenCapturer.shared.hasPermission()` on every pass, so
        // this second copy bought nothing and cost the whole first launch: on a Mac that has
        // not granted Screen Recording yet, `start()` was never called, the timer was never
        // created, and granting the permission during onboarding changed nothing until the
        // person quit and reopened Grux. Which means the first-frame consent gate this wave
        // just added to `tick()` would never have been reached in the exact scenario it was
        // written for.
        //
        // Armed here, held in `tick()`, which is the pattern the rest of this wave settled on.
        if AppState.shared.config.screenAnalysisEnabled {
            FocusWatcher.shared.start()
        }

        // One listening mode, one controller. It maps Always on, After Hey
        // Grux and Off onto the ambient and wake doors, which keep their
        // consent dialogs. Delayed so any prompt appears after the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in await ListeningController.shared.applyAtLaunch() }
        }

        // Commitment scheduler: scans ambient memories every 10s for time-
        // anchored commitments, fires glass Reminder Toasts when due.
        //
        // The ambient flag is read INSIDE the tick, not here, and getting that wrong is a
        // bug I shipped into this same wave and a reviewer caught.
        //
        // Wrapping this call in `if config.ambientEnabled` looked like the same thing
        // AmbientCoach does twenty lines above. It is not. `AmbientState.enable()` is the one
        // door every ambient toggle goes through (Settings, the menu bar row, the HUD capture
        // pill) and it re-fires `AmbientCoach.shared.start()` itself. Nothing re-fires this
        // one: it had exactly one call site in the whole tree. So somebody who turned ambient
        // on mid-session got memories captured and no commitment ever scheduled, silently,
        // until they quit and reopened Grux.
        //
        // Reading the flag in `checkAndFire()` instead matches WorkdayLog, DecisionLog and
        // PersonMemory, which all take the same shape, and it means the timer is always armed
        // and the answer is always current.
        CommitmentScheduler.shared.start()

        // User cron scheduler: fires user-defined recurring schedules
        // (Schedules tab) that run V2 workflows or one-shot agent prompts.
        UserCronScheduler.shared.start()

        // Jax voice-first briefings: speaks a morning (07:00) and night (21:00)
        // briefing in the user's voice clone, local time, DST-safe. Fires an
        // immediate catch-up tick so a launch inside a slot's hour still speaks.
        // Starting the timer here is deliberate rather than consent-gated: the
        // engine's own dueSlot() refuses to fire anything while the first-run
        // flow is on screen, and a timer that is already ticking is what makes
        // the catch-up land the minute that flow finishes, with no relaunch.
        BriefingEngine.shared.start()

        // Jax Phase 2: the goal-pursuit engine. Wakes nightly to pick and plan
        // the highest-leverage next move toward the user's real goals. Defaults to
        // SIMULATE mode (plans + logs, executes nothing), so booting it is safe.
        GoalPursuitEngine.shared.start()

        // Feature Review: seed this session's features + discover staged ones so
        // Grux can pitch them and the user can decide what reaches main.
        FeatureReviewEngine.shared.bootstrap()

        // Post-merge safety net: detect a crash-loop while a freshly merged
        // feature is in its watch window and roll that feature back behind the
        // guarded build-gated script. Arms this session's crash flag.
        PostMergeWatch.shared.activate()

        // IMAP inbox sync: route freshly fetched support-brand mail through
        // the same classify/draft/audit/stage path the webmail scraper uses,
        // so new IMAP mail lands in Support Drafts automatically.
        InboxSyncEngine.triageHook = { inbox, msgs in
            await EmailTriageEngine.shared.triageFetched(inbox: inbox, messages: msgs)
        }

        // Workday Log MOVED TO startConsentGatedWork() for the reason stated there, which
        // is the same reason the two recap schedulers went behind it. The hourly ambient
        // summarizer stays: it folds a ring buffer Grux already holds and raises nothing.
        AmbientHourlySummarizer.shared.start()

        // Notification triage: hourly fold of batched (non-interrupt)
        // notifications into the ambient-summaries digest for the recap.
        TriageBatchQueue.shared.start()

        // Support-email triage: hourly sweep of the open Outlook tab(s),
        // staging brand-voice reply drafts for one-tap send. Nothing sends
        // automatically; drafts land in the Support Drafts window.
        SupportTriageScheduler.shared.start()

        // Decision log: nightly pass extracts explicit decisions from the
        // day's ambient transcript and persists them at ~/.grux/decisions/
        // so Grux chat can answer "why did I switch to X" with a sourced quote.
        // Fires in the [3, 6) local window so it lands before WorkdayLog.
        //
        // OFF by default. checkAndFire() runs synchronously inside start(), so a first
        // launch between 3 and 6 AM went straight into the extraction, and once ambient is
        // on this ships the last 1440 minutes of transcript through AmbientLLM, which falls
        // through to the routed CLOUD provider when the local model is unreachable. Nothing
        // named it anywhere: no feature row, no contract step, no Settings row.
        DecisionLogScheduler.shared.start()

        // Person memory (CRM-lite): nightly NER pass over the day's ambient
        // transcript builds a dossier per named person at ~/.grux/people/<slug>.json.
        // Grux chat surfaces a "person card" when a known name comes up again.
        // Fires in [4, 6), staggered after the decision log's [3, 6).
        //
        // OFF by default, and of the group this is the one whose default is not really a
        // question: it builds dossiers about OTHER PEOPLE, by name, with relationships,
        // dated facts and verbatim quotes, and nobody had ever been told it exists.
        PersonMemoryScheduler.shared.start()

        // Stuck detector: watches idle + silence during an active focus
        // session and nudges the user if they have been quiet + keyboard-idle for
        // `stuckThresholdMinutes` minutes.
        StuckDetector.shared.start()

        // Everything that pops a macOS permission dialog or records what the
        // user is doing is held behind the first-run flow. See
        // startConsentGatedWork() for the list and startWhenOnboardingIsDone()
        // for how the gate opens without a relaunch.
        startWhenOnboardingIsDone()

        // Meeting-app detector: watches NSWorkspace for Zoom / Meet / FaceTime /
        // Teams / Webex becoming frontmost and auto-offers meeting capture
        // via an orb hint. The actual start is still the user's click - we never
        // auto-start capture without consent.
        //
        // "We never auto-start capture without consent" was true and was not the whole
        // story. The OFFER had no gate at all, and it sat deliberately outside the
        // first-run flow three lines below the comment saying what that flow holds back. So
        // somebody who had acknowledged nothing, and might never intend to record a call,
        // got a floating always-on-top overlay reading "FaceTime detected" and a menu bar
        // takeover every time they answered one. Now off by default, with a toggle beside
        // the recording-consent row it belongs to.
        if AppState.shared.config.meetingAutoDetectEnabled {
            MeetingAppDetector.shared.start()
        }

        // Crash-safe audio recovery: if a previous session died mid-capture,
        // replay the WAL'd PCM through WhisperKit and upsert the matching
        // MeetingRecord. Deferred 3s so WhisperKit has a chance to warm up
        // via the ambient bootstrap above (the recovery path reuses that
        // same shared instance). Pure local-first; no network calls.
        if AppState.shared.config.crashSafeAudioEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                AudioWALRecovery.runOnLaunch()
            }
        }

        // iPhone companion receiver. Starts immediately so the Grux Phone app
        // can auto-reconnect whenever it comes back onto the same Wi-Fi. If
        // no secret is configured yet, PhoneReceiverService.start() creates
        // one and advertises - safe idempotent boot path.
        //
        // Gated OFF by default (Settings → Phone companion). Skipping it here is
        // what keeps an unpaired install from sitting on a listening socket it
        // never uses. The listener is same-network only; there is no tunnel and
        // no public ingress.
        if AppState.shared.config.phoneCompanionEnabled {
            PhoneReceiverService.shared.start()
        }

        // PR-digest inbox: a tiny token-guarded HTTP server (POST /api/inbox)
        // the companion digest service pushes the nightly open-PR digest
        // into. Bound on :3852 across the private network. Pulling from the
        // companion is the fallback (PRDigestStore.refresh), so a busy port is non-fatal.
        //
        // GATED OFF BY DEFAULT, for exactly the reason the phone companion above
        // is: an install with no companion service pushing to it must not sit on
        // a listening socket it never uses. This ran unconditionally until
        // 2026-08-16, so every install opened *:3852 on ALL INTERFACES at launch
        // for a feature the user had not configured and, on a fresh install,
        // could not use. Measured with lsof: it was the only listening socket
        // the app owned.
        //
        // The token guard on non-loopback requests was real and is not the
        // point. An unconfigured feature should not be reachable at all.
        if AppState.shared.config.prInboxEnabled {
            PRInboxServer.shared.start()
        }

        // Agent framework - bootstrap restores any stale jobs from disk and
        // marks them failed so the user sees them. New swarms launch via the
        // agent_swarm_start tool from chat or directly from the Agents tab.
        Task { @MainActor in await AgentService.shared.bootstrap() }

        // Commands V2 milestone fan-out - listens for phase transitions on
        // ship-ios-app and triggers macOS banner + GruxPhone push + orb hint
        // for the marquee phases (build/walkthrough/publish/decide-next). Safe
        // to call before the engine has loaded - the dispatcher just observes
        // a NotificationCenter feed that won't fire until something is running.
        CommandV2PhaseNotifier.shared.start()

        // Item 35: outbound webhooks, observes the CommandsV2 phase feed
        // plus the agent-job and reminder lifecycle seams.
        Task { await WebhookManager.shared.start() }

        // Item 32: daily auto-backup tick (off by default, toggled in
        // Settings, Backup). Harmless when disabled, the timer just idles.
        BackupScheduler.shared.start()

        // Shell state bus (item 24): translate existing speech/wake/focus/
        // workflow/agent signals into one canonical ShellMoment feed.
        // Subscriptions only; no producer was modified.
        ShellStateAdapters.shared.start()

        // Orb command palette: its own Carbon slot (GRXP/id 2). Default Cmd+Shift+P.
        OrbCommandPaletteController.shared.registerHotkey()

        // Live workspace focus overlay - floating top-right card that shows
        // the current focus task and pulses in the verdict color. Visible
        // preference persists across launches via FocusOverlayState.
        // Gated on onboarding, because this card defaults to visible on first
        // launch, so a brand new user got a
        // floating panel over their setup flow announcing a seeded starter task
        // they had not written. It is a good feature and a bad first impression,
        // and the two are separable.
        if FocusOverlayState.shared.isVisible, OnboardingModel.shared.stage == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                FocusOverlayController.shared.show()
            }
        }

        // Floating "orb anywhere" - Grux's desktop identity artifact. Persists
        // across Spaces, click to mute, drag to move. Omi has no equivalent.
        //
        // Audio-reactive speaking glow - when Grux starts speaking (TTS) AND
        // `audioReactiveGlow` is on, fire a cyan glow around the active
        // non-Grux window. The 3.5s auto-dismiss handles cleanup; for longer
        // TTS responses we re-fire on the next rising edge.
        speakingGlowSub = SpeechEngine.shared.$isSpeaking
            .removeDuplicates()
            .sink { speaking in
                guard speaking else { return }
                Task { @MainActor in
                    guard AppState.shared.config.audioReactiveGlow else { return }
                    GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .speaking)
                }
            }

        // Cold-boot default lands on the Home tab (the daily-launch briefing),
        // unless a --open-tab=<name> arg was supplied. The arg path fires its
        // own openLaunchWindow(tab:) at +0.8s and sets requestedTab, so it
        // still wins over this home default when present.
        if openTabArg == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // The Command Panel rests with no pane; the classic shell on Home.
                self.openLaunchWindow(tab: AppState.shared.config.legacyShell ? "home" : PanelKeys.none)
                WindowFacade.activateGrux()
            }
        }

        // Observe notification actions
        NotificationCenter.default.addObserver(forName: .gruxNotificationAction, object: nil, queue: .main) { note in
            Task { @MainActor in AppDelegate.shared?.handleAction(note: note) }
        }

        // Re-check screen permission periodically (permission is granted in System Settings).
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                AppState.shared.screenPermissionGranted = ScreenCapturer.shared.hasPermission()
            }
        }

        // Debug injection: if a file appears at ~/.grux/inject-chat.txt with
        // non-empty text, treat its contents as a user chat message (same
        // path a Whisper-transcribed utterance takes). Useful for stress
        // testing tool use + conversation flow without the audio stack.
        // BEHIND THE SAME SWITCH AS THE CONTROL SOCKET, because it is the same kind
        // of thing: a file in the home folder that any process running as this
        // person can write, whose contents go to ChatService.send() and therefore
        // to a model with tools. It is a debug seam that shipped, and the CLI has
        // made it redundant. Default is ON so nothing changes for anybody using
        // it, and the answer to "can this be turned off" is now yes.
        if AppState.shared.config.controlSocketEnabled {
            startInjectChatWatcher()
        }
    }

    /// The `--studio-smoke` developer path: one real generation, a verdict
    /// file, then exit. Never reached without the flag.
    private func runStudioSmoke() {
            WindowFacade.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            Task { @MainActor in
                AppState.shared.load()
                let store = DesignProjectStore.shared
                let project = store.create(title: "Studio Smoke", tags: ["smoke"])
                let config = DesignRunConfig(route: .api, modelId: "claude-haiku-4-5-20251001")
                await DesignStudioEngine.shared.generate(
                    projectId: project.id,
                    brief: "A single dark page with one centered hero headline reading GRUX STUDIO LIVE in bold white type on a near black background, one violet accent underline below it, nothing else.",
                    config: config
                )
                let files = store.artifactFiles(id: project.id)
                let err = DesignStudioEngine.shared.lastError
                let indexHTML = store.siteIndexURL(id: project.id)
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let heroFound = indexHTML.contains("GRUX STUDIO LIVE")
                let verdict = (err == nil && !files.isEmpty && heroFound) ? "PASS" : "FAIL"
                let out = "studio-smoke VERDICT: \(verdict)\nproject: \(project.slug)\nfiles: \(files.joined(separator: ", "))\nheroFound: \(heroFound)\nerror: \(err ?? "none")\n"
                let dir = Persistence.gruxDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? out.write(to: dir.appendingPathComponent("studio-smoke-result.txt"), atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 250_000_000)
                exit(0)
            }
    }

    // MARK: - Consent gate

    /// Hold the consent-gated launch work until the first-run flow is finished,
    /// and make sure it still starts if that happens later in THIS launch.
    ///
    /// An install that is already set up takes the immediate branch: `stage` is
    /// `.done`, which is also where the free migration lands anyone who already
    /// had a model key, so a set-up machine boots exactly as it did before this
    /// gate existed.
    ///
    /// A first run takes the subscription branch. This watches the published
    /// stage rather than sampling `isPresenting` once at boot, because a gate
    /// that only opens on the NEXT launch is a worse bug than the ungated start
    /// it replaced: the app would sit there half dead, recording nothing and
    /// saying nothing, until the user quit and reopened it. `.first()` completes
    /// the subscription on the first `.done`, so this can never fire twice, and
    /// a later Settings "Start over" does not re-run watchers already running.
    private func startWhenOnboardingIsDone() {
        guard OnboardingModel.shared.isPresenting else {
            startConsentGatedWork()
            return
        }
        onboardingGateSub = OnboardingModel.shared.$stage
            .filter { $0 == .done }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.onboardingGateSub = nil
                    self?.startConsentGatedWork()
                }
            }
    }

    /// The launch work that needs consent first. Every start below either pops
    /// a macOS permission dialog, records what the user is doing, or talks out
    /// loud, and the first-run flow has not asked for any of it yet:
    /// ScreenTimeWatcher alone puts the "Grux would like to control this
    /// computer using accessibility features" dialog on screen within about
    /// half a second of a first launch, on top of the onboarding screen, and
    /// then starts logging the frontmost app and window title every 10s. A
    /// permission prompt is a withdrawal from a trust account that has not been
    /// paid into yet.
    ///
    /// Nothing here changed WHAT it does, only when it starts. Every one of
    /// these starts is idempotent (each guards on its own timer/observer being
    /// nil), so a second call is a no-op.
    private func startConsentGatedWork() {
        // Notifications: raises a system permission dialog, so it belongs behind
        // this gate rather than on the unconditional launch path where it used
        // to sit. Smoke runs never reach here (they exit before the gate is
        // armed), which preserves the old `if !isSmokeTest` behaviour.
        NotificationManager.shared.requestAuthorization()

        // Screen-time watcher: polls frontmost app + window title every 10s,
        // writes NDJSON to ~/.grux/ambient/screentime-YYYY-MM-DD.ndjson. Idle
        // is flagged via CGEventSource so per-app dwell can exclude AFK time.
        // Window title needs Accessibility permission, prompted on first start.
        ScreenTimeWatcher.shared.start()

        // Chrome-tab watcher: pairs Chrome's active tab URL + title to the
        // screen-time stream every 15s, but ONLY while Chrome is frontmost.
        // Powers per-brand attribution (which domains map to which brand).
        // Needs Apple Events (Automation > Google Chrome) on first run.
        ChromeTabWatcher.shared.start()

        // Music watcher: polls Spotify.app + Music.app every 30s for now-playing
        // state, writes NDJSON to ~/.grux/ambient/music-YYYY-MM-DD.ndjson. Only
        // touches apps that are already running. Needs Apple Events permission
        // for each (granted on first prompt).
        MusicWatcher.shared.start()

        // Notification-storm watcher: polls the notificationd SQLite store
        // every 60s and appends one NDJSON line per delivered notification
        // to ~/.grux/ambient/notifications-YYYY-MM-DD.ndjson. The daily recap
        // surfaces interrupt counts via WorkdayLogAssembler.
        NotificationWatcher.shared.start()

        // Sleep watcher: NSWorkspace willSleep/didWake → NDJSON at
        // ~/.grux/ambient/system-events-YYYY-MM-DD.ndjson. The workday log
        // reads these so multi-hour sleep gaps don't inflate drift minutes.
        SleepWatcher.shared.start()

        // Calendar correlator: launch only reads the EventKit state and logs
        // it. Asking here put a Calendar dialog over onboarding on a fresh
        // install and again after every re-signed build; the Calendar pane
        // asks when a person opens it (AmbientPromptGuardTests). Events are
        // correlated lazily when WorkdayLogAssembler builds the daily log,
        // and only with access granted.
        WakeLog.shared.log("calendarCorrelator: launch state \(CalendarCorrelator.currentPermissionState()) (not asking)")

        // The two recap schedulers are here for the third reason rather than
        // the first two: each checks its window immediately on start, and each
        // fires a full-screen glass takeover AND speaks it aloud. Neither is
        // behind an enable flag, so a first launch at 8 PM or 10 PM used to put
        // a talking takeover over the onboarding screen, reading out a recap of
        // a day the app was not installed for.

        // Daily recap scheduler: fires a full-screen glass takeover at the
        // configured hour (default 22:00 local).
        DailyRecapScheduler.shared.start()

        // Energy + focus recap scheduler: fires at energyRecapHour (default
        // 20:00 local). Numbers-first surface (hours, top apps, focus breaks)
        // distinct from the 10pm DailyRecap which is the warmer task wrap-up.
        EnergyRecapScheduler.shared.start()

        // The Workday Log is here for the same third reason: checkAndFire() runs
        // synchronously inside start(), the only guard is `hour >= 6 && hour < 10`, and
        // lastFiredDayKey is nil on a fresh Mac. So a first double-click at 8:15 AM built a
        // full report of a day the app was not installed for, out of the person's own
        // project names, branches and commit messages. It sat 34 lines above this gate.
        WorkdayLogScheduler.shared.start()

        // Frontmost app plus AX window title, on every activation. Exactly what
        // ScreenTimeWatcher is held back for, and idempotent, so the move is safe.
        WorkspaceObserver.shared.start()

        // The corpus permission probe. It belongs here rather than on the launch path
        // because probing Notes sends an Apple event and macOS answers an event it has no
        // decision for with a modal, which is precisely what ChromeTabWatcher and
        // MusicWatcher are held back for. The probe itself no longer prompts either, so
        // this is belt and braces, and the step is the one the contract already wrote for
        // this: "Nothing is indexed until you choose."
        //
        // Until then the rows read "Status unknown until first run.", which is true.
        if CapabilityResolver.isSatisfied(.stepCorpusSourcesConfirmed) {
            CorpusCoordinator.shared.bootstrap()
        }
    }

    private var injectChatSource: DispatchSourceFileSystemObject?
    private var injectChatFD: Int32 = -1
    private func startInjectChatWatcher() {
        let dir = Persistence.gruxDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("inject-chat.txt")
        // 0600, LIKE THE SOCKET IT SHARES A SWITCH WITH. Anything written here reaches
        // ChatService.send() and therefore a model with tools, so the file's permissions are
        // part of the security posture and not a detail. It was created with the default
        // mask, which leaves it world readable: a line sitting in it before the 0.8 second
        // timer picks it up was legible to any other account on the Mac.
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "".write(to: file, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? "".write(to: file, atomically: true, encoding: .utf8)
            WakeLog.shared.log("inject-chat: '\(trimmed)'")
            // Swarm agents report through this file (AgentService), so a line
            // here is never the person's own ask.
            Task { @MainActor in await ChatService.shared.send(userText: trimmed, initiator: .agent) }
        }

        // Every ~/.grux/fire-* file-drop trigger, in Triggers/AppTriggers.swift.
        // Registered here, behind the same switch as inject-chat, and armed below.
        AppTriggers.register(in: dir)

        // Stop decorative animation when nobody is looking. Must come after the windows
        // exist so the first occlusion read is meaningful.
        MotionSuspension.shared.start()

        // Arm the single watcher that replaced 57 polling timers. Registration order does
        // not matter; this must come after all of them.
        TriggerWatcher.shared.start()
    }

    func openWindow(_ id: String) {
        openWindowAction?(id)
        if id == "chat" || id == "settings" { openLaunchWindow(tab: id) }
    }

    func registerOpenWindow(_ action: @escaping (String) -> Void) {
        openWindowAction = action
    }

    // Dedicated window for the iPhone QR pairing UI. Uses a plain NSWindow
    // rather than routing through SwiftUI's `openWindow` action because
    // AppDelegate has no easy hook into that environment, and the trigger
    // file handler runs from a Timer (off-scene). Single-instance - if the
    // window already exists, we raise it instead of creating another.
    private var phonePairingWindow: NSWindow?
    /// The one Grux Settings window the Command Panel shell opens, from the
    /// foot gear and the menu bar. A plain NSWindow for the same reason as
    /// Pair iPhone: AppDelegate has no hook into SwiftUI's openWindow.
    private(set) var settingsWindow: NSWindow?

    func openSettingsWindow() {
        if let win = settingsWindow {
            if win.isMiniaturized { win.deminiaturize(nil) }
            WindowFacade.makeKeyAndOrderFront(win)
            WindowFacade.activateGrux()
            return
        }
        let hosting = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "Grux Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.contentMinSize = Self.settingsWindowFloor
        win.setContentSize(Self.settingsWindowResting)
        win.center()
        settingsWindow = win
        WindowFacade.makeKeyAndOrderFront(win)
        WindowFacade.activateGrux()
    }

    /// SettingsView's own frame: minimum 520 x 400, ideal 680 x 620.
    static let settingsWindowFloor = NSSize(width: 520, height: 400)
    static let settingsWindowResting = NSSize(width: 680, height: 620)

    func openPhonePairingWindow() {
        if let win = phonePairingWindow {
            WindowFacade.makeKeyAndOrderFront(win)
            WindowFacade.activateGrux()
            return
        }
        let hosting = NSHostingController(rootView: PhonePairingView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Pair iPhone"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 380, height: 560)
        win.setContentSize(NSSize(width: 380, height: 560))
        win.center()
        phonePairingWindow = win
        WindowFacade.makeKeyAndOrderFront(win)
        WindowFacade.activateGrux()
    }

    func openEmpireDashboardWindow() {
        if let win = empireDashboardWindow {
            WindowFacade.makeKeyAndOrderFront(win)
            WindowFacade.activateGrux()
            return
        }
        let hosting = NSHostingController(rootView: EmpireDashboardWindow())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Empire Dashboard"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        let minContent = NSSize(width: 720, height: 480)
        win.contentMinSize = minContent
        win.setContentSize(NSSize(width: 880, height: 600))
        win.center()
        empireDashboardWindow = win
        WindowFacade.makeKeyAndOrderFront(win)
        WindowFacade.activateGrux()
    }

    func openLaunchWindow(tab: String = "chat") {
        AppState.shared.requestedTab = tab
        if let win = launchWindow {
            // makeKeyAndOrderFront does NOT restore a minimized window and does
            // not unhide a hidden app, so these two lines are still needed for
            // those two states.
            //
            // They are NOT sufficient in general, and the earlier version of
            // this comment claimed they were. Measured on macOS with Grux
            // running as a menu-bar app with no window: the trigger arrives,
            // this method runs, a window IS created (CGWindowList .optionAll
            // lists it at 1040x732, titled "Grux OS"), and it never becomes
            // ON-SCREEN. It is neither hidden nor minimized, so neither call
            // below applies. The cause is activation policy: a background app
            // cannot pull itself to the front, and NSApp.activate does not grant
            // that. `open -b com.gruxai.grux` from outside brings the same window
            // id on screen immediately.
            //
            // So --open-tab and fire-open-tab still cannot surface a window on
            // their own from a fully background app. The sweep in
            // Grux-Mac/tools/grux-sweep.sh works around it by activating the app
            // itself, which an external tool is allowed to do and this app is
            // not. Do not "fix" that by adding more window calls here.
            WindowFacade.unhideGrux()
            if win.isMiniaturized { win.deminiaturize(nil) }
            WindowFacade.makeKeyAndOrderFront(win)
            WindowFacade.activateGrux()
            return
        }
        WindowFacade.unhideGrux()
        let legacy = AppState.shared.config.legacyShell
        // One root for both shells, so the classic-sidebar switch is live.
        let hosting = NSHostingController(rootView: ShellRootView(defaultTab: tab).environmentObject(AppState.shared))
        // The panel resizes the window itself when a pane opens and closes;
        // the hosting controller must not fight it with its own ideal size,
        // which on some relaunches it otherwise applies after first layout.
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "Grux OS"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        // Disable AppKit state restoration so a narrow frame from an
        // older session can't re-appear and collapse the layout.
        win.isRestorable = false
        // NSWindow.minSize (frame-level) + contentMinSize both get set so
        // neither macOS nor NSHostingController can shrink below the
        // side-by-side threshold. This is the REAL floor (the SwiftUI
        // .frame(minWidth:) is advisory and was overridden here). It MUST be
        // >= nav sidebar (240) + the widest detail pane's true min. The chat
        // tab is the widest at 560 (threads 210 + conversation 350), so
        // 240 + 560 = 800; 840 adds slack. Was 920 while ChatView demanded an
        // 820 min, so at the floor the detail pane only got 680 < 820 and the
        // content overflowed and clipped off both edges when the user narrowed the
        // window. Lowering ChatView's min to 560 and this floor to 840 keeps
        // them in agreement so the layout reflows cleanly instead of clipping.
        //
        // The Command Panel's floor is the panel itself: 420 wide with no pane
        // (a floor below the fixed panel would clip it), and the sizer raises
        // it while a pane is open.
        let minContent = Self.launchWindowFloor(legacy: legacy)
        let sizer = LaunchWindowSizer(window: win)
        sizer.setMinimum(minContent)
        // Force an explicit initial content size every launch (was getting
        // overridden to ~620pt by SwiftUI's preferred hosting size on some
        // relaunches, which made the sidebar overlap the detail pane). A
        // --win-w / --win-h launch override exists for narrow-layout
        // verification; it is clamped to the content minimum below.
        let argv = CommandLine.arguments
        func argValue(_ flag: String) -> Double? {
            guard let a = argv.first(where: { $0.hasPrefix(flag + "=") }) else { return nil }
            return Double(a.dropFirst(flag.count + 1))
        }
        let resting = legacy ? Self.legacyRestingContent
            : NSSize(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let explicitW = argValue("--win-w")
        let initW = max(minContent.width, explicitW ?? resting.width)
        // The panel's first sizing pass would otherwise put an explicit
        // --win-w straight back to 420.
        explicitLaunchWidthPending = !legacy && explicitW != nil
        let initH = max(minContent.height, argValue("--win-h") ?? resting.height)
        win.setContentSize(NSSize(width: initW, height: initH))
        win.center()
        launchWindow = win
        WindowFacade.setLevel(LaunchWindowSizer.level(keepOnTop: AppState.shared.config.keepOnTop,
                                                      legacyShell: AppState.shared.config.legacyShell), of: win)
        let toggle = PaneToggleAccessory.make(hidden: legacy)
        win.addTitlebarAccessoryViewController(toggle)
        paneToggleAccessory = toggle
        // A resize that is not a drag can take the window under its floor.
        // Checked once the frame settles, so an animated resize is not fought
        // mid flight.
        if let floorObserver { NotificationCenter.default.removeObserver(floorObserver) }
        floorObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFloorCheck() }
        }
        WindowFacade.makeKeyAndOrderFront(win)
        // After the window is on screen, re-apply the size - NSHostingController
        // can resize its host window to fit the SwiftUI view's ideal size
        // during first layout, which was squeezing the window back down. The
        // panel is not re-applied: it sizes itself, and 1040 would be wrong.
        if legacy {
            DispatchQueue.main.async {
                if win.contentLayoutRect.size.width < initW {
                    sizer.setContentWidth(initW, minWidth: minContent.width, animated: false)
                }
            }
        }
        WindowFacade.activateGrux()
    }

    /// The classic shell's resting content size.
    static let legacyRestingContent = NSSize(width: 1040, height: 700)

    /// The launch window's content floor for a shell with no pane open.
    static func launchWindowFloor(legacy: Bool) -> NSSize {
        legacy ? NSSize(width: GruxLayout.windowFloorWidth, height: GruxLayout.windowFloorHeight)
            : NSSize(width: GruxLayout.panelWidth, height: GruxLayout.panelMinHeight)
    }

    /// The Command Panel grows the window to hold a pane and shrinks it back.
    /// The minimum moves with it, so a user cannot drag the pane off the edge.
    /// The first call after a `--win-w` launch keeps that width (see
    /// `LaunchWindowSizer.setContentWidth`).
    func setLaunchWindowContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool) {
        guard let win = launchWindow else { return }
        let keepExplicit = explicitLaunchWidthPending
        explicitLaunchWidthPending = false
        LaunchWindowSizer(window: win).setContentWidth(width, minWidth: minWidth, animated: animated,
                                                       keepingExplicitWidth: keepExplicit)
    }

    /// Kept for callers that hold a window rather than the delegate.
    static func setContentWidth(of win: NSWindow, to width: CGFloat, minWidth: CGFloat, animated: Bool) {
        LaunchWindowSizer(window: win).setContentWidth(width, minWidth: minWidth, animated: animated)
    }

    private func scheduleFloorCheck() {
        floorCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let win = self?.launchWindow, !win.inLiveResize else { return }
            LaunchWindowSizer(window: win).restoreFloor()
        }
        floorCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Keep Grux on top, or the shell, changed: re-apply the launch window's
    /// level. Only the launch window moves; every other window keeps its own.
    func applyLaunchWindowLevel() {
        let config = AppState.shared.config
        guard let win = launchWindow else { return }
        WindowFacade.setLevel(LaunchWindowSizer.level(keepOnTop: config.keepOnTop,
                                                      legacyShell: config.legacyShell), of: win)
    }

    /// The classic-sidebar switch flipped with the window open: apply the new
    /// shell's floor, and give the classic shell its resting width back. The
    /// panel's own width follows from its pane, which the new root applies.
    func applyLaunchWindowShell(legacy: Bool) {
        paneToggleAccessory?.isHidden = legacy
        guard let win = launchWindow else { return }
        let floor = Self.launchWindowFloor(legacy: legacy)
        let sizer = LaunchWindowSizer(window: win)
        sizer.setMinimum(NSSize(width: win.contentMinSize.width, height: floor.height))
        if win.contentLayoutRect.size.height < floor.height {
            var f = win.frame
            let grow = floor.height - win.contentLayoutRect.size.height
            f.origin.y -= grow
            f.size.height += grow
            win.setFrame(f, display: true)
        }
        if legacy {
            sizer.setContentWidth(max(win.contentLayoutRect.size.width, Self.legacyRestingContent.width),
                                  minWidth: floor.width, animated: true)
        }
    }

    // Best-effort graceful flush on normal quit. SIGKILL obviously doesn't
    // route through here - that's exactly the path AudioWALRecovery
    // handles on the next launch. For a clean quit we mark the WAL as
    // closed so a subsequent launch knows the audio was preserved but
    // the app didn't finish transcribing/summarizing.
    // When Grux regains focus, the user may have just finished re-signing into
    // their Claude account in a browser/Terminal outside the Resume sheet. The
    // orchestrator already returned when the job paused, so a re-auth that
    // happens outside the sheet was previously invisible - nothing polled auth
    // status, nothing called resumeJob(). This hook closes that gap: on focus
    // return (throttled), probe auth status and auto-resume any limit-paused
    // job if a logged-in account is present.
    func applicationDidBecomeActive(_ notification: Notification) {
        let now = Date()
        guard now.timeIntervalSince(lastReauthProbeAt) > 20 else { return }
        lastReauthProbeAt = now
        Task { @MainActor in
            // Cheap pre-check: only spend a `claude auth status` probe if there
            // is actually a limit-paused job waiting on a re-auth.
            await AgentService.shared.refreshJobs()
            let hasPaused = AgentService.shared.jobs.contains {
                $0.status == .waiting && $0.pausedReason == .authLimitHit
            }
            guard hasPaused else { return }
            await AgentService.shared.reengagePausedJobsIfSignedIn()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // FIRST: clear the post-merge crash flag, before the (longer) store
        // flushes below. A clean quit must never read as a crash even if a later
        // flush stalls or the process is killed mid-shutdown.
        PostMergeWatch.shared.markCleanExit()
        PhoneReceiverService.shared.stop()
        OllamaManager.shared.shutdownSync()
        // Debounced stores hold edits in memory for up to 1.5s; a quit
        // inside that window silently dropped them (notes the create_note
        // tool already confirmed, skills just taught, research progress,
        // semantic memories already acknowledged with "I'll remember that").
        // All flushes are synchronous and main-actor, matching this
        // delegate context. Persistence.save no-ops if a restore suspended
        // writes, so a post-restore quit cannot clobber restored data.
        NotesStore.shared.flush()
        SkillStore.shared.flush()
        ResearchStore.shared.flush()
        SemanticMemory.shared.flush()
        ProposalStore.shared.flush()
        TrustLedger.shared.flush()
        FoundryTimelineStore.shared.flush()
        AudioWAL.shared.finalize(clean: false)
        AudioWAL.shared.flushSync()
        WakeLog.shared.log("app: applicationWillTerminate, stores + audio WAL flushed")
    }

    @MainActor
    private func handleAction(note: Notification) {
        guard let info = note.userInfo,
              let action = info["action"] as? String else { return }
        // Pull the inner userInfo dict if present (notification taps wrap the
        // UNNotification's userInfo here under "userInfo"). Some callers
        // (the phone bridge) post the same shape.
        let payload = info["userInfo"] as? [AnyHashable: Any] ?? [:]
        switch action {
        case "grux.stillOnIt":
            AppState.shared.consecutiveDrifts = 0
        case "grux.snooze":
            AppState.shared.snooze(minutes: AppState.shared.config.snoozeMinutes)
        case "grux.switchTask":
            WindowOpener.openChat()
        case "grux.agent.resume", UNNotificationDefaultActionIdentifier:
            // Default tap dispatches by `kind` so the V2 phase-transition
            // banners deep-link to the Workflows tab while the original
            // agent-paused banners keep landing on the Agents tab + Resume
            // sheet. Inline actions (grux.agent.resume) always go agents.
            if action == UNNotificationDefaultActionIdentifier,
               let kind = payload["kind"] as? String,
               kind == "supportDrafts" {
                WindowOpener.openSupportDrafts()
                break
            }
            if action == UNNotificationDefaultActionIdentifier,
               let kind = payload["kind"] as? String,
               kind == "v2PhaseTransition" {
                // Focus the Workflows tab on this run. CommandsV2View doesn't
                // currently filter by run, but setting requestedTab puts the
                // user one click from the run row.
                AppState.shared.requestedTab = "workflows"
                openLaunchWindow(tab: "workflows")
                break
            }
            // "Switch account & resume" inline action OR a tap on an
            // agent-paused banner body. Both surface the Resume sheet - the
            // sheet is where the user actually picks an account (and where
            // the OAuth flow opens its Terminal window from).
            if let jobId = payload["jobId"] as? String {
                AppState.shared.requestedTab = "agents"
                AppState.shared.pendingResumeJobId = jobId
            }
            openLaunchWindow(tab: "agents")
        case "grux.agent.snooze1h":
            if let jobId = payload["jobId"] as? String {
                Task { @MainActor in await AgentService.shared.snoozeJob(jobId: jobId, minutes: 60) }
            }
        case "grux.agent.cancel":
            if let jobId = payload["jobId"] as? String {
                Task { @MainActor in await AgentService.shared.cancel(jobId: jobId) }
            }
        default:
            break
        }
    }
}

enum Bootstrap {
    @MainActor
    static func ensureConfig() {
        let state = AppState.shared
        // Env-var import: used for CI / dev rigs that want to inject a key
        // without popping the UI. Writes straight into Keychain - the
        // plaintext config fields are a deprecated migration surface only.
        if state.anthropicKey.isEmpty {
            if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
                _ = KeychainStore.set(.anthropicApiKey, env)
            }
        }
        if state.elevenLabsKey.isEmpty {
            if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !env.isEmpty {
                _ = KeychainStore.set(.elevenLabsApiKey, env)
            }
        }
        // Seed a starter task if stack is empty
        if state.tasks.isEmpty {
            state.addTask("Wire up Grux and confirm focus reminders fire", project: "GruxAI", priority: .now)
        }
    }

}
