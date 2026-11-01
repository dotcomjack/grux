import XCTest
@testable import Grux

/// release/3.2: the stable prefix is read at launch and on becoming active
/// when the local model is not loaded, so the first turn is not a cold read
/// (measured 2026-10-31 on the 16 GB Mac mini: turns 1 and 2 took 6.18 s and
/// 5.46 s with nothing warmed, about 1 s after).
@MainActor
final class LocalWarmAtLaunchTests: XCTestCase {
    func test_warmsOnlyALocalRouteWhoseModelIsNotLoaded() {
        XCTAssertTrue(LocalModelReset.shouldWarm(localTurn: true, loopback: true, listed: false,
                                                 thinking: false, warming: false))
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: false, loopback: true, listed: false,
                                                  thinking: false, warming: false), "a cloud route")
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: true, loopback: false, listed: false,
                                                  thinking: false, warming: false), "a server elsewhere")
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: true, loopback: true, listed: true,
                                                  thinking: false, warming: false), "already loaded")
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: true, loopback: true, listed: nil,
                                                  thinking: false, warming: false), "Ollama did not answer")
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: true, loopback: true, listed: false,
                                                  thinking: true, warming: false), "a person's turn wins")
        XCTAssertFalse(LocalModelReset.shouldWarm(localTurn: true, loopback: true, listed: false,
                                                  thinking: false, warming: true), "one warm-up at a time")
    }

    /// Launch and becoming active both ask; the warm-up itself is the one a
    /// reset uses, so it keeps its guards (a person's turn cancels it, and
    /// each call waits behind LocalModelGate).
    func test_launchAndBecomingActiveBothWarm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching("))
        let active = try XCTUnwrap(app.range(of: "func applicationDidBecomeActive("))
        let calls = app.ranges(of: "await LocalModelReset.shared.warmIfCold()")
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.contains { $0.lowerBound > launch.upperBound && $0.lowerBound < active.lowerBound })
        XCTAssertTrue(calls.contains { $0.lowerBound > active.upperBound })
        let reset = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Backend/LocalModelReset.swift"),
                               encoding: .utf8)
        XCTAssertTrue(reset.contains("let task = Task { await ChatService.shared.warmLocalPrefix() }\n        warmTask = task"),
                      "the launch warm-up is not the cancellable one")
    }
}
