import XCTest
import AppKit
@testable import Grux

/// No file puts a window in front of a person, or activates an app, except through
/// `WindowFacade`.
///
/// Measured 2026-09-27: about 60 call sites ordered windows front, raised floating
/// levels and activated Grux, so `~/.grux/HEADLESS` could only hold if every one was
/// found by hand, and the next one added would not be. This scans every source file.
final class WindowFacadeArchitectureTests: XCTestCase {

    private static let facade = "Sources/Grux/Shell/WindowFacade.swift"

    /// Only the facade may call these. The lookbehind lets `WindowFacade.x(` through.
    private static let facadeOnly: [String] = [
        #"(?<!WindowFacade)\.makeKeyAndOrderFront\("#,
        #"(?<!WindowFacade)\.orderFrontRegardless\("#,
        #"\.orderFront\("#,
        #"NSApp(lication\.shared)?\.activate\("#,
        #"\.activate\((options|ignoringOtherApps):"#,
        #"(?<!WindowFacade)\.setActivationPolicy\("#,
        #"\.unhide(WithoutActivation)?\("#,
        #"\.level\s*=\s*(\.[a-zA-Z]|LaunchWindowSizer|NS(Window|Panel)\.Level)"#,
        // Implicit self, inside a window subclass: `makeKeyAndOrderFront(nil)`, `level = .floating`.
        #"(^|[^.\w])(makeKeyAndOrderFront|orderFrontRegardless|orderFront)\("#,
        #"(^|[^.\w])level\s*=\s*(\.[a-zA-Z]|NS(Window|Panel)\.Level)"#,
        // SwiftUI's own window level (macOS 15).
        #"\.windowLevel\("#,
    ]

    /// Grux's own objects with an `activate()` of their own, which raises no
    /// app: the self-upgrade engine and its bridge, the updater, two watchers,
    /// and MachineLoad's dispatch source.
    static let ownActivators: Set<String> = [
        "FoundryEngine.shared", "GruxUpdater.shared", "FoundryViewBridge",
        "LiveTreeTripwire.shared", "PostMergeWatch.shared", "source",
    ]

    /// The facade-only patterns a line of code matches. REVIEW-2: a bare
    /// `activate()` (macOS 14 and later) on an NSRunningApplication or
    /// NSApplication brings an app forward too; any receiver that is not one
    /// of Grux's own activators counts.
    static func offenses(_ code: String) -> [String] {
        var found = facadeOnly.filter { code.range(of: $0, options: .regularExpression) != nil }
        let bare = try! NSRegularExpression(pattern: #"([A-Za-z_][\w.]*?)\??\.activate\(\s*\)"#)
        for m in bare.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let r = Range(m.range(at: 1), in: code) else { continue }
            let receiver = String(code[r])
            if receiver == "WindowFacade" || ownActivators.contains(receiver) { continue }
            found.append("bare .activate() on \(receiver)")
        }
        return found
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// (relative path, line number, code with comments stripped)
    private func codeLines() throws -> [(String, Int, String)] {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var out: [(String, Int, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let code = raw.range(of: " //").map { String(raw[..<$0.lowerBound]) } ?? raw
                out.append((rel, i + 1, code))
            }
        }
        XCTAssertGreaterThan(out.count, 10_000, "the scan found almost no source, so it proves nothing")
        return out
    }

    func test_windowAndActivationAPIsAppearOnlyInTheFacade() throws {
        var offenders: [String] = []
        for (file, n, code) in try codeLines() where file != Self.facade {
            for p in Self.offenses(code) {
                offenders.append("\(file):\(n) uses /\(p)/: \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "route these through WindowFacade so ~/.grux/HEADLESS holds")
    }

    /// RV25: each way around the facade the first version missed goes red, and the
    /// facade's own callers stay green.
    func test_theScanSeesEveryWayAroundTheFacade() {
        let planted = [
            "        makeKeyAndOrderFront(nil)",
            "        orderFrontRegardless()",
            "        self.orderFront(nil)",
            "        panel.level = NSWindow.Level.floating",
            "        level = .floating",
            "        level = NSWindow.Level.statusBar",
            "            .windowLevel(.floating)",
            // REVIEW-2: a bare activate() on a running app, however it is reached.
            "        NSRunningApplication.current.activate()",
            "        app.activate()",
            "        NSWorkspace.shared.frontmostApplication?.activate()",
        ]
        for line in planted { XCTAssertFalse(Self.offenses(line).isEmpty, line) }
        let fine = [
            "        WindowFacade.makeKeyAndOrderFront(win)",
            "        WindowFacade.orderFrontRegardless(panel)",
            "        WindowFacade.setLevel(.floating, of: panel)",
            "        let level = LaunchWindowSizer.level(keepOnTop: on, legacyShell: legacy)",
            "        if w.level == .floating { return }",
            "        FoundryEngine.shared.activate()",
            "        GruxUpdater.shared.activate()",
            "        source.activate()",
        ]
        for line in fine { XCTAssertEqual(Self.offenses(line), [], line) }
    }

    /// The runtime backstop behind the scan: a window ordered in around the facade
    /// (as SwiftUI does for its scenes) is concealed by `enforce()`, and put back
    /// when headless mode ends.
    @MainActor
    func test_enforceConcealsAWindowOrderedInAroundTheFacade() {
        // Run alone, nothing has created the shared application yet, and `NSApp` is nil.
        let app = NSApplication.shared
        WindowFacade.headlessUnderTest = true
        let policy = app.activationPolicy()
        // So leaving headless puts the test host back where it was, never `.regular`.
        WindowFacade.setActivationPolicy(policy)
        defer {
            WindowFacade.headlessUnderTest = nil
            app.setActivationPolicy(policy)
        }
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.orderOut(nil) }
        w.level = .floating
        w.orderBack(nil)
        XCTAssertFalse(WindowFacade.isConcealed(w), "the planted window starts visible")

        WindowFacade.enforce()
        XCTAssertTrue(WindowFacade.isConcealed(w), "the backstop left a window visible")
        XCTAssertEqual(app.activationPolicy(), .accessory)
        XCTAssertFalse(app.isActive)

        WindowFacade.headlessUnderTest = false
        WindowFacade.enforce()
        XCTAssertEqual(w.alphaValue, 1)
        XCTAssertFalse(w.ignoresMouseEvents)
        XCTAssertEqual(w.level, .floating)
    }

    /// The guard has to run before SwiftUI builds its first window.
    func test_theGuardStartsBeforeLaunchFinishes() throws {
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)
        let will = try XCTUnwrap(src.range(of: "func applicationWillFinishLaunching"))
        let did = try XCTUnwrap(src.range(of: "func applicationDidFinishLaunching"))
        let start = try XCTUnwrap(src.range(of: "WindowFacade.startGuard()"))
        XCTAssertTrue(will.upperBound < start.lowerBound && start.lowerBound < did.lowerBound)
    }
}
