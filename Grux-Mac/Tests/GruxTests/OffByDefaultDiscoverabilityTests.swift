import XCTest
@testable import Grux

/// The house rule says a feature that ships OFF must be named at first run, have
/// a permanent home in Settings, and have its off state explained, and that this
/// is enforced in the suite rather than in review. Nothing enforced it.
///
/// ## Why this does not grep for a Settings writer
///
/// That was the obvious design and it is the wrong one. Measured while building
/// this: `ambientEnabled` has a working toggle whose `set:` calls
/// `ambient.enable()`, so the controller owns the write and no assignment to the
/// flag appears in the view at all. `offlineMode` is mirrored onto `AppState`
/// with a `didSet` and written as `state.offlineMode`, not `config.offlineMode`.
/// Both have real, working controls. A source scan for `config.X =` reports both
/// as missing, which is a test that cries wolf on correct code, and a test that
/// cries wolf gets deleted or muted within a month.
///
/// So the enforcement is a TABLE a human maintains, and what the suite checks is
/// that the table cannot rot: a new off-by-default flag fails until somebody
/// classifies it, an entry for a flag that no longer exists fails, and an entry
/// claiming a first-run introduction fails unless that phrase is genuinely in
/// the onboarding copy. That last one is reliably greppable precisely because it
/// is prose this repo owns.
final class OffByDefaultDiscoverabilityTests: XCTestCase {

    private struct OffFeature {
        /// The exact phrase that introduces it during first run, or nil.
        let introducedAtFirstRun: String?
        /// Why first run does not mention it. Required whenever the above is nil,
        /// so "we forgot" cannot pass as "we decided".
        let reason: String
    }

    /// Every `Bool` in `Config` that decodes to `false`, and where a user is
    /// supposed to find out it exists.
    private static let classified: [String: OffFeature] = [
        "wakeWordEnabled": OffFeature(
            introducedAtFirstRun: "wake word",
            reason: ""),
        "ambientEnabled": OffFeature(
            introducedAtFirstRun: "Ambient mode",
            reason: ""),
        "screenControlEnabled": OffFeature(
            introducedAtFirstRun: "Screen control",
            reason: ""),

        // The rest are deliberately not introduced at first run, each for a
        // reason that has to survive being read out loud.
        "ambientAutoPromoteActions": OffFeature(
            introducedAtFirstRun: nil,
            reason: "A sub-setting of ambient mode, meaningless until ambient is on. Ambient itself IS introduced, and this sits directly beneath it in the same Settings section."),
        "useLocalQwenForAmbient": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Also a sub-setting of ambient mode: which model transcribes, not whether anything listens. Same section, same argument."),
        "phoneCompanionEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Pairing a second device, and there is no phone in the room during first run. Introducing it there would be an instruction nobody can act on, which is the failure this whole rule exists to stop."),
        "offlineMode": OffFeature(
            introducedAtFirstRun: nil,
            reason: "A mode the user chooses, not a capability that is missing. The model key step already covers running against a local model, which is the same decision in the place it is actually being made."),
        "prInboxEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Developer tooling that needs a GitHub credential, which is offered in the connections step. Naming it before the credential exists is naming something that cannot be turned on."),
        "ascMonitorEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "App Store Connect monitoring, meaningful only to somebody shipping an iOS app from this Mac. It surfaces in context on the iOS surfaces rather than to every new user."),
        "domainMonitorEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Needs a registrar API key, which first run does not ask for. Same argument as its sibling ascMonitorEnabled, which it now sits beside in Settings. It was ON and ungated until the first-run audit: it adopted a credential left in ~/.grux/godaddy-creds.json by anything at all and called the registrar on the strength of it."),
        "musicDuckingEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "A refinement of how Grux speaks, and it lives directly under the spoken-replies toggles that ARE the introduction. Off because turning it on is what sends the first Apple event to Music, which macOS answers with a consent dialog; nothing in the app had ever said Grux touches Music."),
        "meetingAutoDetectEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Sits in the recording-consent section, which is where somebody deciding about call recording already is. Naming it at first run would be describing a hint about an app the person has not opened yet. Recording was always gated; the unprompted OFFER was not, which is what this switch is."),
        "personMemoryEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "A sub-setting of ambient mode with nothing to read until ambient is on, and ambient IS introduced. It sits in the ambient section under a paragraph saying both nightly passes send the transcript to a model. Off because it keeps notes about OTHER PEOPLE by name, and it had no switch of any kind before the first-run audit."),
        "spokenBriefingsEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "Sits directly under the spoken-replies toggles that ARE the introduction, in the same Settings section. Not named at first run because it needs a mail account to have anything to say and the mail step is the LAST thing the flow offers, so at the point it could be described there is nothing yet to describe."),
        "foundryEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "The self-upgrade loop. Off is what the contract has said all along (`grux.foundry.enabled`, \"CR-20, the self-upgrade loop, off by default\"); the flag is new because nothing implemented it and the governor ran unconditionally. Not introduced at first run because it proposes changes to a Grux the person has not used yet, so there is nothing for it to have learned."),
        "decisionLogEnabled": OffFeature(
            introducedAtFirstRun: nil,
            reason: "The same nightly pass over the same transcript an hour earlier, in the same Settings block under the same paragraph, for the same reason."),
    ]

    // MARK: - Sources

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `Bool` config key that decodes to false, read out of the decoder
    /// rather than listed here, so the list cannot drift from the type.
    private static func offByDefaultFlags(in models: String) -> Set<String> {
        var out: Set<String> = []
        let pattern = #"(\w+) = try c\.decodeIfPresent\(Bool\.self, forKey: \.\w+\) \?\? false"#
        let rx = try! NSRegularExpression(pattern: pattern)
        let ns = models as NSString
        for m in rx.matches(in: models, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    // MARK: - Controls

    /// The parser is the part that can silently return nothing and make every
    /// assertion below vacuous, so it is controlled in both directions first.
    func testTheParserItselfWorks() {
        let sample = """
            wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? false
            speakRepliesAloud = try c.decodeIfPresent(Bool.self, forKey: .speakRepliesAloud) ?? true
            someString = try c.decodeIfPresent(String.self, forKey: .someString) ?? ""
            """
        let found = Self.offByDefaultFlags(in: sample)
        XCTAssertEqual(found, ["wakeWordEnabled"],
                       "the parser must find flags defaulting to FALSE and ignore true defaults and non Bools")
        XCTAssertTrue(Self.offByDefaultFlags(in: "nothing here").isEmpty,
                      "and must find nothing in text that has none")
    }

    // MARK: - The table cannot rot

    /// A NEW off-by-default flag fails this until somebody decides how a user is
    /// meant to find out it exists. That is the whole mechanism: the cost of
    /// adding a hidden feature is one deliberate sentence.
    func testEveryOffByDefaultFlagIsClassified() throws {
        let flags = Self.offByDefaultFlags(in: try Self.source("Sources/Grux/Models.swift"))

        XCTAssertGreaterThan(flags.count, 3,
                             "the parser found almost nothing in the real Config, so this test proves nothing")

        let unclassified = flags.subtracting(Self.classified.keys).sorted()
        XCTAssertEqual(unclassified, [],
                       "these ship OFF and nothing says how a user discovers them: \(unclassified.joined(separator: ", ")). "
                       + "Add each to `classified` with either the first-run phrase that introduces it, or a stated reason it needs none.")

        let stale = Set(Self.classified.keys).subtracting(flags).sorted()
        XCTAssertEqual(stale, [],
                       "these are classified but no longer ship off by default, so the table is describing a Config that "
                       + "does not exist: \(stale.joined(separator: ", "))")
    }

    /// An entry may not claim a first-run introduction that is not there. This is
    /// the half that caught the real bug: the wake word had a Settings home and
    /// was named ZERO times in the whole flow, while the chat empty state told
    /// every user to say it.
    func testClaimedIntroductionsAreActuallyInTheOnboardingCopy() throws {
        let steps = try Self.source("Sources/Grux/Onboarding/OnboardingSteps.swift")

        // Control. If the reader handed back the wrong file or an empty string,
        // every claim below would fail for the wrong reason, or worse, a future
        // `contains` on an empty needle would pass.
        XCTAssertTrue(steps.contains("How Grux works"),
                      "control: this is not OnboardingSteps.swift")

        for (flag, feature) in Self.classified {
            guard let phrase = feature.introducedAtFirstRun else { continue }
            XCTAssertFalse(phrase.isEmpty, "\(flag): an empty phrase would match anything")
            XCTAssertTrue(steps.localizedCaseInsensitiveContains(phrase),
                          "\(flag) is recorded as introduced at first run by the phrase \"\(phrase)\", and that phrase "
                          + "is not in the onboarding copy. Either the copy was edited away or the claim was never true.")
        }
    }

    /// Not introducing something has to be a decision somebody wrote down.
    func testEveryUnintroducedFlagHasAStatedReason() {
        for (flag, feature) in Self.classified where feature.introducedAtFirstRun == nil {
            XCTAssertGreaterThan(feature.reason.count, 40,
                                 "\(flag) is not introduced at first run and carries no real reason. "
                                 + "\"We forgot\" and \"we decided\" look identical in a diff, so the reason is the difference.")
        }
    }
}
