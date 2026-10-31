import XCTest
@testable import Grux

/// D40: THE SUITE NEVER TALKS TO THE PERSON'S OWN OLLAMA. Measured on the Mini
/// 2026-10-29 (Ollama's log during a full run): 12 `/api/chat`, version and tag
/// calls from the test process. `WorkflowGateAnswerTests` sent chat turns with
/// offline mode on and reached whatever model was installed, so a result
/// depended on the Mac, and every call could evict the person's loaded model.
/// AppState's discovery at launch also probed it, and discovery may adopt a
/// model into the config. A test that wants a server starts a loopback stub and
/// points the config at it; the live tests opt in with `GRUX_OLLAMA_LIVE=1`.
@MainActor
final class SuiteNeverReachesLocalModelTests: XCTestCase {

    /// A run with the live opt-in reads the configured address on purpose.
    private var live: Bool { ProcessInfo.processInfo.environment["GRUX_OLLAMA_LIVE"] == "1" }

    func test_underTestTheLocalModelAddressIsOneNothingServes() throws {
        // A fresh install's config, which names the real Ollama.
        let stored = GruxConfig.default
        XCTAssertEqual(stored.ollamaBaseURL, "http://localhost:11434")
        let pinned = AppState.pinnedForTests(stored, environment: [:])
        XCTAssertEqual(pinned.ollamaBaseURL, Persistence.testLocalModelBaseURL)
        let url = try XCTUnwrap(URL(string: pinned.ollamaBaseURL))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertNotEqual(url.port, 11434, "the port every Ollama serves on")
    }

    /// The opt-in keeps what the config says, so the live tests still reach it.
    func test_theLiveOptInKeepsTheConfiguredAddress() {
        var stored = GruxConfig.default
        stored.ollamaBaseURL = "http://localhost:11434"
        XCTAssertEqual(AppState.pinnedForTests(stored, environment: ["GRUX_OLLAMA_LIVE": "1"]).ollamaBaseURL,
                       "http://localhost:11434")
        XCTAssertEqual(AppState.pinnedForTests(stored, environment: ["GRUX_OLLAMA_LIVE": "0"]).ollamaBaseURL,
                       Persistence.testLocalModelBaseURL)
    }

    /// What the shared AppState reads in this process, unless a test pointed it
    /// at its own stub and put it back.
    func test_theSharedConfigStartsPinned() throws {
        XCTAssertEqual(AppState.shared.config.ollamaBaseURL,
                       live ? Persistence.load(GruxConfig.self, from: Persistence.configURL, fallback: .default).ollamaBaseURL
                            : Persistence.testLocalModelBaseURL)
    }

    /// And nothing answers there: discovery finds no server, on this Mini as on
    /// a Mac with no Ollama.
    func test_discoveryUnderTestFindsNoServer() async throws {
        let saved = AppState.shared.config.ollamaBaseURL
        defer { AppState.shared.config.ollamaBaseURL = saved; ModelRegistry.shared.resetLocalForTest() }
        AppState.shared.config.ollamaBaseURL = Persistence.testLocalModelBaseURL
        await ModelRegistry.shared.discoverLocal()
        XCTAssertNil(ModelRegistry.shared.local)
        XCTAssertEqual(ModelRegistry.shared.localTags, [])
    }
}
