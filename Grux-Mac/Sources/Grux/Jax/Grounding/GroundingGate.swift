import Foundation

// GroundingGate: the one-call, drop-in fact-grounding gate every PRODUCTION
// content path can route through with a single line.
//
// WHY THIS EXISTS: the $18 fix (GroundedGenerator + FactGuard + ProductCatalog)
// was real but its blast radius was one test entry point. Real generation
// surfaces (document rewrite, chat content drafting, the briefing engine) called
// the model directly and never audited the output against the catalog, so a
// hallucinated product price could still slip through on the normal path. This
// gate is the smallest possible seam those surfaces can adopt without being
// rewritten to use the full GroundedGenerator loop:
//
//   - For a path that ALREADY has a draft string (a document rewrite result, a
//     chat reply about to be shown, a briefing line), call `vet(draft:brief:)`.
//     It detects the brand from the brief (or the draft), audits the draft
//     against the real catalog, and returns a verdict. If the draft asserts a
//     product fact that contradicts the catalog, the verdict is .ungrounded with
//     the concrete issues, and the caller MUST NOT surface it as-is: it should
//     refuse, ask, or regenerate. An ungrounded fact is true confusion, never a
//     guess to publish.
//
//   - For a path that is generating brand content from scratch and can afford the
//     full retrieve-generate-audit-correct loop, prefer GroundedGenerator.generate
//     directly. This gate is the lighter-weight guard for paths that are not (yet)
//     built around that loop.
//
// FAIL-SAFE: the gate never weakens a guardrail. When in doubt it does not pass a
// draft. The only "grounded" verdict is one where the brand is known AND the
// audit found zero contradictions, OR the content is not about a known brand at
// all (no ground truth to violate, so there is nothing to invent). It never
// fabricates a brand or a fact, and it records an honest CognitionTrace event so
// the Cognition Map shows the guard running on the real production path.
//
// House style: @MainActor enum of statics, zero em/en dashes, dollars as $N, no
// vendor/model/stack names. No new SPM dependencies. Builds only on FactGuard +
// ProductCatalog, which already own the data and the detection.

@MainActor
enum GroundingGate {

    // The verdict for one vetted draft. `surfaceable` is true ONLY when the draft
    // carries no ungrounded product fact (either the content is not about a known
    // brand, or every product number in it matches the catalog). When false,
    // `issues` names each concrete contradiction and `corrections` maps each wrong
    // value to the real catalog value, so the caller can name the fix precisely
    // rather than guess.
    struct Verdict {
        // The detected brand, or nil when the content is not about a known brand.
        var brand: String?
        // True only when the draft is safe to surface as-is (no invented fact).
        var surfaceable: Bool
        // One human-readable line per contradiction (empty when surfaceable).
        var issues: [String]
        // Wrong rendered value -> real catalog value, where a single real value
        // can be named (used to build a precise correction prompt).
        var corrections: [String: String]

        // A single honest refusal line the caller can show or log when a draft is
        // not surfaceable. Names the issues, never invents a fix.
        var refusalLine: String {
            guard !surfaceable else { return "" }
            let detail = issues.isEmpty ? "an unbacked product fact" : issues.joined(separator: " ")
            return "Not surfacing this draft: it asserts \(detail). An ungrounded product fact is true confusion, so it must be looked up or asked, never invented."
        }
    }

    // Vet a draft that is about to be surfaced or published. Detects the brand
    // from the brief (falling back to the draft text), audits the draft against
    // the real catalog, records an honest trace, and returns the verdict.
    //
    //   draft  the generated text about to be shown / sent / published.
    //   brief  what was asked for, used to detect the brand. When nil or empty,
    //          the draft itself is scanned for a brand signal so a direct
    //          generation with no separate brief is still covered.
    //
    // When no known brand is detected, the verdict is surfaceable (there is no
    // ground truth to contradict, so nothing can be invented against it). This is
    // the honest default: the gate never fabricates a brand to audit against.
    static func vet(draft: String, brief: String? = nil) -> Verdict {
        let briefText = (brief?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        // Detect the brand from the brief first (it states intent), then fall back
        // to the draft (so a brand named only in the output is still caught).
        let detectionText = briefText.isEmpty ? draft : briefText
        guard let brand = FactGuard.detectBrand(in: detectionText)
                ?? FactGuard.detectBrand(in: draft) else {
            return Verdict(brand: nil, surfaceable: true, issues: [], corrections: [:])
        }

        // Audit the DRAFT (not the brief) against the catalog: a hallucinated
        // number lives in the output, so the output is what must be checked.
        let factIssues = FactGuard.audit(brand: brand, artifact: draft)
        guard !factIssues.isEmpty else {
            return Verdict(brand: brand, surfaceable: true, issues: [], corrections: [:])
        }

        let result = FactGuard.audit(draft, brief: briefText.isEmpty ? draft : briefText)
        return Verdict(
            brand: brand,
            surfaceable: false,
            issues: result.issues.isEmpty ? factIssues.map { $0.describe } : result.issues,
            corrections: result.corrections
        )
    }

    // Convenience: true when a draft is safe to surface as-is. A false means treat
    // it as true confusion (refuse, ask, or regenerate), never surface.
    static func isSurfaceable(draft: String, brief: String? = nil) -> Bool {
        vet(draft: draft, brief: brief).surfaceable
    }

    // The grounding context block for a brief, for any production path that wants
    // to inject the REAL facts into its own system prompt before generating (the
    // PRE half of the fix) without adopting the full GroundedGenerator loop. An
    // empty string when the brief is not about a known brand. This is a thin
    // pass-through to FactGuard so production callers have one import surface.
    static func groundingContext(brief: String) -> String {
        FactGuard.groundingContext(brief: brief)
    }
}
