import Foundation

// ConfidenceGateGrounding: the ungrounded-fact extension to ConfidenceGate.
//
// THE BUG THIS CLOSES: in an end-to-end content run, Jax wrote that a catalog
// body wash "costs $18". The real price is $15. Jax INVENTED a product number. That
// is the exact failure the never-guess mechanism exists to prevent, but the
// content path was not routing factual assertions through the gate, so nothing
// caught it.
//
// The fix, in one sentence: a request (or a draft) that ASSERTS a specific
// product fact (a price, a size, a SKU, a pack count) which is NOT backed by the
// real catalog is treated as TRUE confusion, exactly like a missing referent or
// an unknown term. Jax must look the fact up or ask, never fill the gap with a
// plausible-looking number.
//
// This file does NOT edit ConfidenceGate.swift. It adds:
//   1. JaxProductFacts: a small, self-contained, canonical product catalog
//      seeded from the brand's locked rules. This is the ground truth it reads.
//      It is intentionally embedded here (not a guess, the real locked numbers)
//      so the never-guess check has a real catalog to verify against even before
//      a richer ProductCatalog service is wired in. If a fuller catalog lands
//      later, this stays the offline fallback; the API below is the seam.
//   2. A ConfidenceGate extension with groundedFactConfusion(...) and the
//      assessGrounded(...) wrapper that layers the ungrounded-fact signal on top
//      of the existing structural heuristics, returning the same ConfidenceVerdict
//      type so callers (ChatService, the content path, CognitionTrace) are
//      unchanged in shape.
//
// House style: enum-namespaced pure logic, Codable-friendly values, zero em/en
// dashes, dollars as $N, no vendor/model/stack names. No new SPM deps.

// MARK: - JaxProductFacts (the real catalog, ground truth)

// The canonical product catalog, now a PROJECTION of ProductCatalogSeed
// (the one nonisolated source of truth) rather than a self-contained duplicate.
// Every number is a real, sourced fact, not a guess, and traces to the same seed
// the @MainActor ProductCatalog reads, so the two can never drift apart. The
// grounding check reads this to decide whether an asserted product number is
// true (matches the catalog) or invented (does not). If a fact is not here, the
// honest answer is "I do not have this, look it up or ask", never a fabricated
// value.
enum JaxProductFacts {

    // One product format's real facts, projected from the single source of truth
    // (ProductCatalogSeed). No literals live here anymore: priceUSD/sizeOz/packCount
    // are read straight from the shared seed, so this view can never drift from
    // the @MainActor ProductCatalog that seeds from the same place.
    struct Format: Equatable {
        let key: String          // canonical format key, e.g. "wash"
        let displayName: String  // human label, e.g. "Body Wash"
        let priceUSD: Int        // real price in whole dollars
        let sizeOz: Double       // real net size of ONE unit, in fluid/weight oz
        let packCount: Int       // units per SKU (bar soap is always 2)
        let skuSuffix: String    // SKU pattern suffix, e.g. "wash" -> "<scent>-wash"
        let subscribeCadenceDays: Int  // Subscribe and Save cadence for this format

        // The two oz figures a draft might state for a multi-pack: the per-unit
        // size and the implied total. Both are legitimate ground truth, so a
        // draft that says either is grounded.
        var perUnitOz: Double { sizeOz }
        var totalOz: Double { sizeOz * Double(packCount) }
    }

    // The four real formats, mapped from ProductCatalogSeed.rows. Body Wash $15 /
    // 16.9 oz is the row the $18 bug got wrong. The literal numbers now live ONLY
    // in ProductCatalogSeed, shared with the @MainActor ProductCatalog seed.
    static let formats: [Format] = ProductCatalogSeed.rows.map { r in
        Format(
            key: r.formatKey,
            displayName: r.label,
            priceUSD: r.priceDollars,
            sizeOz: r.sizeOz,
            packCount: r.packCount,
            skuSuffix: r.skuSuffix,
            subscribeCadenceDays: r.cadenceDays
        )
    }

    // The 10 real scent ids, from the shared seed.
    static let scents: [String] = ProductCatalogSeed.variants

    // Subscribe and Save discount, from the shared seed.
    static let subscribeSavePercent = ProductCatalogSeed.subscribeSavePercent

    // Support address, from the shared seed.
    static let supportEmail = ProductCatalogSeed.supportEmail

    // MARK: Fact membership checks

    // The full set of valid prices across the catalog, as whole-dollar Ints.
    // Used to test whether an asserted dollar amount corresponds to ANY real
    // product price. $15, $22, $13 are grounded; $18 is not.
    static let validPricesUSD: Set<Int> = Set(formats.map { $0.priceUSD })

    // The full set of valid net sizes (per-unit AND pack-total), as oz. A draft
    // may legitimately quote 16.9, 10.2, 4.95, 9.9 (the bar 2-pack total), 5.5.
    static let validSizesOz: Set<Double> = {
        var s = Set<Double>()
        for f in formats {
            s.insert(f.perUnitOz)
            if f.packCount > 1 { s.insert(f.totalOz) }
        }
        return s
    }()

    // True when the integer dollar amount matches a real product price.
    static func isGroundedPrice(_ dollars: Int) -> Bool {
        validPricesUSD.contains(dollars)
    }

    // True when the oz value matches a real product size (per-unit or pack total)
    // within a tiny tolerance (floating point + rounding like 9.9 vs 9.90).
    static func isGroundedSize(_ oz: Double) -> Bool {
        validSizesOz.contains { abs($0 - oz) < 0.051 }
    }

    // True when a "<scent>-<suffix>" SKU is fully real: both the scent id and the
    // format suffix exist in the catalog. Tolerant of case and surrounding
    // punctuation; the caller passes the bare token.
    static func isGroundedSKU(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,()[]"))
        guard t.contains("-") else { return false }
        for f in formats {
            let suffix = "-" + f.skuSuffix
            guard t.hasSuffix(suffix) else { continue }
            let scentPart = String(t.dropLast(suffix.count))
            if scents.contains(scentPart) { return true }
        }
        return false
    }

    // Human-readable price and size rosters, BUILT from the catalog rather than
    // retyped as prose. The old versions were hand-written duplicates of the
    // seed, so they could drift from the numbers the check actually enforces,
    // and they hardcoded one brand's product line into a message the model
    // reads.
    //
    // Each returns a WHOLE clause, not a fragment, so the empty-catalog case
    // still reads as a finished sentence at the call site instead of "Real
    // prices are . $18 is not one of them".
    static var priceHint: String {
        guard !formats.isEmpty else { return "I have no product catalog loaded" }
        return "Real prices are " + formats.map { "$\($0.priceUSD) \($0.key)" }.joined(separator: ", ")
    }

    static var sizeHint: String {
        guard !formats.isEmpty else { return "I have no product catalog loaded" }
        return "Real sizes are " + formats.map { f in
            let each = f.packCount > 1 ? " each (\(f.packCount)-pack)" : ""
            return "\(trimOz(f.perUnitOz)) oz \(f.key)\(each)"
        }.joined(separator: ", ")
    }

    // 16.9 not 16.90, 5.5 not 5.50: the on-pack numbers read as written.
    private static func trimOz(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    // The honest, sourced answer for a format's price, for the clarify/lookup
    // path. Returns nil when the format key is unknown (then the gate asks).
    static func format(_ key: String) -> Format? {
        formats.first { $0.key == key }
    }
}

// MARK: - Grounded-fact confusion signal

// A detected ungrounded factual assertion: the surface number the draft/request
// stated, what KIND of fact it is, and the honest correction or lookup hint.
struct UngroundedFact: Equatable {
    enum Kind: String { case price, size, sku }
    let kind: Kind
    let stated: String        // exactly what was asserted, e.g. "$18"
    let lookupHint: String    // the honest "here is what the catalog says / look it up" line
}

extension ConfidenceGate {

    // MARK: Ungrounded-fact detection (pure)

    // Scan a piece of text (a user request that demands a fact, OR a generated
    // draft about to be published) for a specific product number that is NOT in
    // the catalog. This is the signal that should have caught the $18.
    //
    // Conservative by construction, to avoid nagging:
    //   - It only fires when the text reads as product context (a product
    //     format word is present, or the brand matches), so unrelated dollar amounts
    //     ("the sprint is $750") are never flagged.
    //   - A dollar amount that MATCHES a real price is grounded and ignored.
    //   - An oz size that matches a real size is grounded and ignored.
    //   - Only an asserted number that lands in product context AND fails the
    //     catalog check is returned.
    //
    // Returns the FIRST ungrounded fact found (one specific question beats a
    // pile), or nil when every stated product number is backed by the catalog.
    nonisolated static func ungroundedFact(in text: String,
                                           brand: String? = nil) -> UngroundedFact? {
        let lower = text.lowercased()

        // Gate on product context so we never flag money/sizes outside the
        // catalog's own brand. The brand key comes from the seed, never a
        // literal here, so this file names no brand of its own.
        let brandKey = ProductCatalogSeed.brand.lowercased()
        let brandIsCatalog = !brandKey.isEmpty
            && (brand?.lowercased().contains(brandKey) ?? false)
        let formatWords = JaxProductFacts.formats.flatMap { f -> [String] in
            // "body wash" and "wash", "bar soap" and "bar", etc.
            [f.displayName.lowercased(), f.key]
        }
        let mentionsProduct = brandIsCatalog
            || formatWords.contains { lower.contains($0) }
            || JaxProductFacts.scents.contains { lower.contains($0) }
            || lower.contains("body wash") || lower.contains("bar soap")
            || lower.contains("body lotion") || lower.contains("body scrub")
        guard mentionsProduct else { return nil }

        // 1. PRICE assertions: $N or "N dollars" (we still detect the spelled
        //    form so a draft that slipped past the style rule is still grounded).
        if let bad = firstUngroundedPrice(in: text) { return bad }

        // 2. SIZE assertions: "N oz" / "N ounce(s)".
        if let bad = firstUngroundedSize(in: lower) { return bad }

        // 3. SKU assertions: a "<scent>-<suffix>"-shaped token that is not real.
        if let bad = firstUngroundedSKU(in: lower) { return bad }

        return nil
    }

    // Find the first asserted dollar amount that is not a real product price.
    nonisolated private static func firstUngroundedPrice(in text: String) -> UngroundedFact? {
        // Match $N or $N.NN. We treat the dollars portion as the price
        // (catalog prices are whole-dollar), so "$18.00" and "$18" resolve to 18.
        let pattern = "\\$\\s?([0-9]{1,4})(?:\\.([0-9]{2}))?"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let whole = ns.substring(with: m.range)
            let dollarsStr = ns.substring(with: m.range(at: 1))
            guard let dollars = Int(dollarsStr) else { continue }
            // A cents portion that is not .00 means the matched amount is not a
            // whole-dollar catalog price at all, so check the whole-dollar value;
            // either way, if the dollars value is not a real price, it is invented.
            if !JaxProductFacts.isGroundedPrice(dollars) {
                let stated = whole.trimmingCharacters(in: .whitespaces)
                return UngroundedFact(
                    kind: .price,
                    stated: stated,
                    lookupHint: "\(JaxProductFacts.priceHint). \(stated) is not one of them, so I will not state it. Tell me the SKU and I will pull the real price."
                )
            }
        }
        return nil
    }

    // Find the first asserted oz size that is not a real product size.
    nonisolated private static func firstUngroundedSize(in lower: String) -> UngroundedFact? {
        let pattern = "([0-9]{1,3}(?:\\.[0-9]{1,2})?)\\s?(?:oz|ounce|ounces)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        let matches = re.matches(in: lower, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let numStr = ns.substring(with: m.range(at: 1))
            guard let oz = Double(numStr) else { continue }
            if !JaxProductFacts.isGroundedSize(oz) {
                let stated = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                return UngroundedFact(
                    kind: .size,
                    stated: stated,
                    lookupHint: "\(JaxProductFacts.sizeHint). \(stated) is not a real size, so I will not state it. Tell me the SKU and I will pull the real size."
                )
            }
        }
        return nil
    }

    // Find the first SKU-shaped token that is not a real SKU. Two shapes are
    // caught, both of which are the never-guess failure:
    //
    //   1. KNOWN-SUFFIX shape: "<something>-wash" where the something is not a
    //      real scent (e.g. "midnight-wash"). The token ends in a real format
    //      suffix but the scent half is invented.
    //
    //   2. INVENTED-FORMAT shape: "<known-scent>-<unknown-suffix>" where the
    //      scent half IS a real scent but the trailing segment is not a real
    //      format (e.g. "lavender-forest-gel"). This is the case the original
    //      check missed: inventing a non-existent product FORMAT is exactly as
    //      bad as inventing the $18 price, so a fabricated "-gel" SKU must fail.
    //
    // Ordinary hyphenated words are not flagged because shape 1 requires a real
    // format suffix and shape 2 requires a real scent prefix; a word that matches
    // neither half is left alone.
    nonisolated private static func firstUngroundedSKU(in lower: String) -> UngroundedFact? {
        let suffixes = JaxProductFacts.formats.map { $0.skuSuffix }
        let validSuffixSet = Set(suffixes)
        let tokens = lower.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)

        for token in tokens {
            guard token.contains("-") else { continue }

            // Shape 1: ends in a real format suffix.
            let endsInKnownSuffix = suffixes.contains { token.hasSuffix("-" + $0) }

            // Shape 2: starts with a real scent followed by a hyphen, but the
            // trailing segment after that scent is NOT a real format suffix. We
            // split on the LAST hyphen so the scent half can itself contain
            // hyphens ("lavender-forest"): scentPart = everything before the last
            // hyphen, tail = the final segment.
            var inventedFormatOnRealScent = false
            if let lastDash = token.range(of: "-", options: .backwards) {
                let scentPart = String(token[token.startIndex..<lastDash.lowerBound])
                let tail = String(token[lastDash.upperBound...])
                if !tail.isEmpty,
                   JaxProductFacts.scents.contains(scentPart),
                   !validSuffixSet.contains(tail) {
                    inventedFormatOnRealScent = true
                }
            }

            guard endsInKnownSuffix || inventedFormatOnRealScent else { continue }
            if !JaxProductFacts.isGroundedSKU(token) {
                return UngroundedFact(
                    kind: .sku,
                    stated: token,
                    lookupHint: "\(token) is not a real SKU. Real SKUs are <scent>-wash, <scent>-lotion, <scent>-bar, <scent>-scrub across 10 known scents. There is no other format. I will not state a SKU I cannot back."
                )
            }
        }
        return nil
    }

    // MARK: Grounded assessment (the production entry point)

    // The same shape as assess(...), with the ungrounded-fact signal layered in
    // FIRST. A request that demands an unbacked product fact is true confusion:
    // we return an ask verdict (confidence pinned at or below the confused floor)
    // before the structural heuristics even run, because the structurally-clear
    // request "say the wash is $18" reads as perfectly well-formed to the
    // structural checks. That is precisely the gap the $18 bug exposed: clear
    // structure, false fact.
    //
    // factText is what to scan for product numbers. For a user request, pass the
    // prompt. For a generated draft (the content path), pass the DRAFT so a
    // hallucinated $18 in the output is caught before it is published. Callers
    // that want both can call ungroundedFact(in:) on the draft directly after a
    // confident structural verdict.
    static func assessGrounded(prompt: String,
                               factText: String? = nil,
                               context: ConfidenceContext = ConfidenceContext(),
                               apiKey: String = "",
                               model: String = "") async -> ConfidenceVerdict {
        let scanText = factText ?? prompt
        if let bad = ungroundedFact(in: scanText, brand: context.brand) {
            return .confused(
                min(confusedFloor, 0.25),
                question: clarifyForUngrounded(bad),
                reason: "Ungrounded product \(bad.kind.rawValue): \(bad.stated) is not in the catalog. Treating an unbacked factual number as true confusion (look it up or ask, never invent).",
                source: .heuristic
            )
        }
        return await assess(prompt: prompt, context: context, apiKey: apiKey, model: model)
    }

    // Pure, synchronous variant for tests and the content path: structural
    // heuristic verdict with the ungrounded-fact signal layered in, no model.
    nonisolated static func assessGroundedHeuristic(prompt: String,
                                                    factText: String? = nil,
                                                    context: ConfidenceContext = ConfidenceContext()) -> ConfidenceVerdict {
        let scanText = factText ?? prompt
        if let bad = ungroundedFact(in: scanText, brand: context.brand) {
            return .confused(
                min(confusedFloor, 0.25),
                question: clarifyForUngrounded(bad),
                reason: "Ungrounded product \(bad.kind.rawValue): \(bad.stated) is not in the catalog. Treating an unbacked factual number as true confusion (look it up or ask, never invent).",
                source: .heuristic
            )
        }
        return assessHeuristic(prompt: prompt, context: context)
    }

    // The single specific clarifying question for an ungrounded fact. Names the
    // exact number and points at the real catalog, never a generic "what do you
    // mean". This is the honest "I will not invent this" Jax should say.
    nonisolated static func clarifyForUngrounded(_ fact: UngroundedFact) -> String {
        switch fact.kind {
        case .price:
            return "I will not state \(fact.stated). I do not invent prices. \(fact.lookupHint)"
        case .size:
            return "I will not state \(fact.stated). I do not invent sizes. \(fact.lookupHint)"
        case .sku:
            return "I will not state \(fact.stated). I do not invent SKUs. \(fact.lookupHint)"
        }
    }
}
