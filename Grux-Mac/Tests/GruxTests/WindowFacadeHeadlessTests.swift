import XCTest
import AppKit
@testable import Grux

/// Headless mode (`~/.grux/HEADLESS`): no Grux window can be seen, clicked, float or
/// take focus, another app is never activated or hidden, and what the windows hold
/// is still readable from `~/.grux/headless-workspace`.
@MainActor
final class WindowFacadeHeadlessTests: XCTestCase {

    override func tearDown() {
        WindowFacade.headlessUnderTest = nil
        super.tearDown()
    }

    /// Placed far outside every screen as well, so even a failing run shows nothing.
    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Headless Probe"
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.cgColor
        w.contentView = v
        // Closed, not only ordered out: a probe window left alive is in the app's
        // window list for later tests (it once came first in the record).
        addTeardownBlock { w.close() }
        return w
    }

    func test_aTestRunIsHeadlessByDefault() {
        XCTAssertTrue(WindowFacade.isHeadless)
    }

    func test_everyWayToShowAWindowConcealsIt() {
        WindowFacade.headlessUnderTest = true
        let shows: [(String, (NSWindow) -> Void)] = [
            ("makeKeyAndOrderFront", WindowFacade.makeKeyAndOrderFront),
            ("orderFront", WindowFacade.orderFront),
            ("orderFrontRegardless", WindowFacade.orderFrontRegardless),
        ]
        for (name, show) in shows {
            let w = window()
            w.level = .floating
            show(w)
            XCTAssertEqual(w.alphaValue, 0, name)
            XCTAssertTrue(w.ignoresMouseEvents, name)
            XCTAssertEqual(w.level, .normal, name)
            XCTAssertFalse(w.isKeyWindow, name)
            XCTAssertTrue(w.isVisible, "\(name): ordered in, so it keeps drawing")
        }
    }

    func test_aFloatingLevelIsForcedOffAndRestoredWhenHeadlessEnds() {
        WindowFacade.headlessUnderTest = true
        let w = window()
        WindowFacade.setLevel(.floating, of: w)
        XCTAssertEqual(w.level, .normal)
        w.orderOut(nil)
        WindowFacade.restoreAll()
        XCTAssertEqual(w.level, .floating)
        XCTAssertEqual(w.alphaValue, 1)
        XCTAssertFalse(w.ignoresMouseEvents)
    }

    /// RV17: the saved state was keyed by the window's address. A palette that closes
    /// and deallocates frees that address, the next window can land on it, and the
    /// stale entry made the facade skip saving the new one, so it stayed alpha 0 and
    /// click-through after headless mode ended.
    func test_aWindowAtAFreedWindowsAddressIsStillRestoredWhenHeadlessEnds() {
        WindowFacade.headlessUnderTest = true
        func bare() -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            return w
        }
        func address(_ w: NSWindow) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(w).toOpaque()) }
        var freed: UInt = 0
        weak var gone: NSWindow?
        autoreleasepool {
            let a = bare()
            WindowFacade.makeKeyAndOrderFront(a)
            a.orderOut(nil)
            freed = address(a)
            gone = a
        }
        // AppKit lets go of a window a little later; wait for it, with a deadline.
        let deadline = Date().addingTimeInterval(3)
        while gone != nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        print("RV17 probe: the first window was freed: \(gone == nil)")
        var kept: [NSWindow] = []
        var landed: NSWindow?
        for _ in 0..<256 {
            let b = bare()
            kept.append(b)
            if address(b) == freed { landed = b; break }
        }
        let b = landed ?? kept[kept.count - 1]
        print("RV17 probe: a new window reused the freed address: \(landed != nil)")
        WindowFacade.makeKeyAndOrderFront(b)
        XCTAssertEqual(b.alphaValue, 0)
        b.orderOut(nil)
        WindowFacade.headlessUnderTest = false
        WindowFacade.restoreAll()
        XCTAssertEqual(b.alphaValue, 1, "restored, even at a reused address")
        XCTAssertFalse(b.ignoresMouseEvents)
        for w in kept { w.close() }
    }

    /// A closed window leaves the facade's table, and the next facade call on it after
    /// headless mode ends puts it back (setLevel, so the test never orders a window in
    /// visibly on a screen that is not the test's).
    func test_aClosedWindowLeavesTheTableAndComesBackVisible() {
        WindowFacade.headlessUnderTest = true
        let w = window()
        let before = WindowFacade.concealedCount
        WindowFacade.makeKeyAndOrderFront(w)
        XCTAssertEqual(WindowFacade.concealedCount, before + 1)
        w.close()
        XCTAssertEqual(WindowFacade.concealedCount, before, "dropped on close")
        WindowFacade.headlessUnderTest = false
        WindowFacade.setLevel(.normal, of: w)
        XCTAssertEqual(w.alphaValue, 1)
        XCTAssertFalse(w.ignoresMouseEvents)
        w.orderOut(nil)
    }

    /// RV19: under headless mode the Accessibility prompt door never asks, whatever
    /// the caller (the Settings switch, the setup card).
    func test_headlessNeverRequestsTheAccessibilityPrompt() {
        WindowFacade.headlessUnderTest = true
        let before = AccessibilityTrust.testPromptRequests
        _ = ScreenControlEngine.promptAccessibility()
        XCTAssertEqual(AccessibilityTrust.testPromptRequests, before, "the prompt path ran while headless")
    }

    /// RV19: opening an Accessibility pane under headless mode raises no dialog and
    /// brings nothing forward; it records what it would have done.
    func test_headlessOpenSystemSettingsIsRecordedNotDone() {
        WindowFacade.headlessUnderTest = true
        let prompts = AccessibilityTrust.testPromptRequests
        let opened = CapabilityRequest.testOpenedURLs.count
        CapabilityRequest.openSystemSettings(for: .permAccessibility)
        XCTAssertEqual(AccessibilityTrust.testPromptRequests, prompts)
        XCTAssertEqual(CapabilityRequest.testOpenedURLs.count, opened)
        let line = WindowFacade.withheld.last ?? ""
        XCTAssertTrue(line.hasPrefix("open System Settings x-apple.systempreferences:"), line)
        XCTAssertTrue(line.hasSuffix("after the Accessibility prompt"), line)
        let log = (try? String(contentsOf: WindowFacade.withheldLogURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains(line), "one line in withheld.log")
    }

    /// Outside headless mode the path is unchanged: prompt first, then the pane.
    func test_visibleOpenSystemSettingsPromptsThenOpensThePane() {
        WindowFacade.headlessUnderTest = false
        let prompts = AccessibilityTrust.testPromptRequests
        let opened = CapabilityRequest.testOpenedURLs.count
        CapabilityRequest.openSystemSettings(for: .permAccessibility)
        XCTAssertEqual(AccessibilityTrust.testPromptRequests, prompts + 1)
        XCTAssertEqual(CapabilityRequest.testOpenedURLs.count, opened + 1)
        XCTAssertEqual(CapabilityRequest.testOpenedURLs.last, CapabilityRequest.settingsURL(for: .permAccessibility))
    }

    func test_otherAppsAreNeverActivatedOrHidden() {
        WindowFacade.headlessUnderTest = true
        XCTAssertFalse(WindowFacade.activate(NSRunningApplication.current))
        XCTAssertFalse(WindowFacade.hide(NSRunningApplication.current))
    }

    func test_snapshotRendersTheWindowWithoutTheScreen() throws {
        WindowFacade.headlessUnderTest = true
        // The full suite on fc713d4 read alpha 1 from the first record with
        // this title. Any other live window with the same title (another
        // test's probe) can come first, so the record read is this window's,
        // found by its window number. The decoy is such a window.
        let decoy = window()
        decoy.alphaValue = 1
        let w = window()
        WindowFacade.makeKeyAndOrderFront(w)
        let files = HeadlessWorkspace.snapshot(reason: "mailbox")
        let mine = try XCTUnwrap(files.first { $0.contains("-mailbox-headless-probe-") }, "\(files)")
        let image = try XCTUnwrap(NSImage(contentsOfFile: mine))
        XCTAssertEqual(image.size.width, 320, accuracy: 1)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: mine))))
        let c = try XCTUnwrap(rep.colorAt(x: 160, y: 100)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.redComponent, 0.8, "drew the view, not a blank")
        XCTAssertLessThan(c.greenComponent, 0.5)

        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: HeadlessWorkspace.resultURL)) as? [String: Any]
        XCTAssertEqual((result?["files"] as? [String]) ?? [], files)
        let ws = try JSONSerialization.jsonObject(with: Data(contentsOf: HeadlessWorkspace.workspaceURL)) as? [String: Any]
        let wins = (ws?["windows"] as? [[String: Any]]) ?? []
        XCTAssertNotNil(wins.first { ($0["id"] as? Int) == decoy.windowNumber }, "control: the other probe window is in the record too")
        let probe = try XCTUnwrap(wins.first { ($0["id"] as? Int) == w.windowNumber })
        XCTAssertEqual(probe["alpha"] as? Double, 0)
        XCTAssertEqual(ws?["headless"] as? Bool, true)
    }

    /// Measured on the test Mac: `~/.grux/headless/` was the first name for this folder,
    /// and on a case-insensitive disk it IS the sentinel file `~/.grux/HEADLESS`, so
    /// nothing could be written while headless and creating it would switch headless on.
    func test_theWorkspaceFolderIsNotTheSentinelOnACaseInsensitiveDisk() {
        let sentinel = WindowFacade.sentinelURL.standardizedFileURL.path.lowercased()
        let folder = HeadlessWorkspace.dir.standardizedFileURL.path.lowercased()
        XCTAssertNotEqual(folder, sentinel)
        XCTAssertFalse(folder.hasPrefix(sentinel + "/"))
    }

    /// Measured live: the tab-keys sweep renders a tab every 0.25 s, and a coalesced
    /// snapshot left one PNG for 35 tabs. Every render gets its own.
    func test_everyRenderLeavesItsOwnSnapshot() throws {
        WindowFacade.headlessUnderTest = true
        let w = window()
        WindowFacade.makeKeyAndOrderFront(w)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: HeadlessWorkspace.shotsDir.path)) ?? [])
        RenderedTab.note("chat")
        RenderedTab.note("mailbox")
        RenderedTab.note("calendar")
        func mine() -> Set<String> {
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: HeadlessWorkspace.shotsDir.path)) ?? [])
            return after.subtracting(before).filter { $0.contains("headless-probe") }
        }
        // Waits for the three, with a deadline, instead of a fixed pause a slow host outruns.
        let deadline = Date().addingTimeInterval(10)
        while mine().count < 3, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(mine().count, 3, "\(mine().sorted())")
    }

    func test_theShotsFolderKeepsTheNewest200() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HeadlessWorkspace.shotsDir, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: HeadlessWorkspace.shotsDir.path) {
            try fm.removeItem(at: HeadlessWorkspace.shotsDir.appendingPathComponent(name))
        }
        for i in 0..<205 {
            let name = String(format: "20260927-000000-%03d-x.png", i)
            fm.createFile(atPath: HeadlessWorkspace.shotsDir.appendingPathComponent(name).path, contents: Data())
        }
        HeadlessWorkspace.prune()
        let left = try fm.contentsOfDirectory(atPath: HeadlessWorkspace.shotsDir.path).sorted()
        XCTAssertEqual(left.count, 200)
        XCTAssertEqual(left.first, "20260927-000000-005-x.png", "the oldest went first")
    }
}
