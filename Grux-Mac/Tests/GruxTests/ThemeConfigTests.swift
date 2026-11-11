import XCTest
@testable import Grux

// Items 23 + 26: ThemeConfig WCAG gate + persistence round-trip. Every test
// owns a throwaway instance against a temp file (isPrimary: false) so it
// never touches the real ~/Library/Application Support/Grux/theme.json,
// never pushes to the global palette snapshot, and never flips
// NSApp.appearance.
@MainActor
final class ThemeConfigTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-theme-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsMatchCanonicalPalette() {
        let theme = ThemeConfig(fileURL: tempURL)
        XCTAssertEqual(theme.accentHue, ThemeConfig.canonicalAccentHue, accuracy: 0.001)
        XCTAssertEqual(theme.appearance, .dark, "dark stays the canonical default")
        XCTAssertEqual(theme.glassIntensity, 1.0, accuracy: 0.001)
        XCTAssertFalse(theme.reduceMotion)
        XCTAssertNil(theme.accentWarning)
        // The derived palette round-trips through HSB, so compare per
        // channel with tolerance rather than exact Double equality.
        XCTAssertEqual(theme.palette.accentPrimary.r, ThemeConfig.canonicalAccentPrimary.r, accuracy: 0.001)
        XCTAssertEqual(theme.palette.accentPrimary.g, ThemeConfig.canonicalAccentPrimary.g, accuracy: 0.001)
        XCTAssertEqual(theme.palette.accentPrimary.b, ThemeConfig.canonicalAccentPrimary.b, accuracy: 0.001)
    }

    func testCanonicalPalettePassesItsOwnGate() {
        let audit = ThemeConfig.runWCAGAudit(palette: .derived(accentHue: ThemeConfig.canonicalAccentHue))
        XCTAssertTrue(audit.passes, "shipping defaults must clear the WCAG gate: \(audit.failureSummary ?? "")")
        XCTAssertNil(audit.failureSummary)
    }

    // MARK: - WCAG gate

    func testGateRefusesLowContrastAccent() {
        let theme = ThemeConfig(fileURL: tempURL)
        let before = theme.accentHue
        // Hue 120 (green at the canonical S/B) is far too bright for white
        // chip text: the gate must refuse it.
        let audit = theme.requestAccentHue(120)
        XCTAssertFalse(audit.passes)
        XCTAssertEqual(theme.accentHue, before, accuracy: 0.001, "refused hue must not commit")
        XCTAssertNotNil(theme.accentWarning, "refusal surfaces an inline warning")
        XCTAssertNotNil(audit.failureSummary)
    }

    func testGateAcceptsPassingAccent() {
        let theme = ThemeConfig(fileURL: tempURL)
        // Hue 280 (violet-magenta) keeps white-on-accent and accent-on-base
        // above AA at the canonical saturation/brightness.
        let audit = theme.requestAccentHue(280)
        XCTAssertTrue(audit.passes, audit.failureSummary ?? "")
        XCTAssertEqual(theme.accentHue, 280, accuracy: 0.001)
        XCTAssertNil(theme.accentWarning)
    }

    func testPreviewAuditMatchesGateDecision() {
        XCTAssertFalse(ThemeConfig.previewAudit(forHue: 120).passes)
        XCTAssertTrue(ThemeConfig.previewAudit(forHue: 280).passes)
    }

    func testResetAccentRestoresCanonicalAndClearsWarning() {
        let theme = ThemeConfig(fileURL: tempURL)
        theme.requestAccentHue(120)  // refused, sets warning
        theme.requestAccentHue(280)  // accepted
        theme.requestAccentHue(60)   // yellow, refused, sets warning again
        theme.resetAccent()
        XCTAssertEqual(theme.accentHue, ThemeConfig.canonicalAccentHue, accuracy: 0.001)
        XCTAssertNil(theme.accentWarning)
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTrip() {
        let first = ThemeConfig(fileURL: tempURL)
        first.requestAccentHue(280)
        first.appearance = .auto
        first.glassIntensity = 0.4
        first.reduceMotion = true

        let second = ThemeConfig(fileURL: tempURL)
        XCTAssertEqual(second.accentHue, 280, accuracy: 0.001)
        XCTAssertEqual(second.appearance, .auto)
        XCTAssertEqual(second.glassIntensity, 0.4, accuracy: 0.001)
        XCTAssertTrue(second.reduceMotion)
    }

    func testRefusedHueIsNeverPersisted() {
        let first = ThemeConfig(fileURL: tempURL)
        first.requestAccentHue(280)  // accepted + persisted
        first.requestAccentHue(120)  // refused, must not persist

        let second = ThemeConfig(fileURL: tempURL)
        XCTAssertEqual(second.accentHue, 280, accuracy: 0.001)
    }

    func testHandEditedFailingHueFallsBackToCanonicalOnLoad() throws {
        // Simulate a hand-edited theme.json carrying a failing accent.
        let bad = ThemeSettings(accentHue: 120, appearance: .dark, glassIntensity: 1.0, reduceMotion: false)
        let enc = JSONEncoder()
        try enc.encode(bad).write(to: tempURL, options: .atomic)

        let theme = ThemeConfig(fileURL: tempURL)
        XCTAssertEqual(theme.accentHue, ThemeConfig.canonicalAccentHue, accuracy: 0.001,
                       "a persisted failing accent must not render; fall back to canonical")
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("not json".utf8).write(to: tempURL, options: .atomic)
        let theme = ThemeConfig(fileURL: tempURL)
        XCTAssertEqual(theme.accentHue, ThemeConfig.canonicalAccentHue, accuracy: 0.001)
        XCTAssertEqual(theme.appearance, .dark)
    }

    // MARK: - Hue math

    func testHueRotationRoundTripsThroughHSB() {
        let original = ThemeConfig.canonicalAccentPrimary
        let rotated = original.rotatingHue(by: 0)
        XCTAssertEqual(rotated.r, original.r, accuracy: 0.005)
        XCTAssertEqual(rotated.g, original.g, accuracy: 0.005)
        XCTAssertEqual(rotated.b, original.b, accuracy: 0.005)
    }

    func testHueRotationPreservesSaturationAndBrightness() {
        let original = ThemeConfig.canonicalAccentPrimary.hsb
        let rotated = ThemeConfig.canonicalAccentPrimary.rotatingHue(by: 90).hsb
        XCTAssertEqual(rotated.s, original.s, accuracy: 0.01)
        XCTAssertEqual(rotated.b, original.b, accuracy: 0.01)
        XCTAssertEqual(rotated.h, (original.h + 90).truncatingRemainder(dividingBy: 360), accuracy: 0.5)
    }

    func testDerivedPaletteAtCanonicalHueIsIdentity() {
        let p = ThemePalette.derived(accentHue: ThemeConfig.canonicalAccentHue)
        XCTAssertEqual(p.accentPrimary.r, ThemeConfig.canonicalAccentPrimary.r, accuracy: 0.005)
        XCTAssertEqual(p.accentPrimaryLight.g, ThemeConfig.canonicalAccentPrimaryLight.g, accuracy: 0.005)
        XCTAssertEqual(p.accentCo.b, ThemeConfig.canonicalAccentCo.b, accuracy: 0.005)
    }

    // MARK: - D62, D94: the verdict line claims WCAG AA only where AA's own bar is met

    /// (name, ratio, Grux's floor) with AA's bar equal to the floor.
    private func audit(_ pairs: (String, Double, Double)...) -> ThemeWCAGAuditResult {
        ThemeWCAGAuditResult(checks: pairs.map { ThemeWCAGCheck(name: $0.0, ratio: $0.1, required: $0.2) })
    }

    /// The small chip text: Grux refuses an accent under 3:1, AA asks 4.5:1.
    private func chip(_ ratio: Double) -> ThemeWCAGCheck {
        ThemeWCAGCheck(name: "chip text on accent", ratio: ratio, required: 3.0, wcagAA: 4.5)
    }

    /// Sense pass 8 read "Passes WCAG AA. Closest pair: chip text on accent, 4.2:1
    /// (needs 3.0:1)": the chip label is 9 pt, and AA holds text under 14 pt bold
    /// to 4.5:1, so the pass was false (D94). The line names AA's bar.
    func testSmallChipTextUnderAAIsNotCalledAPass() {
        let result = ThemeWCAGAuditResult(checks: [
            chip(4.21),
            ThemeWCAGCheck(name: "light accent text on HUD base", ratio: 9.0, required: 4.5)
        ])
        XCTAssertTrue(result.passes, "Grux's floor still takes this accent")
        XCTAssertEqual(result.verdictLine,
                       "Below WCAG AA: chip text on accent, 4.2:1 (needs 4.5:1). Every other pair passes.")
    }

    /// On, one under and one over each bar: a number is never shown at or above
    /// its bar for a pair that falls short, nor below it for one that meets it.
    func testTheShownRatioNeverCrossesItsBar() {
        // AA's bar for the chip text, with Grux's floor met.
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(4.5)]).verdictLine,
                       "Passes WCAG AA. Closest pair: chip text on accent, 4.5:1 (needs 4.5:1).")
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(4.4999999)]).verdictLine,
                       "Below WCAG AA: chip text on accent, 4.4:1 (needs 4.5:1).")
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(4.51)]).verdictLine,
                       "Passes WCAG AA. Closest pair: chip text on accent, 4.5:1 (needs 4.5:1).")
        // Grux's floor for the chip text: under it the accent is refused.
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(3.0)]).verdictLine,
                       "Below WCAG AA: chip text on accent, 3.0:1 (needs 4.5:1).")
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(2.99)]).verdictLine,
                       "Too low to use: chip text on accent at 2.9:1 (needs 3.0:1).")
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [chip(3.01)]).verdictLine,
                       "Below WCAG AA: chip text on accent, 3.0:1 (needs 4.5:1).")
        // A pair whose floor is AA's bar.
        XCTAssertEqual(audit(("light accent text on HUD base", 4.5, 4.5)).verdictLine,
                       "Passes WCAG AA. Closest pair: light accent text on HUD base, 4.5:1 (needs 4.5:1).")
        XCTAssertEqual(audit(("light accent text on HUD base", 4.46, 4.5)).verdictLine,
                       "Too low to use: light accent text on HUD base at 4.4:1 (needs 4.5:1).")
        XCTAssertEqual(audit(("light accent text on HUD base", 4.4999999, 4.5)).verdictLine,
                       "Too low to use: light accent text on HUD base at 4.4:1 (needs 4.5:1).")
        XCTAssertNil(audit().verdictLine)
        // The refusal warning reads the same numbers the same way.
        XCTAssertEqual(ThemeWCAGAuditResult(checks: [
            chip(2.99), ThemeWCAGCheck(name: "light accent text on HUD base", ratio: 4.46, required: 4.5)
        ]).failureSummary,
                       "Low contrast: chip text on accent (2.9:1, needs 3.0:1), light accent text on HUD base (4.4:1, needs 4.5:1)")
    }

    /// Two pairs under AA are both named, the lower first, and "every other pair"
    /// is said only when another pair exists.
    func testEveryPairUnderAAIsNamed() {
        let two = ThemeWCAGAuditResult(checks: [
            ThemeWCAGCheck(name: "accent on HUD base", ratio: 5.0, required: 3.0),
            chip(4.3),
            ThemeWCAGCheck(name: "badge text", ratio: 3.6, required: 3.0, wcagAA: 4.5)
        ])
        XCTAssertEqual(two.verdictLine,
                       "Below WCAG AA: badge text, 3.6:1 (needs 4.5:1); chip text on accent, 4.3:1 (needs 4.5:1). Every other pair passes.")
        let onlyThem = ThemeWCAGAuditResult(checks: [chip(4.3), ThemeWCAGCheck(name: "badge text", ratio: 3.6, required: 3.0, wcagAA: 4.5)])
        XCTAssertEqual(onlyThem.verdictLine,
                       "Below WCAG AA: badge text, 3.6:1 (needs 4.5:1); chip text on accent, 4.3:1 (needs 4.5:1).")
    }

    /// The shipped audit holds the 9 pt chip label to AA's 4.5:1 for small text,
    /// and every other pair to the bar AA sets for it.
    func testTheShippedAuditHoldsEachPairToItsAABar() throws {
        let result = ThemeConfig.runWCAGAudit(palette: .derived(accentHue: ThemeConfig.canonicalAccentHue))
        let bars = Dictionary(uniqueKeysWithValues: result.checks.map { ($0.name, $0.wcagAA) })
        XCTAssertEqual(bars, ["chip text on accent": 4.5, "accent on HUD base": 3.0,
                              "light accent text on HUD base": 4.5, "co-pilot accent on HUD base": 3.0])
        XCTAssertTrue(result.passes)
        let line = try XCTUnwrap(result.verdictLine)
        XCTAssertFalse(line.hasPrefix("Passes WCAG AA"), line)
        XCTAssertTrue(line.hasPrefix("Below WCAG AA: chip text on accent, 4.2:1 (needs 4.5:1)."), line)
    }

    /// The caption under the slider says what the gate refuses: chip text under
    /// 3:1, not "below WCAG AA", which the gate does not hold chip text to.
    func testTheSliderCaptionNamesTheChipFloor() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/DesignSystem/AppearanceSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("drop chip text or accent-on-base contrast below WCAG AA"))
        // The caption is built from the audit's floors since D179 item 13, so
        // the pin reads the built line, not a literal in the source.
        XCTAssertTrue(src.contains("Text(Self.hueCaption)"))
        XCTAssertTrue(AppearanceSettingsView.hueCaption.contains("chip text under 3.0:1"), AppearanceSettingsView.hueCaption)
    }

    /// The seal beside the line: a green check beside "Below WCAG AA" still read
    /// as a pass on the installed build. Green only when every pair meets AA.
    func testTheSealIsGreenOnlyWhenEveryPairMeetsAA() throws {
        XCTAssertTrue(ThemeWCAGAuditResult(checks: [chip(4.5)]).meetsAA)
        XCTAssertFalse(ThemeWCAGAuditResult(checks: [chip(4.4999999)]).meetsAA)
        XCTAssertFalse(ThemeWCAGAuditResult(checks: [chip(2.99)]).meetsAA)
        XCTAssertFalse(ThemeWCAGAuditResult(checks: []).meetsAA)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/DesignSystem/AppearanceSettingsView.swift"), encoding: .utf8)
        let verdict = try XCTUnwrap(src.range(of: "private var contrastVerdict").map { String(src[$0.lowerBound...].prefix(900)) })
        XCTAssertTrue(verdict.contains("draftAudit.meetsAA"), verdict)
        XCTAssertFalse(verdict.contains("draftAudit.passes ? \"checkmark"), verdict)
    }
}
