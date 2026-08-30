import XCTest
@testable import Grux

/// A Mac with a local model serving and no key still sent every turn to Anthropic.
///
/// Reported from the Mac Mini, 2026-08-30. Setup finished, "Hi Grux" came back as
/// an HTTP 400 from Anthropic, and the machine had qwen3:8b loaded and idle the
/// whole time. The chat footer was printing "cheaper: qwen3:8b free" directly
/// underneath the failure, which is the app naming the answer while routing away
/// from it.
///
/// Every branch of `resolvedProvider` used to end at `.anthropic`. The downgrade
/// existed in one direction only: a local selection with nothing discovered fell
/// back to Anthropic, and an Anthropic selection with nothing to authenticate
/// with fell nowhere.
final class NoKeyRoutesLocalTests: XCTestCase {

    /// The reported case. No key, a local model present, so route to it.
    func testNoKeyWithALocalModelRoutesLocal() {
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: false, hasLocal: true), .local)
    }

    /// A key present still routes to Anthropic even when a local model exists.
    ///
    /// The fallback must not become a preference. Somebody who has paid for a key
    /// and has Ollama installed for other reasons has not asked to be moved onto
    /// a smaller model, and silently doing it would be the same class of surprise
    /// as the bug, pointing the other way.
    func testAKeyStillWinsWhenBothAreAvailable() {
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: true, hasLocal: true), .anthropic)
    }

    /// No key and nothing local: still Anthropic, because there is nowhere else.
    ///
    /// ChatReadiness already has a sentence for this state. A route pointing at a
    /// local server that is not there would be worse than one pointing at a
    /// provider with no key: both fail, but only one of them can explain itself.
    func testNoKeyAndNoLocalStaysOnAnthropicSoTheFailureCanExplainItself() {
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: false, hasLocal: false), .anthropic)
    }

    /// A key and no local model is the ordinary configuration and is unchanged.
    func testTheOrdinaryConfigurationIsUnchanged() {
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: true, hasLocal: false), .anthropic)
    }

    /// The route is decided by the presence of a key, never by whether it works.
    ///
    /// "Is there a key" is free and cannot be got wrong. "Does the key work" costs
    /// a request and is only knowable by spending one, and a router that guessed
    /// at it would move somebody onto a local model over one rate limit. A key
    /// that exists and is refused belongs to the gate that validates it.
    func testTheDecisionUsesPresenceAndNotValidity() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Backend/ModelRegistry.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        // `Self.` matters: without it this matched the func DECLARATION, which
        // sits above the call and mentions the parameter label without the
        // argument, so the assertion failed against correct code.
        guard let call = lines.first(where: { $0.contains("Self.anthropicRoute(hasKey:") })
        else { return XCTFail("resolvedProvider no longer consults the route helper.") }
        XCTAssertTrue(call.contains("KeychainStore.exists(.anthropicApiKey)"),
                      "The route is no longer decided by whether a key is present.")
    }
}
