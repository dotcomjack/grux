import XCTest
@testable import Grux

/// THE TERMINAL ENGINE IS THE BIGGEST THING GRUX DOES AND ONBOARDING NEVER MENTIONS IT.
///
/// Grux opens headless terminal sessions and drives an agent CLI to work
/// hands-free. That CLI authenticates as the user's own logged-in subscription:
/// `AccountSwitcher` deliberately strips twenty credential environment
/// variables (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, the Bedrock and
/// Vertex switches, and more) so a session cannot silently bill an API account
/// instead of using OAuth. That is a real protection and nothing tells the user
/// it exists.
///
/// The house rule in `Grux-Mac/CLAUDE.md` is explicit, and it wants three things
/// rather than two: a feature that ships off must be NAMED AT FIRST RUN, have a
/// PERMANENT HOME in Settings, and have its OFF STATE EXPLAINED. Onboarding
/// already does this for the wake word, for ambient mode and for screen
/// control. It does not do it for the thing that runs a shell on your machine.
///
/// Measured 2026-08-23, the day this file was written: the words "terminal",
/// "session" and the name of the CLI appear ZERO times in `HowItWorksStep`,
/// while `OnboardingSteps.swift` tells every user "You pay your model provider
/// directly, per use." For the subscription path that is not merely incomplete,
/// it is the opposite of what happens, so a user finishes onboarding holding a
/// wrong model of both who is billed and which identity is used.
///
/// These assertions read the shipped source rather than a rendered view because
/// the failure being guarded is a missing paragraph, and a paragraph that is
/// absent renders as nothing at all rather than as an error.
final class TerminalSessionsOnboardingTests: XCTestCase {

    private func macRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: macRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private func onboardingSteps() throws -> String {
        try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
    }

    /// Control. If this cannot find the section every other assertion targets,
    /// the file moved and the rest of this class is proving nothing.
    func testTheFirstRunHowItWorksSectionIsWhereWeThinkItIs() throws {
        let src = try onboardingSteps()
        XCTAssertTrue(src.contains("struct HowItWorksStep"),
                      "HowItWorksStep moved, so every assertion in this file is aimed at the wrong place")
        XCTAssertTrue(src.contains("What is off until you say so"),
                      "the off-by-default section moved or was renamed")
    }

    /// CONDITION 1: named at first run.
    func testFirstRunNamesTheTerminalEngine() throws {
        let src = try onboardingSteps().lowercased()
        XCTAssertTrue(src.contains("terminal"),
                      "onboarding never says the word terminal, yet Grux runs one on the user's Mac")
        XCTAssertTrue(src.contains("headless") || src.contains("session"),
                      "onboarding does not describe that these sessions run on their own")
    }

    /// CONDITION 3, first half: the user is told WHICH CREDENTIAL powers it.
    /// Being billed on an API key you forgot was exported is the concrete harm.
    func testFirstRunExplainsWhichCredentialPowersTheSessions() throws {
        let src = try onboardingSteps().lowercased()
        XCTAssertTrue(src.contains("subscription"),
                      "onboarding never explains that terminal sessions can run on the user's existing subscription")
        XCTAssertTrue(src.contains("api key") || src.contains("api-key"),
                      "onboarding never contrasts the subscription path against the API-key path")
    }

    /// THE CONTRADICTION. The blanket per-use claim describes only the API path
    /// and is wrong for the subscription path, so it cannot stand unqualified.
    func testTheCostCopyDoesNotClaimPerUseBillingForEveryPath() throws {
        let src = try onboardingSteps()
        guard let range = src.range(of: "You pay your model provider directly, per use.") else {
            return   // already rewritten, nothing to guard
        }
        let after = String(src[range.upperBound...].prefix(600)).lowercased()
        // "subscription" ALONE is not enough and this assertion was briefly
        // wrong because of it: the very next sentence already read "There is no
        // Grux subscription", which is a claim about Grux's own pricing and
        // says nothing about which credential a terminal session spends. The
        // window must tie the word to the sessions themselves, or this test
        // passes green over the exact contradiction it exists to catch.
        let qualified = after.contains("subscription")
            && (after.contains("terminal") || after.contains("session"))
        XCTAssertTrue(qualified,
                      """
                      Onboarding asserts flat per-use billing. That is true of the API-key path \
                      and false of the subscription path the terminal engine actually uses, and \
                      no qualification tying a subscription to those sessions appears near the claim.
                      """)
    }

    /// CONDITION 3, second half: running many sessions at once against one
    /// subscription is the behaviour most likely to hit a provider rate limit.
    /// State the mechanism. Do NOT assert a ban, which we cannot substantiate.
    func testFirstRunExplainsTheConcurrencyTradeoff() throws {
        let src = try onboardingSteps().lowercased()
        XCTAssertTrue(src.contains("at once") || src.contains("concurren") || src.contains("parallel"),
                      "nothing warns that stacking sessions is what pushes a subscription into rate limits")
    }

    /// CONDITION 2: a permanent home. First run happens once; discovery has to
    /// keep working in six months when the user finally wants it.
    ///
    /// This assertion was briefly worthless. Grepping SettingsView for
    /// "terminal" passed on day one, before any of this existed, because
    /// Settings already had a Terminal Focus sub-pane for the OVERLAY. A test
    /// that is green before the feature is written is not a test, so it now
    /// demands the things a session pane must actually show.
    func testTheTerminalEngineHasAPermanentSettingsHome() throws {
        let pane = try source("Sources/Grux/Settings/TerminalSessionsSettingsView.swift")
        let lower = pane.lowercased()

        XCTAssertTrue(lower.contains("resolveclaudebinary"),
                      "the pane does not show WHICH binary Grux resolved, so the user cannot tell what will run")
        XCTAssertTrue(lower.contains("subscription"),
                      "the pane does not name the subscription path")
        XCTAssertTrue(lower.contains("api key") || lower.contains("api-key"),
                      "the pane does not contrast the API-key path, which is the one that costs money per call")
        XCTAssertTrue(lower.contains("stepterminalsessionsexplained"),
                      "the pane does not bind the consent step, so it cannot be turned on or off from its permanent home")
    }

    /// The pane has to be REACHABLE. A view file nothing presents is not a home.
    func testTheSettingsPaneIsActuallyWiredIntoSettings() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("TerminalSessionsSettingsView"),
                      "the pane exists but SettingsView never presents it, so it is unreachable")
    }

    /// AND IT HAS TO BE FINDABLE, which is a different claim from reachable.
    ///
    /// Settings is five panes with sub-tabs, so a pane you can only reach by
    /// remembering it lives under Voice and Ambient is not discoverable, it is
    /// a trivia question. The search field at the top of Settings is how anyone
    /// actually finds a setting, and the deep-link alias map is how
    /// `--open-settings-tab` and every setup card reach one.
    ///
    /// Nothing caught this. A whole sub-pane was added, the suite stayed green,
    /// and it was absent from both.
    @MainActor
    func testTheSessionsPaneIsSearchableAndDeepLinkable() throws {
        let registry = try source("Sources/Grux/Settings/SettingsSearchRegistry.swift")
        XCTAssertTrue(registry.contains("\"sessions\""),
                      "no deep-link alias for the sessions sub-pane, so nothing can open it directly")

        let hits = SettingsSearchRegistry.matches("terminal session")
        XCTAssertFalse(hits.isEmpty,
                       "searching Settings for \"terminal session\" finds nothing")

        // The two words a user actually arrives with after reading onboarding.
        for term in ["subscription", "api key"] {
            XCTAssertFalse(SettingsSearchRegistry.matches(term).isEmpty,
                           "searching Settings for \"\(term)\" finds nothing, yet that is the question the pane answers")
        }
    }

    /// CONSENT TRAVELS WITH THE CREDENTIAL SPEND, AT THE SAME SEVERITY.
    ///
    /// The first version of this attached the consent step to `terminal.focus`,
    /// which was wrong twice over. `terminal.focus` is an OBSERVER: a floating
    /// overlay that watches up to four surrounding coding sessions and reads
    /// their window titles. It spawns nothing and spends no credential, so
    /// gating it on consent asked the user to approve something that feature
    /// does not do, while the features that actually drive the CLI stayed
    /// ungated.
    ///
    /// The real signal is `stepAgentCliInstalled`. Wherever driving the CLI
    /// BLOCKS, consent blocks too. Wherever it merely DEGRADES, consent
    /// degrades too. Matching the severity is not cosmetic: `chat` carries the
    /// CLI as optional and is the default landing tab, so a blocking consent
    /// step there would put every new user's first screen into needs-setup.
    @MainActor
    func testConsentIsAttachedWhereverTheAgentCliIs() {
        var checked = 0
        for row in FeatureRegistry.rows {
            let blocksOnCli = row.steps.contains(.stepAgentCliInstalled)
            let degradesOnCli = row.optionalSteps.contains(.stepAgentCliInstalled)
            guard blocksOnCli || degradesOnCli else {
                XCTAssertFalse(row.steps.contains(.stepTerminalSessionsExplained)
                               || row.optionalSteps.contains(.stepTerminalSessionsExplained),
                               "\(row.id) does not drive the agent CLI, so it must not ask for session consent")
                continue
            }
            checked += 1
            if blocksOnCli {
                XCTAssertTrue(row.steps.contains(.stepTerminalSessionsExplained),
                              "\(row.id) blocks on the agent CLI, so consent must block too")
            } else {
                XCTAssertTrue(row.optionalSteps.contains(.stepTerminalSessionsExplained),
                              "\(row.id) degrades without the agent CLI, so consent must only degrade")
                XCTAssertFalse(row.steps.contains(.stepTerminalSessionsExplained),
                               "\(row.id) would be blocked by consent on a path that is merely optional")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5,
                                    "control: found almost no agent-CLI features, so this proves nothing")
    }

    /// The specific catastrophe the rule above prevents, named so it cannot be
    /// refactored away by accident. Chat is where every new user lands.
    @MainActor
    func testChatIsNeverBlockedByTerminalConsent() {
        let chat = FeatureRegistry.rows.first { $0.id == "chat" }
        XCTAssertNotNil(chat, "chat row vanished")
        XCTAssertFalse(chat?.blocking.contains(.stepTerminalSessionsExplained) ?? true,
                       "the default landing tab would be needs-setup on first run for every user")
    }

    /// A BLOCKED FEATURE MUST OFFER A WAY OUT.
    ///
    /// `CapabilitySetupCard` deliberately gives `step.` requirements no button:
    /// "a step is completed by the feature itself, so it gets no button at all
    /// and the sentence explains what will happen." That is right for
    /// `step.first_frame_reviewed`, which you complete by using the feature.
    ///
    /// It is wrong for a CONSENT step. Consent is completed in Settings, the
    /// remediation sentence says so in as many words, and with no button the
    /// card becomes the same dead end that `CapabilityCredentialsSection` was
    /// written to fix for credentials: a sentence telling you to go somewhere,
    /// and no way to get there.
    ///
    /// So the rule is derived, not hardcoded: any step whose remediation
    /// promises Settings must resolve to a destination.
    @MainActor
    func testStepsThatPromiseSettingsCanActuallyGetThere() throws {
        // PRE-EXISTING and deliberately recorded rather than hidden. Both of
        // these promise Settings in their remediation and neither has a home in
        // SettingsView to point at, which is a real gap that predates this work
        // and needs a surface designed, not a route invented. Listing them here
        // keeps the debt visible and still fails the day a NEW step joins them.
        let knownUnrouted: Set<SetupRequirement> = [.stepPhonePaired, .stepYoutubeTranscriptsEnabled]

        var checked = 0
        for req in SetupRequirement.allCases where req.kind == .step {
            guard req.remediation.contains("Settings") else { continue }
            if knownUnrouted.contains(req) {
                XCTAssertNil(SettingsTabAliases.stepDestination(req),
                             "\(req.rawValue) now has a route, so take it off the known-unrouted list")
                continue
            }
            checked += 1
            XCTAssertNotNil(SettingsTabAliases.stepDestination(req),
                            "\(req.rawValue) tells the user to go to Settings and nothing can take them there")
        }
        XCTAssertGreaterThan(checked, 0, "control: no routed steps found, so this proves nothing")
    }

    /// And the card has to actually render the button, not merely be able to.
    func testTheSetupCardOffersAnActionForConsentSteps() throws {
        let card = try source("Sources/Grux/Onboarding/CapabilitySetupCard.swift")
        XCTAssertTrue(card.contains("SettingsTabAliases.stepDestination"),
                      "the card still returns nil for every step, so a consent block has no way out")
    }

    /// THE LANDMINE THIS ALMOST WAS. Adding a BLOCKING requirement to a feature
    /// row makes that feature `needs-setup` forever unless something can also
    /// satisfy it. `stepCompleted` returns false whenever `stepDefaultsKey` is
    /// nil, so a step with no key is permanently unsatisfiable and would have
    /// bricked `terminal.focus` while every other test stayed green.
    ///
    /// It resolves generically off `kind == .step`, so the new requirement is
    /// wired without a special case. This asserts that rather than trusting it.
    @MainActor
    func testTheNewConsentStepIsActuallySatisfiable() throws {
        let req = SetupRequirement.stepTerminalSessionsExplained
        let key = try XCTUnwrap(CapabilityResolver.stepDefaultsKey(for: req),
                                "no defaults key, so this step can never be completed and terminal.focus is bricked")
        XCTAssertEqual(key, "grux.step.terminal_sessions_explained")

        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        CapabilityResolver.markStepCompleted(req, false)
        XCTAssertFalse(CapabilityResolver.isSatisfied(req), "control: it should read false when cleared")
        CapabilityResolver.markStepCompleted(req, true)
        XCTAssertTrue(CapabilityResolver.isSatisfied(req), "marking it complete did not satisfy it")
    }

    /// And the capability has to be REPRESENTED, not just described. Without a
    /// requirement the gate cannot hold the feature closed until the user has
    /// actually been shown what it does.
    func testAConsentRequirementExistsForDrivingTerminalSessions() throws {
        let contract = try source("Sources/Grux/Onboarding/SetupContract.swift")
        XCTAssertTrue(contract.contains("step.terminal_sessions_explained"),
                      """
                      There is no setup requirement representing "the user has been shown what a \
                      headless session does and whose credentials it spends". Without one, the \
                      capability gate has nothing to hold closed.
                      """)
    }
}
