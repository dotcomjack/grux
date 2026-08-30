import XCTest
@testable import Grux

/// The gate whose whole job is checking the key said the key was fine.
///
/// Reported from the Mac Mini, 2026-08-30. The owner completed onboarding,
/// believed he was set up because nothing had said otherwise, opened Chat, sent
/// "Hi Grux" and got:
///
///     anthropic-workspace-id is required when authenticating with an
///     identity-linked API key; send the id of the workspace this request acts
///     in. (HTTP 400)
///
/// `validate(key:)` had already made that exact call during setup and received
/// that exact 400. It fell into a `default:` branch commented "Provider trouble
/// is not the user's problem", which returned true, saved the key, and let the
/// flow finish. The comment was right about 500s and wrong about 400s, and the
/// cost of the difference was somebody learning their setup was broken at the
/// first thing they tried to do with it.
final class KeyGateHonestyTests: XCTestCase {

    private typealias Verdict = OnboardingModel.KeyVerdict

    /// The exact body Anthropic returned on the reported run.
    private var workspaceBody: Data {
        Data("""
        {"type":"error","error":{"type":"invalid_request_error","message":\
        "anthropic-workspace-id is required when authenticating with an identity-linked \
        API key; send the id of the workspace this request acts in."}}
        """.utf8)
    }

    /// The reported case, end to end through the decision.
    func testTheWorkspaceScopedKeyIsRefusedAtTheGate() {
        let verdict = OnboardingModel.verdict(status: 400, body: workspaceBody)
        guard case .reject(let why) = verdict else {
            return XCTFail("A 400 accepted the key again, which is the reported bug.")
        }
        XCTAssertTrue(why.contains("workspace"),
                      "The message does not say what is actually wrong: \(why)")
        XCTAssertTrue(why.contains("console.anthropic.com"),
                      "The message does not say where to get a key that works: \(why)")
    }

    /// It must not simply parrot the API at somebody holding a key.
    ///
    /// "send the id of the workspace this request acts in" is an instruction to
    /// a program. The design bar for this codebase is that an error says what to
    /// DO, so the human sentence has to be Grux's own.
    func testTheMessageIsWrittenForAPersonAndNotForAProgram() {
        guard case .reject(let why) = OnboardingModel.verdict(status: 400, body: workspaceBody)
        else { return XCTFail("expected a rejection") }
        XCTAssertFalse(why.hasPrefix("anthropic-workspace-id"),
                       "The raw API string is being shown as the whole message.")
        XCTAssertTrue(why.contains("local model"),
                      "The message does not offer the way forward that does not need a key.")
    }

    /// Anything genuinely on the provider's side still passes.
    ///
    /// This is the half the old comment got right, and it must not regress into
    /// blaming a user for an outage.
    func testProviderTroubleStillLetsTheUserThrough() {
        for status in [500, 502, 503, 529] {
            XCTAssertEqual(OnboardingModel.verdict(status: status, body: Data()), .accept,
                           "status \(status) refused a key over a provider fault")
        }
    }

    /// Rate limiting means the key WORKS.
    func testRateLimitingIsNotABadKey() {
        XCTAssertEqual(OnboardingModel.verdict(status: 429, body: Data()), .accept)
    }

    /// The ordinary success and the ordinary rejection.
    func testTheOrdinaryOutcomesAreUnchanged() {
        XCTAssertEqual(OnboardingModel.verdict(status: 200, body: Data()), .accept)
        for status in [401, 403] {
            guard case .reject(let why) = OnboardingModel.verdict(status: status, body: Data())
            else { return XCTFail("status \(status) should reject") }
            XCTAssertTrue(why.contains("copied"), "unhelpful message for \(status): \(why)")
        }
    }

    /// A 400 with nothing useful in it still has to refuse, and still has to
    /// leave the person somewhere they can go.
    func testAnUnexplained400StillRefusesAndStillOffersAWayForward() {
        for body in [Data(), Data("not json".utf8), Data("{}".utf8)] {
            guard case .reject(let why) = OnboardingModel.verdict(status: 400, body: body)
            else { return XCTFail("an unexplained 400 accepted the key") }
            XCTAssertTrue(why.contains("local model"),
                          "no way forward offered: \(why)")
        }
    }

    /// The parser reads the provider's own sentence when there is one.
    func testTheProvidersOwnMessageIsRead() {
        XCTAssertEqual(
            OnboardingModel.apiErrorMessage(from: Data(#"{"error":{"message":"nope"}}"#.utf8)),
            "nope")
        XCTAssertEqual(OnboardingModel.apiErrorMessage(from: Data("garbage".utf8)), "")
    }
}
