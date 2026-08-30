import XCTest
@testable import Grux

/// The handoff prompt a user pastes into their own coding agent.
///
/// The interesting property is not that it generates text. It is WHERE THE LINE
/// SITS between what an agent may do and what it may not, because the prompt is
/// an instruction to something that will act on it.
@MainActor
final class AgentHandoffTests: XCTestCase {

    /// THE SAFETY LINE. Four setup steps are decisions rather than installs, and
    /// an agent that ticks them has not completed setup, it has removed the
    /// point of the step. "Confirm you will tell people" is about recording
    /// other humans. "Confirm what stays private" and "Choose what gets indexed"
    /// decide what Grux may read of somebody's own writing. "Review the first
    /// capture" only means anything if a person actually looked.
    func testAnAgentIsNeverAskedToConsentOnSomebodysBehalf() {
        let consent: [SetupRequirement] = [
            .stepRecordingConsentAcknowledged,
            .stepCaptureExclusionsConfirmed,
            .stepCorpusSourcesConfirmed,
            .stepFirstFrameReviewed,
        ]
        for step in consent {
            XCTAssertFalse(AgentHandoff.delegable.contains(step),
                           "\(step.label) is a decision, not an install. An agent answering it defeats the step.")
        }
    }

    /// Credentials and macOS permissions are out for a duller reason: an agent
    /// has no browser session, no card and no way to click System Settings.
    /// Listing them as its work would just produce a confident failure.
    func testNoCredentialOrPermissionIsEverDelegated() {
        for r in AgentHandoff.delegable {
            XCTAssertNotEqual(r.kind, .key, "\(r.label) needs an account and probably a card")
            XCTAssertNotEqual(r.kind, .perm, "\(r.label) needs a click in System Settings")
        }
        XCTAssertFalse(AgentHandoff.delegable.isEmpty,
                       "if nothing is delegable the feature is pointless, so this must not be vacuous")
    }

    // MARK: - The headings the agent actually reads

    /// THE SECOND HALF OF THE SAFETY LINE, and the half that shipped wrong.
    ///
    /// `delegable` correctly kept the four consent steps out of the agent's
    /// list. But the human list was then grouped by `kind`, and ALL NINE `.step`
    /// cases print under "Decisions that are mine to make. Please do not answer
    /// these for me". Five of them are not decisions at all: fetching a speech
    /// model, installing the terminal hook, pairing a phone, turning on YouTube
    /// transcripts, and the agent CLI when it is not delegable.
    ///
    /// The file's own doc comment enumerates the four that ARE consent. Grouping
    /// on `kind == .step` was never the same question, exactly as the comment
    /// beside `delegable` says about the other list.
    func testOnlyRealDecisionsArePresentedAsDecisions() {
        let groups = AgentHandoff.groups(for: SetupRequirement.allCases)
        let decisions = groups.first { $0.heading.contains("Decisions that are mine") }
        let items = Set(decisions?.items ?? [])

        XCTAssertEqual(items, AgentHandoff.consentSteps,
                       "the consent heading must carry exactly the consent steps, no more")
        XCTAssertFalse(items.isEmpty, "control: an empty group would make this vacuous")
    }

    /// Named individually, because a set comparison passing tells you nothing
    /// about WHICH one is wrong when it fails.
    func testTheMechanicalStepsAreNotCalledDecisions() {
        let groups = AgentHandoff.groups(for: SetupRequirement.allCases)
        let decisions = Set(groups.first { $0.heading.contains("Decisions that are mine") }?.items ?? [])

        for step: SetupRequirement in [.stepSpeechModelDownloaded,
                                       .stepTerminalFocusHookInstalled,
                                       .stepPhonePaired,
                                       .stepYoutubeTranscriptsEnabled,
                                       .stepAgentCliInstalled] {
            XCTAssertFalse(decisions.contains(step),
                           "\"\(step.label)\" is a mechanical setup step, and telling an agent it is "
                           + "a personal decision stops it doing work it could have done")
        }
    }

    /// Every one of them still has to appear SOMEWHERE. A grouping fix that
    /// quietly drops the items it no longer knows where to file is a worse bug
    /// than the one it replaced, because the user is then never told about them
    /// at all.
    func testNoRequirementIsSilentlyDroppedByTheGrouping() {
        let input = SetupRequirement.allCases
        let grouped = AgentHandoff.groups(for: input).flatMap { $0.items }

        XCTAssertEqual(Set(grouped), Set(input), "the grouping lost or invented requirements")
        XCTAssertEqual(grouped.count, Set(grouped).count, "a requirement is printed under two headings")
    }

    /// Every heading that prints has items under it, and every group of items
    /// has a heading. An empty heading in the generated text reads as a section
    /// the agent failed to fill in.
    func testNoEmptyHeadingIsEverEmitted() {
        for group in AgentHandoff.groups(for: SetupRequirement.allCases) {
            XCTAssertFalse(group.items.isEmpty, "\"\(group.heading)\" would print with nothing under it")
            XCTAssertFalse(group.heading.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertTrue(AgentHandoff.groups(for: []).isEmpty, "nothing outstanding means no headings")
    }

    /// The rendered prompt, not just the data behind it. This is what the agent
    /// reads, and the grouping only matters if it survives into the text.
    ///
    /// Reading "everything after the consent heading" is only a valid slice
    /// because consent is the LAST group, so that is asserted first rather than
    /// assumed. Reorder the groups and this fails loudly instead of quietly
    /// measuring nothing.
    func testTheRenderedPromptDoesNotFileAnInstallUnderConsent() {
        let consentHeading = "Decisions that are mine to make"
        XCTAssertTrue(AgentHandoff.groups(for: SetupRequirement.allCases).last?.heading
                        .contains(consentHeading) ?? false,
                      "consent is no longer the last group, so the slice below proves nothing")

        let prompt = AgentHandoff.promptFor(
            agent: [],
            human: [.stepSpeechModelDownloaded, .stepRecordingConsentAcknowledged])

        guard let consentAt = prompt.range(of: consentHeading)?.upperBound else {
            return XCTFail("the consent heading did not render at all:\n\(prompt)")
        }
        let afterConsent = String(prompt[consentAt...])

        XCTAssertTrue(afterConsent.contains(SetupRequirement.stepRecordingConsentAcknowledged.label),
                      "the real consent step is not under the consent heading")
        XCTAssertFalse(afterConsent.contains(SetupRequirement.stepSpeechModelDownloaded.label),
                       "\"Fetch the speech model\" is printed under the consent heading:\n\(prompt)")
    }

    /// The prompt has to SAY the rules, not just embody them. It is going to a
    /// model, and the most expensive mistake available here is an agent
    /// helpfully writing an API key into a dotfile.
    func testThePromptForbidsTheExpensiveMistakes() {
        let p = AgentHandoff.prompt()
        XCTAssertTrue(p.contains("Never write an API key"),
                      "the prompt must forbid writing credentials to disk")
        XCTAssertTrue(p.lowercased().contains("keychain"),
                      "and say where credentials actually live")
        // PINS THE PROHIBITION, NOT THE WORDING. This asserted the literal string "do not
        // turn on anything that listens", so rewriting the section to open every line with
        // "Never" for consistency under the NEVER heading failed it, with nothing actually
        // weakened. The substantive clause is the clause about listening; whether it is
        // introduced by "do not" or "never" is copy.
        let listening = p.lowercased()
        XCTAssertTrue(listening.contains("turn on anything that listens"),
                      "the wake word and ambient mode ship off deliberately and are not an "
                      + "agent's to enable")
        XCTAssertTrue(listening.contains("never turn on anything that listens")
                      || listening.contains("do not turn on anything that listens"),
                      "the clause about listening is present but is not phrased as a "
                      + "prohibition")
    }

    /// Everything named must be a real unmet requirement on this machine. A
    /// prompt that asks for work already done wastes the agent's time and the
    /// user's trust in the list.
    func testItOnlyEverAsksForThingsThatAreActuallyMissing() {
        let split = AgentHandoff.outstanding()
        for r in split.agent + split.human {
            XCTAssertFalse(CapabilityResolver.isSatisfied(r),
                           "\(r.label) is already satisfied and should not be in the handoff")
        }
    }

    /// And only capabilities some feature actually claims. Offering to set up a
    /// credential nothing in the app reads is how a setup list becomes noise.
    func testItNeverAsksForACredentialNothingReads() {
        let claimed = Set(FeatureRegistry.rows.flatMap { $0.blocking + $0.optional + $0.optionalSteps })
        let split = AgentHandoff.outstanding()
        XCTAssertFalse(claimed.isEmpty, "control: the registry claims nothing, so this test proves nothing")
        for r in split.agent + split.human {
            XCTAssertTrue(claimed.contains(r), "\(r.label) is in the handoff but no feature requires it")
        }
    }

    /// Discoverability, the same three-part rule the rest of the app answers to:
    /// named at first run, a permanent home, and its purpose explained.
    func testTheHandoffIsDiscoverable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let steps = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"), encoding: .utf8)
        XCTAssertTrue(steps.contains("You can hand the rest to your agent"),
                      "nothing tells a new user this exists")

        let registry = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Settings/SettingsSearchRegistry.swift"), encoding: .utf8)
        XCTAssertTrue(registry.contains("general.handoff"),
                      "it is not in the settings search registry, so searching \"agent\" will not find it")

        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Grux/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("sectionVisible(\"general.handoff\")"),
                      "registered for search but never rendered is worse than absent")
    }

    /// Dumps the real prompt so a person can read what their agent will be told.
    ///     GRUX_SHOT_DIR=/tmp/x swift test --filter AgentHandoffTests
    func testDumpForReading() {
        guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? AgentHandoff.prompt().write(
            to: URL(fileURLWithPath: dir).appendingPathComponent("handoff.txt"),
            atomically: true, encoding: .utf8)
    }
}

// MARK: - CR-36: a handoff must not ask for what you turned off

/// The seam CR-36 left open.
///
/// Giving a feature an off state changed what "outstanding" means, and `AgentHandoff` was
/// not updated with it. Found by driving `grux setup --preset minimal` on the shipped binary
/// and reading all three screens of one run: COST called those capabilities optional, PROVE
/// said "0 still waiting on you", and the prompt between them told an agent to fetch Slack,
/// Notion and Telegram tokens for features that had just been switched off.
@MainActor
final class HandoffRespectsSelectionTests: XCTestCase {

    override func tearDown() {
        // REMOVE, never restore. UserDefaults survives the process, and a teardown that
        // writes a "previous" value back has already leaked one run's state into the next.
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        super.tearDown()
    }

    /// Every capability the prompt mentions must be claimed by a feature that is ON.
    func testTheHandoffNamesNothingOnlyAnOffFeatureWanted() {
        FeatureSelection.choose(["home", "chat", "approvals", "settings"])

        let split = AgentHandoff.outstanding()
        let mentioned = Set(split.agent + split.human)
        XCTAssertFalse(mentioned.isEmpty, "nothing outstanding, so this proves nothing")

        let onRows = FeatureRegistry.rows.filter { FeatureSelection.isOn($0.id) }
        let claimedByOn = Set(onRows.flatMap { $0.blocking + $0.optional + $0.optionalSteps })

        let orphans = mentioned.subtracting(claimedByOn)
        XCTAssertTrue(orphans.isEmpty,
            "the handoff asks for \(orphans.map(\.rawValue).sorted().joined(separator: ", ")), "
            + "which no chosen feature claims")
    }

    /// The positive control. Turning a feature back ON must make its capabilities reappear,
    /// or the filter above could be passing because it returns nothing at all.
    func testTurningAFeatureOnBringsItsAsksBack() {
        FeatureSelection.choose(["home", "settings"])
        let narrow = Set(AgentHandoff.outstanding().human + AgentHandoff.outstanding().agent)

        FeatureSelection.choose(Set(FeatureRegistry.rows.map(\.id)))
        let wide = Set(AgentHandoff.outstanding().human + AgentHandoff.outstanding().agent)

        XCTAssertGreaterThan(wide.count, narrow.count,
            "choosing every feature asked for no more than choosing two, so the selection "
            + "is not reaching this code at all")
        XCTAssertTrue(narrow.isSubset(of: wide),
            "a narrower selection asked for something a wider one does not")
    }

    /// Never asked is not the same as chosen nothing. An install that predates CR-36 has no
    /// stored selection and must still see everything, or upgrading silently empties the
    /// handoff.
    func testNeverAskedStillMeansEverything() {
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        let all = Set(AgentHandoff.outstanding().human + AgentHandoff.outstanding().agent)

        FeatureSelection.choose(Set(FeatureRegistry.rows.map(\.id)))
        let explicit = Set(AgentHandoff.outstanding().human + AgentHandoff.outstanding().agent)

        XCTAssertEqual(all, explicit,
            "an upgraded install with no stored choice does not see what choosing "
            + "everything sees")
    }
}
