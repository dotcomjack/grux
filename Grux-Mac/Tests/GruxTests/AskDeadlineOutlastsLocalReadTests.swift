import XCTest
@testable import Grux

/// `grux ask` gave up at 150 s on a turn a cold local model answered at 180 s
/// (ledger A26b): the CLI said "still working" and the answer landed only in
/// the chat window. The ask has to outwait the local backend's own idle
/// limit, so the backend, not the wait, decides whether a local turn failed,
/// and the CLI socket has to outwait the ask, so the app tells the story.
final class AskDeadlineOutlastsLocalReadTests: XCTestCase {

    func test_theAskOutwaitsTheLocalIdleLimit() {
        XCTAssertGreaterThan(GruxControlTools.askDeadlineSeconds,
                             OpenAICompatBackend.requestIdleTimeout(baseURL: "http://localhost:11434"))
    }

    func test_theCLISocketOutwaitsTheAsk() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Commands/Ask.swift")
        let code = try String(contentsOf: src, encoding: .utf8)
        let needle = "static let waitSeconds: TimeInterval = "
        let at = try XCTUnwrap(code.range(of: needle), "Ask.swift no longer names waitSeconds")
        let wait = try XCTUnwrap(Double(code[at.upperBound...].prefix { $0.isNumber || $0 == "." }))
        XCTAssertGreaterThan(wait, GruxControlTools.askDeadlineSeconds)
    }
}
