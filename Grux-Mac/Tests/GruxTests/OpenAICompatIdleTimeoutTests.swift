import XCTest
@testable import Grux

/// The first local chat turn after a relaunch timed out (ledger A26).
///
/// A streamed call sends nothing until the model has read the whole prompt.
/// On a 16 GB Mac mini with qwen2.5:7b, a cold read of a 16,000 to 22,600
/// token Grux prompt took 109 to 111 s, and the 22,600 token one was cut off
/// by the 120 s idle timeout twice (Ollama log: `500 | 2m0s | POST /api/chat`
/// at 18:52:21 and 19:03:10), so Chat said the model did not answer in time
/// while it was still reading. A local server has no network to stall on:
/// its silence is compute, so its idle limit has to cover a cold read.
final class OpenAICompatIdleTimeoutTests: XCTestCase {

    func test_localServer_waitsLongerThanAColdPromptReadOnASmallMac() {
        for base in ["http://localhost:11434", "http://127.0.0.1:1234", "http://studio.local:11434"] {
            XCTAssertGreaterThanOrEqual(OpenAICompatBackend.requestIdleTimeout(baseURL: base), 300, base)
        }
    }

    func test_hostedEndpoint_keepsTheShortIdleLimit() {
        XCTAssertEqual(OpenAICompatBackend.requestIdleTimeout(baseURL: "https://openrouter.ai/api"), 120)
    }

    func test_theIdleLimitNeverOutlastsTheWholeCall() {
        XCTAssertLessThan(OpenAICompatBackend.requestIdleTimeout(baseURL: "http://localhost:11434"),
                          OpenAICompatBackend.requestResourceTimeout)
    }
}
