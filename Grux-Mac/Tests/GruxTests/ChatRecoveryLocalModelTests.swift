import XCTest
@testable import Grux

// A turn served by a model on this Mac (Ollama, LM Studio) that fails at the
// URL layer never crossed the network. Measured on a keyless install: three
// chat turns sent within 10 s, Ollama busy with the first two, the third timed
// out and Chat said "Network unreachable. Check your connection and retry."
// while the connection was fine. The person then checks Wi-Fi for a problem
// that is the local model being busy or not running.
@MainActor
final class ChatRecoveryLocalModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppState.shared.offlineMode = false
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() {
        AppState.shared.offlineMode = false
        super.tearDown()
    }

    private func urlError(_ code: Int, _ url: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: url)!,
            NSURLErrorFailingURLStringErrorKey: url,
        ])
    }

    func test_aTimeoutFromTheLocalModelNamesTheBusyModelNotTheNetwork() {
        for url in ["http://localhost:11434/api/chat",
                    "http://127.0.0.1:11434/api/chat",
                    "http://[::1]:1234/v1/chat/completions"] {
            let r = ChatService.classifyChatFailure(
                error: urlError(NSURLErrorTimedOut, url),
                userText: "third turn", imageData: nil, imageMediaType: nil
            )
            let m = r.message.lowercased()
            XCTAssertFalse(m.contains("network"), "\(url): \(r.message)")
            XCTAssertFalse(m.contains("connection"), "\(url): \(r.message)")
            XCTAssertTrue(m.contains("local model"), "\(url): \(r.message)")
            XCTAssertTrue(m.contains("busy"), "\(url): \(r.message)")
            XCTAssertEqual(r.kind, .generic, "Continue offline cannot help when the offline model is the one that failed")
            XCTAssertEqual(r.retryText, "third turn")
        }
    }

    func test_aLocalServerThatIsNotRunningSaysSo() {
        let r = ChatService.classifyChatFailure(
            error: urlError(NSURLErrorCannotConnectToHost, "http://127.0.0.1:11434/api/chat"),
            userText: "hi", imageData: nil, imageMediaType: nil
        )
        let m = r.message.lowercased()
        XCTAssertFalse(m.contains("network"), r.message)
        XCTAssertTrue(m.contains("local model"), r.message)
        XCTAssertTrue(m.contains("not running") || m.contains("start"), r.message)
        XCTAssertEqual(r.kind, .generic)
    }

    func test_aCloudTimeoutIsStillTheNetwork() {
        let r = ChatService.classifyChatFailure(
            error: urlError(NSURLErrorTimedOut, "https://api.anthropic.com/v1/messages"),
            userText: "hi", imageData: nil, imageMediaType: nil
        )
        XCTAssertTrue(r.message.lowercased().contains("network"), r.message)
    }
}
