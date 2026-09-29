import Foundation

/// Which of several equally good matches a click means (P-R-4).
///
/// `matchElement` ranks by how well a label fits and breaks ties by reading
/// order, so two "Save" buttons always resolve to the top one. When the caller
/// describes which one it means (`which`: "the Save in the dialog, not the
/// toolbar"), the decision engine picks among the TIED matches only. It can
/// never invent a target the matcher did not find, and below the execute
/// threshold, keyless, or on device, the click lands where it always did.
enum ScreenElementChoice {
    static let surface = "screen.element"

    static let instructions =
        "Several controls on screen match what Grux was asked to click. Which one did the request describe? "
        + "Judge from each control's kind, its text, and where it sits on the screen."

    /// The indices tied at the best score, in reading order. One element or
    /// none means there is nothing to choose between.
    static func tiedAtTop(query: String, role: String?, among elements: [ScreenControlEngine.UIElementInfo]) -> [Int] {
        let q = ScreenControlEngine.normalizeMatch(query)
        let family = role.flatMap { ScreenControlEngine.roleFamily(for: $0) }
        var scored: [(Int, Int)] = []
        for (i, el) in elements.enumerated() {
            if let family, !family.contains(el.role) { continue }
            let s = ScreenControlEngine.matchScore(query: q, element: el)
            if s > 0 { scored.append((i, s)) }
        }
        guard let best = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 == best }.map(\.0)
    }

    /// Where on the screen, coarsely, in words a request would use.
    static func whereOnScreen(_ frame: CGRect, in bounds: CGRect) -> String {
        guard bounds.width > 0, bounds.height > 0 else { return "" }
        let fx = (frame.midX - bounds.minX) / bounds.width
        let fy = (frame.midY - bounds.minY) / bounds.height
        let v = fy < 0.34 ? "top" : (fy > 0.66 ? "bottom" : "middle")
        let h = fx < 0.34 ? "left" : (fx > 0.66 ? "right" : "centre")
        return "\(v) \(h)"
    }

    /// The question, with option keys `1`...`n` in reading order.
    static func question(label: String, which: String, app: String,
                         candidates: [ScreenControlEngine.UIElementInfo]) -> (state: String, questions: [String: DecisionQuestion]) {
        let bounds = candidates.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        var criteria: [String: String] = [:]
        for (n, el) in candidates.enumerated() {
            let text = el.title.isEmpty ? "no text" : "\"\(ScreenControlEngine.UIElementInfo.clip(el.title, 60))\""
            let value = el.value.isEmpty ? "" : ", showing \"\(ScreenControlEngine.UIElementInfo.clip(el.value, 40))\""
            criteria["\(n + 1)"] = "a \(el.role.replacingOccurrences(of: "AX", with: "").lowercased()) \(text)\(value), "
                + whereOnScreen(el.frame, in: bounds) + " of the matching controls"
        }
        let state = "In \(app), Grux was asked to click \"\(label)\", described as: \(which)"
        return (state, ["which": .choice(instructions: instructions, criteria: criteria)])
    }

    /// The index into `elements` to click, or nil to keep reading order.
    static func pick(_ answer: DecisionAnswer?, provider: DecisionProviderKind, threshold: Double,
                     tied: [Int]) -> Int? {
        guard provider != .local, case .choice(let key, let confidence, _)? = answer,
              confidence >= threshold, let n = Int(key), n >= 1, n <= tied.count else { return nil }
        return tied[n - 1]
    }
}
