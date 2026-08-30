import ApplicationServices
import Foundation

// Click a control by WHAT IT IS CALLED, not by where it happens to be.
//
// The shipped loop takes two model turns: `list_ui` (or `read_screen`) to learn
// a coordinate, then `click` at that coordinate. Between them the model has to
// transcribe "center=(140,215)" into an x and a y, and the read it copied from
// can go stale before the click lands. For an operator who drives by voice and
// cannot glance at the screen to catch a slipped digit, that transcription is a
// silent misclick waiting to happen, and the stale read is a click into wherever
// the button USED to be.
//
// `matchElement` is the pure half of a `click_element` action that closes both
// gaps at once. The tool does a FRESH accessibility read at action time, this
// function picks the element the operator named, and the tool clicks its center.
// No coordinate ever crosses the model boundary, and there is no read-then-act
// window for the layout to move in.
//
// This lives exactly where the engine's own header says the accessibility tree
// belongs: "AX is used only to READ the layout so the caller can turn 'the
// Submit button' into a coordinate to click." All this does is move that turn
// out of the model and into the engine, so it stays a coordinate click that
// works in every app, and it composes with the existing OCR confirm loop
// unchanged.
//
// PURE ON PURPOSE, like `pickTarget` and the verifier: it takes a snapshot of
// the app's actionable elements as an argument and returns an index, so every
// scoring and tie-breaking rule can be proven headlessly against hand-built
// element lists, on a host with no display and no Accessibility grant.
extension ScreenControlEngine {

    /// Pick the element a spoken target names, as an index into `elements`, or
    /// nil when nothing matches (or `nth` runs past the matches). `elements` is
    /// the same `[UIElementInfo]` `listUIElements` returns, in AX-walk order,
    /// which is the order `list_ui` numbers them and roughly reading order.
    ///
    /// - `query`: the visible text of the control ("Submit", "Sign in"). Empty
    ///   is allowed when `role` is given: "the third link" needs no label.
    /// - `role`: optional kind filter ("button", "field", "link", …). An
    ///   UNRECOGNISED role is treated as no filter rather than as "match
    ///   nothing", because the label is the stronger signal and a user saying
    ///   "dropdown" should still reach a pop-up button by its text.
    /// - `nth`: 1-based disambiguation among matches, in match order (see
    ///   below). Defaults to the single best match.
    ///
    /// ## Ordering, stated once and load-bearing
    ///
    /// A preference is a SCORE, never array position (the same rule the app-
    /// targeting bug was about). Matches are ranked by how well the label fits:
    /// an exact title beats a prefix beats a substring beats a value hit. Equal
    /// scores are broken by AX-walk order, so two identical "Save" buttons come
    /// back top-first, which is what `nth` then indexes into.
    static func matchElement(query: String, role roleHint: String?, nth: Int?,
                             among elements: [UIElementInfo]) -> Int? {
        let q = normalizeMatch(query)
        let family = roleHint.flatMap { roleFamily(for: $0) }

        // (original index, score) for every candidate that clears the filters.
        var ranked: [(index: Int, score: Int)] = []
        for (i, el) in elements.enumerated() {
            if let family, !family.contains(el.role) { continue }
            let s = matchScore(query: q, element: el)
            if s > 0 { ranked.append((i, s)) }
        }
        guard !ranked.isEmpty else { return nil }

        // Stable: higher score first, then earlier in the walk. `enumerated()`
        // is ascending, so a plain descending sort on score with an index
        // tie-break reproduces walk order within a score band.
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }

        let k = max(1, nth ?? 1)
        guard k <= ranked.count else { return nil }
        return ranked[k - 1].index
    }

    /// How well one element answers to `query` (already normalized). 0 means no
    /// match, so it is dropped. An empty query is the role-only case: every
    /// candidate that passed the role filter is an equal, score-1 match, so
    /// `nth` can walk them in reading order.
    static func matchScore(query q: String, element el: UIElementInfo) -> Int {
        guard !q.isEmpty else { return 1 }
        let title = normalizeMatch(el.title)
        if !title.isEmpty {
            if title == q { return 4 }
            if title.hasPrefix(q) { return 3 }
            if title.contains(q) { return 2 }
        }
        // A field's current contents (or a placeholder) make a weak last-resort
        // label: "click the field that says Search". Never stronger than a title
        // hit, and never double-counts a value that just repeats the title.
        let value = normalizeMatch(el.value)
        if !value.isEmpty, value != title, value == q || value.contains(q) { return 1 }
        return 0
    }

    /// The AX roles a spoken kind covers. Nil for an unrecognised hint, which the
    /// caller reads as "do not filter". The role strings are exactly the ones
    /// `collect` gathers into `actionableRoles`, so a filter can never name a
    /// role the reader would not have returned.
    static func roleFamily(for hint: String) -> Set<String>? {
        switch normalizeMatch(hint) {
        case "button", "buttons", "btn":
            return [kAXButtonRole as String, kAXPopUpButtonRole as String,
                    kAXMenuButtonRole as String, "AXTabButton"]
        case "field", "textfield", "text field", "text", "input", "textbox", "text box":
            return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        case "link", "links":
            return ["AXLink"]
        case "checkbox", "check box", "check", "toggle":
            return [kAXCheckBoxRole as String, "AXToggle"]
        case "radio", "radiobutton", "radio button":
            return [kAXRadioButtonRole as String]
        case "menu", "menuitem", "menu item":
            return [kAXMenuItemRole as String]
        case "tab", "tabs":
            return [kAXTabGroupRole as String, "AXTabButton"]
        case "slider":
            return [kAXSliderRole as String]
        default:
            return nil
        }
    }

    /// Case- and whitespace-insensitive text for label comparison, shared with
    /// the OCR verifier so a control matched here and a toast confirmed there are
    /// normalised the same way.
    static func normalizeMatch(_ s: String) -> String {
        ScreenControlVerifier.normalize(s)
    }
}
