import XCTest
@testable import Grux

/// D116 items 4, 6, 8 and 9 (sense pass 11): four lines that were not true of
/// the Mac they sat on. Each test reads the line a person reads.
@MainActor
final class HonestPaneLinesTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Item 6: Speakers asks to select from an empty list

    /// "Select a speaker to see their stats and actions." sat beside "No
    /// speakers enrolled yet." (`s11-shots/speakers-1.png`): there was nothing
    /// to select.
    func test_withNoSpeakersTheDetailDoesNotAskToSelectOne() {
        let line = SpeakersView.detailPlaceholderLine(profileCount: 0)
        XCTAssertFalse(line.lowercased().contains("select"), line)
        XCTAssertEqual(line, "A voice you name in a meeting shows its stats and actions here.")
    }

    /// One under, at and over the edge: one speaker or more can be selected.
    func test_withSpeakersTheDetailAsksToSelectOne() {
        XCTAssertEqual(SpeakersView.detailPlaceholderLine(profileCount: 1), "Select a speaker to see their stats and actions.")
        XCTAssertEqual(SpeakersView.detailPlaceholderLine(profileCount: 2), "Select a speaker to see their stats and actions.")
    }

    func test_thePaneDrawsTheTestedPlaceholder() throws {
        let src = try source("Sources/Grux/Meeting/SpeakersView.swift")
        XCTAssertTrue(src.contains("Self.detailPlaceholderLine(profileCount: store.profiles.count)"))
        XCTAssertFalse(src.contains("Text(\"Select a speaker"), "the placeholder is drawn from the tested line")
    }

    // MARK: - Item 9: Integrations offers to get a key it already has

    /// "Get a key from TypeSafe" stayed under "Connected" (`integrations-1.png`).
    func test_theGetAKeyLinkShowsOnlyWithoutAKey() {
        XCTAssertTrue(DecisionsSection.showsGetKeyLink(connected: false))
        XCTAssertFalse(DecisionsSection.showsGetKeyLink(connected: true))
    }

    func test_theSectionGatesTheLinkOnTheTestedRule() throws {
        let src = try source("Sources/Grux/Integrations/DecisionsSection.swift")
        let gate = try XCTUnwrap(src.range(of: "if Self.showsGetKeyLink(connected: connected)"))
        let link = try XCTUnwrap(src.range(of: "Label(\"Get a key from TypeSafe\""))
        XCTAssertLessThan(gate.lowerBound, link.lowerBound)
        XCTAssertEqual(src.components(separatedBy: "Get a key from TypeSafe").count, 2, "one link, behind the gate")
    }

    // MARK: - Item 8: "Last decision: Start a self-upgrade cycle"

    /// The value is what the decision was asked about, not what Grux decided
    /// to do; "Last decision: Start a self-upgrade cycle" read as Grux having
    /// decided to start one (`settings-models-1.png`).
    func test_theUsageCardSaysWhatTheLastDecisionWasAbout() {
        let row = DecisionLedgerEntry(surface: "approval", provider: .local, latencyMs: 144,
                                      inputTokens: 0, outputTokens: 0, at: Date(),
                                      summary: "Start a self-upgrade cycle. -> approve 0.9")
        let card = UsageCardContent.build(from: [row])
        XCTAssertEqual(card.lines.last?.label, "Last decision about")
    }

    // MARK: - Item 4 (and D104): the AA warning says what to do about it

    /// The default accent (hue 249) read "Below WCAG AA: chip text on accent,
    /// 4.2:1 (needs 4.5:1)" while the caption said chip text is refused only
    /// under 3:1, and a code comment said no hue fixes it. Hue 240 does; the
    /// pane names it.
    func test_theDefaultAccentNamesTheHueThatMeetsAA() {
        XCTAssertEqual(ThemeConfig.huesMeetingAA, [240], "measured on this palette; update the note test if it moves")
        let hue = ThemeConfig.canonicalAccentHue
        let audit = ThemeConfig.runWCAGAudit(palette: .derived(accentHue: hue))
        XCTAssertEqual(ThemeConfig.chipTextNote(for: audit, draftHue: hue),
                       "Hue 240° meets WCAG AA on every pair, chip text included.")
    }

    /// The hue it names really meets AA on every pair.
    func test_theNamedHueMeetsAA() {
        for hue in ThemeConfig.huesMeetingAA {
            XCTAssertTrue(ThemeConfig.runWCAGAudit(palette: .derived(accentHue: Double(hue))).meetsAA, "\(hue)")
        }
    }

    private func chip(_ ratio: Double) -> ThemeWCAGCheck {
        ThemeWCAGCheck(name: ThemeConfig.chipTextPairName, ratio: ratio, required: 3.0, wcagAA: 4.5)
    }

    /// On, under and over each bar: the note shows only for chip text that Grux
    /// takes (3:1 or over) and AA does not (under 4.5:1), and never when another
    /// pair is also under AA. With no hue meeting AA it says the palette is Grux's.
    func test_theNoteShowsOnlyBetweenGruxsFloorAndAA() {
        XCTAssertNotNil(ThemeConfig.chipTextNote(for: ThemeWCAGAuditResult(checks: [chip(3.0)]), draftHue: 249))
        XCTAssertNotNil(ThemeConfig.chipTextNote(for: ThemeWCAGAuditResult(checks: [chip(4.4999)]), draftHue: 249))
        XCTAssertNil(ThemeConfig.chipTextNote(for: ThemeWCAGAuditResult(checks: [chip(2.9999)]), draftHue: 249), "refused, not taken")
        XCTAssertNil(ThemeConfig.chipTextNote(for: ThemeWCAGAuditResult(checks: [chip(4.5)]), draftHue: 249), "meets AA")
        let alsoBadge = ThemeWCAGAuditResult(checks: [
            chip(4.2), ThemeWCAGCheck(name: "badge text", ratio: 3.6, required: 3.0, wcagAA: 4.5)])
        XCTAssertNil(ThemeConfig.chipTextNote(for: alsoBadge, draftHue: 249), "another pair is under AA too")
        XCTAssertEqual(ThemeConfig.chipTextNote(for: ThemeWCAGAuditResult(checks: [chip(4.2)]), draftHue: 249, huesMeetingAA: []),
                       "No accent hue gives white chip text 4.5:1, so Grux takes it from 3:1. That is Grux's palette, not your choice.")
    }

    /// The nearest hue around the wheel, not the lowest number: from 350 the
    /// hue 10 is 20 degrees away, 200 is 150.
    func test_theNoteNamesTheNearestHueAroundTheWheel() {
        let audit = ThemeWCAGAuditResult(checks: [chip(4.2)])
        XCTAssertEqual(ThemeConfig.chipTextNote(for: audit, draftHue: 350, huesMeetingAA: [10, 200]),
                       "Hue 10° meets WCAG AA on every pair, chip text included.")
        XCTAssertEqual(ThemeConfig.chipTextNote(for: audit, draftHue: 150, huesMeetingAA: [10, 200]),
                       "Hue 200° meets WCAG AA on every pair, chip text included.")
    }

    /// Wave 33 round 1 (P2): hue 240 meets AA only from about 239.95 to 240.16,
    /// the slider was continuous and the label truncated, so at 240.5 the pane
    /// read "Hue 240°", an amber "Below WCAG AA" and "Hue 240° meets WCAG AA".
    /// The label shows a hue that is not whole with its decimal, rounded down
    /// (on, under and over a whole degree).
    func test_theHueLabelNeverPassesAFractionOffAsAWholeDegree() {
        XCTAssertEqual(ThemeConfig.hueLabel(240), "Hue 240°")
        XCTAssertEqual(ThemeConfig.hueLabel(240.5), "Hue 240.5°")
        XCTAssertEqual(ThemeConfig.hueLabel(240.04), "Hue 240.0°")
        XCTAssertEqual(ThemeConfig.hueLabel(239.99), "Hue 239.9°")
        XCTAssertEqual(ThemeConfig.hueLabel(ThemeConfig.canonicalAccentHue), "Hue 249.8°", "0x7B61FF, measured")
        XCTAssertEqual(ThemeConfig.hueLabel(0), "Hue 0°")
    }

    /// At 240.5 the label no longer reads as the hue the note names.
    func test_aDraftBesideTheNamedHueDoesNotReadAsIt() throws {
        let audit = ThemeConfig.runWCAGAudit(palette: .derived(accentHue: 240.5))
        XCTAssertFalse(audit.meetsAA)
        let note = try XCTUnwrap(ThemeConfig.chipTextNote(for: audit, draftHue: 240.5))
        XCTAssertFalse(note.contains(ThemeConfig.hueLabel(240.5).replacingOccurrences(of: "Hue ", with: "")), note)
    }

    /// The hue the note names is one click away, and every dragged hue is a
    /// whole degree, so the named hue is reachable exactly.
    func test_theNamedHueIsOneClickAwayAndTheSliderStepsWholeDegrees() throws {
        XCTAssertEqual(ThemeConfig.nearestHueMeetingAA(to: 249.75), 240)
        XCTAssertEqual(ThemeConfig.nearestHueMeetingAA(to: 10, in: [10, 200]), 10)
        XCTAssertNil(ThemeConfig.nearestHueMeetingAA(to: 10, in: []))
        let src = try source("Sources/Grux/DesignSystem/AppearanceSettingsView.swift")
        XCTAssertTrue(src.contains("Slider(value: $draftHue, in: 0...360, step: 1"), "a dragged hue is a whole degree")
        XCTAssertTrue(src.contains("Text(ThemeConfig.hueLabel(draftHue))"))
        XCTAssertTrue(src.contains("Button(\"Use hue \\(hue)°\")"), "the note's hue is one click away")
        XCTAssertFalse(src.contains("Text(\"Hue \\(Int(draftHue))°\")"))
    }

    func test_thePaneDrawsTheNoteUnderTheVerdict() throws {
        let src = try source("Sources/Grux/DesignSystem/AppearanceSettingsView.swift")
        XCTAssertTrue(src.contains("ThemeConfig.chipTextNote(for: draftAudit, draftHue: draftHue)"))
    }
}
