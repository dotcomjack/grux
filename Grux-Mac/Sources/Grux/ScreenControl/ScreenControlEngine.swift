import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Grux's "act on the screen" capability: click, type, scroll, press keys, and
// read the interactive elements of the frontmost app.
//
// This is the actuation half of screen agency. `read_screen` (VisionTool) is
// the perception half: it tells Grux WHAT is on screen. This engine lets Grux
// DO something about it. Together with the existing shell + filesystem tools
// that closes the loop for a mobility-first operator who drives the machine by
// voice: see it, decide, act, without a hand on the mouse.
//
// Everything here is coordinate-first and deterministic. It posts real HID
// events through the same CGEvent pipe the OS uses for a physical mouse and
// keyboard, so it works in EVERY app, not just ones that expose an AX action.
// AX is used only to READ the layout (`listUIElements`) so the caller can turn
// "the Submit button" into a coordinate to click.
//
// Coordinate system, stated once and load-bearing: global screen POINTS with
// the origin at the TOP-LEFT of the main display. This matches AppleScript
// `bounds`, the AX position attribute, and CGEvent's mouseCursorPosition, so a
// rect read from `listUIElements` can be clicked without any flip. (This is the
// same convention TerminalGridTiler.axQuadrants documents.)
//
// Permission: posting synthetic events and reading another app's AX tree both
// require the macOS Accessibility grant (System Settings -> Privacy & Security
// -> Accessibility -> Grux). Every entry point checks it up front and returns
// an actionable string rather than silently no-op'ing, mirroring MusicTool's
// AX play path.
enum ScreenControlEngine {

    // MARK: - Permission

    /// Non-prompting trust check. Never pops the system dialog mid-command,
    /// same posture as MusicTool.accessibilityGranted().
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompting variant: asks macOS to surface the Accessibility pane the
    /// FIRST time. Returns the current trust state. Only call this from an
    /// explicit "enable / grant" path, never inside a routine action.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Whether flipping the Screen control switch should raise that prompt.
    ///
    /// Pure, and deliberately separate from the switch, because every real
    /// hazard here is about WHEN rather than whether: prompting on launch,
    /// prompting while the user is turning the feature OFF, or prompting
    /// somebody who granted it months ago. macOS shows that dialog at most once
    /// per app, so a prompt spent at the wrong moment is one the user never gets
    /// at the right one, and none of those mistakes produce an error anybody
    /// would see in a log.
    static func shouldPromptForAccessibility(turningOn: Bool, alreadyGranted: Bool) -> Bool {
        turningOn && !alreadyGranted
    }

    // MARK: - Types

    enum MouseButton: String {
        case left, right, center
    }

    /// One interactive element discovered in an app's accessibility tree.
    struct UIElementInfo: Sendable {
        let role: String
        let title: String        // AXTitle / AXDescription / AXValue, best available
        let value: String        // AXValue when distinct + short (text field contents)
        let frame: CGRect        // global screen points, top-left origin

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

        /// Compact, model-facing one-liner. Center coords are click-ready.
        func line(index: Int) -> String {
            let cx = Int(center.x.rounded())
            let cy = Int(center.y.rounded())
            let w = Int(frame.width.rounded())
            let h = Int(frame.height.rounded())
            var label = title.isEmpty ? "" : " \"\(Self.clip(title, 60))\""
            if !value.isEmpty, value != title {
                label += " value=\"\(Self.clip(value, 40))\""
            }
            return "#\(index) \(role)\(label) center=(\(cx),\(cy)) size=\(w)x\(h)"
        }

        static func clip(_ s: String, _ n: Int) -> String {
            let t = s.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }
    }

    // MARK: - Mouse

    /// Move the cursor to a point (no click).
    @discardableResult
    static func move(x: Double, y: Double) -> Bool {
        guard let pt = validPoint(x, y),
              let ev = CGEvent(mouseEventSource: eventSource(), mouseType: .mouseMoved,
                               mouseCursorPosition: pt, mouseButton: .left) else { return false }
        ev.post(tap: .cghidEventTap)
        return true
    }

    /// Click at a point. `count` == 2 synthesizes a double-click by ramping the
    /// click-state field, which is how Cocoa distinguishes single from double.
    @discardableResult
    static func click(x: Double, y: Double, button: MouseButton = .left, count: Int = 1) -> Bool {
        guard let pt = validPoint(x, y) else { return false }
        let src = eventSource()
        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:   downType = .leftMouseDown;  upType = .leftMouseUp;  cgButton = .left
        case .right:  downType = .rightMouseDown; upType = .rightMouseUp; cgButton = .right
        case .center: downType = .otherMouseDown; upType = .otherMouseUp; cgButton = .center
        }
        let clicks = max(1, min(count, 3))
        for i in 1...clicks {
            guard let down = CGEvent(mouseEventSource: src, mouseType: downType,
                                     mouseCursorPosition: pt, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: src, mouseType: upType,
                                   mouseCursorPosition: pt, mouseButton: cgButton) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Scroll at a point. Positive `dy` scrolls the content UP, positive `dx`
    /// scrolls RIGHT, in pixels. The cursor is moved first so the scroll lands
    /// on whatever sits under (x, y), matching how a physical wheel behaves.
    @discardableResult
    static func scroll(x: Double, y: Double, dx: Int, dy: Int) -> Bool {
        guard let pt = validPoint(x, y) else { return false }
        let src = eventSource()
        if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                            mouseCursorPosition: pt, mouseButton: .left) {
            mv.post(tap: .cghidEventTap)
        }
        // wheel1 = vertical, wheel2 = horizontal.
        guard let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                               wheelCount: 2, wheel1: Int32(clampWheel(dy)),
                               wheel2: Int32(clampWheel(dx)), wheel3: 0) else { return false }
        ev.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Keyboard

    /// Type arbitrary text at the current focus by posting per-character
    /// unicode key events. Layout-independent: uses keyboardSetUnicodeString,
    /// so it types the literal characters regardless of the active keyboard
    /// layout (a hardware-keycode approach would mistype on non-US layouts).
    @discardableResult
    static func typeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let src = eventSource()
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Validate a combo WITHOUT posting anything. Returns nil if it would press
    /// cleanly, or the same human error `pressKey` surfaces. One source of truth
    /// so the closed-loop path can reject a bad combo up front, without a dry
    /// fire, and still show the exact message a live press would have.
    static func validateCombo(_ combo: String) -> String? {
        guard let (_, keyName) = parseCombo(combo) else {
            return "empty key combo"
        }
        guard keyCode(for: keyName) != nil else {
            return "unknown key '\(keyName)' - use letters, digits, or names like return, tab, esc, space, up, down, left, right, delete, f1..f12"
        }
        return nil
    }

    /// Press a key combo like "cmd+c", "cmd+shift+4", "return", "esc", "tab".
    /// Returns nil on success, or a human error string. Uses real hardware
    /// keycodes + modifier flags so app keyboard shortcuts actually fire (the
    /// unicode path in typeText does NOT trigger shortcuts).
    static func pressKey(combo: String) -> String? {
        if let err = validateCombo(combo) { return err }
        // Safe to force: validateCombo just proved both resolve.
        let (flags, keyName) = parseCombo(combo)!
        let code = keyCode(for: keyName)!
        let src = eventSource()
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
            return "failed to create key event"
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }

    // MARK: - Accessibility read

    /// Walk the accessibility tree of the target app and return its actionable
    /// elements (buttons, links, fields, menu items, checkboxes, …) with their
    /// on-screen rectangles, so the caller can pick a coordinate to click.
    ///
    /// `appHint` (name or bundle id) targets a specific running app; nil uses
    /// the frontmost application. Grux itself is skipped when it is frontmost
    /// and no hint is given, because the operator is almost always trying to
    /// drive the app they were just looking at, not the assistant window.
    /// ASYNC, AND THE WALK DOES NOT RUN ON THE MAIN ACTOR.
    ///
    /// Resolving the app genuinely needs the main actor, because it touches
    /// `NSWorkspace`. The walk does not, and it is the expensive half: up to
    /// `scanCap` nodes, each doing several BLOCKING `AXUIElementCopyAttributeValue`
    /// round trips into another process, every one of them able to burn the full
    /// 0.6s messaging timeout. Holding the main actor for that freezes the Grux
    /// window for seconds on any large tree (Chrome, Xcode, anything Electron),
    /// and against a beachballed target for `scanned x timeout`.
    @MainActor
    static func listUIElements(appHint: String?, maxCount: Int = 80) async -> (app: String, elements: [UIElementInfo])? {
        guard let app = resolveTargetApp(appHint: appHint) else { return nil }
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "app"
        let elements = await Task.detached(priority: .userInitiated) {
            collectElements(pid: pid, maxCount: maxCount)
        }.value
        return (name, elements)
    }

    /// The AX walk itself. Not isolated to any actor ON PURPOSE: see above. Safe
    /// off the main thread because `AXUIElement` reads are plain synchronous IPC
    /// with no run loop involvement (no `AXObserver` is used here).
    static func collectElements(pid: pid_t, maxCount: Int = 80) -> [UIElementInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        // Fail fast on an unresponsive app rather than hanging the tool call.
        AXUIElementSetMessagingTimeout(axApp, 0.6)

        var out: [UIElementInfo] = []
        var scanned = 0
        let scanCap = 4000
        collect(axApp, depth: 0, scanned: &scanned, scanCap: scanCap, out: &out, limit: maxCount)
        return out
    }

    // MARK: - Internals

    private static let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXSliderRole as String,
        kAXMenuItemRole as String,
        "AXLink",  // no kAX… constant ships for the link role
        kAXTabGroupRole as String,
        kAXDisclosureTriangleRole as String,
        "AXTabButton",
        "AXToggle",
    ]

    private static func collect(_ el: AXUIElement, depth: Int,
                                scanned: inout Int, scanCap: Int,
                                out: inout [UIElementInfo], limit: Int) {
        if out.count >= limit || scanned >= scanCap || depth > 60 { return }
        scanned += 1

        let role = axString(el, kAXRoleAttribute) ?? ""
        if actionableRoles.contains(role), let frame = axFrame(el), frame.width > 1, frame.height > 1 {
            let title = bestTitle(el)
            let value = axString(el, kAXValueAttribute) ?? ""
            out.append(UIElementInfo(role: role, title: title, value: value, frame: frame))
            if out.count >= limit { return }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collect(child, depth: depth + 1, scanned: &scanned, scanCap: scanCap, out: &out, limit: limit)
            if out.count >= limit || scanned >= scanCap { return }
        }
    }

    private static func bestTitle(_ el: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXRoleDescriptionAttribute] {
            if let s = axString(el, attr), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        // Fall back to a short AXValue (a text field's contents make a decent label).
        if let v = axString(el, kAXValueAttribute), v.count <= 60 { return v }
        return ""
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// One running app as the target resolver sees it.
    ///
    /// A value type so the CHOICE can be tested without standing up real
    /// applications. The choice is the part that has been wrong, and it is
    /// untestable through `NSRunningApplication`, whose state is whatever the
    /// developer happens to have open.
    struct AppCandidate: Equatable, Sendable {
        let pid: pid_t
        let bundleID: String?
        let name: String?
        /// `.regular`: owns a Dock icon and windows. Menu bar agents and
        /// background helpers are `.accessory` / `.prohibited` and are never
        /// what an operator means by "the app I was looking at".
        let isRegular: Bool
    }

    @MainActor
    private static func resolveTargetApp(appHint: String?) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = running.map {
            AppCandidate(pid: $0.processIdentifier,
                         bundleID: $0.bundleIdentifier,
                         name: $0.localizedName,
                         isRegular: $0.activationPolicy == .regular)
        }
        let picked = pickTarget(hint: appHint,
                                candidates: candidates,
                                frontToBack: onScreenPIDsFrontToBack(),
                                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                selfPID: selfPID)
        guard let picked else { return nil }
        return running.first { $0.processIdentifier == picked.pid }
    }

    /// What `list_ui` would target right now, WITHOUT reading any AX tree.
    ///
    /// Exists so the targeting fix can be proven from inside the SHIPPED app
    /// rather than only in a test host: `fire-screen-check` dumps this, so the
    /// question "which app does the running Grux think is behind it" has an
    /// answer you can read off disk instead of infer. Cheap and side-effect
    /// free, since it stops before the accessibility walk.
    @MainActor
    static func currentTarget(appHint: String? = nil) -> (pid: pid_t, name: String)? {
        guard let app = resolveTargetApp(appHint: appHint) else { return nil }
        return (app.processIdentifier, app.localizedName ?? app.bundleIdentifier ?? "app")
    }

    /// The pid of every app with an on-screen normal window, FRONTMOST FIRST.
    ///
    /// `NSWorkspace.runningApplications` has no defined order: it is neither
    /// z-ordered nor MRU-ordered. The window server is the only thing that knows
    /// what is actually in front of what, and this is how you ask it.
    ///
    /// `kCGWindowLayer == 0` keeps normal windows and drops the menu bar, the
    /// Dock, and every floating overlay. `.optionOnScreenOnly` is what makes a
    /// MINIMISED app disappear from this list for free, which
    /// `NSRunningApplication.isHidden` never did: an app whose windows are all
    /// minimised reports `isHidden == false`.
    ///
    /// Needs NO permission. Screen Recording gates `kCGWindowName`, not the
    /// owner pid, the layer, or the bounds, and none of those are read here.
    static func onScreenPIDsFrontToBack() -> [pid_t] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var seen = Set<pid_t>()
        var out: [pid_t] = []
        for w in raw {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if seen.insert(pid).inserted { out.append(pid) }
        }
        return out
    }

    /// Which app the operator means, as a pure function over a described stack.
    ///
    /// ## The bug this replaces
    ///
    /// "The app behind Grux" was `runningApplications.first(where: regular &&
    /// not Grux && not hidden)`. That array has NO DEFINED ORDER. It is neither
    /// z-ordered nor MRU-ordered, so the answer was whichever regular app
    /// happened to sit first in it, in practice Finder or the earliest-launched
    /// app. `isHidden` compounded it, because an app whose windows are all
    /// minimised reports `isHidden == false`.
    ///
    /// It never failed loudly. It always returned AN app, so the model got a
    /// real AX tree with real global coordinates for the wrong window, and the
    /// next click in the LOCATE-then-ACT loop landed on whatever was painted
    /// there. Everything downstream inherited the mistake silently.
    ///
    /// ## Why it is pure
    ///
    /// The choice is the part that was wrong, and through `NSRunningApplication`
    /// it is untestable: the inputs are whatever the developer happens to have
    /// open. Taking the stack as an argument is what lets the scenarios be
    /// written down.
    static func pickTarget(hint: String?,
                           candidates: [AppCandidate],
                           frontToBack: [pid_t],
                           frontmostPID: pid_t?,
                           selfPID: pid_t) -> AppCandidate? {
        // Distance from the front. Not on screen at all sorts last.
        func rank(_ c: AppCandidate) -> Int { frontToBack.firstIndex(of: c.pid) ?? Int.max }

        if let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let low = raw.lowercased()
            // BEST match, not first match. The shipped version ORed exact and
            // `contains` into one `first(where:)` over an unordered array, so
            // "Mail" resolved to Mailplane whenever Mailplane came first. Same
            // root cause as the bug above: a preference expressed as array
            // position is not a preference.
            func score(_ c: AppCandidate) -> Int {
                let b = c.bundleID?.lowercased()
                let n = c.name?.lowercased()
                if b == low || n == low { return 3 }
                if b?.hasPrefix(low) == true || n?.hasPrefix(low) == true { return 2 }
                if b?.contains(low) == true || n?.contains(low) == true { return 1 }
                return 0
            }
            return candidates.filter { score($0) > 0 }.min { a, b in
                let (sa, sb) = (score(a), score(b))
                // Equally good names are separated by what is actually in front,
                // which is the only tie-break that means anything to a person.
                return sa == sb ? rank(a) < rank(b) : sa > sb
            }
        }

        guard let front = frontmostPID else { return nil }
        if front != selfPID {
            // The operator is looking at it. That is the whole question.
            return candidates.first { $0.pid == front }
        }

        // They are looking at Grux, so they mean the app behind it: the next
        // on-screen regular app in the WINDOW SERVER's order. Walking
        // `frontToBack` is also what excludes minimised apps for free, since a
        // minimised window is not on screen.
        for pid in frontToBack where pid != selfPID {
            if let c = candidates.first(where: { $0.pid == pid }), c.isRegular { return c }
        }

        // NEVER GUESS. Nothing behind Grux is a real answer, and the tool turns
        // it into "bring the app you want to control to the front". The shipped
        // code fell through to returning Grux itself, so the model received a
        // tree of the assistant's own window with no signal that it had.
        return nil
    }

    // MARK: - Pure helpers (unit-tested; no HID posting, no AX)

    /// Split "cmd+shift+c" into (modifier flags, base key name). Returns nil for
    /// an empty combo. The final token is the base key; all earlier tokens are
    /// modifiers. A literal "+" as a key is expressed as "plus".
    ///
    /// "plus" carries an IMPLICIT SHIFT, and that is a fix rather than a
    /// flourish. `namedKeyCodes` maps both "plus" and "equals" to 0x18, which
    /// unshifted is "=", so `keys="plus"` posted "=" and every zoom-in the model
    /// reached for did nothing. On the US layout the keycode table is built
    /// from, "+" IS shift-equals, so the shift belongs to the key and not to
    /// something a caller has to know.
    static func parseCombo(_ combo: String) -> (flags: CGEventFlags, keyName: String)? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        let tokens = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = tokens.last else { return nil }
        var flags: CGEventFlags = []
        for mod in tokens.dropLast() {
            switch mod {
            case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "shift":                            flags.insert(.maskShift)
            case "ctrl", "control":                  flags.insert(.maskControl)
            case "opt", "option", "alt":             flags.insert(.maskAlternate)
            case "fn", "function":                   flags.insert(.maskSecondaryFn)
            default: break // unknown modifier ignored; base-key resolution still governs success
            }
        }
        // See the note above: 0x18 unshifted is "=", so a plus without a shift
        // is not a plus. "equals" deliberately keeps meaning "=".
        if key == "plus" { flags.insert(.maskShift) }
        return (flags, key)
    }

    /// Map a key name to a US-layout hardware keycode. Covers a-z, 0-9, F1..F12,
    /// and the common named keys. Returns nil for anything unmapped.
    static func keyCode(for name: String) -> CGKeyCode? {
        if let code = namedKeyCodes[name] { return code }
        // Single letter or digit.
        if name.count == 1, let code = letterDigitCodes[name] { return code }
        return nil
    }

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31, "spacebar": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "forwarddelete": 0x75, "fwddelete": 0x75,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "plus": 0x18, "minus": 0x1B, "equals": 0x18,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    private static let letterDigitCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
        "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
        "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    ]

    /// Reject NaN / infinite coordinates before they reach CGEvent, which would
    /// otherwise place the cursor at an undefined location.
    static func validPoint(_ x: Double, _ y: Double) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Keep a single scroll delta inside a sane pixel range.
    static func clampWheel(_ v: Int) -> Int {
        max(-3000, min(3000, v))
    }

    private static func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }
}
