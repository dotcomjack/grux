import SwiftUI

// Items 23 + 26: consolidated Appearance tab for Settings.
//
// Brings together everything visual that used to be scattered across tabs:
//   - WCAG-gated accent hue with live preview + contrast verdict (ThemeConfig)
//   - dark / light / auto appearance (dark stays the canonical default)
//   - glass intensity + reduce motion
//   - the existing orb / glow / stage toggles from GruxConfig
//
// Mount inside SettingsView's TabView:
//   appearanceTab.tabItem { Label("Appearance", systemImage: "paintpalette") }
// with `private var appearanceTab: some View { AppearanceSettingsView() }`.
// AppState arrives via the same .environmentObject(state) the window already
// injects.
struct AppearanceSettingsView: View {
    /// What the glow, the stage and the FOCUS card are. Pinned by
    /// `D179PaneLinesTests`: the stage tool goes to whichever model chat runs on.
    /// Under the hue slider. It said chip text "below WCAG AA" choices were
    /// refused while the pane kept a 4.2:1 chip hue with a
    /// below-AA warning (D179 item 13). The numbers come from the audit's own
    /// floors, so the kept band and the refused band cannot drift from the gate.
    static let hueCaption: String = {
        let checks = ThemeConfig.previewAudit(forHue: ThemeConfig.canonicalAccentHue).checks
        func ratio(_ v: Double) -> String { ThemeWCAGAuditResult.shown(v) + ":1" }
        let chip = checks.first { $0.name == ThemeConfig.chipTextPairName }
        let others = checks.filter { $0.name != ThemeConfig.chipTextPairName }
        let refused = ([chip.map { "chip text under \(ratio($0.required))" }].compactMap { $0 }
            + others.map { "\($0.name) under \(ratio($0.required))" })
        let list = refused.count > 1
            ? refused.dropLast().joined(separator: ", ") + " or " + refused.last!
            : refused.joined()
        var line = "Rotates the iridescent accent around the hue wheel."
        if let chip, chip.wcagAA > chip.required {
            line += " A hue whose chip text is under WCAG AA's \(ratio(chip.wcagAA)) but at least \(ratio(chip.required)) is kept, and the line above says it is below AA."
        }
        return line + " A hue with \(list) is refused, so the HUD never ships unreadable."
    }()
    static let brandCaption = "The window-edge glow and the cinematic stage together form Grux's brand identity. Each is independent. The stage is opt-in per response: the model your chat runs on decides when a moment deserves it. The FOCUS overlay is the top-right card that tracks your current focus task; turn it off to clear it from the desktop."

    @EnvironmentObject var state: AppState
    @ObservedObject private var theme = ThemeConfig.shared
    @ObservedObject private var focusState = FocusOverlayState.shared

    // Slider draft: previewed live, committed (and WCAG-gated) on release.
    @State private var draftHue: Double = ThemeConfig.canonicalAccentHue
    @State private var draftAudit: ThemeWCAGAuditResult = ThemeConfig.previewAudit(
        forHue: ThemeConfig.canonicalAccentHue
    )
    @State private var rejectedLastCommit: Bool = false

    var body: some View {
        ScrollView {
            Form {
                accentSection
                appearanceSection
                glassMotionSection
                orbOverlaysSection
            }
            .formStyle(.grouped)
            .settingsPaneBackground()
        }
        .onAppear {
            draftHue = theme.accentHue
            draftAudit = ThemeConfig.previewAudit(forHue: draftHue)
        }
    }

    // MARK: - Accent

    private var accentSection: some View {
        Section("Accent color") {
            HStack(spacing: 12) {
                previewChip
                VStack(alignment: .leading, spacing: 2) {
                    Text(ThemeConfig.hueLabel(draftHue))
                        .font(GruxTheme.Font.body)
                    contrastVerdict
                    if let note = ThemeConfig.chipTextNote(for: draftAudit, draftHue: draftHue) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // AA holds about 0.2 degrees wide around the named hue,
                        // so the note puts it one click away.
                        if let hue = ThemeConfig.nearestHueMeetingAA(to: draftHue) {
                            Button("Use hue \(hue)°") {
                                draftHue = Double(hue)
                                draftAudit = ThemeConfig.previewAudit(forHue: draftHue)
                                commitDraftHue()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                Spacer()
                Button("Reset") {
                    theme.resetAccent()
                    draftHue = theme.accentHue
                    draftAudit = ThemeConfig.previewAudit(forHue: draftHue)
                    rejectedLastCommit = false
                }
                .controlSize(.small)
                .disabled(abs(theme.accentHue - ThemeConfig.canonicalAccentHue) < 0.5 && !rejectedLastCommit)
            }
            // Whole degrees, so a dragged hue is exactly the one its label names.
            Slider(value: $draftHue, in: 0...360, step: 1, onEditingChanged: { editing in
                if !editing { commitDraftHue() }
            })
            .onChange(of: draftHue) { _, newValue in
                draftAudit = ThemeConfig.previewAudit(forHue: newValue)
            }
            if let warning = theme.accentWarning, rejectedLastCommit {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(GruxTheme.warnAmber)
            }
            Text(Self.hueCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commitDraftHue() {
        let audit = theme.requestAccentHue(draftHue)
        rejectedLastCommit = !audit.passes
        if audit.passes { draftAudit = audit }
    }

    // Live chip preview rendered from the CANDIDATE palette (draft hue), so
    // dragging shows the would-be accent before the gate decides.
    private var previewChip: some View {
        let candidate = ThemePalette.derived(accentHue: draftHue)
        return HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
            Text("PREVIEW")
                .font(GruxTheme.Font.microCaps)
                .kerning(1.2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            Capsule().fill(LinearGradient(
                colors: [
                    candidate.accentPrimaryLight.color,
                    candidate.accentPrimary.color,
                    candidate.accentCo.color.opacity(0.85)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
        .shadow(color: candidate.accentPrimary.color.opacity(0.45), radius: 6)
    }

    private var contrastVerdict: some View {
        return HStack(spacing: 4) {
            // Green only when every pair meets WCAG AA; amber when Grux takes the
            // accent but a pair is below AA (D94); rose when it is refused.
            Image(systemName: draftAudit.meetsAA ? "checkmark.seal.fill"
                  : draftAudit.passes ? "exclamationmark.triangle.fill" : "xmark.seal.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(draftAudit.meetsAA ? GruxTheme.successMint
                                 : draftAudit.passes ? GruxTheme.warnAmber : GruxTheme.destructiveRose)
            if let line = draftAudit.verdictLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Appearance mode

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Window appearance", selection: Binding(
                get: { theme.appearance },
                set: { theme.appearance = $0 }
            )) {
                ForEach(ThemeAppearance.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Dark is Grux's canonical look; the HUD vibrancy and palette are tuned for it. Auto follows the macOS setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Glass + motion

    private var glassMotionSection: some View {
        Section("Glass & motion") {
            HStack {
                Text("Glass intensity").frame(width: 110, alignment: .leading).font(.caption)
                Slider(value: Binding(
                    get: { theme.glassIntensity },
                    set: { theme.glassIntensity = $0 }
                ), in: 0...1)
                Text("\(Int(theme.glassIntensity * 100))%")
                    .font(GruxTheme.Font.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            Toggle("Reduce motion", isOn: Binding(
                get: { theme.reduceMotion },
                set: { theme.reduceMotion = $0 }
            ))
            Text("Glass intensity scales the frosted tint on every HUD card. Reduce motion asks animation-heavy surfaces (orb idle drift, stage blooms, glow pulses) to hold still.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Orb & overlays (existing GruxConfig toggles, consolidated)

    private var orbOverlaysSection: some View {
        Section("Orb & overlays") {
            // Shows what is true: the edges follow screen analysis verdicts,
            // so it is off while analysis is, the choice kept (D197).
            Toggle("Animate window edges red/green when I drift or re-focus", isOn: Binding(
                get: { DriftGlowToggleTruth.shown(choice: state.config.glowOverlayEnabled,
                                                  analysisOn: state.config.screenAnalysisEnabled,
                                                  granted: state.screenPermissionGranted) },
                set: { v in
                    state.config.glowOverlayEnabled = v
                    state.saveConfig()
                }
            ))
            .disabled(!DriftGlowToggleTruth.usable(analysisOn: state.config.screenAnalysisEnabled,
                                                   granted: state.screenPermissionGranted))
            if let line = DriftGlowToggleTruth.line(analysisOn: state.config.screenAnalysisEnabled,
                                                    granted: state.screenPermissionGranted) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Pulse window edges in cyan while Grux is speaking", isOn: Binding(
                get: { state.config.audioReactiveGlow },
                set: { v in
                    state.config.audioReactiveGlow = v
                    state.saveConfig()
                }
            ))
            Toggle("Let Grux bloom a cinematic “stage” on hero moments", isOn: Binding(
                get: { state.config.stageEnabled },
                set: { v in
                    state.config.stageEnabled = v
                    state.saveConfig()
                }
            ))
            Toggle("Show the floating FOCUS overlay card", isOn: Binding(
                get: { focusState.isVisible },
                set: { v in
                    focusState.isVisible = v
                    if v { FocusOverlayController.shared.show() }
                    else { FocusOverlayController.shared.hide() }
                }
            ))
            Text(Self.brandCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
