import Foundation

// Claude-tool bridge for screen agency. Exposes ONE multiplexed tool,
// `control_screen`, that clicks / types / scrolls / presses keys and reads the
// interactive elements of the frontmost app. Registered into
// ChatService.allTools() and dispatched from ChatService.dispatchTool().
//
// Two gates stand in front of the actuation, both fail-closed:
//   1. config.screenControlEnabled (the user's consent switch, OFF by default,
//      surfaced + explained in Settings and named at first run). Off -> skipped.
//   2. The macOS Accessibility grant. Missing -> an actionable error, never a
//      silent no-op.
//
// Every action writes ONE audit line (SecurityAuditLog, kind "screen_control").
// The privacy invariant of that log is upheld here: a `type` action logs the
// character COUNT, never the typed text, because the text can be a password.
enum ScreenControlTool {

    static let toolNames: Set<String> = ["control_screen"]

    static func claudeTools() -> [ClaudeTool] {
        return [
            ClaudeTool(
                name: "control_screen",
                description: """
                Act on the user's Mac screen: click, type, scroll, press a key combo, or list the interactive elements of the frontmost app. This is the ACTUATION counterpart to read_screen (which only LOOKS). Use it to finish a task hands-free for a user who drives by voice.

                Two ways to click. PREFER click_element when you know what the control SAYS: action="click_element" label="Submit" clicks the best-matching button/link/field in one step, doing its own fresh read so you never copy a coordinate or risk a stale one. Fall back to the coordinate loop (list_ui/read_screen to find WHERE, then click x/y) for things AX does not expose, like a spot on a canvas or an image.

                list_ui returns each button/field/link with a center=(x,y) you can pass straight to a click.

                Coordinates are global screen points, origin at the TOP-LEFT of the main display (the same numbers list_ui and read_screen report).

                Requires the user to have turned Screen control ON in Settings AND granted macOS Accessibility to Grux. If either is missing the tool tells you exactly what to do; relay that to the user rather than retrying.

                Actions:
                - list_ui: list actionable elements of the frontmost app (optionally target a specific app by name). START HERE when you need coordinates.
                - click_element: click the control whose text matches label (e.g. label="Sign in"). Optional role ("button", "link", "field", "checkbox", "menu", "tab") narrows it, and nth picks among repeats (1-based, reading order). Grux reads the app fresh and clicks the match's center, so no coordinates are needed. PREFERRED over click for anything with a label.
                - click: click at (x, y). button left/right/center, count 1 (default) or 2 for double-click.
                - move: move the cursor to (x, y) without clicking.
                - scroll: scroll at (x, y). dy>0 scrolls up, dx>0 scrolls right, in pixels.
                - type: type literal text at the current focus (click a field first).
                - key: press a key combo like "cmd+c", "cmd+shift+4", "return", "tab", "esc". Use this for shortcuts and Enter/Tab, NOT type.
                - check_permission: report whether Accessibility is granted.

                CONFIRMING THE EFFECT (closed loop) - use this for anything consequential, because this user cannot glance at the screen to catch a bad click:
                - Add expect="<text>" to a click/scroll/key to confirm the action WORKED: Grux screenshots + OCRs before and after and checks that text appeared (e.g. a dialog title, a "Sent"/"Saved" toast, a new label). Add expect_gone="<text>" to confirm text DISAPPEARED (a dialog you dismissed).
                - For type, pass expect with any value to confirm the field CHANGED. Grux never echoes what you typed (it may be a password), so type confirms change only, not the literal text.
                - With an expectation, an "ok:" result means CONFIRMED. An "unconfirmed:" result means the event fired once but the effect was not seen: do NOT blindly repeat it (that could double-fire a Send/Delete/Buy) - read_screen or list_ui to check, then retry only if it truly did not take.
                - Optional: settle_ms (wait before checking, default 350) and polls (re-check attempts, default 4).
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list_ui", "click_element", "click", "move", "scroll", "type", "key", "check_permission"],
                            "description": "What to do."
                        ],
                        "label": ["type": "string", "description": "For click_element: the visible text on the control to click, e.g. \"Submit\", \"Sign in\", \"Search\". Grux reads the app fresh and clicks the best match, so you do NOT pass coordinates. May be empty if you give a role (e.g. role=\"link\" nth=3)."],
                        "role": ["type": "string", "description": "Optional (click_element). Narrow the match to a kind of control: button, link, field, checkbox, menu, tab, radio, slider."],
                        "nth": ["type": "integer", "description": "Optional (click_element). When several controls match, pick the Nth in reading order (1-based). Default 1."],
                        "x": ["type": "number", "description": "X coordinate (global screen points, top-left origin). For click/move/scroll."],
                        "y": ["type": "number", "description": "Y coordinate (global screen points, top-left origin). For click/move/scroll."],
                        "button": ["type": "string", "enum": ["left", "right", "center"], "description": "Mouse button for click. Default left."],
                        "count": ["type": "integer", "description": "Click count. 1 (default) or 2 for double-click."],
                        "dx": ["type": "integer", "description": "Horizontal scroll pixels (scroll). Positive = right."],
                        "dy": ["type": "integer", "description": "Vertical scroll pixels (scroll). Positive = up."],
                        "text": ["type": "string", "description": "Literal text to type (type action). Click into the field first."],
                        "keys": ["type": "string", "description": "Key combo for the key action, e.g. \"cmd+c\", \"cmd+shift+4\", \"return\", \"tab\", \"esc\"."],
                        "app": ["type": "string", "description": "Optional. For list_ui and click_element: target this running app by name or bundle id instead of the frontmost one."],
                        "expect": ["type": "string", "description": "Optional (click/scroll/key/type). Confirm the action worked by checking this text APPEARS on screen afterward. For type, any value turns confirmation on (the field must change; the typed text is never echoed). Strongly recommended for anything consequential."],
                        "expect_gone": ["type": "string", "description": "Optional (click/scroll/key). Confirm by checking this text DISAPPEARS afterward, e.g. a dialog you dismissed."],
                        "settle_ms": ["type": "integer", "description": "Optional. Milliseconds to wait for the UI to settle before checking. Default 350."],
                        "polls": ["type": "integer", "description": "Optional. How many times to re-check for the expected change before giving up. Default 4."]
                    ],
                    "required": ["action"]
                ]
            )
        ]
    }

    @MainActor
    static func dispatch(name: String, input: [String: Any]) async -> String {
        guard name == "control_screen" else { return "error: unknown screen tool '\(name)'" }
        let action = ((input["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !action.isEmpty else { return "error: action is required" }

        // Gate 1: the consent switch. Off means off, uniformly.
        guard AppState.shared.config.screenControlEnabled else {
            return "skipped: screen control is off. Ask the user to turn on \"Screen control\" in Settings → Data & Security, then Grux can click, type, and scroll for them."
        }

        // check_permission is a status read, not an actuation: answer it without
        // requiring the grant it is reporting on.
        if action == "check_permission" {
            let ok = ScreenControlEngine.hasAccessibility()
            await audit(action: action, verdict: ok ? "ok" : "error", detail: ok ? "granted" : "not granted")
            return ok
                ? "ok: Accessibility is granted. Screen control is ready."
                : "error: Accessibility is NOT granted. Grux needs it to control the screen. Grant it in System Settings → Privacy & Security → Accessibility → Grux, then try again."
        }

        // Gate 2: the Accessibility grant, for anything that actually acts.
        guard ScreenControlEngine.hasAccessibility() else {
            await audit(action: action, verdict: "error", detail: "no accessibility grant")
            return "error: Grux needs macOS Accessibility permission to control the screen. Grant it in System Settings → Privacy & Security → Accessibility → Grux, then try again."
        }

        // The closed loop is opt-in per call: only engaged when the caller asks
        // to confirm an effect (expect / expect_gone). With neither, the acting
        // actions stay open-loop and byte-for-byte unchanged.
        let expectation = expectationFor(action: action, input: input)
        let settleMs = intVal(input, "settle_ms") ?? 350
        let polls = intVal(input, "polls") ?? 4

        switch action {
        case "list_ui":
            let appHint = (input["app"] as? String)
            guard let result = await ScreenControlEngine.listUIElements(appHint: appHint) else {
                await audit(action: action, verdict: "error", detail: "no target app")
                return "error: no target app found to inspect. Ask the user to bring the app they want to control to the front."
            }
            await audit(action: action, verdict: "ok", detail: "app=\(result.app) elements=\(result.elements.count)")
            if result.elements.isEmpty {
                return "ok: \(result.app) exposes no actionable elements right now (it may render with its own drawing rather than standard controls). Fall back to read_screen to locate a target, then click by coordinate."
            }
            let lines = result.elements.enumerated().map { $0.element.line(index: $0.offset + 1) }
            return "ok: \(result.app) interactive elements (center=(x,y) is click-ready):\n" + lines.joined(separator: "\n")

        case "click_element":
            // Label OR role: "the third link" carries no text, but a bare
            // click_element with neither is a click into nothing.
            let label = ((input["label"] as? String) ?? (input["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let roleHint = (input["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nth = intVal(input, "nth")
            guard !label.isEmpty || (roleHint?.isEmpty == false) else {
                return "error: click_element needs a label (the text on the control, e.g. \"Submit\") or a role (\"button\", \"link\", \"field\")."
            }
            let appHint = (input["app"] as? String)
            // Fresh read at action time: the whole point of this action is that
            // the coordinate is resolved NOW, not copied from an earlier list_ui.
            guard let result = await ScreenControlEngine.listUIElements(appHint: appHint) else {
                await audit(action: action, verdict: "error", detail: "no target app")
                return "error: no target app found. Ask the user to bring the app they want to control to the front."
            }
            guard let idx = ScreenControlEngine.matchElement(
                query: label, role: roleHint, nth: nth, among: result.elements) else {
                let scope = label.isEmpty ? "role \"\(roleHint ?? "")\"" : "\"\(label)\""
                await audit(action: action, verdict: "error",
                            detail: "no match for \(scope) among \(result.elements.count) in \(result.app)")
                // Fail helpfully: show what IS there so the model can retry with a
                // real label or fall back to a coordinate click, not just retry blind.
                let sample = result.elements.prefix(12).enumerated()
                    .map { $0.element.line(index: $0.offset + 1) }.joined(separator: "\n")
                return "unmatched: nothing in \(result.app) matched \(scope). "
                    + (sample.isEmpty
                        ? "It exposes no actionable elements right now; use read_screen to locate a target, then click by coordinate."
                        : "Here is what IS actionable (retry click_element with one of these labels, or click a center=(x,y) directly):\n" + sample)
            }
            let el = result.elements[idx]
            let button = ScreenControlEngine.MouseButton(rawValue: (input["button"] as? String) ?? "left") ?? .left
            let count = intVal(input, "count") ?? 1
            let cx = el.center.x
            let cy = el.center.y
            let what = el.title.isEmpty
                ? el.role
                : "\(el.role) \"\(ScreenControlEngine.UIElementInfo.clip(el.title, 48))\""
            return await runAction(
                action: action,
                auditDetail: "\(button.rawValue)x\(max(1, count)) [\(el.role)] @(\(Int(cx)),\(Int(cy)))",
                openLoopMessage: "clicked \(what) at (\(Int(cx)), \(Int(cy)))",
                failMessage: "could not synthesize the click on \(what)",
                expectation: expectation, settleMs: settleMs, polls: polls,
                perform: { ScreenControlEngine.click(x: cx, y: cy, button: button, count: count) })

        case "click":
            guard let x = num(input, "x"), let y = num(input, "y") else {
                return "error: click needs numeric x and y"
            }
            let button = ScreenControlEngine.MouseButton(rawValue: (input["button"] as? String) ?? "left") ?? .left
            let count = intVal(input, "count") ?? 1
            return await runAction(
                action: action,
                auditDetail: "\(button.rawValue)x\(max(1, count)) @(\(Int(x)),\(Int(y)))",
                openLoopMessage: "\(count >= 2 ? "double-" : "")\(button.rawValue)-clicked at (\(Int(x)), \(Int(y)))",
                failMessage: "could not synthesize the click event",
                expectation: expectation, settleMs: settleMs, polls: polls,
                perform: { ScreenControlEngine.click(x: x, y: y, button: button, count: count) })

        case "move":
            guard let x = num(input, "x"), let y = num(input, "y") else {
                return "error: move needs numeric x and y"
            }
            let ok = ScreenControlEngine.move(x: x, y: y)
            await audit(action: action, verdict: ok ? "ok" : "error", detail: "@(\(Int(x)),\(Int(y)))")
            return ok ? "ok: moved cursor to (\(Int(x)), \(Int(y)))" : "error: could not move the cursor"

        case "scroll":
            guard let x = num(input, "x"), let y = num(input, "y") else {
                return "error: scroll needs numeric x and y (the point to scroll over)"
            }
            let dx = intVal(input, "dx") ?? 0
            let dy = intVal(input, "dy") ?? 0
            guard dx != 0 || dy != 0 else { return "error: scroll needs a non-zero dx or dy" }
            return await runAction(
                action: action,
                auditDetail: "d(\(dx),\(dy)) @(\(Int(x)),\(Int(y)))",
                openLoopMessage: "scrolled (dx \(dx), dy \(dy)) at (\(Int(x)), \(Int(y)))",
                failMessage: "could not scroll",
                expectation: expectation, settleMs: settleMs, polls: polls,
                perform: { ScreenControlEngine.scroll(x: x, y: y, dx: dx, dy: dy) })

        case "type":
            let text = (input["text"] as? String) ?? ""
            guard !text.isEmpty else { return "error: type needs non-empty text" }
            // Privacy: the audit detail and the confirmation both stay text-free
            // (the text can be a password). expectationFor forces a change-only
            // check for type, so nothing typed is ever echoed back or logged;
            // only the character count is.
            return await runAction(
                action: action,
                auditDetail: "len=\(text.count)",
                openLoopMessage: "typed \(text.count) character\(text.count == 1 ? "" : "s")",
                failMessage: "could not type",
                expectation: expectation, settleMs: settleMs, polls: polls,
                perform: { ScreenControlEngine.typeText(text) })

        case "key":
            let combo = (input["keys"] as? String) ?? (input["key"] as? String) ?? ""
            guard !combo.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: key needs a combo like \"cmd+c\" or \"return\""
            }
            // Reject a bad combo up front, WITHOUT a dry fire, so the closed loop
            // never captures a baseline for a press that was never going to land.
            if let err = ScreenControlEngine.validateCombo(combo) {
                await audit(action: action, verdict: "error", detail: err)
                return "error: \(err)"
            }
            return await runAction(
                action: action,
                auditDetail: combo,
                openLoopMessage: "pressed \(combo)",
                failMessage: "could not press \(combo)",
                expectation: expectation, settleMs: settleMs, polls: polls,
                perform: { ScreenControlEngine.pressKey(combo: combo) == nil })

        default:
            return "error: unknown action '\(action)' - use list_ui, click, move, scroll, type, key, or check_permission"
        }
    }

    // MARK: - Helpers

    private static func audit(action: String, verdict: String, detail: String) async {
        await SecurityAuditLog.shared.record(
            kind: "screen_control", source: action, verdict: verdict,
            tags: ["SCREEN_CONTROL"], detail: detail)
    }

    // MARK: - The closed loop (see -> act ONCE -> confirm)

    /// Turn the caller's expect / expect_gone into an expectation, or nil when
    /// no confirmation was asked for. `type` is special: to keep the privacy
    /// invariant airtight (the typed text can be a password), it never confirms
    /// against the literal text, only that the focused field CHANGED.
    private static func expectationFor(action: String, input: [String: Any]) -> ScreenControlVerifier.Expectation? {
        let appears = (input["expect"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gone = (input["expect_gone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsConfirm = (appears?.isEmpty == false) || (gone?.isEmpty == false)
        guard wantsConfirm else { return nil }
        if action == "type" { return .changes }
        if let a = appears, !a.isEmpty { return .appears(a) }
        if let g = gone, !g.isEmpty { return .disappears(g) }
        return .changes
    }

    /// Perform an acting action, open-loop or closed-loop, and return the one
    /// model-facing line plus the audit. `perform` posts the real event and is
    /// the ONLY actuation; it runs EXACTLY ONCE on every path.
    @MainActor
    private static func runAction(action: String,
                                  auditDetail: String,
                                  openLoopMessage: String,
                                  failMessage: String,
                                  expectation: ScreenControlVerifier.Expectation?,
                                  settleMs: Int,
                                  polls: Int,
                                  perform: () -> Bool) async -> String {
        // No confirmation requested: unchanged open-loop behaviour.
        guard let expectation else {
            let ok = perform()
            await audit(action: action, verdict: ok ? "ok" : "error", detail: auditDetail)
            return ok ? "ok: \(openLoopMessage)" : "error: \(failMessage)"
        }

        switch await actAndConfirm(expectation: expectation, settleMs: settleMs, polls: polls, perform: perform) {
        case .actFailed:
            await audit(action: action, verdict: "error", detail: auditDetail)
            return "error: \(failMessage)"
        case .unverifiable:
            await audit(action: action, verdict: "ok", detail: "\(auditDetail); unverified(no-capture)")
            return "ok: \(openLoopMessage) (could not auto-confirm: turn on Screen Recording for Grux in System Settings → Privacy & Security so Grux can verify its own actions)"
        case .verified(let r) where r.confirmed:
            await audit(action: action, verdict: "ok", detail: "\(auditDetail); confirmed")
            return "ok: \(openLoopMessage). CONFIRMED: \(r.message)."
        case .verified(let r):
            await audit(action: action, verdict: "ok", detail: "\(auditDetail); unconfirmed")
            return "unconfirmed: \(openLoopMessage), but I could not confirm the effect: \(r.message). Do NOT blindly repeat this action (it could double-fire a Send/Delete/Buy); use read_screen or list_ui to check what actually happened, then retry only if it truly did not take."
        }
    }

    private enum ConfirmOutcome {
        case actFailed                                   // the event could not be posted
        case unverifiable                                // acted once, but no capture permission to confirm
        case verified(ScreenControlVerifier.Result)      // acted once, then polled to a verdict
    }

    /// The mechanics of the loop. Screenshot + OCR a baseline, act EXACTLY ONCE,
    /// then re-screenshot with backoff until the expected effect shows or the
    /// polls run out. The single act is load-bearing safety: this whole feature
    /// exists so a mobility-first operator does not get a silently mis-fired
    /// action, and re-firing to "make sure" would be the exact catastrophe.
    @MainActor
    private static func actAndConfirm(expectation: ScreenControlVerifier.Expectation,
                                      settleMs: Int, polls: Int,
                                      perform: () -> Bool) async -> ConfirmOutcome {
        // Confirmation needs to SEE the screen. Without Screen Recording we still
        // do what the user asked (the Accessibility grant already let us act),
        // then say plainly that we could not verify, rather than fake a verdict.
        guard ScreenCapturer.shared.hasPermission() else {
            _ = perform()
            return .unverifiable
        }

        let before = (try? await ScreenCapturer.shared.captureAndOCR().ocrText) ?? ""
        guard perform() else { return .actFailed }   // the one and only actuation

        let settle = max(50, min(settleMs, 5000))
        let attempts = max(1, min(polls, 8))
        var wait = settle
        var last = ScreenControlVerifier.Result(verdict: .unconfirmed, message: "no change was observed")
        for _ in 1...attempts {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            let after = (try? await ScreenCapturer.shared.captureAndOCR().ocrText) ?? before
            last = ScreenControlVerifier.evaluate(before: before, after: after, expectation: expectation)
            if last.confirmed { return .verified(last) }
            wait = min(Int(Double(wait) * 1.6), 2000)   // gentle backoff, capped
        }
        return .verified(last)
    }

    /// Read a JSON number that may arrive as Double, Int, NSNumber, or a numeric String.
    private static func num(_ input: [String: Any], _ key: String) -> Double? {
        if let d = input[key] as? Double { return d }
        if let i = input[key] as? Int { return Double(i) }
        if let n = input[key] as? NSNumber { return n.doubleValue }
        if let s = input[key] as? String, let d = Double(s) { return d }
        return nil
    }

    private static func intVal(_ input: [String: Any], _ key: String) -> Int? {
        if let i = input[key] as? Int { return i }
        if let d = input[key] as? Double { return Int(d) }
        if let n = input[key] as? NSNumber { return n.intValue }
        if let s = input[key] as? String, let i = Int(s) { return i }
        return nil
    }
}
