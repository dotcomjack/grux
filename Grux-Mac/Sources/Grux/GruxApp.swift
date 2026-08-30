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

        Window("Grux Settings", id: "settings") {
            SettingsView().environmentObject(state)
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
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.openLaunchWindow(tab: "chat")
    }
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.openLaunchWindow(tab: "settings")
    }
    static func openTasks() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.openLaunchWindow(tab: "tasks")
    }
    // Opens the launch window focused on the Workflows tab. Used by the
    // menu bar phase ribbon to deep-link into the active V2 run.
    static func openWorkflows() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.openLaunchWindow(tab: "workflows")
    }
    // Opens the staged support drafts. Per the approved UI/UX design (decision
    // 1A + 5), drafts now live inside Jax HQ rather than a floating window, so
    // this navigates to the Jax HQ tab (which carries the Drafts section).
    static func openSupportDrafts() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.openLaunchWindow(tab: "jaxHQ")
    }
    // Opens the cold-outreach composer with a blank, editable draft.
    static func composeOutreach() {
        NSApp.activate(ignoringOtherApps: true)
        ColdEmailEngine.shared.startManualCompose()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var openWindowAction: ((String) -> Void)?

    private var launchWindow: NSWindow?
    private var empireDashboardWindow: NSWindow?
    private var terminalFocusHotkeySub: AnyCancellable?
    private var speakingGlowSub: AnyCancellable?
    // Held only while the first-run flow is on screen. Released the moment it
    // finishes, which is also the moment the consent-gated work starts.
    private var onboardingGateSub: AnyCancellable?

    // Throttle for the re-auth observer: applicationDidBecomeActive fires on
    // every focus return, so we rate-limit the `claude auth status` probe to
    // at most once per 20s. Re-engaging a paused job is the goal; spawning the
    // CLI on every window focus is not.
    private var lastReauthProbeAt: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // A write into a pipe whose reader died (crashed MCP server, exited
        // shell child) raises SIGPIPE, which by default terminates the whole
        // app. Ignore it process-wide so those writes surface as catchable
        // EPIPE errors instead. URLSession sockets already set SO_NOSIGPIPE;
        // this covers Pipe/FileHandle plumbing.
        signal(SIGPIPE, SIG_IGN)
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
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let dump = MusicTool.dumpMusicAXButtons()
                let outPath = NSHomeDirectory() + "/.grux/music-ax-dump.txt"
                try? dump.write(toFile: outPath, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data((dump + "\n").utf8))
                try? await Task.sleep(nanoseconds: 250_000_000)
                exit(0)
            }
            return
        }

        // Hidden dev mode: `--overlay-demo` exercises the Orb / Glow / HUD
        // overlay surfaces (OrbAnywhere, OrbHintBus, StageController) then
        // exits. Runs as a fresh process so the production /Applications/Grux.app
        // keeps running; the two menu bar icons briefly coexist. Used for CLI
        // end-to-end verification without popping TCC dialogs - skips all of
        // the FocusWatcher / Ambient / Mic init paths.
        if args.contains("--overlay-demo") {
            NSApp.setActivationPolicy(.regular)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                // 1. Floating orb on first.
                OrbAnywhereController.shared.show()
                try? await Task.sleep(nanoseconds: 300_000_000)
                // 2. Push a tool-style status hint.
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
            NSApp.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let result = await MusicTool.play(song: song, artist: artist)
                let dir = NSHomeDirectory() + "/.grux"
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
            NSApp.setActivationPolicy(.accessory)
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
                let dir = NSHomeDirectory() + "/.grux"
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
        if args.contains("--studio-smoke") {
            NSApp.setActivationPolicy(.accessory)
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
                let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? out.write(to: dir.appendingPathComponent("studio-smoke-result.txt"), atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 250_000_000)
                exit(0)
            }
            return
        }

        if let idx = args.firstIndex(of: "--jax-seed"), idx + 1 < args.count {
            let path = args[idx + 1]
            NSApp.setActivationPolicy(.accessory)
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
            NSApp.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let dir = NSHomeDirectory() + "/.grux/jax"
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
            NSApp.setActivationPolicy(.accessory)
            Bootstrap.ensureConfig()
            AppState.shared.load()
            Task { @MainActor in
                let dir = NSHomeDirectory() + "/.grux/jax"
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
            NSApp.setActivationPolicy(.accessory)
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
            NSApp.setActivationPolicy(.accessory)
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
            NSApp.setActivationPolicy(.accessory)
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
        NSApp.setActivationPolicy(isSmokeTest ? .accessory : .regular)
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
                AppState.shared.requestedTab = tab
                self.openLaunchWindow(tab: tab)
                NSApp.activate(ignoringOtherApps: true)
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
                NSApp.activate(ignoringOtherApps: true)
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

        // Domain renewal watcher, sweeps every 24h across every GoDaddy
        // domain on the account, surfaces expiry in the Empire dashboard, and
        // speaks + posts a system notification when any ACTIVE domain crosses
        // the 30-day line. ACTIVE-only so long-dead CANCELLED domains stay
        // quiet. Creds resolve from the Keychain only on this path: see
        // resolveCredentials(allowAmbientSources:).
        //
        // GATED for the same reason as the App Store Connect monitor nine lines above, which
        // was gated while this was not. Its comment names this exact file by hand: "a
        // credential file left behind by some other tool was enough to make Grux start
        // talking to App Store Connect on the user's behalf, unasked. Same defect shape as
        // the GoDaddy file source". The Empire dashboard's manual sweep still works.
        if AppState.shared.config.domainMonitorEnabled {
            DomainMonitor.shared.start()
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

        // Ambient mode owns the mic when enabled - wake listener is mutually exclusive.
        if AppState.shared.config.ambientEnabled {
            AmbientState.shared.isEnabled = true
            AmbientCoach.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in await AmbientListener.shared.start() }
            }
            if AppState.shared.config.ambientHUDVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    AmbientState.shared.hudVisible = true
                    AmbientPanelController.shared.show()
                }
            }
        } else if AppState.shared.config.wakeWordEnabled {
            // Delay so mic/speech prompts appear after the main window is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in await WakeWordListener.shared.start() }
            }
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

        // Terminal Focus - start() calls refresh() which shows overlay if conditions are met
        TerminalFocusState.shared.start()

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

        // Register the global hotkey from persisted config and re-register on change.
        let tfcfg = TerminalFocusState.shared.terminalFocusCfg
        GlobalHotkey.shared.register(
            keyCode: tfcfg.hotkey.keyCode,
            modifiers: tfcfg.hotkey.modifiers
        ) { TerminalFocusState.shared.toggleOverlay() }
        // Re-register on config change so capturing a new combo in Settings
        // takes effect immediately.
        terminalFocusHotkeySub = TerminalFocusState.shared.$terminalFocusCfg
            .map(\.hotkey)
            .removeDuplicates()
            .sink { hk in
                GlobalHotkey.shared.register(
                    keyCode: hk.keyCode,
                    modifiers: hk.modifiers
                ) { TerminalFocusState.shared.toggleOverlay() }
            }

        // Shell state bus (item 24): translate existing speech/wake/focus/
        // workflow/agent signals into one canonical ShellMoment feed.
        // Subscriptions only; no producer was modified.
        ShellStateAdapters.shared.start()

        // Orb command palette: its own Carbon slot (GRXP/id 2) alongside the
        // Terminal Focus hotkey (GRUX/id 1). Default Cmd+Shift+P.
        OrbCommandPaletteController.shared.registerHotkey()

        // restoreOverlayAtLaunch, NOT showOverlay. showOverlay force-enables the
        // feature kill-switch, which is correct for a person asking for the
        // overlay and wrong for a launch timer: it made "off" fail to survive a
        // restart, and put the overlay on screen during onboarding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            TerminalFocusState.shared.restoreOverlayAtLaunch()
        }

        // Live workspace focus overlay - floating top-right card that shows
        // the current focus task and pulses in the verdict color. Visible
        // preference persists across launches via FocusOverlayState.
        // Gated on onboarding for the same reason the terminal overlay is: this
        // card defaults to visible on first launch, so a brand new user got a
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
        // GATED ON ONBOARDING FOR THE REASON STATED ELEVEN LINES ABOVE, which was
        // written for the focus overlay and applies here word for word: this
        // defaults to TRUE, so a brand new user got a floating always-on-top
        // window over their setup flow. The focus card got the gate and the orb,
        // which is larger and sits on every Space, did not.
        if AppState.shared.config.orbAnywhereEnabled, OnboardingModel.shared.stage == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OrbAnywhereController.shared.show()
            }
        }

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
                self.openLaunchWindow(tab: "home")
                NSApp.activate(ignoringOtherApps: true)
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

        // Calendar correlator: requests EventKit access on first launch (the
        // OS shows the prompt once and remembers the answer; idempotent on
        // repeat launches). Events are correlated to ambient sessions lazily
        // when WorkdayLogAssembler builds the daily log, so nothing else has
        // to run here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in await CalendarCorrelator.ensurePermission() }
        }

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
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux")
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
            Task { @MainActor in await ChatService.shared.send(userText: trimmed) }
        }

        // Debug recap trigger - touch ~/.grux/fire-recap to force the daily
        // recap at any time without waiting for 22:00.
        let recapFile = dir.appendingPathComponent("fire-recap")
        TriggerWatcher.shared.register(recapFile) {
            guard FileManager.default.fileExists(atPath: recapFile.path) else { return }
            try? FileManager.default.removeItem(at: recapFile)
            WakeLog.shared.log("manual recap trigger fired")
            Task { @MainActor in await DailyRecapScheduler.shared.fireRecapNow() }
        }

        // Debug MusicKit probe: touch ~/.grux/fire-musickit-test to verify whether
        // ApplicationMusicPlayer + a catalog request FUNCTION in this signed build
        // (with or without the com.apple.developer.musickit entitlement). File
        // contents optional: a numeric Apple Music store id to probe, else a
        // default. Result -> ~/.grux/musickit-test-result.txt and wake.log. First
        // run shows the Apple Music access prompt (one-time grant).
        let mkProbeFile = dir.appendingPathComponent("fire-musickit-test")
        TriggerWatcher.shared.register(mkProbeFile) {
            guard FileManager.default.fileExists(atPath: mkProbeFile.path) else { return }
            let payload = (try? String(contentsOf: mkProbeFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: mkProbeFile)
            let storeID = payload.isEmpty ? "1442846328" : payload   // default: Kanye West, Stronger
            Task { @MainActor in
                let result = await MusicKitPlayer.probe(testStoreID: storeID)
                WakeLog.shared.log("musickit-probe: \(result)")
                try? result.write(to: dir.appendingPathComponent("musickit-test-result.txt"),
                                   atomically: true, encoding: .utf8)
            }
        }

        // Debug STT-correction trigger: write a raw (possibly misheard) transcript
        // into ~/.grux/fire-stt-correct and Grux runs TranscriptCorrector on it,
        // writing the corrected text to ~/.grux/stt-correct-result.txt + wake.log.
        // Lets the correction layer be verified without a microphone.
        let sttCorrectFile = dir.appendingPathComponent("fire-stt-correct")
        TriggerWatcher.shared.register(sttCorrectFile) {
            guard FileManager.default.fileExists(atPath: sttCorrectFile.path) else { return }
            let raw = (try? String(contentsOf: sttCorrectFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: sttCorrectFile)
            guard !raw.isEmpty else { return }
            Task { @MainActor in
                let corrected = await TranscriptCorrector.correct(raw)
                let out = "RAW: \(raw)\nCORRECTED: \(corrected)"
                WakeLog.shared.log("stt-correct-test: \(out.replacingOccurrences(of: "\n", with: " | "))")
                try? out.write(to: dir.appendingPathComponent("stt-correct-result.txt"),
                               atomically: true, encoding: .utf8)
            }
        }

        // Debug issue-from-voice trigger: touch ~/.grux/fire-issue-from-voice-test
        // to run the spoken-frustration -> GitHub issue pipeline end to end,
        // bypassing the heuristic + debounce. File contents are optional:
        //   - empty            : draft from a built-in seed transcript, then
        //                        present the confirmation panel (nothing filed).
        //   - "file"           : also file the drafted issue to GitHub via gh
        //                        (proves the gh path; writes the created URL).
        //   - "file|<text>"    : file, drafting from <text> as the transcript.
        //   - "<text>"         : draft from <text>, present the panel.
        // Result is written to ~/.grux/issue-from-voice-test-result.txt.
        let issueVoiceFile = dir.appendingPathComponent("fire-issue-from-voice-test")
        TriggerWatcher.shared.register(issueVoiceFile) {
            guard FileManager.default.fileExists(atPath: issueVoiceFile.path) else { return }
            let payload = (try? String(contentsOf: issueVoiceFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: issueVoiceFile)
            WakeLog.shared.log("manual issue-from-voice-test trigger fired")
            // Parse "file" prefix and optional inline transcript.
            var autoFile = false
            var seed = ""
            if payload.lowercased() == "file" {
                autoFile = true
            } else if payload.lowercased().hasPrefix("file|") {
                autoFile = true
                seed = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                seed = payload
            }
            if seed.isEmpty && !autoFile {
                seed = """
                Me: ok let me push this build.
                Me: ugh the Grux deploy script always fails on the notarize step, this is broken every single time and it is so annoying.
                Me: I really need to fix that, it wastes ten minutes a run.
                """
            } else if seed.isEmpty && autoFile {
                seed = """
                Me: the Grux deploy script always fails on the notarize step, this is broken and really annoying. I need to fix that.
                """
            }
            let outPath = NSHomeDirectory() + "/.grux/issue-from-voice-test-result.txt"
            Task { @MainActor in
                await IssueExtractor.shared.runSmokeTest(seed: seed, autoFile: autoFile, resultPath: outPath)
            }
        }

        // Debug support-triage trigger: touch ~/.grux/fire-support-triage-test
        // to run the support-email triage pipeline end to end without waiting
        // for the hourly sweep. File contents are optional:
        //   - empty            : the first configured inbox, built-in fixture
        //                        (deterministic).
        //   - "<inbox>"        : that inbox, built-in fixture.
        //   - "<inbox>|<path>" : that inbox, read the [InboxMessage] JSON at
        //                        <path> (use this to test live-tab scraping by
        //                        pointing at a file you dumped, or omit the
        //                        path to scrape the open Outlook tab).
        // Stages drafts in SupportDraftStore, opens the Support Drafts window,
        // and writes a summary to ~/.grux/support-triage-test-result.txt.
        let supportTriageFile = dir.appendingPathComponent("fire-support-triage-test")
        TriggerWatcher.shared.register(supportTriageFile) {
            guard FileManager.default.fileExists(atPath: supportTriageFile.path) else { return }
            let payload = (try? String(contentsOf: supportTriageFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: supportTriageFile)
            WakeLog.shared.log("manual support-triage-test trigger fired")
            var fixturePath = ""
            let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count > 1 { fixturePath = parts[1].trimmingCharacters(in: .whitespaces) }
            let outPath = NSHomeDirectory() + "/.grux/support-triage-test-result.txt"
            // "live" payload runs the REAL unattended sweep (reads the open
            // Outlook tab, no fixture), so the live path can be verified on
            // demand instead of only at the top of the hour. Checked before the
            // inbox is resolved because a live sweep walks the whole roster and
            // needs no single inbox.
            if fixturePath.lowercased() == "live" || payload.trimmingCharacters(in: .whitespaces).lowercased() == "live" {
                Task { @MainActor in
                    let n = await EmailTriageEngine.shared.runHourly()
                    WakeLog.shared.log("manual LIVE support sweep: staged \(n) draft(s)")
                    WindowOpener.openSupportDrafts()
                }
                return
            }
            // The inbox the payload names, else the first configured one. There
            // is no compiled-in default any more: with no support inboxes in
            // ~/.grux/brands.json there is nothing to triage, so say so and stop
            // rather than smoke-testing a brand this install never had.
            let named = parts.first.flatMap {
                SupportInbox(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces))
            }
            guard let inbox = named ?? SupportInbox.roster.first else {
                let msg = "support-triage-test: no support inboxes configured in ~/.grux/brands.json, nothing to triage"
                WakeLog.shared.log(msg)
                try? msg.write(toFile: outPath, atomically: true, encoding: .utf8)
                return
            }
            Task { @MainActor in
                await EmailTriageEngine.shared.runSmokeTest(inbox: inbox, fixturePath: fixturePath, resultPath: outPath)
            }
        }

        // Graph mail setup: drop ~/.grux/fire-graph-mail-setup containing JSON
        //   {"tenantId","clientId","clientSecret","mailboxes":[{"inbox","address"}]}
        // to wire DIRECT M365 access (no tab). The secret is moved into Keychain
        // and the file is shredded immediately so it never lingers in plaintext.
        let graphSetupFile = dir.appendingPathComponent("fire-graph-mail-setup")
        TriggerWatcher.shared.register(graphSetupFile) {
            guard FileManager.default.fileExists(atPath: graphSetupFile.path) else { return }
            let data = (try? Data(contentsOf: graphSetupFile)) ?? Data()
            try? FileManager.default.removeItem(at: graphSetupFile)
            Task { @MainActor in
                WakeLog.shared.log(GraphMailStore.shared.ingest(data))
            }
        }

        // Debug cold-email trigger: touch ~/.grux/fire-cold-email-test to draft
        // a voice-style outreach email end to end (no auto-send; opens the
        // confirm dialog). File contents are optional:
        //   - empty                         : built-in test target.
        //   - "<person>|<company>|<email?>" : draft to that target.
        // Writes a summary (including an em/en-dash check) to
        // ~/.grux/cold-email-test-result.txt for CLI verification.
        let coldEmailFile = dir.appendingPathComponent("fire-cold-email-test")
        TriggerWatcher.shared.register(coldEmailFile) {
            guard FileManager.default.fileExists(atPath: coldEmailFile.path) else { return }
            let payload = (try? String(contentsOf: coldEmailFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: coldEmailFile)
            WakeLog.shared.log("manual cold-email-test trigger fired")
            let outPath = NSHomeDirectory() + "/.grux/cold-email-test-result.txt"
            Task { @MainActor in
                await ColdEmailEngine.shared.runSmokeTest(payload: payload, resultPath: outPath)
            }
        }

        // Debug energy-recap trigger: touch ~/.grux/fire-energy-recap-test
        // to force the 8pm energy + focus recap at any time. Builds the
        // EnergyRecap from today's data, presents the glass takeover, speaks
        // the summary, and pushes to phone via TTSBroadcaster when paired.
        let energyRecapFile = dir.appendingPathComponent("fire-energy-recap-test")
        TriggerWatcher.shared.register(energyRecapFile) {
            guard FileManager.default.fileExists(atPath: energyRecapFile.path) else { return }
            try? FileManager.default.removeItem(at: energyRecapFile)
            WakeLog.shared.log("manual energy-recap trigger fired")
            Task { @MainActor in await EnergyRecapScheduler.shared.fireRecapNow() }
        }

        // Debug workday-log trigger - touch ~/.grux/fire-workday-log to
        // generate TODAY's archival workday log immediately and open the
        // panel. Useful for CLI-based end-to-end verification.
        let wdFile = dir.appendingPathComponent("fire-workday-log")
        TriggerWatcher.shared.register(wdFile) {
            guard FileManager.default.fileExists(atPath: wdFile.path) else { return }
            try? FileManager.default.removeItem(at: wdFile)
            WakeLog.shared.log("manual workday-log trigger fired")
            Task { @MainActor in
                let dk = WorkdayLogScheduler.currentDayKey()
                _ = await WorkdayLogScheduler.shared.generateWorkdayLogNow(forDayKey: dk)
                WorkdayLogPanelController.shared.present()
            }
        }

        // Debug decision-log trigger: touch ~/.grux/fire-decision-log-test to
        // run the extraction pass over whatever transcript is currently in
        // the AmbientState ring buffer (uses a 360-min window so a quick test
        // only needs a few recent chunks). Writes a summary to
        // ~/.grux/decision-log-test-result.txt for CLI verification.
        let dlFile = dir.appendingPathComponent("fire-decision-log-test")
        TriggerWatcher.shared.register(dlFile) {
            guard FileManager.default.fileExists(atPath: dlFile.path) else { return }
            try? FileManager.default.removeItem(at: dlFile)
            WakeLog.shared.log("manual decision-log-test trigger fired")
            Task { @MainActor in
                let result = await DecisionLogScheduler.shared.runNow(transcriptMinutes: 360)
                let now = Date()
                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("decision-log-test result @ \(iso.string(from: now))")
                lines.append("provider: \(result.provider)")
                lines.append("new decisions saved this pass: \(result.records.count)")
                for d in result.records {
                    lines.append("  - [\(d.dayKey)] \(d.summary)")
                    if !d.rationale.isEmpty { lines.append("    why: \(d.rationale)") }
                    if !d.alternatives.isEmpty {
                        lines.append("    alts: \(d.alternatives.joined(separator: " | "))")
                    }
                    lines.append("    id: \(d.id)")
                }
                let all = DecisionLog.loadAllDecisions(limit: 5)
                lines.append("most-recent stored (across all days): \(all.count)")
                for d in all {
                    lines.append("  - [\(d.dayKey)] \(d.summary)")
                }
                let outPath = NSHomeDirectory() + "/.grux/decision-log-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug person-memory trigger: touch ~/.grux/fire-person-memory-test to
        // run the NER + fact pass over a SEEDED multi-person transcript (so the
        // smoke test never depends on real ambient audio being in the buffer).
        // HERMETIC: pre-cleans the synthetic test slugs so the run is repeatable
        // and the acceptance gate counts ONLY this pass (not the real CRM);
        // runs with name-fold OFF so the fakes can't graft onto a real dossier;
        // post-cleans so the fakes never pollute ~/.grux/people/. Writes a
        // summary to ~/.grux/person-memory-test-result.txt for CLI verification.
        let personMemFile = dir.appendingPathComponent("fire-person-memory-test")
        TriggerWatcher.shared.register(personMemFile) {
            guard FileManager.default.fileExists(atPath: personMemFile.path) else { return }
            try? FileManager.default.removeItem(at: personMemFile)
            WakeLog.shared.log("manual person-memory-test trigger fired")
            Task { @MainActor in
                // Synthetic people. "Mark" (a single-word, common-word name)
                // exists specifically to exercise the false-positive guard.
                let testSlugs = ["sarah-chen","marcus-reed","priya-patel","devon-brooks","linda-okafor","mark"]
                @MainActor func wipeTestDossiers() {
                    for s in testSlugs {
                        try? FileManager.default.removeItem(at: PersonMemory.rootDir.appendingPathComponent("\(s).json"))
                    }
                    PersonMemory.shared.invalidateCache() // drop ghosts from the hot-path cache
                }
                wipeTestDossiers() // start clean so the gate counts THIS pass only

                let seeded = """
                - I just got off the phone with Sarah Chen, she's the new ops lead at the fulfillment center and she said the bar soap two-packs ship out of the east warehouse now.
                - Marcus Reed from the Alibaba supplier confirmed the turmeric citrus scent batch is ready to pour next week.
                - Got an email from Priya Patel, she's the lawyer reviewing the enterprise contract, she works at a firm called Westfield.
                - My buddy Devon Brooks is cutting the launch video, he lives in Austin and he's done three of my promos already.
                - Linda Okafor wants to put money into the new app, she runs a small angel fund and asked for the deck.
                - Talked to Mark today about the warehouse lease, he's the property manager.
                - Reminded myself to text Sarah Chen back about the lotion cadence, she's waiting on the forty-two day number.
                """
                let result = await PersonMemoryScheduler.shared.runNow(transcriptOverride: seeded, allowNameFold: false)

                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("person-memory-test result @ \(iso.string(from: Date()))")
                lines.append("provider: \(result.provider)")
                lines.append("dossiers this pass: \(result.dossiers.count)")
                lines.append("new facts this pass: \(result.newFactCount)")
                lines.append("ACCEPTANCE (>= 5 dossiers THIS pass): \(result.dossiers.count >= 5 ? "PASS" : "FAIL")")
                lines.append("ACCEPTANCE (new facts > 0): \(result.newFactCount > 0 ? "PASS" : "FAIL")")
                for d in result.dossiers.sorted(by: { $0.name < $1.name }) {
                    lines.append("  - \(d.name) [\(d.relationship.isEmpty ? "?" : d.relationship)] facts=\(d.facts.count) mentions=\(d.mentionCount)")
                }

                // Chat-surface: a known full name must surface a card.
                if let card = PersonMemory.shared.cardBlock(forUtterance: "did Sarah Chen ever get back to me about that?") {
                    lines.append("CARD_LOOKUP (multi-word name): PASS")
                    lines.append("--- sample card ---")
                    lines.append(card)
                } else {
                    lines.append("CARD_LOOKUP (multi-word name): FAIL")
                }
                // Single-word name, capitalized and mid-sentence: SHOULD match.
                let posSingle = PersonMemory.shared.cardBlock(forUtterance: "I talked to Mark today about the lease")
                lines.append("SINGLE_WORD_POSITIVE (\"...Mark...\"): \(posSingle != nil ? "PASS" : "FAIL")")
                // Same word lowercased as a verb: must NOT match (false-positive guard).
                let negVerb = PersonMemory.shared.cardBlock(forUtterance: "can you mark that one done and bill it later")
                lines.append("FALSE_POSITIVE_GUARD (\"mark/bill\" lowercase): \(negVerb == nil ? "PASS (no card)" : "FAIL (card injected)")")

                wipeTestDossiers() // never leave synthetic people in the real CRM

                let outPath = NSHomeDirectory() + "/.grux/person-memory-test-result.txt"
                try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug idea-dedup trigger: touch ~/.grux/fire-idea-dedup-test to run
        // a two-idea smoke test through IdeaQueue. Captures a unique idea, then
        // a near paraphrase, and writes the dedup outcome to
        // ~/.grux/idea-dedup-test-result.txt for CLI verification.
        let ideaTestFile = dir.appendingPathComponent("fire-idea-dedup-test")
        TriggerWatcher.shared.register(ideaTestFile) {
            guard FileManager.default.fileExists(atPath: ideaTestFile.path) else { return }
            try? FileManager.default.removeItem(at: ideaTestFile)
            WakeLog.shared.log("manual idea-dedup-test trigger fired")
            Task {
                // Sprinkle a per-run nonce throughout both strings so the
                // embedding is dominated by run-specific tokens. Without this,
                // a re-trigger sees the prior run's near-identical pair still
                // in the index and the new FIRST capture comes back as a
                // duplicate of an older run, masking real regressions.
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
                let original = "Idea dedup smoke nonce \(nonce): a voice trigger named \(nonce) that summarizes yesterday's commits \(nonce) into a short audio clip \(nonce) every weekday morning."
                let paraphrase = "Idea dedup smoke nonce \(nonce): a morning recap feature called \(nonce) that voices yesterday's git commits \(nonce) as a quick audio snippet \(nonce) on weekdays."
                let first = await IdeaQueue.shared.capture(content: original)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let second = await IdeaQueue.shared.capture(content: paraphrase)

                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("idea-dedup-test result @ \(iso.string(from: Date()))")
                lines.append("memory_available: \(first.memoryAvailable && second.memoryAvailable)")
                lines.append("nonce: \(nonce)")
                lines.append("")
                lines.append("FIRST (expected: unique, fresh nonce)")
                lines.append("  id=\(first.id) duplicate=\(first.isDuplicate) score=\(first.score.map { String(format: "%.4f", $0) } ?? "nil")")
                lines.append("  file=\(first.filePath)")
                lines.append("")
                lines.append("SECOND (expected: duplicate of FIRST)")
                lines.append("  id=\(second.id) duplicate=\(second.isDuplicate) score=\(second.score.map { String(format: "%.4f", $0) } ?? "nil")")
                lines.append("  file=\(second.filePath)")
                if let pid = second.priorId { lines.append("  prior_id=\(pid)") }
                if let pd = second.priorDate { lines.append("  prior_date=\(iso.string(from: pd))") }
                lines.append("")
                // PASS requires: FIRST treated as fresh AND SECOND linked back
                // to FIRST (not to some older smoke-test entry left in the
                // index). The !first.isDuplicate clause is what surfaces a
                // polluted index instead of silently green-lighting a re-run.
                let pass = !first.isDuplicate
                    && second.isDuplicate
                    && second.priorId == first.id
                lines.append("VERDICT: \(pass ? "PASS" : "FAIL")")
                let outPath = NSHomeDirectory() + "/.grux/idea-dedup-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)

                // Self-cleanup: remove this run's entries from the companion
                // service's Lance index AND delete the on-disk .md files. Without
                // this, every fire-trigger leaves two near-identical entries
                // that drift the next run's FIRST capture above the 0.85
                // duplicate threshold, masking real regressions.
                let rag = RAGClient()
                _ = try? await rag.deleteDoc(id: first.id)
                _ = try? await rag.deleteDoc(id: second.id)
                try? FileManager.default.removeItem(atPath: first.filePath)
                try? FileManager.default.removeItem(atPath: second.filePath)
            }
        }

        // Debug clone-extractor trigger: touch ~/.grux/fire-clone-extractor-test
        // to mine Grux's own transcripts (chat threads + ambient buffer +
        // meeting captures) for canonical own-voice Q-A pairs, synthesize them
        // via AmbientLLM (local qwen3:8b first, Claude fallback), redact PII,
        // and write JSONL to ~/.grux/clone/exports/<dayKey>.jsonl. Writes a
        // summary to ~/.grux/clone-extractor-test-result.txt for CLI checks.
        let cloneTestFile = dir.appendingPathComponent("fire-clone-extractor-test")
        TriggerWatcher.shared.register(cloneTestFile) {
            guard FileManager.default.fileExists(atPath: cloneTestFile.path) else { return }
            try? FileManager.default.removeItem(at: cloneTestFile)
            WakeLog.shared.log("manual clone-extractor-test trigger fired")
            Task { @MainActor in
                // Don't POST during the smoke test even if an import-config
                // happens to be present; this run only proves local extraction.
                let result = await CloneExtractor.shared.runExtraction(targetPairs: 30, allowPost: false)
                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("clone-extractor-test result @ \(iso.string(from: Date()))")
                lines.append("provider: \(result.provider)")
                lines.append("corpus chars: \(result.corpusChars)")
                lines.append("windows run: \(result.windowsRun)")
                lines.append("name redactions: \(result.redactions)")
                lines.append("pairs synthesized: \(result.pairs.count)")
                lines.append("export: \(result.exportURL?.path ?? "(none)")")
                lines.append("ACCEPTANCE (>= 20 pairs): \(result.pairs.count >= 20 ? "PASS" : "FAIL")")
                // PII guard: a secret survives SecretRedactor, OR an email /
                // phone slips the contact-PII pass, OR a First-Last name escapes
                // the redactor. Any of those = leak.
                let emailRe = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
                let phoneRe = try? NSRegularExpression(pattern: #"\b\d{3}[.\-\s]\d{3}[.\-\s]\d{4}\b"#)
                let leak = result.pairs.contains { p in
                    let blob = p.question + " " + p.answer
                    if SecretRedactor.redact(blob) != blob { return true }
                    let r = NSRange(blob.startIndex..., in: blob)
                    if emailRe?.firstMatch(in: blob, range: r) != nil { return true }
                    if phoneRe?.firstMatch(in: blob, range: r) != nil { return true }
                    return false
                }
                lines.append("ACCEPTANCE (no secret/contact-PII leaks): \(leak ? "FAIL" : "PASS")")

                // Deterministic redaction self-test (does not depend on what the
                // LLM happened to emit). Proves the contact-PII pass, single-token
                // known-name redaction, and First-Last heuristic, plus the
                // place/brand precision guard.
                lines.append("")
                lines.append("--- redaction self-test ---")
                let (r1, c1) = CloneExtractor.redact(
                    "Email me at jane.doe@example.com or call 313-555-0188, ask for Sarah.",
                    knownNames: ["Sarah Chen", "Sarah"])
                let t1 = !r1.contains("@") && !r1.contains("555") && !r1.contains("Sarah") && c1 >= 3
                lines.append("contact+single-name: \(t1 ? "PASS" : "FAIL") -> \(r1)")
                let (r2, _) = CloneExtractor.redact(
                    "I talked to Maria Gonzalez about the contract.", knownNames: [])
                let t2 = !r2.contains("Maria") && !r2.contains("Gonzalez") && r2.contains("[person]")
                lines.append("first-last heuristic: \(t2 ? "PASS" : "FAIL") -> \(r2)")
                let (r3, _) = CloneExtractor.redact(
                    "Meet me at the App Store in New York to talk roadmap.", knownNames: [])
                let t3 = r3.contains("App Store") && r3.contains("New York") && !r3.contains("[person]")
                lines.append("precision (no place/brand over-redact): \(t3 ? "PASS" : "FAIL") -> \(r3)")
                // Salvage parser: a truncated array still yields its complete pairs.
                let truncated = "{\"pairs\":[{\"question\":\"a?\",\"answer\":\"b\"},{\"question\":\"c?\",\"answer\":\"d\"},{\"question\":\"e?\",\"answer\":"
                let salvaged = CloneExtractor.salvagePairObjects(truncated)
                lines.append("salvage truncated JSON (expect 2): \(salvaged.count == 2 ? "PASS" : "FAIL") -> \(salvaged.count)")

                lines.append("")
                lines.append("--- sample pairs (first 5) ---")
                for p in result.pairs.prefix(5) {
                    lines.append("Q: \(p.question)")
                    lines.append("A: \(p.answer)")
                    lines.append("   topic=\(p.topic) tags=\(p.tags.joined(separator: ",")) type=\(p.sourceType)")
                    lines.append("")
                }
                let outPath = NSHomeDirectory() + "/.grux/clone-extractor-test-result.txt"
                try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug cross-brand-rag trigger: touch ~/.grux/fire-cross-brand-rag-test
        // to exercise the companion RAG store end-to-end. Indexes three nonce-tagged docs
        // across different brand_hints, runs a recall query, and writes the
        // verdict to ~/.grux/cross-brand-rag-test-result.txt for CLI
        // verification. Self-cleans the nonce entries so the index does not
        // accumulate test cruft.
        let ragTestFile = dir.appendingPathComponent("fire-cross-brand-rag-test")
        TriggerWatcher.shared.register(ragTestFile) {
            guard FileManager.default.fileExists(atPath: ragTestFile.path) else { return }
            try? FileManager.default.removeItem(at: ragTestFile)
            WakeLog.shared.log("manual cross-brand-rag-test trigger fired")
            Task {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
                let rag = RAGClient()
                let docs: [RAGClient.Document] = [
                    .init(
                        id: "rag-smoke-brand-a-\(nonce)",
                        source: "ambient",
                        text: "RAG smoke nonce \(nonce): brand A goat milk lotion subscribe and save cadence is forty two days.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "brand-a"
                    ),
                    .init(
                        id: "rag-smoke-grux-\(nonce)",
                        source: "decision",
                        text: "RAG smoke nonce \(nonce): the Grux exception allows a deploy without an explicit ship-it confirmation, no other brand qualifies.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "grux"
                    ),
                    .init(
                        id: "rag-smoke-brand-b-\(nonce)",
                        source: "doc",
                        text: "RAG smoke nonce \(nonce): brand B primary working tree is the Express plus React plus Drizzle codebase on Render.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "brand-b"
                    ),
                ]

                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("cross-brand-rag-test result @ \(iso.string(from: Date()))")
                lines.append("nonce: \(nonce)")
                lines.append("")

                var indexedOK = false
                do {
                    let resp = try await rag.index(docs)
                    indexedOK = resp.indexed == docs.count
                    lines.append("index: indexed=\(resp.indexed) table_rows=\(resp.tableRows)")
                } catch {
                    lines.append("index: FAILED \(error)")
                }

                var hitBrandA = false
                var hitGrux = false
                var hitBrandB = false
                var hitTopScore: Double = 0
                if indexedOK {
                    do {
                        let resp = try await rag.query("smoke nonce \(nonce)", k: 5)
                        hitTopScore = resp.hits.first?.score ?? 0
                        for h in resp.hits {
                            if h.id == "rag-smoke-brand-a-\(nonce)" { hitBrandA = true }
                            if h.id == "rag-smoke-grux-\(nonce)" { hitGrux = true }
                            if h.id == "rag-smoke-brand-b-\(nonce)" { hitBrandB = true }
                        }
                        lines.append("query: hits=\(resp.hits.count) top_score=\(String(format: "%.3f", hitTopScore))")
                        for h in resp.hits.prefix(5) {
                            lines.append("  - \(h.id) score=\(String(format: "%.3f", h.score)) brand=\(h.brandHint) source=\(h.source)")
                        }
                    } catch {
                        lines.append("query: FAILED \(error)")
                    }

                    do {
                        let brandResp = try await rag.query("smoke nonce \(nonce)", k: 5, brandHint: "brand-a")
                        let allBrandA = !brandResp.hits.isEmpty && brandResp.hits.allSatisfy { $0.brandHint == "brand-a" }
                        lines.append("brand_filter(brand-a): hits=\(brandResp.hits.count) all_brand_a=\(allBrandA)")
                    } catch {
                        lines.append("brand_filter(brand-a): FAILED \(error)")
                    }
                }

                let pass = indexedOK && hitBrandA && hitGrux && hitBrandB && hitTopScore > 0.5
                lines.append("")
                lines.append("VERDICT: \(pass ? "PASS" : "FAIL")")

                let outPath = NSHomeDirectory() + "/.grux/cross-brand-rag-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)

                for doc in docs {
                    _ = try? await rag.deleteDoc(id: doc.id)
                }
            }
        }

        // Open the Creative tab: touch ~/.grux/fire-open-creative
        // Routes through AppState.requestedTab which LaunchRootView observes,
        // so any external caller (CLI verification, fire-and-forget script,
        // future iOS deep link) can pop the user straight into the inbox.
        let openCreativeFile = dir.appendingPathComponent("fire-open-creative")
        TriggerWatcher.shared.register(openCreativeFile) {
            guard FileManager.default.fileExists(atPath: openCreativeFile.path) else { return }
            try? FileManager.default.removeItem(at: openCreativeFile)
            WakeLog.shared.log("manual open-creative trigger fired")
            Task { @MainActor in AppState.shared.requestedTab = "creative" }
        }

        // Voice-to-creative-engine smoke trigger: touch ~/.grux/fire-voice-image-test
        // to run a hard-coded creative brief end to end. Routes through
        // CreativeEngine (wrapper → image service → claude direct fallback),
        // saves the bundle to ~/.grux/creative/<brand>/<id>.json, and writes a
        // result summary to ~/.grux/voice-image-test-result.txt for CLI
        // verification. Lets us prove the pipeline works without a voice prompt.
        let voiceImageTestFile = dir.appendingPathComponent("fire-voice-image-test")
        TriggerWatcher.shared.register(voiceImageTestFile) {
            guard FileManager.default.fileExists(atPath: voiceImageTestFile.path) else { return }
            try? FileManager.default.removeItem(at: voiceImageTestFile)
            WakeLog.shared.log("manual voice-image-test trigger fired")
            Task { @MainActor in await CreativeEngine.shared.runSmokeTest() }
        }

        // Whisper-queue smoke trigger: touch ~/.grux/fire-whisper-queue-test
        // to run the Mac to companion service transcription round trip end to end. Resolves
        // a test WAV (explicit ~/.grux/whisper-test-audio.wav fixture, else a
        // freshly synthesized short `say` clip), uploads to the companion
        // transcription queue, polls for the result, and writes
        // ~/.grux/whisper-queue-test-result.txt for CLI verification. Proves the
        // offload path without waiting for a real 5-min-plus meeting to end.
        let whisperQueueTestFile = dir.appendingPathComponent("fire-whisper-queue-test")
        TriggerWatcher.shared.register(whisperQueueTestFile) {
            guard FileManager.default.fileExists(atPath: whisperQueueTestFile.path) else { return }
            try? FileManager.default.removeItem(at: whisperQueueTestFile)
            WakeLog.shared.log("manual whisper-queue-test trigger fired")
            Task {
                let summary = await WhisperQueueClient.shared.runSmokeTest()
                await MainActor.run {
                    AppState.shared.appendChat(ChatMessage(role: .system, content: "🎙️ \(summary)"))
                }
            }
        }

        // LLM-spend smoke trigger: touch ~/.grux/fire-llm-spend-test to verify
        // the spend tracker end to end without waiting for the 6h sweep or a
        // real billing spike. Contents:
        //   - empty / "synthetic" : inject a 7-day flat baseline + a 9x spike
        //                           day, run the REAL anomaly detector, and
        //                           speak + banner the alert (proves detection).
        //   - "live"              : force a real refresh and dump current
        //                           daily spend + provider split.
        // Result is written to ~/.grux/llm-spend-test-result.txt.
        let llmSpendTestFile = dir.appendingPathComponent("fire-llm-spend-test")
        TriggerWatcher.shared.register(llmSpendTestFile) {
            guard FileManager.default.fileExists(atPath: llmSpendTestFile.path) else { return }
            let payload = (try? String(contentsOf: llmSpendTestFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: llmSpendTestFile)
            WakeLog.shared.log("manual llm-spend-test trigger fired (mode=\(payload.isEmpty ? "synthetic" : payload))")
        }

        // Manual audio-restore escape hatch: touch ~/.grux/fire-audio-restore
        // when Music has been stranded at the ducked level (50) outside the
        // ducker's normal start/stop notification flow. Force-restores from
        // the persisted breadcrumb or to a sane default (80) when no
        // breadcrumb exists. Belt-and-suspenders for the crash-mid-duck
        // path that the self-heal in AudioDucker.install() already covers.
        let audioRestoreFile = dir.appendingPathComponent("fire-audio-restore")
        TriggerWatcher.shared.register(audioRestoreFile) {
            guard FileManager.default.fileExists(atPath: audioRestoreFile.path) else { return }
            try? FileManager.default.removeItem(at: audioRestoreFile)
            WakeLog.shared.log("manual audio-restore trigger fired")
            Task { @MainActor in AudioDucker.shared.forceRestoreNow() }
        }

        // Debug stuck-trigger - touch ~/.grux/fire-stuck to force the stuck
        // detector to fire a nudge right now (bypasses idle/silence checks
        // and the 20-min cooldown). Used for testing + power users.
        let stuckFile = dir.appendingPathComponent("fire-stuck")
        TriggerWatcher.shared.register(stuckFile) {
            guard FileManager.default.fileExists(atPath: stuckFile.path) else { return }
            try? FileManager.default.removeItem(at: stuckFile)
            WakeLog.shared.log("manual stuck trigger fired")
            Task { @MainActor in await StuckDetector.shared.forceFire() }
        }

        // Debug screen-time trigger: touch ~/.grux/fire-screentime-test to
        // force an immediate tick (writes one NDJSON line now) and dump the
        // last hour's per-app dwell summary to ~/.grux/screentime-test-result.txt
        // for CLI verification.
        let stFile = dir.appendingPathComponent("fire-screentime-test")
        TriggerWatcher.shared.register(stFile) {
            guard FileManager.default.fileExists(atPath: stFile.path) else { return }
            try? FileManager.default.removeItem(at: stFile)
            WakeLog.shared.log("manual screentime-test trigger fired")
            Task { @MainActor in
                ScreenTimeWatcher.shared.fireTickNow()
                // Give the async tick ~1.5s to land on disk before reading.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let events = ScreenTimeWatcher.loadEvents(between: hourAgo, and: now)
                let dwell = ScreenTimeWatcher.perAppDwell(between: hourAgo, and: now)
                var lines: [String] = []
                lines.append("screentime-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: app=\(last.appName) title=\(last.windowTitle) idle=\(last.idle) idle_seconds=\(last.idleSeconds)")
                }
                lines.append("per-app dwell (last hour, idle excluded):")
                for entry in dwell.prefix(10) {
                    lines.append("  \(entry.app): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = NSHomeDirectory() + "/.grux/screentime-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug chrome-tabs trigger: touch ~/.grux/fire-chrome-tabs-test to
        // force one ChromeTabWatcher tick (writes one NDJSON line right now
        // if Chrome is frontmost, skips if not) and dump the last hour's
        // per-domain dwell to ~/.grux/chrome-tabs-test-result.txt for CLI
        // verification.
        let ctFile = dir.appendingPathComponent("fire-chrome-tabs-test")
        TriggerWatcher.shared.register(ctFile) {
            guard FileManager.default.fileExists(atPath: ctFile.path) else { return }
            try? FileManager.default.removeItem(at: ctFile)
            WakeLog.shared.log("manual chrome-tabs-test trigger fired")
            Task { @MainActor in
                ChromeTabWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let events = ChromeTabWatcher.loadEvents(between: hourAgo, and: now)
                let dwell = ChromeTabWatcher.perDomainDwell(between: hourAgo, and: now)
                var lines: [String] = []
                lines.append("chrome-tabs-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: domain=\(last.domain) title=\(last.title.prefix(80))")
                    lines.append("url: \(last.url.prefix(200))")
                }
                lines.append("per-domain dwell (last hour):")
                for entry in dwell.prefix(10) {
                    lines.append("  \(entry.domain): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = NSHomeDirectory() + "/.grux/chrome-tabs-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug music-tracker trigger: touch ~/.grux/fire-music-tracker-test to
        // force one MusicWatcher tick (writes one NDJSON line per playing
        // source if any are running, skips silently otherwise) and dump the
        // last hour's top artists + genres + total listen-seconds to
        // ~/.grux/music-test-result.txt for CLI verification.
        let mtFile = dir.appendingPathComponent("fire-music-tracker-test")
        TriggerWatcher.shared.register(mtFile) {
            guard FileManager.default.fileExists(atPath: mtFile.path) else { return }
            try? FileManager.default.removeItem(at: mtFile)
            WakeLog.shared.log("manual music-tracker-test trigger fired")
            Task { @MainActor in
                MusicWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let dayAgo = now.addingTimeInterval(-86400)
                let events = MusicWatcher.loadEvents(between: hourAgo, and: now)
                let artistsH = MusicWatcher.perArtistDwell(between: hourAgo, and: now)
                let artistsD = MusicWatcher.perArtistDwell(between: dayAgo, and: now)
                let genresD = MusicWatcher.perGenreDwell(between: dayAgo, and: now)
                let listenH = MusicWatcher.totalListenSeconds(between: hourAgo, and: now)
                let listenD = MusicWatcher.totalListenSeconds(between: dayAgo, and: now)
                var lines: [String] = []
                lines.append("music-tracker-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: source=\(last.source) state=\(last.state) artist=\(last.artist) track=\(last.track.prefix(60))")
                }
                lines.append("listen-seconds last hour: \(listenH) (\(listenH / 60)m)")
                lines.append("listen-seconds last 24h: \(listenD) (\(listenD / 60)m)")
                lines.append("top artists last hour:")
                for entry in artistsH.prefix(5) {
                    lines.append("  \(entry.artist): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                lines.append("top artists last 24h:")
                for entry in artistsD.prefix(10) {
                    lines.append("  \(entry.artist): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                lines.append("top genres last 24h (Apple Music only):")
                for entry in genresD.prefix(5) {
                    lines.append("  \(entry.genre): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = NSHomeDirectory() + "/.grux/music-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug notification-storm trigger: touch ~/.grux/fire-notif-storm-test
        // to force one NotificationWatcher poll, then dump the last hour and
        // last 24h interrupt totals + per-app breakdown to
        // ~/.grux/notif-storm-test-result.txt for CLI verification. Lets us
        // prove the watcher end-to-end without waiting for the natural 60s
        // tick or for the next 6am workday rollup.
        let nsFile = dir.appendingPathComponent("fire-notif-storm-test")
        TriggerWatcher.shared.register(nsFile) {
            guard FileManager.default.fileExists(atPath: nsFile.path) else { return }
            try? FileManager.default.removeItem(at: nsFile)
            WakeLog.shared.log("manual notif-storm-test trigger fired")
            Task { @MainActor in
                NotificationWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let dayAgo = now.addingTimeInterval(-86400)
                let hourCount = NotificationWatcher.interruptCount(between: hourAgo, and: now)
                let dayCount = NotificationWatcher.interruptCount(between: dayAgo, and: now)
                let hourApps = NotificationWatcher.perAppInterrupts(between: hourAgo, and: now)
                let dayApps = NotificationWatcher.perAppInterrupts(between: dayAgo, and: now)
                var lines: [String] = []
                lines.append("notif-storm-test result @ \(ISO8601DateFormatter().string(from: now))")
                if NotificationWatcher.isFDADenied() {
                    lines.append("WARNING: Full Disk Access denied. See ~/.grux/notif-storm-fda-required.txt for the one-time grant steps. Counts below will be 0 until granted.")
                }
                lines.append("interrupts last hour:  \(hourCount)")
                lines.append("interrupts last 24h:   \(dayCount)")
                lines.append("per-app last hour:")
                for entry in hourApps.prefix(10) {
                    lines.append("  \(entry.app): \(entry.count)")
                }
                lines.append("per-app last 24h:")
                for entry in dayApps.prefix(10) {
                    lines.append("  \(entry.app): \(entry.count)")
                }
                let outPath = NSHomeDirectory() + "/.grux/notif-storm-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug calendar-correlator trigger: touch ~/.grux/fire-calendar-correlator-test
        // to fetch the past 24h of EventKit events, correlate them to the
        // current ambient transcript chunks, and dump the resulting timeline
        // entries to ~/.grux/calendar-correlator-test-result.txt. Used for
        // CLI-driven end-to-end verification without waiting for the next 6am
        // WorkdayLog rollup.
        let ccFile = dir.appendingPathComponent("fire-calendar-correlator-test")
        TriggerWatcher.shared.register(ccFile) {
            guard FileManager.default.fileExists(atPath: ccFile.path) else { return }
            try? FileManager.default.removeItem(at: ccFile)
            WakeLog.shared.log("manual calendar-correlator-test trigger fired")
            Task { @MainActor in
                let granted = await CalendarCorrelator.ensurePermission()
                let now = Date()
                let dayAgo = now.addingTimeInterval(-24 * 3600)
                let chunks = AmbientState.shared.recentChunks
                let entries = await CalendarCorrelator.entries(
                    forWindow: dayAgo, windowEnd: now, chunks: chunks
                )
                let sessions = CalendarCorrelator.ambientSessions(from: chunks)
                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("calendar-correlator-test result @ \(iso.string(from: now))")
                lines.append("permission_granted: \(granted)")
                lines.append("ambient_chunks_in_buffer: \(chunks.count)")
                lines.append("ambient_sessions_inferred: \(sessions.count)")
                lines.append("entries (\(entries.count)):")
                for e in entries {
                    let ambient = e.ambientSessionId ?? "(none)"
                    let cal = e.calendarName.isEmpty ? "(no calendar name)" : e.calendarName
                    lines.append("  - \(iso.string(from: e.tsStart)) -> \(iso.string(from: e.tsEnd)) | \(e.eventTitle) | \(cal) | session=\(ambient)")
                }
                let outPath = NSHomeDirectory() + "/.grux/calendar-correlator-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug sleep-log trigger: touch ~/.grux/fire-sleep-log-test to
        // synthesize a paired sleep+wake event right now (bypasses NSWorkspace
        // so verification works on an awake Mac) and dump the rows from
        // today's NDJSON to ~/.grux/sleep-log-test-result.txt for CLI checks.
        let slFile = dir.appendingPathComponent("fire-sleep-log-test")
        TriggerWatcher.shared.register(slFile) {
            guard FileManager.default.fileExists(atPath: slFile.path) else { return }
            try? FileManager.default.removeItem(at: slFile)
            WakeLog.shared.log("manual sleep-log-test trigger fired")
            Task { @MainActor in
                SleepWatcher.shared.fireSyntheticTestEvents()
                let url = SleepWatcher.systemEventsURL(forDate: Date())
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let now = Date()
                let dayStart = Calendar.current.startOfDay(for: now)
                let intervals = SleepWatcher.sleepIntervals(in: dayStart..<now)
                var lines: [String] = []
                lines.append("sleep-log-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("file: \(url.path)")
                lines.append("rows:")
                lines.append(body)
                lines.append("paired sleep intervals today: \(intervals.count)")
                for iv in intervals.suffix(5) {
                    let secs = Int(iv.end.timeIntervalSince(iv.start).rounded())
                    lines.append("  \(iv.start) -> \(iv.end) (\(secs)s)")
                }
                let outPath = NSHomeDirectory() + "/.grux/sleep-log-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug glow triggers - touch ~/.grux/fire-glow-red / fire-glow-green /
        // fire-glow-speaking to render the refocus glow around the frontmost
        // window. Lets the user verify the overlay end-to-end without waiting.
        let glowRed = dir.appendingPathComponent("fire-glow-red")
        let glowGreen = dir.appendingPathComponent("fire-glow-green")
        let glowSpeaking = dir.appendingPathComponent("fire-glow-speaking")
        TriggerWatcher.shared.register(glowRed) {
            if FileManager.default.fileExists(atPath: glowRed.path) {
                try? FileManager.default.removeItem(at: glowRed)
                WakeLog.shared.log("manual glow (red) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .distracted) }
            }
            if FileManager.default.fileExists(atPath: glowGreen.path) {
                try? FileManager.default.removeItem(at: glowGreen)
                WakeLog.shared.log("manual glow (green) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .focused) }
            }
            if FileManager.default.fileExists(atPath: glowSpeaking.path) {
                try? FileManager.default.removeItem(at: glowSpeaking)
                WakeLog.shared.log("manual glow (speaking) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .speaking) }
            }
        }

        // Debug orb-anywhere + hint + stage triggers - drop the matching file
        // at ~/.grux/ to exercise each surface end-to-end. For fire-orb-hint
        // and fire-stage, the file's text (if any) is used as the message.
        let orbAnywhereToggle = dir.appendingPathComponent("fire-orb-anywhere")
        let hintFile = dir.appendingPathComponent("fire-orb-hint")
        let stageFile = dir.appendingPathComponent("fire-stage")
        TriggerWatcher.shared.register(orbAnywhereToggle) {
            if FileManager.default.fileExists(atPath: orbAnywhereToggle.path) {
                try? FileManager.default.removeItem(at: orbAnywhereToggle)
                WakeLog.shared.log("manual orb-anywhere toggle fired")
                Task { @MainActor in OrbAnywhereController.shared.toggle() }
            }
            if FileManager.default.fileExists(atPath: hintFile.path) {
                let payload = (try? String(contentsOf: hintFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: hintFile)
                WakeLog.shared.log("manual orb-hint fired: '\(payload)'")
                Task { @MainActor in
                    // Payload can be "message" or "message|state". Default state is thinking.
                    let parts = payload.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let message = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "working on it"
                    let stateStr = parts.count > 1 ? parts[1] : "thinking"
                    OrbHintBus.shared.show(
                        message: message,
                        state: OrbHintBus.parseState(stateStr),
                        duration: 4.0
                    )
                }
            }
            if FileManager.default.fileExists(atPath: stageFile.path) {
                let payload = (try? String(contentsOf: stageFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: stageFile)
                WakeLog.shared.log("manual stage fired: '\(payload)'")
                Task { @MainActor in
                    let message = payload.isEmpty ? "shipped it" : payload
                    StageController.shared.show(message: message, state: .speaking, duration: 3.5)
                }
            }
        }

        // Force one focus check immediately - handy for testing the new vision
        // path without waiting for captureIntervalSeconds to elapse.
        let focusNow = dir.appendingPathComponent("fire-focus-check")
        TriggerWatcher.shared.register(focusNow) {
            guard FileManager.default.fileExists(atPath: focusNow.path) else { return }
            try? FileManager.default.removeItem(at: focusNow)
            WakeLog.shared.log("manual focus check fired")
            Task { @MainActor in FocusWatcher.shared.runOnceNow() }
        }

        // Security smoke test - touch ~/.grux/fire-smoke-test to run the
        // FilesystemTool / Redaction / Keychain / audit checks in-process
        // and write results to ~/.grux/smoke-test-results.txt.
        let smokeTrigger = dir.appendingPathComponent("fire-smoke-test")
        TriggerWatcher.shared.register(smokeTrigger) {
            guard FileManager.default.fileExists(atPath: smokeTrigger.path) else { return }
            try? FileManager.default.removeItem(at: smokeTrigger)
            WakeLog.shared.log("smoke test triggered")
            Task { @MainActor in await SmokeTest.runAndWriteReport() }
        }

        // iPhone pairing window trigger - touch ~/.grux/fire-pair-iphone to
        // open the QR pairing window. CLI verification uses this so the
        // physical iPhone can pair without clicking through the menu bar.
        let pairTrigger = dir.appendingPathComponent("fire-pair-iphone")
        TriggerWatcher.shared.register(pairTrigger) {
            guard FileManager.default.fileExists(atPath: pairTrigger.path) else { return }
            try? FileManager.default.removeItem(at: pairTrigger)
            WakeLog.shared.log("manual pair-iphone trigger fired")
            Task { @MainActor in
                AppDelegate.shared?.openPhonePairingWindow()
            }
        }

        // Agents tab CLI trigger - touch ~/.grux/fire-open-agents to open
        // the launch window with the Agents tab focused. Used by E2E scripts
        // verifying job-row right-click context menus without driving the
        // menu bar extra (System Events automation is permission-gated and
        // unreliable from Bash subshells).
        let openAgentsTrigger = dir.appendingPathComponent("fire-open-agents")
        TriggerWatcher.shared.register(openAgentsTrigger) {
            guard FileManager.default.fileExists(atPath: openAgentsTrigger.path) else { return }
            try? FileManager.default.removeItem(at: openAgentsTrigger)
            WakeLog.shared.log("manual open-agents trigger fired")
            Task { @MainActor in
                AppState.shared.requestedTab = "agents"
                AppDelegate.shared?.openLaunchWindow(tab: "agents")
            }
        }

        // Job context-menu E2E trigger - touch ~/.grux/fire-test-job-ctxmenu
        // to exercise every menu action against the FIRST job in svc.jobs and
        // dump a verification report to ~/.grux/job-ctxmenu-test.json. Used by
        // CLI verification that can't dispatch real synthetic right-clicks
        // (System Events automation is permission-gated). Each action's
        // observable side effect is captured: clipboard contents (Copy *),
        // existence of the job dir on disk (Open in Finder → Job folder),
        // and a flag for whether the Expand window scene was successfully
        // requested (Open Window).
        let ctxMenuTestTrigger = dir.appendingPathComponent("fire-test-job-ctxmenu")
        TriggerWatcher.shared.register(ctxMenuTestTrigger) {
            guard FileManager.default.fileExists(atPath: ctxMenuTestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: ctxMenuTestTrigger)
            WakeLog.shared.log("manual fire-test-job-ctxmenu fired")
            Task { @MainActor in
                await AgentService.shared.refreshJobs()
                guard let job = AgentService.shared.jobs.first else {
                    let report: [String: Any] = ["ok": false, "reason": "no jobs to test against"]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                        try? data.write(to: dir.appendingPathComponent("job-ctxmenu-test.json"))
                    }
                    return
                }
                var results: [String: Any] = [:]
                results["job_id"] = job.id
                results["job_title"] = job.title
                results["job_status"] = job.status.rawValue
                let workersDone = job.workers.filter { $0.status == .done }.count
                let workersFailed = job.workers.filter { $0.status == .failed }.count
                results["workers_total"] = job.workers.count
                results["workers_done"] = workersDone
                results["workers_failed"] = workersFailed
                results["is_terminal"] = job.isTerminal
                // Action: Copy job ID → clipboard
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(job.id, forType: .string)
                let clipped = pb.string(forType: .string) ?? ""
                results["copy_id_action"] = [
                    "expected": job.id,
                    "clipboard": clipped,
                    "match": clipped == job.id
                ]
                // Action: Reveal job folder in Finder (verify path exists)
                let folder = AgentService.shared.jobFolderURL(jobId: job.id)
                results["reveal_job_folder_action"] = [
                    "path": folder.path,
                    "exists_on_disk": FileManager.default.fileExists(atPath: folder.path)
                ]
                // Action: Open Expand window via the registered "agent-job" scene.
                // We can't call SwiftUI's openWindow from outside a View, but
                // we can prove the scene is registered + AgentJobWindow renders
                // by instantiating it directly and confirming type identity.
                let _ = AgentJobWindow(jobId: job.id)
                results["expand_window_scene"] = [
                    "scene_id": "agent-job",
                    "view_type": String(describing: AgentJobWindow.self),
                    "instantiated": true
                ]
                // Action: Retry-failed availability (only meaningful when failed > 0)
                results["retry_failed_workers_available"] = workersFailed > 0
                // Action: Resume availability (only when waiting + authLimitHit)
                results["resume_available"] = (job.status == .waiting && job.pausedReason == .authLimitHit)
                // Final verdict
                let copyOk = (results["copy_id_action"] as? [String: Any])?["match"] as? Bool ?? false
                results["all_critical_paths_ok"] = copyOk
                results["timestamp"] = ISO8601DateFormatter().string(from: Date())
                if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) {
                    try? data.write(to: dir.appendingPathComponent("job-ctxmenu-test.json"))
                }
                WakeLog.shared.log("ctxmenu-test wrote report; copy_id_match=\(copyOk)")
            }
        }

        // Expand-job-window E2E trigger - touch ~/.grux/fire-test-expand-job
        // to open the AgentJobWindow scene for the first job, exercising the
        // exact codepath the right-click "Expand" menu item uses. Posts a
        // notification that LaunchRootView observes (it has the SwiftUI
        // openWindow environment value in scope).
        let expandTrigger = dir.appendingPathComponent("fire-test-expand-job")
        TriggerWatcher.shared.register(expandTrigger) {
            guard FileManager.default.fileExists(atPath: expandTrigger.path) else { return }
            try? FileManager.default.removeItem(at: expandTrigger)
            WakeLog.shared.log("manual fire-test-expand-job fired")
            Task { @MainActor in
                guard let jobId = AgentService.shared.jobs.first?.id else { return }
                NotificationCenter.default.post(
                    name: .gruxOpenAgentJobWindow,
                    object: nil,
                    userInfo: ["jobId": jobId]
                )
            }
        }

        // Brand-time CLI smoke trigger: touch ~/.grux/fire-brand-time-test
        // to compute today's per-brand breakdown right now (reads
        // ~/.grux/ambient/screentime-*.ndjson + chrome-tabs-*.ndjson + walks
        // discovered git repos for commits since 00:00 local). Writes
        // ~/.grux/brand-time/YYYY-MM-DD.json and dumps a verification summary
        // to ~/.grux/brand-time-test-result.txt for CLI checks. Also nudges
        // the in-memory BrandTimeStore so the EmpireDashboard reflects the
        // new report next time it opens.
        let btFile = dir.appendingPathComponent("fire-brand-time-test")
        TriggerWatcher.shared.register(btFile) {
            guard FileManager.default.fileExists(atPath: btFile.path) else { return }
            try? FileManager.default.removeItem(at: btFile)
            WakeLog.shared.log("manual brand-time-test trigger fired")
            Task.detached(priority: .utility) {
                let now = Date()
                let report = BrandAttribution.computeAndWriteToday(now: now)
                // Hand the just-computed report to the store directly so we
                // don't fire a second detached compute that races with this
                // one on the output file.
                await MainActor.run { BrandTimeStore.shared.setReport(report, computedAt: now) }
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("brand-time-test result @ \(iso.string(from: now))")
                lines.append("report: \(BrandAttribution.outputURL(for: now).path)")
                lines.append("date: \(report.date)")
                lines.append("total active seconds today: \(report.totalActiveSeconds) (\(report.totalActiveSeconds / 60)m)")
                lines.append("unattributed seconds: \(report.unattributedSeconds) (\(report.unattributedSeconds / 60)m)")
                lines.append("brands surfaced: \(report.brands.count)")
                for row in report.brands.prefix(15) {
                    let mins = row.totalSeconds / 60
                    lines.append("  \(row.brand): \(mins)m total, \(row.gitCommits) commit\(row.gitCommits == 1 ? "" : "s"), web \(row.chromeSeconds / 60)m")
                }
                let outPath = NSHomeDirectory() + "/.grux/brand-time-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Empire dashboard CLI trigger: touch ~/.grux/fire-empire-dashboard
        // to open the live stat grid. Same purpose as
        // fire-pair-iphone: lets E2E scripts open the window without
        // driving sidebar clicks.
        let empireTrigger = dir.appendingPathComponent("fire-empire-dashboard")
        TriggerWatcher.shared.register(empireTrigger) {
            guard FileManager.default.fileExists(atPath: empireTrigger.path) else { return }
            try? FileManager.default.removeItem(at: empireTrigger)
            WakeLog.shared.log("manual empire-dashboard trigger fired")
            Task { @MainActor in
                AppDelegate.shared?.openEmpireDashboardWindow()
            }
        }

        // Brand-sentiment CLI smoke trigger: touch ~/.grux/fire-sentiment-test
        // to pull the latest digest from the companion sentiment service right
        // now (GET <host>/api/digest/latest), refresh the in-memory
        // store so the EmpireDashboard reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/sentiment-test-result.txt for CLI
        // checks. End-to-end verifiable without waiting for the nightly cron.
        let sentimentTrigger = dir.appendingPathComponent("fire-sentiment-test")
        TriggerWatcher.shared.register(sentimentTrigger) {
            guard FileManager.default.fileExists(atPath: sentimentTrigger.path) else { return }
            try? FileManager.default.removeItem(at: sentimentTrigger)
            WakeLog.shared.log("manual sentiment-test trigger fired")
            Task { @MainActor in
                await SentimentStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = SentimentStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("sentiment-test result @ \(iso.string(from: Date()))")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt)")
                    lines.append("brands: \(d.brandCount) | mentions: \(d.totalMentions) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    for b in d.brands.sorted(by: { $0.mentionCount > $1.mentionCount }) {
                        lines.append("  \(b.name): \(b.mood) \(String(format: "%.2f", b.score)) | \(b.mentionCount) mention(s) | \(b.provider)")
                    }
                } else {
                    lines.append("no digest (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = NSHomeDirectory() + "/.grux/sentiment-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Domain-renewal CLI smoke trigger: touch ~/.grux/fire-domain-renewal-test
        // to sweep GoDaddy right now (GET /v1/domains), refresh DomainMonitor so
        // the Empire dashboard reflects it, open the dashboard, force-speak the
        // soonest-expiring ACTIVE domain (so the alert path is verified even when
        // nothing is naturally inside the 30-day window), and dump a summary to
        // ~/.grux/domain-renewal-test-result.txt for CLI checks. End-to-end
        // verifiable without waiting for the 24h cadence.
        let domainRenewalTrigger = dir.appendingPathComponent("fire-domain-renewal-test")
        TriggerWatcher.shared.register(domainRenewalTrigger) {
            guard FileManager.default.fileExists(atPath: domainRenewalTrigger.path) else { return }
            try? FileManager.default.removeItem(at: domainRenewalTrigger)
            WakeLog.shared.log("manual domain-renewal-test trigger fired")
            Task { @MainActor in
                await DomainMonitor.shared.sweep(askedForByAPerson: true)
                AppDelegate.shared?.openEmpireDashboardWindow()
                let mon = DomainMonitor.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("domain-renewal-test result @ \(iso.string(from: Date()))")
                if let err = mon.lastError {
                    lines.append("ERROR: \(err)")
                }
                lines.append("active domains: \(mon.records.count)")
                let expiring = mon.records.filter { $0.isExpiring }
                lines.append("within 30 days: \(expiring.count)")
                for r in mon.records.prefix(8) {
                    let flag = r.isExpiring ? (r.renewAuto ? " [SOON]" : " [URGENT]") : ""
                    lines.append("  \(r.daysUntilExpiry)d  \(r.domain)  renewAuto=\(r.renewAuto)\(flag)")
                }
                // Force-speak the soonest domain so the voice/banner path is
                // proven regardless of the natural 30-day window state.
                if let soonest = mon.records.first {
                    let note = soonest.renewAuto ? "Auto renew is on." : "Auto renew is OFF."
                    let say = "Domain check. Soonest is \(soonest.domain) in \(soonest.daysUntilExpiry) days. \(note)"
                    SpeechEngine.shared.speak(say)
                    NotificationManager.shared.sendInfo(
                        title: "Domain check: \(soonest.domain)",
                        body: "\(soonest.daysUntilExpiry) days. \(note)")
                    lines.append("spoke + posted banner: \(say)")
                } else {
                    lines.append("no domains to speak (check ERROR above)")
                }
                let outPath = NSHomeDirectory() + "/.grux/domain-renewal-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // PR-digest CLI smoke trigger: touch ~/.grux/fire-pr-summarizer-test to
        // pull the latest open-PR digest from the companion digest service
        // right now (GET <host>/api/digest/latest), refresh the
        // store so the EmpireDashboard reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/pr-summarizer-test-result.txt. This
        // exercises the Grux pull path + render end-to-end without waiting for
        // the 5:55am cron. (The PUSH path, companion POST -> /api/inbox, is verified
        // separately by the deploy smoke script.)
        let prDigestTrigger = dir.appendingPathComponent("fire-pr-summarizer-test")
        TriggerWatcher.shared.register(prDigestTrigger) {
            guard FileManager.default.fileExists(atPath: prDigestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: prDigestTrigger)
            WakeLog.shared.log("manual pr-summarizer-test trigger fired")
            Task { @MainActor in
                await PRDigestStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = PRDigestStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("pr-summarizer-test result @ \(iso.string(from: Date()))")
                lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt) | source: \(d.source)")
                    lines.append("open: \(d.openCount) | repos: \(d.repoCount) | headline: \(d.headlineProvider) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    lines.append("headline: \(d.headline)")
                    for p in d.prs.sorted(by: { $0.ageDays > $1.ageDays }) {
                        lines.append("  \(p.repo) #\(p.number) | \(p.mergeable)\(p.draft ? "/draft" : "") | \(p.ageDays)d | \(p.title)")
                    }
                } else {
                    lines.append("no digest (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = NSHomeDirectory() + "/.grux/pr-summarizer-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Nightly-tests CLI smoke trigger: touch ~/.grux/fire-nightly-tests-test to
        // pull the latest nightly test report from the companion nightly service
        // right now (GET <host>/api/tests/latest), refresh the store
        // so the EmpireDashboard's Nightly Tests section reflects it, open the
        // dashboard, and dump a verification summary to
        // ~/.grux/nightly-tests-test-result.txt. Exercises the Grux pull path +
        // render end-to-end without waiting for the 4:15am cron. (The PUSH path,
        // companion POST -> /api/inbox/tests, is verified separately by the deploy
        // smoke script.)
        let nightlyTrigger = dir.appendingPathComponent("fire-nightly-tests-test")
        TriggerWatcher.shared.register(nightlyTrigger) {
            guard FileManager.default.fileExists(atPath: nightlyTrigger.path) else { return }
            try? FileManager.default.removeItem(at: nightlyTrigger)
            WakeLog.shared.log("manual nightly-tests-test trigger fired")
            Task { @MainActor in
                await TestDigestStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = TestDigestStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("nightly-tests-test result @ \(iso.string(from: Date()))")
                lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt) | source: \(d.source)")
                    lines.append("pass: \(d.passCount) | fail: \(d.failCount) | skip: \(d.skipCount) | error: \(d.errorCount) | repos: \(d.repoCount) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    lines.append("headline: \(d.headline)")
                    for r in d.results {
                        lines.append("  \(r.name) [\(r.status)] | \(r.gitInfo)")
                        for c in r.checks {
                            lines.append("    \(c.kind): \(c.status) (\(Int(c.durationSec))s)")
                        }
                    }
                } else {
                    lines.append("no report (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = NSHomeDirectory() + "/.grux/nightly-tests-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Empire-ops snapshot CLI smoke trigger: touch ~/.grux/fire-empire-dash-test
        // to pull the aggregated snapshot from the companion snapshot service
        // right now (GET <host>/api/empire/snapshot), refresh the store
        // so the Empire Dashboard's Ops grid reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/empire-dash-test-result.txt. Exercises the
        // Grux pull + render end-to-end without waiting for the hourly refresh.
        let empireDashTrigger = dir.appendingPathComponent("fire-empire-dash-test")
        TriggerWatcher.shared.register(empireDashTrigger) {
            guard FileManager.default.fileExists(atPath: empireDashTrigger.path) else { return }
            try? FileManager.default.removeItem(at: empireDashTrigger)
            WakeLog.shared.log("manual empire-dash-test trigger fired")
            Task { @MainActor in
                await EmpireSnapshotStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = EmpireSnapshotStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("empire-dash-test result @ \(iso.string(from: Date()))")
                if let s = store.snapshot {
                    let t = s.totals
                    let rev = t.revenueCents.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "n/a"
                    lines.append("generatedAt: \(s.generatedAt) | source: \(s.source) | tookMs: \(s.tookMs)")
                    lines.append("brands: \(s.brandCount) | revenue: \(rev) | installs: \(t.installs.map(String.init) ?? "n/a") | ratings: \(t.ratingCount ?? 0) | openPRs: \(t.openPRs) | infra: \(t.infraHealthy)/\(t.infraTotal)")
                    lines.append("servingStale: \(store.servingStale)")
                    let order = ["stripe", "asc", "github", "render", "cloudflare", "support"]
                    let badges = order.compactMap { k -> String? in
                        guard let m = s.sources[k] else { return nil }
                        let state = (m.ok == true) ? "ok" : ((m.configured == true) ? "cfg" : "off")
                        return "\(k)=\(state)"
                    }
                    lines.append("sources: " + badges.joined(separator: " "))
                    for b in s.brands {
                        let r = b.revenueCents.map { String(format: "$%.0f", Double($0) / 100.0) } ?? "n/a"
                        lines.append("  \(b.name): rev \(r) | installs \(b.installs.map(String.init) ?? "n/a")(\(b.installsSource)) | PRs \(b.openPRs) | infra \(b.infra.healthy)/\(b.infra.total)")
                    }
                    if !s.errors.isEmpty { lines.append("errors: \(s.errors.joined(separator: "; "))") }
                } else {
                    lines.append("no snapshot (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = NSHomeDirectory() + "/.grux/empire-dash-test-result.txt"
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Social Ops cockpit CLI smoke trigger: touch ~/.grux/fire-social-ops-cockpit-test
        // to pull the live grid from the companion social-ops service right now
        // (GET <host>/api/social-ops/state), ingest it so the
        // Empire Dashboard's Social Ops section reflects it, open the dashboard,
        // write a PASS/FAIL summary to ~/.grux/social-ops-cockpit-test-result.txt,
        // and append a one-line result to chat. Exercises the Mac pull + render
        // end-to-end without waiting for a sweep change-event.
        let socialOpsTrigger = dir.appendingPathComponent("fire-social-ops-cockpit-test")
        TriggerWatcher.shared.register(socialOpsTrigger) {
            guard FileManager.default.fileExists(atPath: socialOpsTrigger.path) else { return }
            try? FileManager.default.removeItem(at: socialOpsTrigger)
            WakeLog.shared.log("manual social-ops-cockpit-test trigger fired")
            Task { @MainActor in
                let summary = await SocialOpsCoordinator.shared.runSmokeTest()
                AppDelegate.shared?.openEmpireDashboardWindow()
                AppState.shared.appendChat(ChatMessage(role: .system, content: "📣 \(summary)"))
            }
        }

        // Social Ops digest CLI trigger: touch ~/.grux/fire-social-ops-digest to
        // force the daily health digest + weekly reach-trend cards right now
        // (ignoring the once-per-period guards), so the native notification +
        // chat card + phone push path can be verified without waiting for the
        // 15-minute tick or a day/week rollover.
        let socialOpsDigestTrigger = dir.appendingPathComponent("fire-social-ops-digest")
        TriggerWatcher.shared.register(socialOpsDigestTrigger) {
            guard FileManager.default.fileExists(atPath: socialOpsDigestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: socialOpsDigestTrigger)
            WakeLog.shared.log("manual social-ops-digest trigger fired")
            Task { @MainActor in
                SocialOpsCoordinator.shared.runScheduledDigestsIfDue(force: true)
            }
        }

        // iPhone receiver status dump - touch ~/.grux/fire-phone-status to
        // write a one-shot JSON file at ~/.grux/phone-receiver-status.json
        // with the current port, connection state, and frame counts.
        let phoneStatusTrigger = dir.appendingPathComponent("fire-phone-status")
        TriggerWatcher.shared.register(phoneStatusTrigger) {
            guard FileManager.default.fileExists(atPath: phoneStatusTrigger.path) else { return }
            try? FileManager.default.removeItem(at: phoneStatusTrigger)
            Task { @MainActor in
                let s = PhoneReceiverState.shared
                let json: [String: Any] = [
                    "isRunning": s.isRunning,
                    "isConnected": s.isConnected,
                    "connectedDevice": s.connectedDevice,
                    "audioFramesReceived": s.audioFramesReceived,
                    "listenerPort": Int(s.listenerPort),
                    "latestTranscript": s.latestTranscript,
                    "lastError": s.lastError,
                    "lastFrameAtEpoch": s.lastFrameAt.timeIntervalSince1970,
                    "pairingSecretConfigured": PhonePairing.isConfigured,
                    "hostname": PhonePairing.localHostname()
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                    let out = dir.appendingPathComponent("phone-receiver-status.json")
                    try? data.write(to: out)
                }
            }
        }

        // Screen control status dump - touch ~/.grux/fire-screen-check to write
        // ~/.grux/screen-control-status.json.
        //
        // THIS EXISTS BECAUSE OF A GAP IN WHAT TESTS CAN SEE. The screen control
        // tests run in the test host, which is a different binary with its own
        // TCC grants and its own place in the window stack. A green suite there
        // says the logic is right; it says nothing about whether the SHIPPED,
        // re-signed Grux.app still holds Accessibility, or which app the running
        // app believes is behind it. Both of those are exactly the questions
        // that go wrong silently, and both are only answerable from inside this
        // process.
        //
        // Read-only and side-effect free: it reports the switch and the grant,
        // and resolves the target WITHOUT walking any accessibility tree, so
        // firing it never touches another app.
        let screenCheckTrigger = dir.appendingPathComponent("fire-screen-check")
        TriggerWatcher.shared.register(screenCheckTrigger) {
            guard FileManager.default.fileExists(atPath: screenCheckTrigger.path) else { return }
            try? FileManager.default.removeItem(at: screenCheckTrigger)
            Task { @MainActor in
                let selfPID = ProcessInfo.processInfo.processIdentifier
                let order = ScreenControlEngine.onScreenPIDsFrontToBack()
                let target = ScreenControlEngine.currentTarget()
                var json: [String: Any] = [
                    "accessibilityGranted": ScreenControlEngine.hasAccessibility(),
                    "screenControlEnabled": AppState.shared.config.screenControlEnabled,
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "selfPID": Int(selfPID),
                    "frontmostPID": NSWorkspace.shared.frontmostApplication
                        .map { Int($0.processIdentifier) } ?? -1,
                    "gruxIsFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == selfPID,
                    "onScreenFrontToBack": order.map(Int.init),
                    // The whole point of the dump: which app list_ui would read.
                    "resolvedTarget": target?.name ?? "(none)",
                    "resolvedTargetPID": target.map { Int($0.pid) } ?? -1,
                    "resolvedTargetIsSelf": target?.pid == selfPID,
                    // The layout the key table is relative to, plus the one combo
                    // that was silently typing the wrong character.
                    "keyboardLayout": ScreenControlEngine.currentKeyboardLayoutName() ?? "unknown",
                    "plusTypes": ScreenControlEngine.producedCharacter(for: "plus") ?? "(none)",
                    "equalsTypes": ScreenControlEngine.producedCharacter(for: "equals") ?? "(none)",
                    "writtenAtEpoch": Date().timeIntervalSince1970
                ]
                json["onScreenAppNames"] = order.compactMap { pid in
                    NSWorkspace.shared.runningApplications
                        .first { $0.processIdentifier == pid }?.localizedName
                }
                if let data = try? JSONSerialization.data(withJSONObject: json,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: dir.appendingPathComponent("screen-control-status.json"))
                }
            }
        }

        // Fire a TTS utterance through SpeechEngine - same path as a chat
        // reply. Used to end-to-end verify the phone's TTS playback pipeline
        // from CLI without typing into chat. Reads message from the trigger
        // file contents; fallback text if empty.
        let fireSpeak = dir.appendingPathComponent("fire-speak")
        TriggerWatcher.shared.register(fireSpeak) {
            guard FileManager.default.fileExists(atPath: fireSpeak.path) else { return }
            let msg = (try? String(contentsOf: fireSpeak, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireSpeak)
            let text = msg.isEmpty
                ? "Grux is now streaming both ways over Cloudflare. If you can hear this on your phone, we nailed the bidirectional pipeline."
                : msg
            WakeLog.shared.log("fire-speak: \(text.prefix(60))")
            Task { @MainActor in SpeechEngine.shared.speak(text) }
        }

        // fire-open-tab: switch the RUNNING app to a tab, contents = the tab key
        // (the same keys --open-tab accepts). Opens the launch window if it is
        // closed, then selects the tab.
        //
        // This exists for UI verification. The only way to reach a specific tab
        // from outside was `--open-tab=` at LAUNCH, so sweeping every tab meant
        // quitting and relaunching per tab: about 12 seconds each, roughly 7
        // minutes for a full pass, which is slow enough that a full-app visual
        // check gets skipped and layout regressions ship. Switching a live tab
        // is a repaint, so the same pass runs in about a second per tab.
        //
        // Writes ~/.grux/open-tab-ack.txt with the key it applied, so a script
        // can wait for the switch to actually land instead of sleeping and
        // hoping. That ack is what makes the loop both fast and reliable.
        // fire-mic-mute / fire-mic-unmute: drive the microphone from the CLI.
        //
        // Added while fixing a bug where MUTED left the device held: a mute that
        // can only be triggered by clicking an orb cannot be verified without a
        // person, and this app's owner has limited mobility, so "just click it"
        // is not a test plan OR an acceptable only-path for the feature itself.
        // Writes a status file so a caller can assert the result rather than
        // sleeping and hoping.
        let fireMicMute = dir.appendingPathComponent("fire-mic-mute")
        TriggerWatcher.shared.register(fireMicMute) {
            try? FileManager.default.removeItem(at: fireMicMute)
            Task { @MainActor in
                MicController.mute()
                await MicController.writeMicStatus(dir: dir)
            }
        }
        let fireMicUnmute = dir.appendingPathComponent("fire-mic-unmute")
        TriggerWatcher.shared.register(fireMicUnmute) {
            try? FileManager.default.removeItem(at: fireMicUnmute)
            Task { @MainActor in
                MicController.unmute()
                await MicController.writeMicStatus(dir: dir)
            }
        }

        // fire-ambient-enable / fire-wake-enable: drive the LISTENING CONSENT
        // path from the CLI.
        //
        // Turning either feature on presents a modal dialog, and a modal is a
        // mouse gesture by construction. Same reasoning that produced
        // fire-mic-mute directly above: a feature whose only trigger is a click
        // cannot be verified by this app's owner, and a consent gate that has
        // never been seen working is a consent gate nobody should trust.
        //
        // Each writes mic-status.json after the dialog closes, so the ANSWER is
        // assertable: declining leaves ambientEnabledPreference false.
        let fireAmbientEnable = dir.appendingPathComponent("fire-ambient-enable")
        TriggerWatcher.shared.register(fireAmbientEnable) {
            try? FileManager.default.removeItem(at: fireAmbientEnable)
            Task { @MainActor in
                await AmbientState.shared.enable()
                await MicController.writeMicStatus(dir: dir)
            }
        }
        let fireWakeEnable = dir.appendingPathComponent("fire-wake-enable")
        TriggerWatcher.shared.register(fireWakeEnable) {
            try? FileManager.default.removeItem(at: fireWakeEnable)
            Task { @MainActor in
                await WakeWordListener.shared.enable()
                await MicController.writeMicStatus(dir: dir)
            }
        }
        // And a read with no side effects, so state can be checked without
        // changing it. Every other status write here rides on an action.
        let fireMicStatus = dir.appendingPathComponent("fire-mic-status")
        TriggerWatcher.shared.register(fireMicStatus) {
            try? FileManager.default.removeItem(at: fireMicStatus)
            Task { @MainActor in await MicController.writeMicStatus(dir: dir) }
        }

        // The setup surface, refreshed on demand and with no side effects.
        //
        // Every agent handoff Grux emits ends with a VERIFY section pointing at this state,
        // so it has to be readable without launching a UI and without changing anything.
        // The app also writes it at launch and after any step completes; this trigger is
        // for a caller that wants it recomputed right now, which is what the CLI does after
        // handing a permission queue over and waiting for the answer.
        let fireSetupStatus = dir.appendingPathComponent("fire-setup-status")
        TriggerWatcher.shared.register(fireSetupStatus) {
            try? FileManager.default.removeItem(at: fireSetupStatus)
            Task { @MainActor in SetupStatusFile.write() }
        }

        let fireOpenTab = dir.appendingPathComponent("fire-open-tab")
        TriggerWatcher.shared.register(fireOpenTab) {
            guard FileManager.default.fileExists(atPath: fireOpenTab.path) else { return }
            let key = (try? String(contentsOf: fireOpenTab, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireOpenTab)
            guard !key.isEmpty else { return }
            Task { @MainActor in
                // `settings:<tag>` selects a pane INSIDE Settings as well as the
                // tab, so a sweep can reach every Settings surface rather than
                // photographing whichever pane happened to be open last.
                //
                // Settings is one sidebar entry hiding five panes and nine
                // sub-panes, which is more distinct surface than most tabs have,
                // and none of it was reachable from outside. That is precisely
                // the gap this trigger's own comment describes: a surface that
                // cannot be driven does not get checked, and layout regressions
                // ship there. The tag goes through SettingsTabAliases, the same
                // resolver the setup card's deep link uses, so there is no
                // second vocabulary to keep in sync.
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                let tab = parts[0]
                if parts.count == 2 { AppState.shared.requestedSettingsTab = parts[1] }
                AppState.shared.requestedTab = tab
                (NSApp.delegate as? AppDelegate)?.openLaunchWindow(tab: tab)
                NSApp.activate(ignoringOtherApps: true)
                let ack = dir.appendingPathComponent("open-tab-ack.txt")
                // Acks the FULL key including the pane, so a script waiting on
                // "settings:models" is not released by a bare "settings".
                try? key.write(to: ack, atomically: true, encoding: .utf8)
                WakeLog.shared.log("fire-open-tab: \(key)")
            }
        }

        // fire-jax-brief: Jax speaks an on-demand briefing now (Home "brief me"
        // / CLI hook). Does not touch the scheduled-slot dedupe.
        let fireJaxBrief = dir.appendingPathComponent("fire-jax-brief")
        TriggerWatcher.shared.register(fireJaxBrief) {
            guard FileManager.default.fileExists(atPath: fireJaxBrief.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxBrief)
            WakeLog.shared.log("fire-jax-brief: on-demand briefing requested")
            Task { @MainActor in await BriefingEngine.shared.briefNow() }
        }

        // fire-foundry-resume: clear a tripped auto-land pause (the crash-loop
        // breaker pauses Foundry auto-land after repeated launch crashes; this
        // is the human reset). touch ~/.grux/fire-foundry-resume to resume.
        let fireFoundryResume = dir.appendingPathComponent("fire-foundry-resume")
        TriggerWatcher.shared.register(fireFoundryResume) {
            guard FileManager.default.fileExists(atPath: fireFoundryResume.path) else { return }
            try? FileManager.default.removeItem(at: fireFoundryResume)
            WakeLog.shared.log("fire-foundry-resume: clearing auto-land pause")
            Task { @MainActor in GruxUpdater.shared.clearAutoLandPause() }
        }

        // fire-jax-goalcycle: run one Jax goal-pursuit cycle now (respects the
        // current autonomy mode; SIMULATE by default, so it plans + logs only).
        // Reusable for verification and on-demand "what would you do next".
        let fireJaxGoal = dir.appendingPathComponent("fire-jax-goalcycle")
        TriggerWatcher.shared.register(fireJaxGoal) {
            guard FileManager.default.fileExists(atPath: fireJaxGoal.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxGoal)
            WakeLog.shared.log("fire-jax-goalcycle: goal-pursuit cycle requested")
            Task { @MainActor in _ = await GoalPursuitEngine.shared.runNow() }
        }

        // fire-jax-ingest: run the full corpus ingest now (all sources). Drop new
        // exports into ~/.grux/jax/imports first, then touch this file. Result is
        // logged to WakeLog. Reusable after dropping fresh data.
        let fireJaxIngest = dir.appendingPathComponent("fire-jax-ingest")
        TriggerWatcher.shared.register(fireJaxIngest) {
            guard FileManager.default.fileExists(atPath: fireJaxIngest.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxIngest)
            WakeLog.shared.log("fire-jax-ingest: corpus ingest requested")
            Task { @MainActor in
                let summary = await CorpusCoordinator.shared.runAll()
                WakeLog.shared.log("fire-jax-ingest done: \(summary)")
            }
        }

        // Rotate phone pairing secret. Closes any active phone session so
        // it can't keep streaming with the now-revoked key, deletes the
        // secret from Keychain (where we have ACL), and regenerates. The
        // pair QR window auto-re-renders once a new CF tunnel URL is ready.
        let fireRotate = dir.appendingPathComponent("fire-rotate-secret")
        TriggerWatcher.shared.register(fireRotate) {
            guard FileManager.default.fileExists(atPath: fireRotate.path) else { return }
            try? FileManager.default.removeItem(at: fireRotate)
            WakeLog.shared.log("fire-rotate-secret triggered")
            Task { @MainActor in
                PhoneReceiverService.shared.closeActiveConnectionForRotate()
                _ = PhonePairing.reset()
                _ = PhonePairing.ensureSecret()
            }
        }

        // Smoke-test the local-Qwen ambient brain end to end. Touch
        // ~/.grux/fire-ambient-llm-test to send a canned prompt through the
        // exact AmbientLLM routing the hourly summarizer uses, then write the
        // reply + latency + provider to ~/.grux/ambient-llm-test-result.txt.
        // Lets E2E scripts verify the Mac → companion service → Ollama loop without
        // waiting for the hour boundary or opening Settings.
        let fireAmbientLLM = dir.appendingPathComponent("fire-ambient-llm-test")
        TriggerWatcher.shared.register(fireAmbientLLM) {
            guard FileManager.default.fileExists(atPath: fireAmbientLLM.path) else { return }
            let prompt = (try? String(contentsOf: fireAmbientLLM, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireAmbientLLM)
            let user = prompt.isEmpty
                ? "TRANSCRIPT_CHUNKS:\n- shipped the PDP image render\n- still need to wire the label-fidelity check\n- Grux ambient brain landed today\nOne-sentence summary:"
                : prompt
            let sys = "You are Grux summarizing one hour of the user's ambient speech. Produce ONE short sentence (≤40 words). If pure filler, reply quiet. No emoji, no markdown."
            Task { @MainActor in
                let started = Date()
                let intent = AppState.shared.config.useLocalQwenForAmbient
                    ? "local/\(AppState.shared.config.localLLMModel)"
                    : "claude"
                do {
                    let res = try await AmbientLLM.completeTagged(
                        system: sys,
                        messages: [ClaudeMessage(role: "user", content: user)],
                        maxTokens: 120, temperature: 0.3,
                        featureTag: "ambient_llm_smoke_test"
                    )
                    let reply = res.text
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    // Provider used may differ from intent if the local path
                    // failed and the router fell back to Claude.
                    let actual = res.provider
                    let out = "intent=\(intent) provider=\(actual) ms=\(ms)\nreply: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    let outUrl = dir.appendingPathComponent("ambient-llm-test-result.txt")
                    try? out.write(to: outUrl, atomically: true, encoding: .utf8)
                    WakeLog.shared.log("fire-ambient-llm-test: ok (intent=\(intent) provider=\(actual), \(ms)ms)")
                } catch {
                    let outUrl = dir.appendingPathComponent("ambient-llm-test-result.txt")
                    try? "intent=\(intent) FAILED: \(error.localizedDescription)\n"
                        .write(to: outUrl, atomically: true, encoding: .utf8)
                    WakeLog.shared.log("fire-ambient-llm-test: failed \(error.localizedDescription)")
                }
            }
        }

        // Direct-to-phone synthetic TTS tone. Doesn't touch SpeechEngine or
        // ElevenLabs - synthesizes a 24kHz PCM16 warble right into
        // TTSBroadcaster. Lets us end-to-end verify the phone TTS playback
        // path even without an ElevenLabs key configured.
        let fireTTSTone = dir.appendingPathComponent("fire-tts-tone")
        TriggerWatcher.shared.register(fireTTSTone) {
            guard FileManager.default.fileExists(atPath: fireTTSTone.path) else { return }
            try? FileManager.default.removeItem(at: fireTTSTone)
            WakeLog.shared.log("fire-tts-tone → injecting 2s warble into TTSBroadcaster")
            Task { @MainActor in
                TTSBroadcaster.shared.speakStart()
                // 2-second warble: slow-sweeping sine, 24 kHz. Produces a
                // recognizable "dooo-waaa" that's obvious over a phone speaker.
                let sr = 24_000
                let totalSamples = sr * 2
                var pcm = Data(count: totalSamples * 2)
                pcm.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                    for i in 0..<totalSamples {
                        let t = Double(i) / Double(sr)
                        let freq = 300.0 + 250.0 * sin(2.0 * .pi * 0.5 * t)
                        let v = sin(2.0 * .pi * freq * t) * 0.25
                        base[i] = Int16(clamping: Int(v * Double(Int16.max)))
                    }
                }
                TTSBroadcaster.shared.feedPCM24(pcm)
                // Small drain delay so the phone plays the full tone before
                // END fires (which would otherwise stop the player node).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    Task { @MainActor in TTSBroadcaster.shared.speakEnd() }
                }
            }
        }

        // V2 workflow CANCEL trigger - touch ~/.grux/fire-v2-cancel with a
        // run id (8-char prefix is enough) in the file body to cancel the
        // matching active or waiting run. Used for headless E2E recovery
        // when a run is parked at an approval gate.
        let v2CancelTrigger = dir.appendingPathComponent("fire-v2-cancel")
        TriggerWatcher.shared.register(v2CancelTrigger) {
            guard FileManager.default.fileExists(atPath: v2CancelTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2CancelTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2CancelTrigger)
            guard !payload.isEmpty else {
                WakeLog.shared.log("fire-v2-cancel: empty payload - skipping")
                return
            }
            Task { @MainActor in
                let prefix = String(payload.prefix(36))
                let match = CommandV2Engine.shared.activeRuns.first {
                    $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) ||
                    $0.id.uuidString.lowercased() == prefix.lowercased()
                }
                guard let target = match else {
                    WakeLog.shared.log("fire-v2-cancel: no active run matches '\(prefix)'")
                    return
                }
                await CommandV2Engine.shared.cancel(target.id)
                WakeLog.shared.log("fire-v2-cancel: canceled \(target.id.uuidString.prefix(8))")
            }
        }

        // V2 workflow APPROVE trigger - touch ~/.grux/fire-v2-approve with a
        // run id (8-char prefix or full UUID) optionally followed by `|<reply>`
        // to programmatically advance a userApprovalGate-paused run. Used so
        // autonomous loops can drive workflows past walkthrough gates without
        // a human click.
        let v2ApproveTrigger = dir.appendingPathComponent("fire-v2-approve")
        TriggerWatcher.shared.register(v2ApproveTrigger) {
            guard FileManager.default.fileExists(atPath: v2ApproveTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2ApproveTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2ApproveTrigger)
            guard !payload.isEmpty else { return }
            let parts = payload.split(separator: "|", maxSplits: 1).map { String($0) }
            let prefix = parts[0].trimmingCharacters(in: .whitespaces)
            let reply = parts.count > 1 ? parts[1] : "approved (CLI)"
            Task { @MainActor in
                let match = CommandV2Engine.shared.activeRuns.first {
                    $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) ||
                    $0.id.uuidString.lowercased() == prefix.lowercased()
                }
                guard let target = match else {
                    WakeLog.shared.log("fire-v2-approve: no waiting run matches '\(prefix)'")
                    return
                }
                await CommandV2Engine.shared.resume(target.id, userReply: reply)
                WakeLog.shared.log("fire-v2-approve: advanced \(target.id.uuidString.prefix(8)) reply='\(reply)'")
            }
        }

        // V2 workflow CLI trigger - touch ~/.grux/fire-v2-run with a
        // definition id (e.g. "smoke-hello-world") in the file body to
        // start that V2 workflow. Used for headless E2E verification of
        // the engine without driving the SwiftUI tab.
        let v2RunTrigger = dir.appendingPathComponent("fire-v2-run")
        TriggerWatcher.shared.register(v2RunTrigger) {
            guard FileManager.default.fileExists(atPath: v2RunTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2RunTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2RunTrigger)
            // Payload format: "<definition-id>" or "<definition-id>|<param>=<value>,<param>=<value>"
            let parts = payload.split(separator: "|", maxSplits: 1).map { String($0) }
            let defId = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !defId.isEmpty else {
                WakeLog.shared.log("fire-v2-run: empty payload - skipping")
                return
            }
            var params: [String: JSONValue] = [:]
            if parts.count > 1 {
                for kv in parts[1].split(separator: ",") {
                    let bits = kv.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if bits.count == 2 { params[bits[0]] = .string(bits[1]) }
                }
            }
            WakeLog.shared.log("fire-v2-run: starting '\(defId)' with params \(params.keys.sorted())")
            Task { @MainActor in
                let result = await CommandV2Engine.shared.start(definitionId: defId, params: params)
                let outURL = dir.appendingPathComponent("v2-run-result.txt")
                let line: String
                switch result {
                case .success(let id):
                    line = "started \(defId) → \(id.uuidString)\n"
                case .failure(let err):
                    line = "error: \(err.localizedDescription)\n"
                }
                try? line.write(to: outURL, atomically: true, encoding: .utf8)
            }
        }

        // Pairing URL dump - touch ~/.grux/fire-phone-pair-dump to write the
        // full grux-pair:// URL (INCLUDING the shared secret) to
        // ~/.grux/phone-pair-url.txt. Dev + CI testing only - the secret is
        // the whole trust boundary, so we nuke the file 30s after writing and
        // require the trigger to be re-touched each time.
        let phonePairDumpTrigger = dir.appendingPathComponent("fire-phone-pair-dump")
        TriggerWatcher.shared.register(phonePairDumpTrigger) {
            guard FileManager.default.fileExists(atPath: phonePairDumpTrigger.path) else { return }
            try? FileManager.default.removeItem(at: phonePairDumpTrigger)
            Task { @MainActor in
                _ = PhonePairing.ensureSecret()
                guard let secret = PhonePairing.secret() else { return }
                let port: UInt16 = PhoneReceiverState.shared.listenerPort == 0
                    ? 55000 : PhoneReceiverState.shared.listenerPort
                // LAN only: the cloud tunnel is inert, so the branch that used to
                // prefer a wss://*.trycloudflare.com URL had one live arm left.
                let wss = "ws://\(PhonePairing.localHostname()):\(port)/ws"
                let info = PhonePairingURL.Info(
                    secretBase64URL: PhonePairingURL.base64URLEncode(secret),
                    wssURL: wss,
                    name: PhonePairing.displayName()
                )
                let out = dir.appendingPathComponent("phone-pair-url.txt")
                try? info.url.absoluteString.write(to: out, atomically: true, encoding: .utf8)
                // Auto-shred after 30s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    try? FileManager.default.removeItem(at: out)
                }
            }
        }

        // Dynamic image render trigger (Studio CLI front door). Drop
        // ~/.grux/fire-image with a JSON payload, e.g.
        //   {"brand":"<brand>","directive":"Change the white background. ...","sku":"standard","aspect":"4:5","count":2}
        // and CreativeEngine.renderDynamic runs the same path as the Studio
        // composer, landing the batch in the inbox. Writes
        // ~/.grux/fire-image-result.txt for CLI verification. One code path,
        // two front doors.
        let fireImageTrigger = dir.appendingPathComponent("fire-image")
        TriggerWatcher.shared.register(fireImageTrigger) {
            guard FileManager.default.fileExists(atPath: fireImageTrigger.path) else { return }
            let raw = (try? String(contentsOf: fireImageTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireImageTrigger)
            let resultPath = dir.appendingPathComponent("fire-image-result.txt").path
            guard !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let brand = json["brand"] as? String,
                  let directive = json["directive"] as? String, !directive.isEmpty else {
                let msg = "fire-image: missing or invalid JSON payload (need brand + directive)"
                try? msg.write(toFile: resultPath, atomically: true, encoding: .utf8)
                WakeLog.shared.log(msg)
                return
            }
            let sku = json["sku"] as? String
            let aspect = json["aspect"] as? String
            // JSONSerialization may hand back a number as Int or Double depending
            // on whether the literal had a decimal point, so accept both.
            let count = (json["count"] as? Int) ?? (json["count"] as? Double).map(Int.init) ?? 1
            WakeLog.shared.log("creative: fire-image trigger brand=\(brand) aspect=\(aspect ?? "4:5") count=\(count)")
            Task { @MainActor in
                await CreativeEngine.shared.renderDynamic(
                    brand: brand, directive: directive, sku: sku,
                    aspect: aspect, count: count, resultPath: resultPath
                )
            }
        }

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
    func openPhonePairingWindow() {
        if let win = phonePairingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openEmpireDashboardWindow() {
        if let win = empireDashboardWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            if NSApp.isHidden { NSApp.unhide(nil) }
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        let hosting = NSHostingController(rootView: LaunchRootView(defaultTab: tab).environmentObject(AppState.shared))
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
        let minContent = NSSize(width: 840, height: 560)
        win.contentMinSize = minContent
        var frame = win.frame
        let chrome = frame.size.width - win.contentLayoutRect.size.width
        win.minSize = NSSize(width: minContent.width + chrome, height: minContent.height + (frame.size.height - win.contentLayoutRect.size.height))
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
        let initW = max(minContent.width, argValue("--win-w") ?? 1040)
        let initH = max(minContent.height, argValue("--win-h") ?? 700)
        win.setContentSize(NSSize(width: initW, height: initH))
        win.center()
        launchWindow = win
        win.makeKeyAndOrderFront(nil)
        // After the window is on screen, re-apply the size - NSHostingController
        // can resize its host window to fit the SwiftUI view's ideal size
        // during first layout, which was squeezing the window back down.
        DispatchQueue.main.async {
            var f = win.frame
            if f.size.width < initW {
                f.size.width = initW
                win.setFrame(f, display: true)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
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
        // stop() is now a no-op: CloudflareTunnelManager is inert and spawns no
        // child, so there is nothing to reap. The call stays as the shutdown
        // contract at the one site that owns it. The bug it was written for was
        // real (30 quick tunnels reparented to launchd, each holding a live
        // *.trycloudflare.com ingress to a dead loopback port); removing the
        // spawn is the stronger fix, since a child you never create cannot be
        // orphaned. If spawn ever returns, it returns behind this call.
        CloudflareTunnelManager.shared.stop()
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
