import SwiftUI
import AppKit
import GruxShellCore

// Items 23 + 26: runtime theming engine.
//
// ThemeConfig is the single mutable source of truth for appearance:
//   - accentHue: rotates the iridescent accent trio (primary / light / cyan co)
//     around the hue wheel while preserving each token's saturation + brightness,
//     so the signature gradient relationship survives any accent choice.
//   - appearance: dark (canonical default) / light / auto, applied via
//     NSApp.appearance.
//   - glassIntensity: scales the frosted-tint opacities inside GruxGlassCard.
//   - reduceMotion: opt-out flag that animation-heavy surfaces (orb, stage,
//     glow overlays) consult before running decorative animation.
//
// Every accent change is gated by a WCAG 2.1 audit (via GruxShellCore's
// WCAGContrastChecker): a candidate accent that drops chip text or
// accent-on-base contrast below AA thresholds is refused and surfaced as an
// inline warning instead of silently shipping an unreadable palette.
//
// GruxTheme's palette statics read ThemeConfig.currentPalette (a lock-guarded
// snapshot, safe from any thread), so existing call-sites keep their exact
// signatures and repaint live when the root view is keyed on `revision`.

// MARK: - RGB + HSB math (pure, deterministic, testable)

struct ThemeRGB: Codable, Equatable, Sendable {
    var r: Double  // 0...1
    var g: Double  // 0...1
    var b: Double  // 0...1

    init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var wcag: WCAGColor { WCAGColor(r: r, g: g, b: b) }

    // Hue in degrees 0..<360, saturation + brightness 0...1.
    var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let delta = mx - mn
        var h: Double = 0
        if delta > 0 {
            if mx == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { h = 60 * (((b - r) / delta) + 2) }
            else { h = 60 * (((r - g) / delta) + 4) }
        }
        if h < 0 { h += 360 }
        let s = mx == 0 ? 0 : delta / mx
        return (h, s, mx)
    }

    static func from(h: Double, s: Double, b: Double) -> ThemeRGB {
        var hue = h.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let c = b * s
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (rp, gp, bp): (Double, Double, Double)
        switch hue {
        case ..<60:   (rp, gp, bp) = (c, x, 0)
        case ..<120:  (rp, gp, bp) = (x, c, 0)
        case ..<180:  (rp, gp, bp) = (0, c, x)
        case ..<240:  (rp, gp, bp) = (0, x, c)
        case ..<300:  (rp, gp, bp) = (x, 0, c)
        default:      (rp, gp, bp) = (c, 0, x)
        }
        return ThemeRGB(r: rp + m, g: gp + m, b: bp + m)
    }

    // Rotate this color's hue by `delta` degrees, preserving S + B.
    func rotatingHue(by delta: Double) -> ThemeRGB {
        let (h, s, b) = hsb
        return ThemeRGB.from(h: h + delta, s: s, b: b)
    }
}

// MARK: - Appearance mode

enum ThemeAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark   // canonical default
    case light
    case auto   // follow macOS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .auto: return "Auto"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .auto: return nil  // nil = inherit the system setting
        }
    }
}

// MARK: - WCAG audit

struct ThemeWCAGCheck: Equatable, Sendable {
    let name: String
    let ratio: Double      // measured contrast ratio (1...21)
    let required: Double   // AA threshold for this pair
    var passes: Bool { ratio >= required }
}

struct ThemeWCAGAuditResult: Equatable, Sendable {
    let checks: [ThemeWCAGCheck]
    var passes: Bool { checks.allSatisfy { $0.passes } }
    var worst: ThemeWCAGCheck? { checks.min { ($0.ratio / $0.required) < ($1.ratio / $1.required) } }

    var failureSummary: String? {
        guard !passes else { return nil }
        let failing = checks.filter { !$0.passes }
            .map { String(format: "%@ (%.1f:1, needs %.1f:1)", $0.name, $0.ratio, $0.required) }
        return "Low contrast: " + failing.joined(separator: ", ")
    }
}

// The accent-derived palette a candidate hue produces. Audited before commit.
struct ThemePalette: Equatable, Sendable {
    var accentPrimary: ThemeRGB
    var accentPrimaryLight: ThemeRGB
    var accentCo: ThemeRGB

    static func derived(accentHue: Double) -> ThemePalette {
        let delta = accentHue - ThemeConfig.canonicalAccentHue
        return ThemePalette(
            accentPrimary: ThemeConfig.canonicalAccentPrimary.rotatingHue(by: delta),
            accentPrimaryLight: ThemeConfig.canonicalAccentPrimaryLight.rotatingHue(by: delta),
            accentCo: ThemeConfig.canonicalAccentCo.rotatingHue(by: delta)
        )
    }
}

// MARK: - Thread-safe palette snapshot (read by GruxTheme from any thread)

struct GruxPaletteSnapshot: Sendable {
    var accentPrimary: ThemeRGB
    var accentPrimaryLight: ThemeRGB
    var accentCo: ThemeRGB
    var glassIntensity: Double
    var reduceMotion: Bool

    static let canonical = GruxPaletteSnapshot(
        accentPrimary: ThemeConfig.canonicalAccentPrimary,
        accentPrimaryLight: ThemeConfig.canonicalAccentPrimaryLight,
        accentCo: ThemeConfig.canonicalAccentCo,
        glassIntensity: 1.0,
        reduceMotion: false
    )
}

// Minimal lock box so GruxTheme's computed statics can read the live palette
// from any thread without hopping to the main actor.
private final class PaletteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: GruxPaletteSnapshot = .canonical

    var value: GruxPaletteSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func set(_ new: GruxPaletteSnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshot = new
    }
}

// MARK: - Persisted settings (JSON on disk, same posture as config.json)

struct ThemeSettings: Codable, Equatable {
    var accentHue: Double
    var appearance: ThemeAppearance
    var glassIntensity: Double  // 0...1, 1 = canonical frosted tint
    var reduceMotion: Bool

    static let `default` = ThemeSettings(
        accentHue: ThemeConfig.canonicalAccentHue,
        appearance: .dark,
        glassIntensity: 1.0,
        reduceMotion: false
    )
}

// MARK: - ThemeConfig

@MainActor
final class ThemeConfig: ObservableObject {

    // Canonical palette: exactly the values GruxTheme shipped with, so the
    // default render is byte-identical to the pre-theming app.
    static let canonicalAccentPrimary = ThemeRGB(hex: 0x7B61FF)
    static let canonicalAccentPrimaryLight = ThemeRGB(hex: 0xC8B6FF)
    static let canonicalAccentCo = ThemeRGB(hex: 0x6EE0FF)
    static let canonicalBase = ThemeRGB(hex: 0x0A0A0C)
    static let canonicalTextPrimary = ThemeRGB(hex: 0xF5F5F7)
    static let canonicalAccentHue: Double = canonicalAccentPrimary.hsb.h

    static let shared = ThemeConfig(
        fileURL: Persistence.supportDir.appendingPathComponent("theme.json"),
        isPrimary: true
    )

    // Live palette for GruxTheme call-sites. Safe from any thread.
    private static let paletteBox = PaletteBox()
    nonisolated static var currentPalette: GruxPaletteSnapshot { paletteBox.value }

    // MARK: Published state

    @Published private(set) var accentHue: Double
    @Published var appearance: ThemeAppearance {
        didSet { guard appearance != oldValue else { return }; settingsChanged() }
    }
    @Published var glassIntensity: Double {
        didSet { guard glassIntensity != oldValue else { return }; settingsChanged() }
    }
    @Published var reduceMotion: Bool {
        didSet { guard reduceMotion != oldValue else { return }; settingsChanged() }
    }
    // Inline warning shown when a requested accent fails the WCAG gate.
    @Published private(set) var accentWarning: String?
    // Bumped on every committed visual change. Key the app's root view on
    // this (`.id(theme.revision)`) so a theme change repaints everything.
    @Published private(set) var revision: Int = 0

    /// Re-key every theme-hosted root so `onAppear` re-runs and animation sites re-read
    /// `GruxTheme.reduceMotion`. Used by `MotionSuspension` when the app goes background or
    /// comes forward. Same mechanism the reduce-motion toggle already relies on.
    func bumpRevisionForMotion() { revision &+= 1 }

    private let fileURL: URL
    // Only the primary (shared) instance pushes to the global palette box and
    // touches NSApp.appearance: test instances stay fully sandboxed.
    private let isPrimary: Bool

    init(fileURL: URL, isPrimary: Bool = false) {
        self.fileURL = fileURL
        self.isPrimary = isPrimary
        let loaded = Persistence.load(ThemeSettings.self, from: fileURL, fallback: .default)
        // Re-gate the persisted hue: if a hand-edited theme.json carries a
        // failing accent, fall back to canonical rather than render it.
        let candidate = ThemePalette.derived(accentHue: loaded.accentHue)
        let safeHue = ThemeConfig.runWCAGAudit(palette: candidate).passes
            ? loaded.accentHue
            : ThemeConfig.canonicalAccentHue
        self.accentHue = safeHue
        self.appearance = loaded.appearance
        self.glassIntensity = min(1, max(0, loaded.glassIntensity))
        self.reduceMotion = loaded.reduceMotion
        publish()
        if isPrimary { applyAppearance() }
    }

    // MARK: Accent (WCAG-gated)

    // Audit a candidate hue WITHOUT committing: drives the live verdict
    // label while the slider is dragging.
    nonisolated static func previewAudit(forHue hue: Double) -> ThemeWCAGAuditResult {
        runWCAGAudit(palette: .derived(accentHue: hue))
    }

    // Request an accent change. Commits + persists only when the derived
    // palette clears the WCAG gate; otherwise records an inline warning and
    // leaves the current accent untouched.
    @discardableResult
    func requestAccentHue(_ hue: Double) -> ThemeWCAGAuditResult {
        let candidate = ThemePalette.derived(accentHue: hue)
        let audit = ThemeConfig.runWCAGAudit(palette: candidate)
        if audit.passes {
            accentWarning = nil
            accentHue = hue
            settingsChanged()
        } else {
            accentWarning = audit.failureSummary
        }
        return audit
    }

    func resetAccent() {
        accentWarning = nil
        accentHue = ThemeConfig.canonicalAccentHue
        settingsChanged()
    }

    func clearAccentWarning() { accentWarning = nil }

    var palette: ThemePalette { .derived(accentHue: accentHue) }

    // MARK: WCAG audit

    // AA thresholds per WCAG 2.1: 3:1 for large text / UI components
    // (the bold micro-caps chips and accent rims), 4.5:1 for normal text.
    // All pairs are checked against the canonical surfaces, which stay fixed.
    nonisolated static func runWCAGAudit(palette: ThemePalette) -> ThemeWCAGAuditResult {
        let base = canonicalBase.wcag
        let white = WCAGColor.white
        let checks = [
            ThemeWCAGCheck(
                name: "chip text on accent",
                ratio: WCAGContrastChecker.contrastRatio(white, palette.accentPrimary.wcag),
                required: 3.0
            ),
            ThemeWCAGCheck(
                name: "accent on HUD base",
                ratio: WCAGContrastChecker.contrastRatio(palette.accentPrimary.wcag, base),
                required: 3.0
            ),
            ThemeWCAGCheck(
                name: "light accent text on HUD base",
                ratio: WCAGContrastChecker.contrastRatio(palette.accentPrimaryLight.wcag, base),
                required: 4.5
            ),
            ThemeWCAGCheck(
                name: "co-pilot accent on HUD base",
                ratio: WCAGContrastChecker.contrastRatio(palette.accentCo.wcag, base),
                required: 3.0
            )
        ]
        return ThemeWCAGAuditResult(checks: checks)
    }

    // MARK: Appearance

    func applyAppearance() {
        guard isPrimary, let app = NSApp else { return }
        app.appearance = appearance.nsAppearance
    }

    // MARK: Persistence + propagation

    private var settings: ThemeSettings {
        ThemeSettings(
            accentHue: accentHue,
            appearance: appearance,
            glassIntensity: glassIntensity,
            reduceMotion: reduceMotion
        )
    }

    private func settingsChanged() {
        publish()
        if isPrimary { applyAppearance() }
        Persistence.save(settings, to: fileURL)
        revision &+= 1
    }

    private func publish() {
        guard isPrimary else { return }
        let p = palette
        ThemeConfig.paletteBox.set(GruxPaletteSnapshot(
            accentPrimary: p.accentPrimary,
            accentPrimaryLight: p.accentPrimaryLight,
            accentCo: p.accentCo,
            glassIntensity: glassIntensity,
            reduceMotion: reduceMotion
        ))
    }
}

// MARK: - Motion tokens (shell-wide animation timing)

// Single source of truth for animation timing across the shell. Surfaces
// (orb, glow overlay, Stage, ambient HUD) reference these instead of inline
// duration literals so motion stays consistent and tunable in one place.
//
// Duration scale:
//   fast (120ms)    micro interactions: chevron spins, hover state swaps
//   base (160ms)    standard control transitions: color swaps, toggles
//   slow (300ms)    surface-level fades: orb state crossfade, Stage in/out
//   ambient (2.5s)  dwell for decorative overlays: glow border hold time
//
// reduceMotion: decorative animation must consult GruxTheme.reduceMotion
// (already wired into the orb, glow, and Stage). The `gated(_:)` helper
// returns nil under reduce-motion so `.animation(...)` paths collapse to
// an instant swap without per-call-site ternaries.
enum MotionTokens {

    // MARK: Durations (seconds)

    static let fast: Double = 0.12
    static let base: Double = 0.16
    static let slow: Double = 0.30
    static let ambient: Double = 2.5

    // MARK: Looping decorative periods (seconds)

    // repeatForever / repeatCount cycle lengths, not one-shot transitions.
    // They freeze entirely under reduceMotion (each surface guards its own
    // startAnimating path).
    static let orbRotationPeriod: Double = 8.0   // angular gradient spin
    static let orbPulsePeriod: Double = 1.4      // listening/speaking rings
    static let glowWobblePeriod: Double = 1.5    // glow hue wobble cycle
    // Glow fade-out is intentionally longer than `slow`: the border should
    // linger as it releases, not snap off like a control transition.
    static let glowFadeOut: Double = 0.5

    // MARK: Curve presets

    static var easeOutFast: Animation { .easeOut(duration: fast) }
    static var easeOutBase: Animation { .easeOut(duration: base) }
    static var easeOutSlow: Animation { .easeOut(duration: slow) }
    // Symmetric crossfade for state-driven color/shape swaps (orb states).
    static var crossfade: Animation { .easeInOut(duration: slow) }
    // Standard spring for pop-in affordances.
    static var spring: Animation { .spring(response: 0.35, dampingFraction: 0.8) }

    // reduceMotion gate for decorative animation: returns nil (no animation)
    // when the user opted out. Reads the lock-guarded palette snapshot, so
    // it is safe from any thread and matches GruxTheme.reduceMotion exactly.
    static func gated(_ animation: Animation) -> Animation? {
        ThemeConfig.currentPalette.reduceMotion ? nil : animation
    }
}

// MARK: - Theme revision keying for NSHostingController roots

// Hosted-window counterpart of LaunchRootView's `.id(theme.revision)`.
// Roots built once via NSHostingController (AmbientHUD, Orb Anywhere) never
// re-key on theme commits, so surfaces that read GruxTheme statics only at
// onAppear (the orb's repeatForever phase/pulse animations, reduceMotion)
// kept their stale settings until the next state change. Wrapping the hosted
// root observes ThemeConfig and re-keys the subtree on every committed
// change, so onAppear re-runs with the fresh snapshot.
struct ThemeRevisionHost<Content: View>: View {
    @ObservedObject private var theme = ThemeConfig.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().id(theme.revision)
    }
}
