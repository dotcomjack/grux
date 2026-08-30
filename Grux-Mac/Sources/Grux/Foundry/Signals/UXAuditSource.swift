import Foundation
import AppKit
import ScreenCaptureKit

// UX-polish lane of the Sense pass: the engine screenshots its own tabs and
// critiques them against the GruxTheme design tokens. This is the lane the
// blueprint nominates as the v1-feel sweep ("twenty rough edges, found by the
// engine itself").
//
// Both halves are injected so tests never launch an app or hit the network:
//   - UXAppDriving: produces (tab, JPEG) pairs. The live driver relaunches
//     /Applications/Grux.app via `open` with --open-tab=<tab>, waits for the
//     window, captures it with ScreenCaptureKit, and writes each frame to a
//     temp dir for the audit trail.
//   - UXVisionCritiquing: turns one screenshot into critique text. The live
//     critic calls ClaudeClient.completeVision with the design-token rubric.
struct UXAuditSource: FoundrySignalSource {

    let sourceName = "ux-audit"

    var tabs: [String]
    var driver: UXAppDriving
    var critic: UXVisionCritiquing

    // Tabs the self-audit intentionally skips. Empty today: settings was
    // already in the audited set, and every other surface is worth a shot.
    // Kept as a seam so a noisy or non-visual tab can be pulled without
    // touching the derivation below.
    static let excludedTabs: Set<String> = []

    // The launch-window tabs worth auditing, derived from the sidebar IA so the
    // sweep covers every shipped surface (Media Studio, Design Studio, Projects,
    // Mailbox, ...) and can never drift from what the sidebar actually shows.
    // SidebarItem.key is the LaunchRootView.applyTab key verbatim.
    static let defaultTabs: [String] = SidebarIA.allItems
        .map(\.key)
        .filter { !excludedTabs.contains($0) }

    init(
        tabs: [String] = UXAuditSource.defaultTabs,
        driver: UXAppDriving,
        critic: UXVisionCritiquing
    ) {
        self.tabs = tabs
        self.driver = driver
        self.critic = critic
    }

    func harvest() async throws -> [FoundrySignal] {
        let shots = try await driver.screenshotTabs(tabs)
        var signals: [FoundrySignal] = []
        for shot in shots {
            // One bad critique call should not sink the rest of the sweep.
            guard let critique = try? await critic.critique(tab: shot.tab, imageJPEG: shot.jpeg) else { continue }
            signals += Self.signals(fromCritique: critique, tab: shot.tab)
        }
        return signals
    }

    // The critic is asked to answer in strict pipe-delimited lines:
    //   SEVERITY | summary | evidence
    // where SEVERITY is one of HIGH / MEDIUM / LOW / INFO. Anything else is
    // ignored, so a chatty model degrades to fewer signals, never to garbage.
    // Exposed for tests.
    static func signals(fromCritique critique: String, tab: String) -> [FoundrySignal] {
        var out: [FoundrySignal] = []
        for lineSub in critique.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = lineSub.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3,
                  let severity = severity(from: parts[0]),
                  !parts[1].isEmpty
            else { continue }
            out.append(FoundrySignal(
                source: "ux-audit",
                severity: severity,
                summary: "[\(tab)] \(parts[1])",
                evidence: parts[2],
                suggestedLane: .uxPolish,
                suggestedDomain: "ui:\(tab)"
            ))
        }
        return out
    }

    static func severity(from token: String) -> FoundrySignal.Severity? {
        switch token.uppercased() {
        case "HIGH": return .high
        case "MEDIUM", "MED": return .medium
        case "LOW": return .low
        case "INFO": return .info
        default: return nil
        }
    }

    // The rubric every screenshot is judged against. Mirrors GruxTheme: deep
    // near-black base, iridescent-violet primary accent, cyan co-pilot accent,
    // amber reserved for reminders, rose for destructive only, mint for
    // success, tight control scale, consistent type hierarchy.
    static let critiqueSystemPrompt = """
    You are Grux's UX auditor. You are shown one screenshot of one tab of the \
    Grux macOS app. Critique it against the app's design tokens:
    - Base surface: deep near-black (#0A0A0C) with real macOS vibrancy.
    - Primary accent: iridescent violet (#7B61FF, light #C8B6FF). Cyan (#6EE0FF) only for co-pilot/coach highlights.
    - Amber is RESERVED for reminders/urgent nudges. Rose ONLY for destructive actions. Mint for success states.
    - Controls are tight, not chunky: small paddings, 13px-or-smaller control text, pill or 10px radii.
    - Clear type hierarchy: one primary text tone, muted secondary, faint tertiary. No raw default-blue buttons.
    - Empty states should explain themselves with one line and a CTA, never a blank pane.

    Report each concrete paper cut on its own line in EXACTLY this format:
    SEVERITY | one-line summary | evidence visible in the screenshot
    SEVERITY is HIGH, MEDIUM, LOW, or INFO. Maximum 6 lines. No prose before \
    or after the lines. If the tab honors the tokens, output nothing.
    """
}

// MARK: - Driver seam

struct UXTabScreenshot: Sendable {
    var tab: String
    var jpeg: Data
}

protocol UXAppDriving: Sendable {
    func screenshotTabs(_ tabs: [String]) async throws -> [UXTabScreenshot]
}

// Test/fixture driver: returns canned screenshots, captures nothing.
struct FixtureUXAppDriver: UXAppDriving {
    var shots: [UXTabScreenshot]
    func screenshotTabs(_ tabs: [String]) async throws -> [UXTabScreenshot] {
        shots.filter { tabs.contains($0.tab) }
    }
}

// Live driver: relaunches the installed app per tab with --open-tab=<tab>
// (the same hook verification scripts use), waits for the window, then
// captures the Grux window via ScreenCaptureKit. Frames are written to a
// temp dir so the cycle's audit trail can show before/after proof.
//
// Note on `open --args`: launch arguments only apply on a FRESH launch, so
// the driver targets the installed bundle at /Applications/Grux.app and is
// meant to run from a context where that copy is not already front (e.g. the
// nightly window, or a dev build auditing the installed build).
struct LiveGruxAppDriver: UXAppDriving {

    var appPath: String
    var appName: String
    var settleSeconds: Double
    var outputDir: URL

    init(
        appPath: String = "/Applications/Grux.app",
        appName: String = "Grux",
        settleSeconds: Double = 2.5,
        outputDir: URL? = nil
    ) {
        self.appPath = appPath
        self.appName = appName
        self.settleSeconds = settleSeconds
        self.outputDir = outputDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-ux-audit-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    }

    func screenshotTabs(_ tabs: [String]) async throws -> [UXTabScreenshot] {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var shots: [UXTabScreenshot] = []
        for tab in tabs {
            openApp(tab: tab)
            try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
            guard let image = try? await captureGruxWindow(),
                  let jpeg = await MainActor.run(body: {
                      ScreenCapturer.jpegData(from: image, maxDimension: 1600, quality: 0.7)
                  })
            else { continue }
            try? jpeg.write(to: outputDir.appendingPathComponent("\(tab).jpg"))
            shots.append(UXTabScreenshot(tab: tab, jpeg: jpeg))
        }
        return shots
    }

    private func openApp(tab: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", appPath, "--args", "--open-tab=\(tab)"]
        try? p.run()
        p.waitUntilExit()
    }

    private func captureGruxWindow() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { win in
            guard let app = win.owningApplication else { return false }
            return app.applicationName == appName
                && win.frame.width > 300 && win.frame.height > 300
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw NSError(domain: "Grux", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No \(appName) window on screen to audit"
            ])
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false
        config.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Critic seam

protocol UXVisionCritiquing: Sendable {
    func critique(tab: String, imageJPEG: Data) async throws -> String
}

// Test/fixture critic: canned critique text per tab.
struct FixtureUXVisionCritic: UXVisionCritiquing {
    var critiques: [String: String]
    func critique(tab: String, imageJPEG: Data) async throws -> String {
        critiques[tab] ?? ""
    }
}

// Live critic: one completeVision call per screenshot against the token
// rubric. apiKey is injected by the caller (read AppState.shared.anthropicKey
// on the MainActor at wiring time); never stored anywhere on disk.
struct ClaudeUXVisionCritic: UXVisionCritiquing {
    var apiKey: String
    var model: String = "claude-haiku-4-5-20251001"

    func critique(tab: String, imageJPEG: Data) async throws -> String {
        // PINNED TO ANTHROPIC, DELIBERATELY. This is a vision call, and
        // OpenAICompatBackend's completeVision degrades to an error on purpose
        // because most local models have no vision, so routing it would swap a
        // working audit for a guaranteed failure. The injected `apiKey` also
        // stays the credential: this type's whole contract is that the caller
        // reads AppState on the MainActor at wiring time and nothing here
        // touches disk or global state.
        //
        // This struct is NOT MainActor-isolated, so the registry read takes an
        // explicit hop. It happens once per screenshot, outside the caller's
        // loop over tabs, and it exists only to share the one ClaudeClient
        // instead of building a fresh URLSession per critique.
        // `pinnedModel` is a local copy on purpose: the hop closure is
        // @Sendable, so capturing `self.model` would drag the whole struct
        // across the boundary for one String.
        let pinnedModel = model
        let backend = await MainActor.run {
            ModelRegistry.shared.resolvedRouting(provider: "anthropic",
                                                 modelOverride: pinnedModel).backend
        }
        return try await backend.completeVision(
            apiKey: apiKey,
            model: model,
            system: UXAuditSource.critiqueSystemPrompt,
            userText: "Tab: \(tab). Audit this screenshot against the design tokens.",
            imageJPEG: imageJPEG,
            mediaType: "image/jpeg",
            maxTokens: 600,
            temperature: 0.1,
            spanName: "foundry.uxAudit",
            feature: "foundry"
        )
    }
}
