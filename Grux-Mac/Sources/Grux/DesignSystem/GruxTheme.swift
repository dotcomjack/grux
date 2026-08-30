import SwiftUI
import AppKit

// Centralized design tokens. Informed by the Omi / Limitless / Rewind
// competitive study - dark-first, iridescent-violet accent, real macOS
// vibrancy (NSVisualEffectView) not fake CSS-style translucency.
enum GruxTheme {

    // MARK: - Palette

    // Deep near-black HUD base. Not pure black so the .hudWindow blur
    // behind it still reads.
    static let base = Color(red: 0x0A/255, green: 0x0A/255, blue: 0x0C/255)

    // Iridescent violet gradient, used for primary accents, ON-state pills,
    // "focus" badges, progress. Matches Omi/Limitless's premium feel.
    // Items 23 + 26: routed through ThemeConfig so a WCAG-gated accent-hue
    // change repaints every call-site live. Defaults are the exact canonical
    // values these used to hard-code (#7B61FF / #C8B6FF / #6EE0FF).
    static var accentPrimary: Color { ThemeConfig.currentPalette.accentPrimary.color }
    static var accentPrimaryLight: Color { ThemeConfig.currentPalette.accentPrimaryLight.color }

    // Cyan co-pilot accent - used for coach/mentor-mode highlights.
    static var accentCo: Color { ThemeConfig.currentPalette.accentCo.color }

    // Glass tint multiplier (0...1, 1 = canonical frosted look) and the
    // decorative-motion opt-out. Animation-heavy surfaces (orb, stage, glow
    // overlays) should consult `reduceMotion` before running ambient motion.
    static var glassIntensity: Double { ThemeConfig.currentPalette.glassIntensity }
    /// True when decorative animation must not run.
    ///
    /// Two independent reasons, deliberately collapsed into the one flag every
    /// animation site already consults, so no call site had to change.
    ///
    /// 1. The user asked for reduced motion.
    /// 2. **Nobody is looking.** Thirteen `repeatForever` animations and several
    ///    `TimelineView`s at 30 to 40 fps kept committing Core Animation transactions
    ///    while Grux sat in the background. Measured on an idle laptop: the main thread was
    ///    busy 1959 samples of 7350, and 1041 of those were
    ///    `UC::DriverCore::continueProcessing` into `stepTransactionFlush`, which is the
    ///    display transaction flush. That was the app's largest remaining idle cost, and it
    ///    is spent drawing an orb that nobody can see.
    ///
    /// `MotionSuspension` bumps `ThemeConfig.revision` on change, and roots key on that, so
    /// `onAppear` re-runs and the animations restart the moment the app comes forward.
    static var reduceMotion: Bool {
        ThemeConfig.currentPalette.reduceMotion || MotionSuspension.suspended
    }

    // Warm amber - dedicated to URGENT / nudge surfaces so it stands out
    // without triggering alarm-red panic. Reserved exclusively for reminders.
    static let warnAmber = Color(red: 0xFF/255, green: 0xB8/255, blue: 0x6B/255)

    // Mint - success / captured / accepted confirmation.
    static let successMint = Color(red: 0x7C/255, green: 0xE3/255, blue: 0xA8/255)

    // Rose - used ONLY for destructive confirmation (dismiss / remove).
    static let destructiveRose = Color(red: 0xFF/255, green: 0x6B/255, blue: 0x9E/255)

    // Text
    static let textPrimary = Color(red: 0xF5/255, green: 0xF5/255, blue: 0xF7/255)
    static let textSecondary = Color(red: 0xA1/255, green: 0xA1/255, blue: 0xAA/255)
    static let textTertiary = Color(red: 0x71/255, green: 0x71/255, blue: 0x7A/255)

    // MARK: - Gradients

    // Signature iridescent gradient - used on primary buttons, orb core,
    // accent strokes. Feels Omi/Limitless, isn't a direct copy.
    static var iridescent: LinearGradient {
        LinearGradient(
            colors: [accentPrimaryLight, accentPrimary, accentCo.opacity(0.85)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static var iridescentRim: LinearGradient {
        LinearGradient(
            colors: [
                accentPrimaryLight.opacity(0.55),
                accentPrimary.opacity(0.30),
                accentCo.opacity(0.25),
                Color.white.opacity(0.08)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // Urgent gradient for time-based reminder toasts. Warmer skew.
    static var urgentGradient: LinearGradient {
        LinearGradient(
            colors: [warnAmber, accentPrimary],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: - Radii

    enum Radius {
        static let card: CGFloat = 16
        static let hud: CGFloat = 22      // matches macOS Control Center
        static let chip: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - Shadows

    static func violetGlow(strong: Bool = false) -> Color {
        accentPrimary.opacity(strong ? 0.55 : 0.30)
    }

    static func amberGlow(strong: Bool = false) -> Color {
        warnAmber.opacity(strong ? 0.55 : 0.30)
    }

    // MARK: - Typography helpers

    enum Font {
        static let display = SwiftUI.Font.system(size: 28, weight: .heavy, design: .default).width(.condensed)
        static let title = SwiftUI.Font.system(size: 17, weight: .bold, design: .default)
        static let body = SwiftUI.Font.system(size: 13, weight: .medium, design: .default)
        static let caption = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default)
        static let mono = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        static let microCaps = SwiftUI.Font.system(size: 9, weight: .heavy, design: .monospaced)
    }
}

// MARK: - Orb state to glow hue mapping (single source of truth)

// One static table mapping every GruxOrbState to its full visual identity:
// the orb's primary/secondary colors AND the glow-border hue a glow surface
// uses when it mirrors that state. GruxOrbState.primary/.secondary read
// from this table and GlowColorMode.speaking reads its baseHue from the
// .speaking entry, so the orb and the glow border can never disagree about
// what a state looks like.
//
// Color values are byte-identical to the literals GruxOrbState shipped
// with (and to GruxShellCore's OrbPalette, the platform-free mirror for
// the glasses companion). If a color changes here, update OrbPalette too.
struct OrbGlowEntry {
    let primary: Color    // orb halo + core lead color
    let secondary: Color  // orb gradient orbit color
    let glowHue: Double   // 0...1 hue for GlowEdgeView gradients
}

enum OrbGlowMap {
    // glowHue notes: speaking (0.53 cyan) is the only hue a glow surface
    // renders today (GlowColorMode.speaking). The rest are documented so
    // any future glow surface that mirrors an orb state picks the hue from
    // here instead of inventing one: idle/muted sit on the brand violet,
    // listening on mint, thinking on amber.
    static let table: [GruxOrbState: OrbGlowEntry] = [
        .idle: OrbGlowEntry(
            primary: .purple.opacity(0.55), secondary: .indigo, glowHue: 0.75),
        .listening: OrbGlowEntry(
            primary: .mint, secondary: .green, glowHue: 0.42),
        .thinking: OrbGlowEntry(
            primary: .yellow, secondary: .orange, glowHue: 0.13),
        .speaking: OrbGlowEntry(
            primary: .cyan, secondary: .blue, glowHue: 0.53),
        .muted: OrbGlowEntry(
            primary: .gray.opacity(0.45), secondary: .gray.opacity(0.3), glowHue: 0.75)
    ]

    static func entry(for state: GruxOrbState) -> OrbGlowEntry {
        // Table is exhaustive (enforced by OrbGlowMapTests); the fallback
        // only guards a future case added without a table row.
        table[state] ?? OrbGlowEntry(primary: .purple, secondary: .indigo, glowHue: 0.75)
    }
}

// MARK: - Shared SwiftUI building blocks

// Tone of a glass surface - affects accent rim + glow + badge colors.
// Top-level so callers can reference it without naming the generic wrapper.
enum GruxGlassTone { case normal, urgent, success }

// A single-pattern "glass card" view - frosted vibrancy + gradient rim +
// violet glow shadow. Use this for every proactive reminder / HUD surface
// so the aesthetic stays consistent.
struct GruxGlassCard<Content: View>: View {
    let tone: GruxGlassTone
    @ViewBuilder let content: () -> Content

    init(tone: GruxGlassTone = .normal, @ViewBuilder content: @escaping () -> Content) {
        self.tone = tone
        self.content = content
    }

    var body: some View {
        ZStack {
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.06 * GruxTheme.glassIntensity),
                        accentTint.opacity(0.045 * GruxTheme.glassIntensity),
                        Color.black.opacity(0.10 * GruxTheme.glassIntensity)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(rimGradient, lineWidth: 1)
        )
        .shadow(color: glowColor, radius: 28, x: 0, y: 14)
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 6)
    }

    private var accentTint: Color {
        switch tone {
        case .normal: return GruxTheme.accentPrimary
        case .urgent: return GruxTheme.warnAmber
        case .success: return GruxTheme.successMint
        }
    }

    private var glowColor: Color {
        switch tone {
        case .normal: return GruxTheme.violetGlow()
        case .urgent: return GruxTheme.amberGlow(strong: true)
        case .success: return GruxTheme.successMint.opacity(0.30)
        }
    }

    private var rimGradient: LinearGradient {
        switch tone {
        case .normal: return GruxTheme.iridescentRim
        case .urgent:
            return LinearGradient(
                colors: [GruxTheme.warnAmber.opacity(0.65), GruxTheme.accentPrimary.opacity(0.30), Color.white.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [GruxTheme.successMint.opacity(0.60), GruxTheme.accentPrimary.opacity(0.25), Color.white.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

// Standard action chip - used for Accept / Dismiss / Snooze on reminder cards.
struct GruxChip: View {
    enum Style { case primary, secondary, destructive, success }
    let title: String
    var systemImage: String? = nil
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = systemImage {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.2)
                    // A chip is a button, and a button label must never wrap.
                    // Without these two, SwiftUI treats the Text as compressible
                    // when a toolbar runs out of room and breaks it MID-WORD:
                    // the Mailbox toolbar at the 840pt window floor rendered
                    // "Compose" as "Compos / e" and "Accounts" as "Account / s".
                    // lineLimit ONLY, and the absence of fixedSize is the whole
                    // lesson. fixedSize does keep the label whole, but it makes
                    // every chip rigid, which raises the toolbar's minimum past
                    // what the detail pane can hand it. The HStack then
                    // over-commits, the fixed nav rail is handed less than its
                    // 240 while still DRAWING 240, and SwiftUI centres an
                    // oversized child: measured on Mailbox at the 840pt floor,
                    // the rail bled off both edges and the sidebar rendered
                    // "MMAND" and "aused". Trading a truncated button label for
                    // a mangled global sidebar is a bad trade.
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(background)
            .overlay(
                Capsule().stroke(borderColor, lineWidth: 0.8)
            )
            .shadow(color: shadowColor, radius: 6)
        }
        .buttonStyle(.plain)
        // App-wide hover: every action chip (Accept / Dismiss / Snooze, Edit /
        // Delete, etc.) now lifts and shows a pointer so it reads as clickable.
        .gruxHoverable(cornerRadius: 999, lift: 1.05, rimOnHover: 0, fillOnHover: 0)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return GruxTheme.textSecondary
        case .destructive: return .white
        case .success: return .white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule().fill(GruxTheme.iridescent)
        case .secondary:
            Capsule().fill(Color.white.opacity(0.06))
        case .destructive:
            Capsule().fill(GruxTheme.destructiveRose)
        case .success:
            Capsule().fill(GruxTheme.successMint)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return Color.white.opacity(0.25)
        case .secondary: return Color.white.opacity(0.10)
        case .destructive: return Color.white.opacity(0.30)
        case .success: return Color.white.opacity(0.30)
        }
    }

    private var shadowColor: Color {
        switch style {
        case .primary: return GruxTheme.violetGlow(strong: true)
        case .secondary: return .clear
        case .destructive: return GruxTheme.destructiveRose.opacity(0.45)
        case .success: return GruxTheme.successMint.opacity(0.45)
        }
    }
}
