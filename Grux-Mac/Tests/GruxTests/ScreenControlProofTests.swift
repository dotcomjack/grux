import AppKit
import CoreGraphics
import XCTest
@testable import Grux

/// Box the event tap callback writes into. A class because the callback is a C
/// function pointer and gets its context through a raw pointer.
///
/// Locked, because the tap runs its run loop on its OWN thread. That thread is
/// not a stylistic choice, it is the fix for a flaky suite: the first version
/// pumped the MAIN run loop with `CFRunLoopRunInMode` to wait for the event, and
/// pumping the main run loop mid-test lets every queued `Task { @MainActor }`
/// and timer from the rest of the suite run reentrantly at a moment no test
/// expects. One full run came back with 56 scattered failures and the next two
/// were clean on identical code. Waiting on a semaphore blocks the main thread
/// without pumping anything, so nothing else gets to move.
private final class TapBox {
    private let lock = NSLock()
    private var events: [(code: Int64, flags: CGEventFlags)] = []
    let arrived = DispatchSemaphore(value: 0)

    func record(code: Int64, flags: CGEventFlags) {
        lock.lock(); events.append((code, flags)); lock.unlock()
        arrived.signal()
    }

    var first: (code: Int64, flags: CGEventFlags)? {
        lock.lock(); defer { lock.unlock() }
        return events.first
    }
}

/// Consumes ONLY the probe keycode, passes everything else straight through.
///
/// Narrow on purpose. A tap that swallowed every key would eat whatever the
/// person at the machine typed during the test window; this one can only ever
/// swallow the synthetic event the test itself posts, which is also the reason
/// no "+" can escape into a real document.
private func probeTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    if type == .keyDown || type == .keyUp {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 0x18 {
            Unmanaged<TapBox>.fromOpaque(refcon).takeUnretainedValue()
                .record(code: code, flags: event.flags)
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
}

/// THE FOUR THINGS THE FIRST PASS COULD NOT PROVE.
///
/// Every fix in the screen-control range was pinned by a test, and four claims
/// still rested on reading the code rather than on running it:
///
///   1. that turning the Settings switch on offers the Accessibility grant,
///   2. that "plus" now types a "+" and not an "=",
///   3. that the shipped, re-signed Grux.app still holds Accessibility,
///   4. that `list_ui` survives the whole tool layer, including the `await`
///      that was just added between the two gates and the engine.
///
/// Three are closed here. The fourth, the shipped app's own grant, cannot be
/// answered from a test host at all, because the test host is a different binary
/// with its own TCC record: it is answered by `fire-screen-check`, and the test
/// at the bottom is what stops that diagnostic being quietly deleted.
@MainActor
final class ScreenControlProofTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - 4. The seam: the whole tool layer, both gates open

    /// THE GAP THE LAST PASS LEFT. Both gates were covered CLOSED (switch off,
    /// grant missing) and the engine was covered live, but nothing drove
    /// `dispatch` all the way through with both gates OPEN. That is exactly the
    /// path the new `await` sits in, and a hang or a dropped result there would
    /// have shown up as a silent no-op in the running app rather than a failure.
    func testListUIRunsEndToEndThroughTheToolWithBothGatesOpen() async throws {
        try XCTSkipUnless(ScreenControlEngine.hasAccessibility(),
                          "the test host has no Accessibility grant, so gate 2 cannot be opened")
        try XCTSkipUnless(NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Finder" },
                          "Finder is not running")

        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "list_ui", "app": "Finder"])

        XCTAssertTrue(out.hasPrefix("ok:"), "the full path did not succeed. Got: \(out)")
        XCTAssertTrue(out.contains("Finder"), "it reported a different app than the hint. Got: \(out)")
        XCTAssertFalse(out.contains("config."), "internal identifiers reached the model-facing string")
    }

    /// And the coordinates it hands back are actually clickable, which is the
    /// only property of that string the model depends on. A line that parses but
    /// points off every display is worse than no line.
    func testTheCoordinatesListUIReturnsLandOnARealDisplay() async throws {
        try XCTSkipUnless(ScreenControlEngine.hasAccessibility(), "no Accessibility grant in the test host")
        try XCTSkipUnless(NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Finder" },
                          "Finder is not running")
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "list_ui", "app": "Finder"])
        try XCTSkipUnless(out.contains("center=("),
                          "Finder exposed no actionable elements right now, which the tool reports honestly")

        // The engine documents global screen POINTS with a top-left origin, so
        // build the same space out of the real displays and check containment.
        //
        // Guarded, for the same reason the window-order test is: a host with no
        // display has no screen rects, and "is this coordinate on a display"
        // is not a question that has an answer there. Reachable only if a
        // headless host somehow held the Accessibility grant, which is unlikely
        // rather than impossible, and a test that fails for an environmental
        // reason is worse than one that says so.
        try XCTSkipIf(NSScreen.screens.isEmpty, "no displays attached to this host")
        var bounds = CGRect.null
        for screen in NSScreen.screens { bounds = bounds.union(screen.frame) }
        XCTAssertFalse(bounds.isNull, "control: no screens, so this proves nothing")
        let slack = bounds.insetBy(dx: -2000, dy: -2000)

        var checked = 0
        for line in out.components(separatedBy: "\n") {
            // ELEMENT LINES ONLY. The header says `center=(x,y) is click-ready`
            // to teach the model the format, and parsing that as a coordinate is
            // how the first version of this test failed on literally the word
            // "x". Element lines are the ones that start with "#".
            guard line.hasPrefix("#") else { continue }
            guard let open = line.range(of: "center=("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex) else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                return XCTFail("unparseable coordinate in: \(line)")
            }
            XCTAssertTrue(x.isFinite && y.isFinite, "non-finite coordinate in: \(line)")
            XCTAssertTrue(slack.contains(CGPoint(x: x, y: y)),
                          "coordinate \(x),\(y) is nowhere near any display (\(bounds)): \(line)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no coordinate was actually parsed, so nothing was checked")
    }

    /// The status read answers without needing the grant it reports on, through
    /// the real dispatcher rather than the engine.
    func testCheckPermissionAnswersThroughTheToolLayer() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "check_permission"])
        XCTAssertEqual(out.hasPrefix("ok:"), ScreenControlEngine.hasAccessibility(),
                       "check_permission disagrees with the real trust state. Got: \(out)")
    }

    // MARK: - 2. "plus" really types a plus

    /// THE PROOF A KEYCODE TEST CANNOT GIVE.
    ///
    /// `keyCode(for: "plus") == 0x18` passes on the broken code AND the fixed
    /// code, because the keycode was never the wrong part: "+" is the SHIFTED
    /// face of that key and the flags were missing. The only check that
    /// separates the two is asking what character the (keycode, flags) pair
    /// actually produces, and the authority on that is the layout the machine
    /// is running.
    ///
    /// Measured 2026-08-23, the obvious alternative does not work:
    /// `CGEvent.keyboardGetUnicodeString` IGNORES the event's flags and returns
    /// "=" for a shifted 0x18 as readily as a bare one, so a test built on it
    /// would have passed against the bug.
    func testPlusActuallyProducesAPlusOnThisMachinesKeyboard() throws {
        let layout = ScreenControlEngine.currentKeyboardLayoutName() ?? "unknown"

        // Controls first, and they double as the layout check: on a layout where
        // the US keycode table does not hold, these fail and say which layout.
        XCTAssertEqual(ScreenControlEngine.producedCharacter(for: "equals"), "=",
                       "keycode 0x18 unshifted is not \"=\" on layout \(layout)")
        XCTAssertEqual(ScreenControlEngine.producedCharacter(for: "c"), "c",
                       "the letter table does not hold on layout \(layout)")

        XCTAssertEqual(ScreenControlEngine.producedCharacter(for: "plus"), "+",
                       "\"plus\" types \(ScreenControlEngine.producedCharacter(for: "plus") ?? "nothing") "
                       + "on layout \(layout), not \"+\"")

        // And the shift is what does it, spelled the long way round.
        XCTAssertEqual(ScreenControlEngine.producedCharacter(for: "shift+equals"), "+",
                       "shift-equals is not a plus, so the whole premise of the fix is wrong")
    }

    /// A DISCOVERY WORTH PINNING, found by this suite rather than reasoned out.
    ///
    /// `producedCharacter(for: "cmd+plus")` is "=", not "+". That is not a bug in
    /// the combo: with Command held, `UCKeyTranslate` deliberately returns the
    /// BASE-LAYER character, because that is what a menu key equivalent is
    /// matched against. The event we post is still the right one, and this test
    /// exists so nobody later "fixes" the character check by stripping the shift
    /// out of `cmd+plus` and silently reintroducing the original defect.
    ///
    /// So the flags are what matter for a shortcut, and they are asserted here
    /// directly rather than through the character.
    func testCommandChangesWhatTranslatesButNotWhatIsPosted() throws {
        XCTAssertEqual(ScreenControlEngine.producedCharacter(for: "cmd+plus"), "=",
                       "UCKeyTranslate no longer returns the base layer under Command, so the note "
                       + "above is stale and the reasoning needs redoing")

        let combo = try XCTUnwrap(ScreenControlEngine.parseCombo("cmd+plus"))
        XCTAssertTrue(combo.flags.contains(.maskCommand), "the shortcut lost its Command")
        XCTAssertTrue(combo.flags.contains(.maskShift), "the shortcut lost the shift that makes it a plus")
        XCTAssertEqual(ScreenControlEngine.keyCode(for: combo.keyName), 0x18)
    }

    /// A key with no character stays nil rather than inventing one.
    func testKeysThatTypeNothingReportNothing() {
        XCTAssertNil(ScreenControlEngine.producedCharacter(for: "f5"))
        XCTAssertNil(ScreenControlEngine.producedCharacter(for: "hyperspace"))
    }

    /// AND THE EVENT REALLY GOES OUT. The translation above proves the
    /// (keycode, flags) pair means "+"; this proves `pressKey` posts that exact
    /// pair into the real HID stream, which is the other half of the chain.
    ///
    /// The tap consumes only keycode 0x18, so the synthetic keystroke cannot
    /// land in whatever the person at the machine has open, and no other key
    /// they press is affected.
    func testPressKeyPostsARealShiftedEventIntoTheHIDStream() throws {
        try XCTSkipUnless(ScreenControlEngine.hasAccessibility(),
                          "an event tap needs the Accessibility grant")

        let box = TapBox()
        let installed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Not `var` on the main thread and read from another: the tap thread owns
        // its own lifetime and stops when the flag flips, guarded by the same
        // lock discipline as the box.
        let stopping = NSLock()
        var shouldStop = false
        var created = false

        // The tap's run loop lives on ITS OWN thread, so waiting for the event
        // never pumps the main run loop. See the note on TapBox.
        let thread = Thread {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: CGEventMask(mask),
                                              callback: probeTapCallback,
                                              userInfo: Unmanaged.passUnretained(box).toOpaque()) else {
                installed.signal()
                finished.signal()
                return
            }
            created = true
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            installed.signal()

            while true {
                stopping.lock(); let done = shouldStop; stopping.unlock()
                if done { break }
                CFRunLoopRunInMode(.defaultMode, 0.05, false)
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            finished.signal()
        }
        thread.start()
        installed.wait()
        defer {
            stopping.lock(); shouldStop = true; stopping.unlock()
            finished.wait()
        }
        try XCTSkipUnless(created, "could not create an event tap in this host")

        XCTAssertNil(ScreenControlEngine.pressKey(combo: "plus"), "pressKey reported an error")

        // A semaphore wait blocks this thread and pumps NOTHING.
        XCTAssertEqual(box.arrived.wait(timeout: .now() + 3), .success,
                       "the posted key never reached the HID tap within 3s")

        let down = try XCTUnwrap(box.first,
                                 "the posted key never reached the HID tap, so pressKey posts nothing")
        XCTAssertEqual(down.code, 0x18, "a different physical key was posted")
        XCTAssertTrue(down.flags.contains(.maskShift),
                      "the event went out UNSHIFTED, which is the bug: it would have typed \"=\"")
        XCTAssertEqual(ScreenControlEngine.character(forKeyCode: CGKeyCode(down.code), flags: down.flags), "+",
                       "the event that actually went out does not translate to a plus")
    }

    // MARK: - 1. The Accessibility prompt, at the right moment and no other

    /// The hazard here is never "does macOS show a dialog", which is Apple's
    /// documented behaviour for `AXIsProcessTrustedWithOptions`. It is WHEN we
    /// ask. macOS shows it at most once per app, so a prompt spent on launch, or
    /// while the user is switching the feature OFF, is one they never get at the
    /// moment they actually want it, and none of those mistakes log anything.
    func testTheGrantIsOfferedOnlyWhenTurningItOnWithoutIt() {
        XCTAssertTrue(ScreenControlEngine.shouldPromptForAccessibility(turningOn: true, alreadyGranted: false),
                      "the one case that must prompt does not")
        XCTAssertFalse(ScreenControlEngine.shouldPromptForAccessibility(turningOn: true, alreadyGranted: true),
                       "it prompts somebody who granted it already")
        XCTAssertFalse(ScreenControlEngine.shouldPromptForAccessibility(turningOn: false, alreadyGranted: false),
                       "it prompts while the user is switching the feature OFF")
        XCTAssertFalse(ScreenControlEngine.shouldPromptForAccessibility(turningOn: false, alreadyGranted: true),
                       "it prompts on the way out with the grant already held")
    }

    /// And the prompt is raised from EXACTLY ONE place. A second call site is
    /// how a prompt ends up firing at launch, which is the failure the truth
    /// table above cannot see on its own.
    func testNothingButTheSwitchEverRaisesThePrompt() throws {
        let sources = repoRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk \(sources.path)")
        }

        var callSites: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let src = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in src.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                // The declaration itself is not a call site.
                if line.contains("func promptAccessibility") { continue }
                if line.contains("promptAccessibility()") {
                    // File, not file:line. A line number here would break on any
                    // edit above it, and the property under test is "one place,
                    // and it is the switch", which a line number does not carry.
                    callSites.append(url.lastPathComponent)
                    _ = i
                }
            }
        }

        XCTAssertGreaterThan(scanned, 100, "the walk found almost no Swift files, so it proved nothing")
        XCTAssertEqual(callSites, ["SettingsView.swift"],
                       "the Accessibility prompt is raised from somewhere other than the Screen control "
                       + "switch, or from more than one place: \(callSites)")
    }

    // MARK: - 3. The shipped app's own grant, via the diagnostic

    /// The one claim a test host structurally CANNOT make.
    ///
    /// These tests run in `GruxPackageTests.xctest`, a different binary with its
    /// own TCC record, so its Accessibility grant says nothing about whether the
    /// re-signed `Grux.app` kept its own. `fire-screen-check` answers it from
    /// inside the shipped process, and this test exists so the diagnostic cannot
    /// be deleted while the claim that rests on it stays in the notes.
    func testTheShippedAppCanReportItsOwnScreenControlState() throws {
        let app = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)

        XCTAssertTrue(app.contains("fire-screen-check"), "the trigger is gone")
        XCTAssertTrue(app.contains("screen-control-status.json"), "it no longer writes anywhere readable")
        for key in ["accessibilityGranted", "resolvedTarget", "onScreenFrontToBack", "plusTypes"] {
            XCTAssertTrue(app.contains("\"\(key)\""),
                          "the dump no longer reports \(key), which is one of the things only the "
                          + "running app can answer")
        }
    }

    /// The diagnostic reports the same target the tool would act on. If these
    /// two ever diverge the dump becomes a comfortable lie, which is worse than
    /// having no dump at all.
    func testTheDiagnosticAgreesWithWhatTheToolWouldTarget() async throws {
        let target = ScreenControlEngine.currentTarget(appHint: "Finder")
        try XCTSkipUnless(target != nil, "Finder is not running")
        try XCTSkipUnless(ScreenControlEngine.hasAccessibility(), "no Accessibility grant in the test host")

        let read = await ScreenControlEngine.listUIElements(appHint: "Finder", maxCount: 5)
        XCTAssertEqual(target?.name, read?.app,
                       "the diagnostic names a different app than the one list_ui actually reads")
    }
}
