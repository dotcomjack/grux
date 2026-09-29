import AppKit
import Combine
import XCTest
@testable import Grux

/// The orbs are on screen all day, the Focus pill on every Space. Their motion
/// moved from SwiftUI `repeatForever` onto Core Animation on 2026-09-21, because
/// a SwiftUI loop re-renders the window on the main thread every frame and a CA
/// loop is interpolated by the render server for nothing. Measured before the
/// move, muted, main window off screen: 33.3% of a core, the display cycle
/// taking 1248 of 4103 main thread samples.
@MainActor
final class OrbRenderServerTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/" + rel), encoding: .utf8)
    }

    /// Code only, so a comment explaining the history does not trip the guard.
    private func code(_ rel: String) throws -> String {
        try source(rel).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_theAlwaysOnScreenOrbsDoNotLoopInSwiftUI() throws {
        for file in ["OrbView.swift", "FocusOverlayView.swift"] {
            let src = try code(file)
            XCTAssertFalse(src.contains("repeatForever"),
                           "\(file) loops in SwiftUI again, which re-renders its window every frame")
            XCTAssertFalse(src.contains("TimelineView(.animation"),
                           "\(file) ticks a TimelineView, the same per-frame cost")
        }
        XCTAssertTrue(try code("OrbView.swift").contains("OrbCoreLayer("))
        XCTAssertTrue(try code("FocusOverlayView.swift").contains("OrbCoreLayer("))
    }

    /// The Focus pill held the motion gate open forever, because it is always
    /// on screen. It must not count, and it must not count BY OPTING IN, so a
    /// new always-on panel decides on purpose.
    func test_aRenderServerWindowDoesNotHoldTheGateOpen() throws {
        final class Pill: NSObject, MotionLivesOnTheRenderServer {}
        final class Ordinary: NSObject {}
        XCTAssertFalse(MotionSuspension.keepsMotionAlive(Pill(), isVisible: true, onScreen: true))
        XCTAssertTrue(MotionSuspension.keepsMotionAlive(Ordinary(), isVisible: true, onScreen: true),
                      "an ordinary visible window must still keep its animations alive")
        XCTAssertFalse(MotionSuspension.keepsMotionAlive(Ordinary(), isVisible: true, onScreen: false))
        XCTAssertFalse(MotionSuspension.keepsMotionAlive(Ordinary(), isVisible: false, onScreen: true))
        XCTAssertTrue(try source("FocusOverlayController.swift")
            .contains("class FocusOverlayPanel: NSPanel, MotionLivesOnTheRenderServer"),
                      "the Focus pill's panel must opt out of the gate")
    }

    /// Same angular speed as the SwiftUI turn it replaced (phase * 18 degrees,
    /// phase 0 to 2 pi per period), as one seamless full turn instead of a
    /// 113 degree sweep that snapped back.
    func test_theTurnKeepsItsOldSpeedWithoutTheSnap() throws {
        let oldDegreesPerSecond = (2 * Double.pi * 18) / MotionTokens.orbRotationPeriod
        XCTAssertEqual(360 / OrbView.turnSeconds, oldDegreesPerSecond, accuracy: 0.0001)

        let turn = try XCTUnwrap(OrbMotion.turn(seconds: OrbView.turnSeconds),
                                 "the default palette does not ask for stillness")
        XCTAssertEqual(turn.keyPath, "transform.rotation.z")
        XCTAssertEqual(turn.fromValue as? Double, 0)
        XCTAssertEqual(turn.toValue as? Double, -2 * Double.pi, "a full turn, clockwise")
        XCTAssertEqual(turn.repeatCount, .infinity)
        XCTAssertFalse(turn.isRemovedOnCompletion)
    }

    /// The rings keep the poses the SwiftUI version actually animated between.
    func test_theRingsKeepTheirPoses() throws {
        let rings = OrbView.rings(for: .listening)
        XCTAssertEqual(rings.map(\.scale), [1.0...1.6, 1.315...1.585])
        XCTAssertEqual(rings.map(\.opacity.from), [1, 0.7])
        XCTAssertTrue(rings.allSatisfy { $0.seconds == MotionTokens.orbPulsePeriod })
        let group = try XCTUnwrap(OrbMotion.ring(rings[0]))
        XCTAssertEqual(group.repeatCount, .infinity)
        XCTAssertEqual(group.animations?.count, 2)
    }

    /// Turning reduce motion on must stop an orb that is already turning, and
    /// turning it off must start it again, with no colour change to prompt a
    /// rebuild. The Focus pill is built once and never rebuilt on a theme
    /// change, so before this the toggle was ignored until the next state
    /// change. Found by the independent review of P-R-8.
    func test_aLiveReduceMotionToggleReachesATurningOrb() {
        let savedStill = OrbMotion.stillness, savedChanged = OrbMotion.preferenceChanged
        defer { OrbMotion.stillness = savedStill; OrbMotion.preferenceChanged = savedChanged }
        var still = false
        let changed = PassthroughSubject<Void, Never>()
        OrbMotion.stillness = { still }
        OrbMotion.preferenceChanged = changed.eraseToAnyPublisher()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let core = OrbCoreNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let rings = OrbRingsNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        window.contentView?.addSubview(core)
        window.contentView?.addSubview(rings)
        core.apply(OrbView.coreSpec(for: .listening, diameter: 64))
        rings.apply(OrbView.rings(for: .listening))
        XCTAssertTrue(core.isTurning)
        XCTAssertEqual(rings.pulsingCount, 2)

        still = true
        changed.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(core.isTurning, "reduce motion was turned on and the orb kept turning")
        XCTAssertEqual(rings.pulsingCount, 0, "reduce motion was turned on and the rings kept pulsing")

        still = false
        changed.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(core.isTurning, "reduce motion was turned off and the orb stayed still")
        XCTAssertEqual(rings.pulsingCount, 2)
    }

    /// The core's mask kept a fixed 80 point radius in SwiftUI whatever the orb's
    /// size, so the rail's 68 point orb only ever showed the inner part of it.
    func test_theCoreMaskKeepsItsFixedRadius() {
        XCTAssertEqual(OrbView.coreSpec(for: .idle, diameter: 68).maskRadius, 80.0 / 34.0, accuracy: 0.0001)
    }
}

/// Every object the main window's root observes re-renders the WHOLE window
/// when it publishes. An observation nothing reads is pure cost: the root
/// observed the wake word listener, read none of it, and re-rendered on every
/// partial transcript the recognizer produced.
final class RootObservesOnlyWhatItReadsTests: XCTestCase {
    func test_everyObservedObjectOnTheRootIsRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/LaunchRootView.swift"),
                             encoding: .utf8)
        let decl = try NSRegularExpression(pattern: #"@ObservedObject\s+private\s+var\s+(\w+)\s*="#)
        let names = decl.matches(in: src, range: NSRange(src.startIndex..., in: src)).compactMap {
            Range($0.range(at: 1), in: src).map { String(src[$0]) }
        }
        XCTAssertGreaterThanOrEqual(names.count, 5, "the scanner found too few observations to trust")
        for name in names {
            let uses = src.components(separatedBy: "\(name).").count - 1
                + src.components(separatedBy: "$\(name)").count - 1
            XCTAssertGreaterThan(uses, 0, "LaunchRootView observes `\(name)` and never reads it, "
                                 + "so it re-renders the whole window for nothing")
        }
    }
}
