import XCTest
@testable import Grux

/// D133: first run's How Grux works card said "TIER 0 Proposes: Grux writes up
/// what it would change and waits", marked "you are here", on every new install,
/// where self-upgrade is off and Grux proposes nothing. The card now follows the
/// switch and the tier Tuning holds.
final class HowItWorksSelfUpgradeTests: XCTestCase {

    func test_off_marksNoTier_andSaysItIsOff() {
        for tier in [0, 1, 2] {
            let card = HowItWorksCopy.autonomy(enabled: false, tier: tier)
            XCTAssertNil(card.current, "tier \(tier): self-upgrade off is at no tier of the ladder")
            XCTAssertTrue(card.intro.contains("off"), card.intro)
            XCTAssertTrue(card.intro.contains("proposes nothing"), card.intro)
            XCTAssertFalse(card.caption.contains("You are"), card.caption)
        }
    }

    /// `selfUpgradeMaxTier` is a ceiling ("Self-upgrade, at most" in Tuning): every lane
    /// starts at TIER 0 and earns its way up to it (`FoundryEngine.cappedTier`). Wave 38
    /// round 1 found the card marking the ceiling as where you are.
    func test_off_saysItStartsAtTier0_andNamesTheCeiling() {
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: false, tier: 0).caption,
                       "Switched on, it starts at TIER 0 and stays there while \"Self-upgrade, at most\" in Tuning is set to Proposes. "
                       + "Raise that limit and a part of Grux moves up a tier each time 5 of its changes in a row are approved and kept.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: false, tier: 1).caption,
                       "Switched on, it starts at TIER 0. A part of Grux moves up a tier each time 5 of its changes in a row "
                       + "are approved and kept, as far as TIER 1, the limit \"Self-upgrade, at most\" sets in Tuning.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: false, tier: 2).caption,
                       "Switched on, it starts at TIER 0. A part of Grux moves up a tier each time 5 of its changes in a row "
                       + "are approved and kept, as far as TIER 2, the limit \"Self-upgrade, at most\" sets in Tuning.")
    }

    func test_on_marksTier0_whateverTheCeiling() {
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 0),
                       .init(intro: "Grux can improve its own code. You choose how far that goes.",
                             current: 0,
                             caption: "You are starting at TIER 0. It stays there while \"Self-upgrade, at most\" in Tuning is set to Proposes. "
                                + "Raise that limit and a part of Grux moves up a tier each time 5 of its changes in a row are approved and kept."))
        for ceiling in [1, 2] {
            let card = HowItWorksCopy.autonomy(enabled: true, tier: ceiling)
            XCTAssertEqual(card.current, 0, "ceiling \(ceiling): a lane with no history proposes")
            XCTAssertEqual(card.caption, "You are starting at TIER 0. A part of Grux moves up a tier each time 5 of its changes in a row "
                           + "are approved and kept, as far as TIER \(ceiling), the limit \"Self-upgrade, at most\" sets in Tuning.")
        }
    }

    /// W38-FIX P3 5 (wave 38 round 2): on a re-run from Settings, a part of Grux that had
    /// earned TIER 1 or 2 still read "You are starting at TIER 0". Wave 39 round 1: marking
    /// the earned tier as "you are here" was wrong too, because every proposal is filed at
    /// `ProposalSynthesizer.filedTier` (TIER 0), so `FoundryEngine.shouldAutoLand` never
    /// lands one and a person still presses Build. The card marks the tier a filed proposal
    /// acts at, and names an earned tier as a fact.
    func test_aRerun_marksTheTierAProposalActsAt_andNamesWhatWasEarned() {
        // The oracle, in plain words: a proposal acts at the lower of what its lane earned
        // (capped by Tuning) and what it was filed at.
        func acts(_ earned: Int, _ ceiling: Int) -> Int {
            min(FoundryEngine.cappedTier(earned: TrustTier(rawValue: earned) ?? .propose, ceiling: ceiling),
                ProposalSynthesizer.filedTier).rawValue
        }
        for earned in -1...3 {
            for ceiling in -1...3 {
                let card = HowItWorksCopy.autonomy(enabled: true, tier: ceiling, earned: earned)
                XCTAssertEqual(card.current, acts(earned, ceiling), "earned \(earned) ceiling \(ceiling): \(card.caption)")
                let known = (TrustTier(rawValue: earned) ?? .propose).rawValue
                if known == 0 {
                    XCTAssertEqual(card, HowItWorksCopy.autonomy(enabled: true, tier: ceiling),
                                   "earned \(earned) ceiling \(ceiling): nothing earned reads as a new install")
                } else {
                    // Wave 39 round 2: the earned tier is named as earned (not the capped
                    // number), and no caption, on or off, promises building or landing.
                    for on in [true, false] {
                        let c = HowItWorksCopy.autonomy(enabled: on, tier: ceiling, earned: earned).caption
                        XCTAssertFalse(c.contains("starting at TIER 0"), "\(on) earned \(earned) ceiling \(ceiling): \(c)")
                        XCTAssertTrue(c.contains("earned TIER \(known)"), "\(on) earned \(earned) ceiling \(ceiling): \(c)")
                        XCTAssertTrue(c.lowercased().contains("every proposal still waits for your ok"), "\(on) earned \(earned) ceiling \(ceiling): \(c)")
                        XCTAssertFalse(c.contains("keeps the tier"), "\(on) earned \(earned) ceiling \(ceiling): \(c)")
                        XCTAssertFalse(c.contains("earn its way up"), "\(on) earned \(earned) ceiling \(ceiling): \(c)")
                    }
                }
            }
        }
        XCTAssertEqual(ProposalSynthesizer.filedTier, .propose, "update the copy below when proposals are filed higher")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 2, earned: 2).current, 0)
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 2, earned: 1).caption,
                       "A part of Grux has earned TIER 1. Every proposal still waits for your OK before it is built, so Grux works at TIER 0.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 2, earned: 2).caption,
                       "A part of Grux has earned TIER 2, the most Tuning allows. Every proposal still waits for your OK before it is built, so Grux works at TIER 0.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 1, earned: 2).caption,
                       "A part of Grux has earned TIER 2, and Tuning holds it to TIER 1. Every proposal still waits for your OK before it is built, so Grux works at TIER 0.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: 0, earned: 2).caption,
                       "A part of Grux has earned TIER 2, and Tuning holds it to TIER 0. Every proposal still waits for your OK before it is built, so Grux works at TIER 0.")
        // Off: no tier is marked; the earned tier is a fact and nothing is promised.
        let off = HowItWorksCopy.autonomy(enabled: false, tier: 2, earned: 2)
        XCTAssertNil(off.current)
        XCTAssertEqual(off.caption, "A part of Grux has earned TIER 2, the most Tuning allows. Switched on, every proposal still waits for your OK before it is built.")
        XCTAssertEqual(HowItWorksCopy.autonomy(enabled: false, tier: 2, earned: 0),
                       HowItWorksCopy.autonomy(enabled: false, tier: 2))
    }

    /// Every proposal source files at the one constant the card reads.
    func test_proposalsAreFiledAtTheTierTheCardReads() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Foundry/ProposalSynthesizer.swift"))
        XCTAssertTrue(src.contains("tierRequired: filedTier"), "a proposal filed at a tier the card does not read")
        XCTAssertFalse(src.contains("tierRequired: ."), "a proposal filed at a literal tier")
    }

    /// The governor reads a tier it does not know as TIER 0 (`TrustTier(rawValue:)` is nil,
    /// `cappedTier` falls back to `.propose`), and so does the card.
    func test_outOfRangeCeiling_readsAsTier0_asTheGovernorDoes() {
        for bad in [-1, 3, 9] {
            XCTAssertEqual(HowItWorksCopy.autonomy(enabled: true, tier: bad),
                           HowItWorksCopy.autonomy(enabled: true, tier: 0), "\(bad)")
            XCTAssertEqual(HowItWorksCopy.autonomy(enabled: false, tier: bad),
                           HowItWorksCopy.autonomy(enabled: false, tier: 0), "\(bad)")
        }
    }

    /// The card reads the switch and the tier; nothing in the view hard-codes a position.
    func test_theCardIsDrawnFromTheCopy() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"))
        XCTAssertFalse(src.contains("current: true"), "a tier marked current by a literal")
        XCTAssertFalse(src.contains("current: false"), "a tier marked not current by a literal")
        XCTAssertTrue(src.contains("HowItWorksCopy.autonomy(enabled: c.foundryEnabled, tier: c.selfUpgradeMaxTier,\n                                              earned: TrustLedger.shared.highestTier.rawValue)"),
                      "the card does not read what the trust ledger holds")
    }

    /// D138 item 6 (sense pass 15): the card said "stays there until you raise it in
    /// Tuning" and "the most Tuning allows", and first run never says what in Tuning
    /// holds a tier or how one is earned. The card names Tuning's own dial and choice,
    /// read from the constants Tuning draws, and the trust ledger's own streak.
    func test_theCardNamesTuningsDial_andHowATierIsEarned() throws {
        XCTAssertEqual(TrustLedger.promotionStreak, 5, "update the card's expected copy above")
        for on in [true, false] {
            for ceiling in [0, 1, 2] {
                let c = HowItWorksCopy.autonomy(enabled: on, tier: ceiling).caption
                XCTAssertTrue(c.contains("\"\(TuningCopy.selfUpgradeDial)\""), "\(on) \(ceiling): \(c)")
                XCTAssertTrue(c.contains("\(TrustLedger.promotionStreak) of its changes in a row are approved and kept"), "\(on) \(ceiling): \(c)")
                XCTAssertFalse(c.contains("raise it in Tuning"), "\(on) \(ceiling): \(c)")
                XCTAssertFalse(c.contains("the most Tuning allows"), "\(on) \(ceiling): \(c)")
                if ceiling == 0 { XCTAssertTrue(c.contains("is set to \(TuningCopy.selfUpgradeChoices[0])."), c) }
            }
        }
        XCTAssertEqual(TuningCopy.selfUpgradeChoices.count, 3, "one Tuning choice per tier")
        let tuning = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Tuning/TuningView.swift"))
        XCTAssertTrue(tuning.contains("dial(TuningCopy.selfUpgradeDial)"), "Tuning's dial does not read the label the card names")
        XCTAssertTrue(tuning.contains("Text(TuningCopy.selfUpgradeChoices[tier]).tag(tier)"), "Tuning's choices do not read the names the card names")
    }

}
