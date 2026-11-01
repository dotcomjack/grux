import XCTest
@testable import Grux

/// release/3.2: the stable prefix is read at launch and on becoming active
/// when the local model is not loaded, so the first turn is not a cold read
/// (measured 2026-10-31 on the 16 GB Mac mini: turns 1 and 2 took 6.18 s and
/// 5.46 s with nothing warmed, about 1 s after).
@MainActor
final class LocalWarmAtLaunchTests: XCTestCase {
    func test_warmsOnlyALocalRouteWhoseModelIsNotLoaded() {
        func warm(local: Bool = true, loopback: Bool = true, installed: Bool = true, listed: Bool? = false,
                  thinking: Bool = false, warming: Bool = false, headroom: MachineLoad.Headroom = .full) -> Bool {
            LocalModelReset.shouldWarm(localTurn: local, loopback: loopback, installed: installed, listed: listed,
                                       thinking: thinking, warming: warming, headroom: headroom)
        }
        XCTAssertTrue(warm())
        XCTAssertFalse(warm(local: false), "a cloud route")
        XCTAssertFalse(warm(loopback: false), "a server elsewhere")
        XCTAssertFalse(warm(installed: false), "a model the server does not hold")
        XCTAssertFalse(warm(listed: true), "already loaded")
        XCTAssertFalse(warm(listed: nil), "Ollama did not answer")
        XCTAssertFalse(warm(thinking: true), "a person's turn wins")
        XCTAssertFalse(warm(warming: true), "one warm-up at a time")
        XCTAssertFalse(warm(headroom: .reduced), "memory pressure: MachineLoad unloads, a warm-up would reload")
        XCTAssertFalse(warm(headroom: .minimal))
    }

    /// A failed warm call warmed nothing and must not read as warmed; a route
    /// that is not local does not probe for a server at every activation; and
    /// a warm-up's own calls do not count as use for the idle reset.
    func test_theWarmUpReportsFailureAndLeavesCloudRoutesAlone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let warmFn = try XCTUnwrap(chat.range(of: "func warmLocalPrefix() async -> Bool {"))
        let body = chat[warmFn.upperBound...].prefix(2_000)
        XCTAssertFalse(body.contains("try? await routing.backend.completeWithTools"), "a failed call counts as warmed")
        XCTAssertTrue(body.contains("} catch {\n                return false"))
        let reset = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Backend/LocalModelReset.swift"),
                               encoding: .utf8)
        let fn = try XCTUnwrap(reset.range(of: "func warmIfCold() async {"))
        let cold = String(reset[fn.upperBound...].prefix(3_000))
        let guardAt = try XCTUnwrap(cold.range(of: "guard routedLocal else { return }"))
        let discover = try XCTUnwrap(cold.range(of: "await registry.discoverLocal()"))
        XCTAssertLessThan(guardAt.lowerBound, discover.lowerBound, "a cloud route probes for a server first")
        XCTAssertTrue(cold.contains("checkedThrough = LocalModelUnload.lastUse() ?? checkedThrough"))
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
