import Foundation

// The pure brain of the see -> act -> CONFIRM loop.
//
// `control_screen` posts real HID events. Left open-loop it reports success the
// instant the CGEvent is posted, which only proves the event LEFT Grux, never
// that it LANDED where the operator meant. For a user who drives by voice and
// cannot glance at the screen to catch a bad click, "it says it worked" and "it
// is confirmed to have worked" are the whole difference between a demo and a
// tool. A misclick that silently reports ok is the exact failure this closes.
//
// This type is the judgement, and nothing else. It takes the OCR text of the
// screen BEFORE an action and AFTER it, plus what the caller expected to change,
// and returns a verdict. It is deliberately, load-bearingly PURE: no screenshot,
// no CGEvent, no permission, no clock, no actor. That purity is what lets every
// branch of the loop's judgement be proven HEADLESSLY, against fixed text pairs,
// on a host with no display and no Accessibility grant. The live loop feeds real
// Vision OCR into the same `evaluate` the tests drive, so the shipped verdict is
// the tested verdict.
enum ScreenControlVerifier {

    /// What the caller asked the action to accomplish, expressed against the text
    /// that is visible on screen (which is all OCR can see).
    enum Expectation: Equatable {
        /// `text` should be ON screen after the action but was NOT before: a
        /// dialog opened, a toast appeared, a value got typed into a field.
        /// This is the reliable path, because it names a specific effect.
        case appears(String)
        /// `text` should be GONE after the action but WAS there before: a dialog
        /// dismissed, a menu closed, a row deleted.
        case disappears(String)
        /// No specific text, only: the screen must have meaningfully changed.
        /// The weak fallback. Catches a click into dead space that did nothing,
        /// but cannot tell a right change from a wrong one. Prefer `.appears`.
        case changes
    }

    enum Verdict: Equatable {
        /// The expected effect is present. Safe to report as done.
        case confirmed
        /// The action fired but the expected effect is not visible. NOT an error
        /// (the event was posted) and NOT a success (nothing observable changed).
        /// The caller must not blindly re-fire: a repeated Delete / Send / Buy is
        /// the catastrophe this whole loop exists to prevent.
        case unconfirmed
    }

    /// The verdict plus a single model-facing line explaining it.
    struct Result: Equatable {
        let verdict: Verdict
        let message: String
        var confirmed: Bool { verdict == .confirmed }
    }

    /// Decide whether `expectation` held between the before- and after-action OCR.
    static func evaluate(before: String, after: String, expectation: Expectation) -> Result {
        switch expectation {
        case .appears(let raw):
            let needle = normalize(raw)
            // An empty target cannot be looked for. Degrade to the change check
            // rather than claim a confirmation that means nothing.
            guard !needle.isEmpty else { return evaluate(before: before, after: after, expectation: .changes) }
            let wasThere = contains(before, needle)
            let isThere = contains(after, needle)
            if isThere && !wasThere {
                return Result(verdict: .confirmed, message: "\"\(clip(raw))\" appeared on screen")
            }
            if isThere && wasThere {
                // Present the whole time: the action cannot be credited for it.
                return Result(verdict: .unconfirmed,
                              message: "\"\(clip(raw))\" was already on screen before the action, so its appearance is not evidence the action worked")
            }
            return Result(verdict: .unconfirmed,
                          message: "\"\(clip(raw))\" did not appear on screen")

        case .disappears(let raw):
            let needle = normalize(raw)
            guard !needle.isEmpty else { return evaluate(before: before, after: after, expectation: .changes) }
            let wasThere = contains(before, needle)
            let isThere = contains(after, needle)
            if wasThere && !isThere {
                return Result(verdict: .confirmed, message: "\"\(clip(raw))\" is gone from the screen")
            }
            if !wasThere {
                // Never there to begin with: removal is unprovable, not proven.
                return Result(verdict: .unconfirmed,
                              message: "\"\(clip(raw))\" was not on screen before the action, so its removal cannot be confirmed")
            }
            return Result(verdict: .unconfirmed,
                          message: "\"\(clip(raw))\" is still on screen")

        case .changes:
            if changedEnough(before: before, after: after) {
                return Result(verdict: .confirmed, message: "the screen changed after the action")
            }
            return Result(verdict: .unconfirmed,
                          message: "the screen looks unchanged, so the action may have had no effect")
        }
    }

    // MARK: - Pure helpers (all unit-tested)

    /// Case- and whitespace-insensitive text used for every comparison. OCR
    /// spacing and capitalisation are not stable enough to compare literally, so
    /// collapse runs of whitespace to one space, lowercase, and trim.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return collapsed.joined(separator: " ")
    }

    /// Whether `haystack` contains `normalizedNeedle` (already normalized).
    static func contains(_ haystack: String, _ normalizedNeedle: String) -> Bool {
        guard !normalizedNeedle.isEmpty else { return false }
        return normalize(haystack).contains(normalizedNeedle)
    }

    /// Whether two screens differ by ENOUGH to credit an action with the change.
    ///
    /// Exact inequality is unusable here: a blinking caret, a menu-bar clock
    /// ticking from 12:03 to 12:04, or a one-pixel OCR wobble all make two shots
    /// of a static screen "different", which would confirm an action that did
    /// nothing. So compare the SET of word tokens and require the symmetric
    /// difference (tokens in one shot but not the other) to clear a small floor.
    /// A real effect (a toast, a new dialog, a scrolled page) moves several
    /// tokens; a clock digit moves one. This is a coarse signal by design, which
    /// is exactly why `.appears` / `.disappears` are the recommended path.
    static func changedEnough(before: String, after: String, floor: Int = 3) -> Bool {
        let a = tokens(before)
        let b = tokens(after)
        if a.isEmpty && b.isEmpty { return false }
        let onlyA = a.subtracting(b)
        let onlyB = b.subtracting(a)
        return onlyA.count + onlyB.count >= floor
    }

    /// Lowercased alphanumeric word tokens. Splitting on every non-alphanumeric
    /// makes "12:03" two tokens ("12","03"), so a clock tick changes one token,
    /// not a whole string, and stays under the floor.
    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { !$0.isEmpty })
    }

    private static func clip(_ s: String, _ n: Int = 48) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
}
