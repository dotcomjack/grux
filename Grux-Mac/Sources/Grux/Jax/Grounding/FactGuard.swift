import Foundation

// FactGuard: the fact-grounding guard that closes the invented-fact hole.
//
// THE BUG THIS FIXES: Jax generated product blog copy that said a body wash
// costs "$18" when the catalog said $15. Jax INVENTED a product fact. The hard
// rule is that Jax must never guess or make things up: content generation must RETRIEVE
// real product facts from a real catalog, never generate them, and an ungrounded
// factual number is TRUE confusion (look it up or ask, never invent).
//
// This guard works in two directions around any content/comms generation:
//
//   PRE  groundingContext(brief:)  detects the brand + product a brief is about
//        and returns the REAL fact block (from ProductCatalog.shared) plus a hard
//        instruction: use ONLY these facts for any price, size, or SKU; if a
//        needed fact is not listed, do NOT invent it, omit it or flag it.
//
//   POST audit(brand:artifact:)    scans a generated artifact for product-fact
//        claims (prices like $NN, sizes like NN oz, SKUs) about known products
//        and flags any that do NOT match the catalog. A "$18" when the catalog
//        says $15 comes back as a concrete FactIssue { claim, found, expected }.
//
// When the audit finds a mismatch, the caller treats it as TRUE confusion: do
// NOT publish. Regenerate with the grounding context, or refuse and ask. An
// invented number is never passed through.
//
// House style mirrors ConfidenceGate: an enum-namespaced pure core (so the
// detection is deterministic and unit-testable off the main actor) plus the
// small @MainActor reads of the catalog. Codable issue type, zero em/en dashes,
// dollars as $N. No new SPM dependencies.
//
// Sibling note: ProductCatalog.swift (built alongside) owns the ground-truth
// DATA and the contextBlock(brand:) renderer. CognitionTrace.swift owns the
// honest decision log. This module references both via their shared singletons
// and does NOT redefine either. A grounding event can be recorded on
// CognitionTrace.shared by the caller (or via recordTrace below) so the
// Cognition Map shows Jax retrieving a real fact rather than guessing one.

// MARK: - FactIssue

// One concrete mismatch the auditor found. Everything is a real, sourced string:
// the claim is the exact text pulled from the artifact, found is the value the
// artifact asserted, expected is what the catalog actually says. kind lets the
// caller phrase the regenerate/ask message precisely.
struct FactIssue: Codable, Equatable, Hashable, Identifiable {

    enum Kind: String, Codable, Equatable, Hashable {
        case price      // a $NN that is not a real catalog price for this brand
        case size       // an "NN oz" size that matches no product for this brand
        case sku        // a "<scent>-<format>" SKU that is not a valid catalog SKU
    }

    let kind: Kind

    // The exact claim text as it appeared in the artifact (e.g. "$18", "9.5 oz",
    // "ocean-mist-cream"). Quoted back verbatim so the issue is concrete.
    let claim: String

    // What the artifact asserted, normalized (e.g. "18", "9.5 oz", "ocean-mist-cream").
    let found: String

    // What the catalog actually says, phrased for a human. For a price this is
    // the set of real prices; for a SKU it is the valid suffix set; for a size
    // the set of real sizes. Never invented: it is read straight from the catalog.
    let expected: String

    var id: String { "\(kind.rawValue)|\(claim)|\(found)" }

    // A one-line human description for a report or a clarify message.
    var describe: String {
        switch kind {
        case .price: return "Price \(claim) is not a real catalog price. Real prices: \(expected)."
        case .size:  return "Size \(claim) matches no product. Real sizes: \(expected)."
        case .sku:   return "SKU \(claim) is not a valid catalog SKU. Valid forms: \(expected)."
        }
    }
}

// MARK: - FactGuard

@MainActor
enum FactGuard {

    // MARK: PRE: grounding context

    // Build the grounding block to inject into a content/comms generation prompt.
    // Detects the brand the brief is about (any brand the catalog has been
    // seeded with), pulls the REAL fact block from the catalog, and appends the hard never
    // invent instruction. Returns an empty string when no known brand is detected
    // (the caller then generates with no special grounding, since there is no
    // product fact to ground against).
    static func groundingContext(brief: String) -> String {
        guard let brand = detectBrand(in: brief) else { return "" }
        return groundingContext(brand: brand)
    }

    // Brand-explicit overload for callers that already know the brand (a comms
    // path with a brand hint, a brand-scoped content task).
    static func groundingContext(brand: String) -> String {
        let block = ProductCatalog.shared.contextBlock(brand: brand)
        guard !block.isEmpty else { return "" }
        return """
        \(block)

        Use ONLY these real product facts for any price, size, or SKU. If you need a product fact that is not listed here, do NOT invent it: omit it or flag it. Dollars as $N.
        """
    }

    // Did this brief name (or clearly imply) a known brand? Conservative: matches
    // an explicit brand token or a brand scent/format vocabulary hit, so a brief
    // that has nothing to do with a seeded product does not get a misleading
    // grounding block. Returns the canonical brand key on a hit.
    static func detectBrand(in text: String) -> String? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }

        // 1. Explicit brand mention: the brief names one of the catalog's own
        // brand keys. Read from the catalog rather than hardcoded, so an empty
        // catalog simply matches nothing instead of claiming a brand it has no
        // facts for. Longest key first so "acme labs" wins over "acme".
        let brandKeys = Set(ProductCatalog.shared.facts.map { $0.brand })
            .union(ProductCatalog.shared.scentsByBrand.keys)
        for key in brandKeys.sorted(by: { $0.count > $1.count }) {
            let needle = key.lowercased()
            guard !needle.isEmpty else { continue }
            if lower.contains(needle) {
                return ProductCatalog.shared.canonicalBrand(key)
            }
        }

        // 2. Vocabulary hit: a brief that names one of a brand's scents (e.g.
        // "ocean mist body wash") is about that brand even without naming it.
        // We check each seeded brand's scent list, matching the scent with its
        // hyphens removed too ("ocean-mist" and "ocean mist" both count).
        for brand in ProductCatalog.shared.scentsByBrand.keys {
            for scent in ProductCatalog.shared.scents(brand: brand) {
                let dashed = scent.lowercased()
                let spaced = dashed.replacingOccurrences(of: "-", with: " ")
                if lower.contains(dashed) || lower.contains(spaced) {
                    return brand
                }
            }
        }
        return nil
    }

    // MARK: POST: audit a generated artifact

    // Scan a generated artifact for product-fact claims that contradict the
    // catalog. Returns every concrete mismatch. An empty result means nothing in
    // the artifact contradicts ground truth (it may simply state no facts, which
    // is fine). An unknown brand returns no issues: there is no ground truth to
    // audit against, so the guard does not fabricate one.
    //
    // Detection is deliberately conservative to avoid false alarms on prose: it
    // only flags a price/size/SKU that is clearly a PRODUCT claim for THIS brand
    // and clearly does not match. It does not try to parse arbitrary numbers as
    // prices (a "$50K revenue gate" is not a product price), and it does not flag
    // a price that IS a real catalog price.
    static func audit(brand: String, artifact: String) -> [FactIssue] {
        guard let key = ProductCatalog.shared.canonicalBrand(brand) else { return [] }
        let facts = ProductCatalog.shared.factsFor(brand: key)
        guard !facts.isEmpty else { return [] }

        var issues: [FactIssue] = []
        issues.append(contentsOf: auditPrices(brand: key, artifact: artifact, facts: facts))
        issues.append(contentsOf: auditSizes(brand: key, artifact: artifact, facts: facts))
        issues.append(contentsOf: auditSKUs(brand: key, artifact: artifact))

        // Record an honest grounding event so the Cognition Map shows the guard
        // running and what it found. Real data only: the issue count and brand.
        recordTrace(brand: key, issues: issues, artifactChars: artifact.count)
        return dedupe(issues)
    }

    // Convenience: true when the artifact contains NO catalog contradiction. The
    // caller publishes only on true; a false means treat it as TRUE confusion
    // (regenerate with grounding, or refuse and ask), never publish.
    static func isGrounded(brand: String, artifact: String) -> Bool {
        audit(brand: brand, artifact: artifact).isEmpty
    }

    // MARK: Brief-shaped audit (the GroundedGenerator seam)

    // The result GroundedGenerator consumes after a generation pass. It carries
    // the same FactIssue list as a brand-keyed audit, but also exposes a
    // human-readable issue list and a wrong-value -> real-value correction map so
    // the regenerate pass can name each fix explicitly ("you wrote $18, the real
    // value is $15"). grounded is true ONLY when no issue was found.
    struct AuditResult {
        let brand: String?
        let factIssues: [FactIssue]

        var isGrounded: Bool { factIssues.isEmpty }

        // One human-readable line per issue, for a report.
        var issues: [String] { factIssues.map { $0.describe } }

        // Wrong rendered value -> the real catalog value, where a single real
        // value can be named. Used by the correction prompt. A price issue maps
        // its rendered claim ("$18") to the format's real price when the brief
        // implies a single format, otherwise to the nearest real price. A size or
        // SKU issue maps to the catalog form when unambiguous; ambiguous cases are
        // left out of the map (the issues list still carries the full detail).
        let corrections: [String: String]
    }

    // Audit a generated artifact using only the brief to detect the brand. This
    // is the entry point GroundedGenerator calls: it does NOT require the caller
    // to know the brand up front. When no known brand is detected from the brief,
    // there is no ground truth to audit against, so the result is grounded (empty)
    // by construction: the guard never fabricates a brand or a fact.
    static func audit(_ artifact: String, brief: String) -> AuditResult {
        guard let brand = detectBrand(in: brief) else {
            return AuditResult(brand: nil, factIssues: [], corrections: [:])
        }
        let factIssues = audit(brand: brand, artifact: artifact)
        let corrections = buildCorrections(brand: brand, brief: brief, issues: factIssues)
        return AuditResult(brand: brand, factIssues: factIssues, corrections: corrections)
    }

    // Build the wrong-value -> real-value map for the correction prompt. Real
    // values only, read straight from the catalog: never an invented "fix".
    private static func buildCorrections(brand: String, brief: String, issues: [FactIssue]) -> [String: String] {
        guard let key = ProductCatalog.shared.canonicalBrand(brand) else { return [:] }
        let facts = ProductCatalog.shared.factsFor(brand: key)
        guard !facts.isEmpty else { return [:] }

        // If the brief implies one specific format, we can name its exact real
        // value as the fix. Otherwise we only correct when the catalog is
        // unambiguous (a single real value for that kind).
        let impliedFormat = formatHinted(in: brief)

        var map: [String: String] = [:]
        for issue in issues {
            switch issue.kind {
            case .price:
                if let f = impliedFormat, let p = ProductCatalog.shared.expectedPrice(brand: key, format: f) {
                    map[issue.claim] = "$\(p)"
                } else {
                    let prices = ProductCatalog.shared.validPrices(brand: key)
                    if prices.count == 1, let only = prices.first {
                        map[issue.claim] = "$\(only)"
                    }
                }
            case .size:
                if let f = impliedFormat, let fact = ProductCatalog.shared.fact(brand: key, format: f) {
                    map[issue.claim] = fact.sizeText
                } else {
                    let sizes = ProductCatalog.shared.validSizes(brand: key)
                    if sizes.count == 1, let only = sizes.first {
                        map[issue.claim] = only
                    }
                }
            case .sku:
                // The real SKU shape; the scent half is whatever the artifact used,
                // so we point at the valid format suffix set rather than inventing a scent.
                map[issue.claim] = issue.expected
            }
        }
        return map
    }

    // Which product format (if any) does the brief clearly name? Used to pick the
    // single real value for a correction. Conservative: returns nil when the brief
    // names no format or more than one.
    private static func formatHinted(in brief: String) -> ProductFormat? {
        let lower = brief.lowercased()
        var hits: [ProductFormat] = []
        if lower.contains("body wash") || lower.contains("wash") { hits.append(.wash) }
        if lower.contains("lotion") { hits.append(.lotion) }
        if lower.contains("bar soap") || lower.contains("bar") { hits.append(.bar) }
        if lower.contains("scrub") { hits.append(.scrub) }
        return hits.count == 1 ? hits.first : nil
    }

    // MARK: Price audit

    // Flag a "$NN" that reads as a PRODUCT price but is not any real catalog
    // price for this brand. Matches "$18", "$18.00", "$ 18", "$150".
    //
    // The decision of whether a "$N" is a PRODUCT price is made by PROXIMITY to a
    // product/format word, NOT by a flat magnitude ceiling. The old cutoff
    // (dollars <= 100) silently let an invented premium price like "$150 body
    // wash" through, which is the same invented-fact class as the $18 bug, just
    // at a larger number. So instead: a "$N" is a product-price claim only when a
    // product/format/scent word sits within a small window of the amount. That
    // catches "$150 luxury body wash" while leaving "$750 sprint", "$249
    // teardown", and "$50K gate" alone (no product word near them), with no
    // arbitrary dollar ceiling. The K/M scale suffix is still excluded from the
    // match itself (a "$50K" is never a bottle price).
    private static func auditPrices(brand: String, artifact: String, facts: [ProductFact]) -> [FactIssue] {
        let validPrices = ProductCatalog.shared.validPrices(brand: brand)
        let expected = validPrices.sorted().map { "$\($0)" }.joined(separator: ", ")
        var out: [FactIssue] = []

        let ns = artifact as NSString
        let lower = artifact.lowercased()
        let lowerNS = lower as NSString
        let productWords = productContextWords(brand: brand)

        // $ then optional space, then digits (up to 4, so $150 and $1200 are
        // candidates), optional .dd, NOT followed by a K/M scale suffix.
        let pattern = "\\$\\s?([0-9]{1,4})(?:\\.([0-9]{2}))?(?![0-9KkMm])"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = rx.matches(in: artifact, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let claim = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            let dollarsStr = ns.substring(with: m.range(at: 1))
            let centsStr = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            guard let dollars = Int(dollarsStr) else { continue }

            // Cents on a catalog price are themselves a mismatch (catalog prices
            // are whole-dollar). A real price with .00 is tolerated; anything
            // else with cents is flagged.
            let hasNonZeroCents = !centsStr.isEmpty && Int(centsStr) != 0

            // A real catalog price (whole-dollar) is always grounded, near a
            // product word or not.
            if validPrices.contains(dollars) && !hasNonZeroCents { continue }

            // Otherwise it is only a PRODUCT-price claim (and thus an issue) when
            // a product/format/scent word sits within the proximity window. This
            // replaces the magnitude ceiling: "$150 body wash" is flagged because
            // "body wash" is adjacent, "$750 sprint" is not because no product
            // word is near it.
            guard isNearProductWord(matchRange: m.range, in: lowerNS, productWords: productWords) else { continue }

            out.append(FactIssue(
                kind: .price,
                claim: claim,
                found: hasNonZeroCents ? "\(dollars).\(centsStr)" : "\(dollars)",
                expected: expected.isEmpty ? "(no catalog prices)" : expected
            ))
        }
        return out
    }

    // The product/format/scent vocabulary for a brand, lowercased. A "$N" sitting
    // near any of these reads as a product-price claim. Mirrors the product
    // context gate ConfidenceGateGrounding.ungroundedFact uses, so both paths
    // agree on what "product context" means.
    private static func productContextWords(brand: String) -> [String] {
        var words: [String] = ["body wash", "body lotion", "bar soap", "body scrub", "bottle", "jar"]
        for fmt in ProductFormat.allCases {
            words.append(fmt.label.lowercased())   // "body wash", "bar soap", etc.
            words.append(fmt.rawValue)             // "wash", "lotion", "bar", "scrub"
        }
        words.append(contentsOf: ProductCatalog.shared.scents(brand: brand).map { $0.lowercased() })
        // Spaced scent forms ("ocean mist" as well as "ocean-mist").
        words.append(contentsOf: ProductCatalog.shared.scents(brand: brand)
            .map { $0.lowercased().replacingOccurrences(of: "-", with: " ") })
        return words
    }

    // True when a product/format/scent word occurs within a proximity window of
    // the matched amount. The window is a fixed character span on each side, big
    // enough to span a normal clause ("Just $18 for a generous bottle", "$150
    // luxury body wash") but not the whole document, so a "$750 sprint" three
    // sentences away from an unrelated "body wash" mention is not falsely linked.
    private static func isNearProductWord(matchRange: NSRange, in lowerNS: NSString, productWords: [String]) -> Bool {
        let window = 48
        let start = max(0, matchRange.location - window)
        let end = min(lowerNS.length, matchRange.location + matchRange.length + window)
        let span = NSRange(location: start, length: end - start)
        let context = lowerNS.substring(with: span)
        return productWords.contains { !$0.isEmpty && context.contains($0) }
    }

    // MARK: Size audit

    // Flag an "NN oz" (or "NN.N oz") size that matches no product for this brand.
    // Sizes in the catalog are stored as exact strings ("16.9 oz", "10.2 oz",
    // "5.5 oz", and the bar "2 x 4.95 oz"), but a draft may legitimately quote the
    // PACK TOTAL too (the bar 2-pack is 9.9 oz: 2 x 4.95). So the valid-size set is
    // derived from ProductCatalogSeed.rows (the single source of truth), taking the
    // per-unit sizeOz AND, for any multi-unit format, the pack total sizeOz *
    // packCount. This is the IDENTICAL computation JaxProductFacts.validSizesOz
    // performs from the same seed, so the nonisolated ungrounded-fact check and
    // this POST audit can never disagree on whether 9.9 oz is grounded. A "9.5 oz
    // body wash" is still flagged; "16.9 oz" and "9.9 oz total" both pass.
    private static func auditSizes(brand: String, artifact: String, facts: [ProductFact]) -> [FactIssue] {
        var validOz = Set<Double>()
        for row in ProductCatalogSeed.rows {
            validOz.insert(row.sizeOz)
            if row.packCount > 1 { validOz.insert(row.totalOz) }
        }
        guard !validOz.isEmpty else { return [] }
        let expected = ProductCatalog.shared.validSizes(brand: brand).sorted().joined(separator: ", ")
        var out: [FactIssue] = []

        let ns = artifact as NSString
        // digits with an optional 1-2 place decimal, a space-ish gap, then oz.
        // The leading (?<![0-9.]) boundary stops the engine from matching the
        // trailing digits of a decimal as their own number: without it "4.95 oz"
        // mis-matched as "95 oz" and falsely flagged a grounded bar size. Allowing
        // up to two decimals lets "4.95" match as a single token.
        let pattern = "(?<![0-9.])([0-9]{1,3}(?:\\.[0-9]{1,2})?)\\s?(?:oz|ounce|ounces)\\b"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let matches = rx.matches(in: artifact, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let claim = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            let numStr = ns.substring(with: m.range(at: 1))
            guard let oz = Double(numStr) else { continue }
            if validOz.contains(where: { abs($0 - oz) < 0.01 }) { continue }
            out.append(FactIssue(
                kind: .size,
                claim: claim,
                found: "\(numStr) oz",
                expected: expected.isEmpty ? "(no catalog sizes)" : expected
            ))
        }
        return out
    }

    // MARK: SKU audit

    // Flag a "<scent>-<suffix>" token that LOOKS like a catalog SKU (a known scent
    // followed by a hyphen and a word) but is not a VALID catalog SKU. A valid
    // SKU is a known scent + a known format suffix (wash/lotion/bar/scrub). So
    // "ocean-mist-wash" passes, "ocean-mist-cream" (no such format) is flagged,
    // and a bare "ocean-mist" is not treated as a SKU claim at all.
    private static func auditSKUs(brand: String, artifact: String) -> [FactIssue] {
        let scents = ProductCatalog.shared.scents(brand: brand).map { $0.lowercased() }
        guard !scents.isEmpty else { return [] }
        let validSuffixes = Set(ProductFormat.allCases.map { $0.skuSuffix })
        let expectedSuffix = validSuffixes.sorted().joined(separator: ", ")
        let lower = artifact.lowercased()
        var out: [FactIssue] = []

        for scent in scents {
            // Find "<scent>-<token>" occurrences. We look for the scent followed
            // by a hyphen and a trailing alpha token.
            var searchStart = lower.startIndex
            while let r = lower.range(of: scent + "-", range: searchStart..<lower.endIndex) {
                // Pull the suffix token after "<scent>-".
                var i = r.upperBound
                var suffix = ""
                while i < lower.endIndex, lower[i].isLetter {
                    suffix.append(lower[i])
                    i = lower.index(after: i)
                }
                searchStart = i < lower.endIndex ? lower.index(after: i) : lower.endIndex
                guard !suffix.isEmpty else { continue }
                // A known suffix is a valid SKU: not an issue.
                if validSuffixes.contains(suffix) { continue }
                // An unknown suffix on a known scent is an invented SKU.
                let claim = "\(scent)-\(suffix)"
                out.append(FactIssue(
                    kind: .sku,
                    claim: claim,
                    found: claim,
                    expected: "<scent>-{\(expectedSuffix)}"
                ))
            }
        }
        return out
    }

    // MARK: Helpers

    // Extract the oz value(s) from a catalog size string. "16.9 oz" -> [16.9];
    // "2 x 4.95 oz" -> [4.95] (the per-unit oz, which is what copy would cite).
    // Pure + nonisolated so it can be unit-tested without the main actor.
    nonisolated static func ozValues(in sizeText: String) -> [Double] {
        let ns = sizeText as NSString
        let pattern = "([0-9]{1,3}(?:\\.[0-9]+)?)\\s?(?:oz|ounce|ounces)\\b"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let matches = rx.matches(in: sizeText, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { Double(ns.substring(with: $0.range(at: 1))) }
    }

    // Stable de-dupe (same kind + claim + found counts once) preserving order.
    private static func dedupe(_ issues: [FactIssue]) -> [FactIssue] {
        var seen = Set<String>()
        var out: [FactIssue] = []
        for i in issues where seen.insert(i.id).inserted {
            out.append(i)
        }
        return out
    }

    // MARK: Cognition trace

    // Record an honest grounding event. Real data only: whether the guard found a
    // contradiction, how many, for which brand. A clean audit is recorded as a
    // grounded retrieval (the guard ran, nothing was invented). A mismatch is
    // recorded as TRUE confusion ("clarify"), matching how the rest of Jax treats
    // an ungrounded fact: do not publish, regenerate or ask. Does not redefine
    // any CognitionTrace type; just calls its note(...) API.
    private static func recordTrace(brand: String, issues: [FactIssue], artifactChars: Int) {
        if issues.isEmpty {
            CognitionTrace.shared.note(
                kind: .task,
                trigger: "fact grounding audit (\(brand))",
                memoriesRetrieved: ["\(brand) product catalog (ground truth)"],
                gateVerdict: "proceed",
                gateReason: "Generated \(brand) artifact (\(artifactChars) chars) matches catalog ground truth. No invented price, size, or SKU.",
                mode: AutonomyMode.simulate.rawValue,
                outcome: "Grounded: every product fact traces to the catalog."
            )
        } else {
            let summary = issues.prefix(3).map { $0.claim }.joined(separator: ", ")
            CognitionTrace.shared.note(
                kind: .task,
                trigger: "fact grounding audit (\(brand))",
                memoriesRetrieved: ["\(brand) product catalog (ground truth)"],
                gateVerdict: "clarify",
                gateReason: "Generated \(brand) artifact asserts product facts that contradict the catalog: \(summary). An ungrounded fact is true confusion, not a guess to publish.",
                confidence: 0.2,
                mode: AutonomyMode.simulate.rawValue,
                outcome: "Blocked publish on \(issues.count) invented fact\(issues.count == 1 ? "" : "s"). Regenerate with grounding or ask."
            )
        }
    }
}
