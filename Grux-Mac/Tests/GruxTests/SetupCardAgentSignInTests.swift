import XCTest
@testable import Grux

/// D70 (sense pass 5, `jaxCommand-1.png`): Jax Command's setup card read "One
/// item is missing. Everything else is ready." while the Claude sign-in had
/// expired and no agent could run. The agent tool step counts as done when the
/// binary is on disk, so the card credited it as ready. The card now lists the
/// sign-in whenever a feature it stands in for needs the agent and the last
/// agent run found the sign-in expired, and stops counting that step as ready.
@MainActor
final class SetupCardAgentSignInTests: XCTestCase {

    private let agentFeature: [SetupRequirement] = [.stepAgentCliInstalled, .stepCorpusSourcesConfirmed,
                                                    .stepTerminalSessionsExplained]

    func test_anExpiredSignInIsListedWhenTheFeatureNeedsTheAgent() {
        XCTAssertTrue(CapabilitySetupCard.listsAgentSignIn(blocking: agentFeature,
                                                           missing: [.stepCorpusSourcesConfirmed],
                                                           signInExpired: true))
    }

    func test_aSignInThatWorksIsNotListed() {
        XCTAssertFalse(CapabilitySetupCard.listsAgentSignIn(blocking: agentFeature,
                                                            missing: [.stepCorpusSourcesConfirmed],
                                                            signInExpired: false))
    }

    /// With the tool not installed the card already lists installing it, and
    /// the sign-in comes after that.
    func test_aMissingToolIsListedOnceNotTwice() {
        XCTAssertFalse(CapabilitySetupCard.listsAgentSignIn(blocking: agentFeature,
                                                            missing: [.stepAgentCliInstalled],
                                                            signInExpired: true))
    }

    /// A feature that runs without the agent (or only uses it optionally)
    /// says nothing about the sign-in.
    func test_aFeatureThatDoesNotNeedTheAgentSaysNothing() {
        XCTAssertFalse(CapabilitySetupCard.listsAgentSignIn(blocking: [.endpointImap],
                                                            missing: [.endpointImap],
                                                            signInExpired: true))
    }

    /// The screen that was filed: Jax Command, the tool installed, terminal
    /// sessions explained, the corpus not chosen, the sign-in expired.
    func test_jaxCommandWithAnExpiredSignInNamesBothAndCreditsOnlyTheRest() throws {
        let row = try XCTUnwrap(FeatureRegistry.row(forTab: "jaxCommand"))
        let blocking = row.requires + row.steps
        XCTAssertTrue(blocking.contains(.stepAgentCliInstalled),
                      "Jax Command stopped needing the agent; this test no longer covers the filed screen")
        let missing: [SetupRequirement] = [.stepCorpusSourcesConfirmed]
        let copy = CapabilitySetupCard.copy(featureLabel: row.label, blocking: blocking,
                                            listedEntries: 1, missing: missing, signInExpired: true)
        XCTAssertEqual(copy.headline, "Jax Command needs 2 more things")
        // Three blocking steps, the corpus missing, the agent unusable: only
        // terminal sessions is ready.
        XCTAssertEqual(copy.subtitle, "Everything else is ready.")

        let signedIn = CapabilitySetupCard.copy(featureLabel: row.label, blocking: blocking,
                                                listedEntries: 1, missing: missing, signInExpired: false)
        XCTAssertEqual(signedIn.headline, "Jax Command needs one more thing")
        XCTAssertEqual(signedIn.subtitle, "Everything else is ready.")
    }

    /// When the sign-in is the only thing the agent step had going for it and
    /// nothing else is ready, the card must not say the rest is ready.
    func test_theSignInIsNotCountedAsReady() {
        let copy = CapabilitySetupCard.copy(featureLabel: "Agents", blocking: [.stepAgentCliInstalled],
                                            listedEntries: 0, missing: [], signInExpired: true)
        XCTAssertEqual(copy.headline, "Agents needs one more thing")
        XCTAssertEqual(copy.subtitle, "Once this is done, it is ready.")
    }

    /// The listed item says what to do in the same words the Now row uses.
    func test_theSignInItemSaysWhatHappensAndWhatToDo() {
        XCTAssertEqual(CapabilitySetupCard.agentSignInLabel, "Claude sign-in expired")
        XCTAssertTrue(CapabilitySetupCard.agentSignInRemediation.hasPrefix("Agents cannot run until you sign in"))
        XCTAssertEqual(CapabilitySetupCard.agentSignInButton, "Sign in")
    }

    /// D116 item 3: Jax Command's card said "Agents cannot run until you sign
    /// in again." under "Jax Command needs 2 more things", naming a feature
    /// the person was not looking at. Each card names its own feature; the
    /// Agents card keeps its line.
    func test_theSignInLineNamesTheCardsOwnFeature() {
        XCTAssertEqual(CapabilitySetupCard.agentSignInRemediation(featureLabel: "Agents"),
                       CapabilitySetupCard.agentSignInRemediation)
        XCTAssertEqual(CapabilitySetupCard.agentSignInRemediation(featureLabel: "Jax Command"),
                       "What Jax Command hands to Claude cannot run until you sign in. "
                       + "Sign in opens Claude's login in Terminal, and it finishes in your browser.")
        XCTAssertTrue(CapabilitySetupCard.agentSignInRemediation(featureLabel: "This feature")
            .hasPrefix("What this feature hands to Claude cannot run"))
        for label in ["Jax Command", "Social", "Research"] {
            let line = CapabilitySetupCard.agentSignInRemediation(featureLabel: label)
            XCTAssertTrue(line.contains(label), label)
            XCTAssertFalse(line.contains("Agents"), label)
        }
    }
}
