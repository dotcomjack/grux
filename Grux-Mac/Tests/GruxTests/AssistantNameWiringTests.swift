import XCTest
@testable import Grux

/// `config.assistantName` must actually change what the assistant calls itself.
///
/// It did not. The field existed, the decoder had a default, the contract
/// documented it, and NOTHING read it: `JaxProfile.persona` was a stored `let`
/// with the name hardcoded twice. So it was a config key with no effect, which
/// under this repo's own rule is not a feature but dead code wearing a setting.
///
/// It surfaced from the other end. Trying to mutation-prove a different test, a
/// planted string inside `UserIdentity.assistantName` never reached the binary,
/// because the whole property was dead-stripped for having no callers.
@MainActor
final class AssistantNameWiringTests: XCTestCase {

    private var original = ""

    override func setUp() async throws {
        original = AppState.shared.config.assistantName
    }

    override func tearDown() async throws {
        AppState.shared.config.assistantName = original
    }

    /// The whole point: set the name, and the text sent to the model uses it.
    func testRenamingTheAssistantChangesThePersonaSentToTheModel() {
        AppState.shared.config.assistantName = "Ada"
        let persona = JaxProfile.shared.persona

        XCTAssertTrue(persona.contains("You are Ada"),
            "the persona does not open with the configured name, so renaming the assistant "
            + "changes nothing the model ever sees")
        XCTAssertFalse(persona.contains("You are Jax"),
            "the default name is still hardcoded in the persona alongside the configured one")
    }

    /// Every self-reference moves, not just the first. The persona named itself
    /// twice, and a fix that interpolated only the opening line would leave the
    /// assistant contradicting itself mid-prompt.
    func testNoSelfReferenceIsLeftBehind() {
        AppState.shared.config.assistantName = "Ada"
        XCTAssertFalse(JaxProfile.shared.persona.contains("Jax"),
            "a hardcoded self-reference survives somewhere in the persona body")
    }

    /// Wiring a setting up must not silently rename an existing install's
    /// assistant. The default is the name the persona already shipped with.
    func testTheDefaultPreservesShippedBehaviour() {
        AppState.shared.config.assistantName = ""
        XCTAssertEqual(UserIdentity.assistantName, "Jax",
            "an empty setting must fall back to the name the persona already used")
        XCTAssertTrue(JaxProfile.shared.persona.contains("You are Jax"))
    }

    /// Whitespace is not a rename. Someone clearing the field leaves a space
    /// behind more often than not.
    func testWhitespaceOnlyFallsBackRatherThanNamingNobody() {
        AppState.shared.config.assistantName = "   "
        XCTAssertEqual(UserIdentity.assistantName, "Jax")
        XCTAssertFalse(JaxProfile.shared.persona.contains("You are    "),
            "a whitespace name reached the prompt, so the assistant introduces itself as nothing")
    }

    /// Renaming the ASSISTANT must not rename the APP. Grux is the application;
    /// Jax is the assistant it runs. The bundle id, the support directory and the
    /// `Jax HQ` / `Jax Command` tabs are product identity, not a self-reference,
    /// and moving them would revoke TCC grants and strand user data.
    func testRenamingTheAssistantDoesNotTouchProductIdentity() {
        AppState.shared.config.assistantName = "Ada"
        XCTAssertEqual(KeychainStore.service, "com.gruxai.grux",
                       "the Keychain service moved, which would strand every stored credential")
        XCTAssertTrue(Persistence.supportDir.path.contains("Grux"),
                      "the support directory moved, which would strand all user data")
    }

    /// The Settings copy promises "takes effect on the next message", so the
    /// persona must NOT be cached. Reading it twice from the same instance across
    /// a config change has to give two different answers.
    ///
    /// This is the assertion that would have failed against the original `let
    /// persona: String = """..."""`, and it is the one that keeps a future
    /// optimisation from quietly reintroducing the bug by memoising it.
    func testThePersonaIsNotCachedAcrossAConfigChange() {
        let profile = JaxProfile.shared

        AppState.shared.config.assistantName = "Ada"
        let first = profile.persona

        AppState.shared.config.assistantName = "Bea"
        let second = profile.persona

        XCTAssertTrue(first.contains("You are Ada"))
        XCTAssertTrue(second.contains("You are Bea"),
            "the persona is cached, so renaming the assistant needs a relaunch and the "
            + "Settings copy promising otherwise is a lie")
        XCTAssertNotEqual(first, second)
    }

    /// The user's name and the assistant's name are different fields and must not
    /// be crossed, which is exactly the kind of wiring mistake this change could
    /// have introduced.
    func testTheUsersNameAndTheAssistantsNameAreIndependent() {
        AppState.shared.config.assistantName = "Ada"
        let before = UserIdentity.name
        XCTAssertNotEqual(UserIdentity.assistantName, before,
                          "setting the assistant name changed the user's name")
        XCTAssertEqual(UserIdentity.assistantName, "Ada")
    }
}

/// Onboarding must ask who the user is before it asks for anything expensive.
@MainActor
final class OnboardingAsksNameFirstTests: XCTestCase {

    /// At EVERY level. A level that skips the name would greet somebody by nobody
    /// for the life of the install, and the levels are the one thing that varies.
    func testIdentityIsTheFirstQuestionAtEveryLevel() {
        for level in OnboardingModel.Level.allCases {
            let stages = OnboardingModel.stages(for: level)
            guard let levelIdx = stages.firstIndex(of: .level),
                  let identityIdx = stages.firstIndex(of: .identity) else {
                XCTFail("\(level) has no identity stage, so it never asks the user's name")
                continue
            }
            XCTAssertEqual(identityIdx, levelIdx + 1,
                "at level \(level) the first thing asked after choosing a level is "
                + "\(stages[levelIdx + 1]), not the user's name. Order: \(stages)")
        }
    }

    /// Specifically before the model key. Asking for a pasted credential before
    /// asking someone's name is the order this replaced.
    func testTheNameIsAskedBeforeTheApiKey() {
        for level in OnboardingModel.Level.allCases {
            let stages = OnboardingModel.stages(for: level)
            guard let identity = stages.firstIndex(of: .identity),
                  let modelKey = stages.firstIndex(of: .modelKey) else { continue }
            XCTAssertLessThan(identity, modelKey,
                "at level \(level) the API key is requested before the user's name")
        }
    }
}
