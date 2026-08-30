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
}
