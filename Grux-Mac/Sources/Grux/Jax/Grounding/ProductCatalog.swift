import Foundation

// ProductCatalog: the REAL, seeded source of product facts Jax retrieves from.
//
// This is the anti-hallucination foundation. Jax's hard rule is that it never
// guesses or makes things up: a product fact (price, size, SKU, cadence) is the
// kind of detail a language model will happily INVENT a plausible-but-wrong
// number for. So content generation must RETRIEVE these facts from here, never
// generate them. When Jax needs a price and it is not in this catalog, that is
// TRUE confusion: look it up or ask, never invent.
//
// What lives here is exactly what the configured brand rules say, byte for
// byte. The numbers are NOT computed, inferred, or rounded by Jax: they are
// transcribed from the canonical brand spec and stored as ground truth.
//
// House style mirrors the rest of Jax: @MainActor ObservableObject singleton,
// Codable, local persistence under ~/.grux/jax/ so an updated catalog survives
// relaunch, zero em/en dashes, dollars as $N. No new SPM dependencies.
//
// Sibling note: FactGuard.swift (built alongside) is the guard that consumes
// this catalog two ways, a PRE grounding-context injector and a POST fact
// auditor. This file owns the DATA; FactGuard owns the DETECTION. Neither
// redefines the other.

// MARK: - Product format

// The four seeded product formats. Each carries the exact size + price + SKU
// suffix from the brand spec. Bar soap is ALWAYS a 2-pack: there is no
// single-bar SKU, so the format encodes that truth rather than leaving it
// implicit.
enum ProductFormat: String, Codable, CaseIterable, Hashable {
    case wash
    case lotion
    case bar
    case scrub

    // The SKU suffix appended to a scent id: "<scent>-wash" etc.
    var skuSuffix: String { rawValue }

    // Human label for copy + reports.
    var label: String {
        switch self {
        case .wash:   return "Body Wash"
        case .lotion: return "Body Lotion"
        case .bar:    return "Bar Soap"
        case .scrub:  return "Body Scrub"
        }
    }
}

// MARK: - Product fact

// One ground-truth product fact row. Every field is transcribed from the brand
// spec, never derived by Jax. priceDollars is the whole-dollar list price (all
// four seeded formats are whole dollars); sizeText is the exact on-pack size string
// ("16.9 oz", "2 x 4.95 oz"); subscribeCadenceDays is the Subscribe and Save
// cadence in days. packNote captures pack rules that copy must not get wrong
// (the bar 2-pack).
struct ProductFact: Codable, Hashable, Identifiable {
    let brand: String
    let format: ProductFormat
    let priceDollars: Int
    let sizeText: String
    let packNote: String
    let subscribeCadenceDays: Int

    // Stable identity = brand + format (one fact row per format per brand).
    var id: String { "\(brand.lowercased())-\(format.rawValue)" }

    // The canonical SKU for a given scent: "<scent>-<suffix>".
    func sku(scent: String) -> String {
        "\(scent)-\(format.skuSuffix)"
    }

    // The dollar amount rendered as $N, the only acceptable price form in copy.
    // Never "15 dollars", never "fifteen dollars".
    var priceString: String { "$\(priceDollars)" }

    // A single honest line a grounding block can show:
    //   "Body Wash: 16.9 oz, $15, SKU <scent>-wash (single)"
    var summaryLine: String {
        "\(format.label): \(sizeText), \(priceString), SKU <scent>-\(format.skuSuffix) (\(packNote))"
    }
}

// MARK: - Catalog

@MainActor
final class ProductCatalog: ObservableObject {
    static let shared = ProductCatalog()

    // All ground-truth facts, keyed nowhere fancy: a flat list the guard scans.
    // @Published so a future catalog editor surface can bind to it.
    @Published private(set) var facts: [ProductFact] = []

    // The scent ids per brand. Used to detect "is this brief about the seeded
    // brand?" and to resolve a concrete SKU when copy names a scent.
    @Published private(set) var scentsByBrand: [String: [String]] = [:]

    // Brand-level support contact, so generated comms cite the real address
    // rather than inventing one.
    @Published private(set) var supportEmailByBrand: [String: String] = [:]

    private let storeURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("jax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("product-catalog.json")
    }()

    private init() {
        load()
        // Seed the canonical facts if the catalog is empty (first launch) or is
        // missing the seeded brand. The seed is the source of truth: a stale
        // persisted file from before this rule shipped gets the real facts back.
        if facts.isEmpty || factsFor(brand: ProductCatalogSeed.brand).isEmpty {
            seedCanonicalBrand()
            save()
        }
    }

    // MARK: Seed (canonical ground truth)

    // Transcribed EXACTLY from the locked brand rules. Do not alter these
    // numbers: they are the fix for the invented-$18 hallucination. Bar soap is
    // a 2-pack at $13 with no single-bar SKU; the packNote carries that.
    private func seedCanonicalBrand() {
        let brand = ProductCatalogSeed.brand
        // Build the canonical rows from the single source of truth. The literal
        // numbers no longer live here: they live ONLY in ProductCatalogSeed, shared
        // with the nonisolated ungrounded-fact check so the two can never drift.
        let rows: [ProductFact] = ProductCatalogSeed.rows.compactMap { r in
            guard let fmt = ProductFormat(rawValue: r.formatKey) else { return nil }
            return ProductFact(
                brand: brand,
                format: fmt,
                priceDollars: r.priceDollars,
                sizeText: r.sizeText,
                packNote: ProductCatalogSeed.packNote(forFormatKey: r.formatKey),
                subscribeCadenceDays: r.cadenceDays
            )
        }
        // Replace any existing rows for this brand, keep other brands untouched.
        facts.removeAll { $0.brand.caseInsensitiveCompare(brand) == .orderedSame }
        facts.append(contentsOf: rows)

        scentsByBrand[brand] = ProductCatalogSeed.variants
        supportEmailByBrand[brand] = ProductCatalogSeed.supportEmail
    }

    // MARK: Lookups

    // Case-insensitive brand match: any casing of a known brand key resolves.
    // Returns the canonical brand key actually stored, or nil when unknown.
    func canonicalBrand(_ brand: String) -> String? {
        let needle = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let row = facts.first(where: { $0.brand.caseInsensitiveCompare(needle) == .orderedSame }) {
            return row.brand
        }
        // Also resolve a brand we know scents for but (defensively) have no facts.
        return scentsByBrand.keys.first(where: { $0.caseInsensitiveCompare(needle) == .orderedSame })
    }

    func factsFor(brand: String) -> [ProductFact] {
        facts.filter { $0.brand.caseInsensitiveCompare(brand) == .orderedSame }
    }

    func scents(brand: String) -> [String] {
        guard let key = canonicalBrand(brand) else { return [] }
        return scentsByBrand[key] ?? []
    }

    func supportEmail(brand: String) -> String? {
        guard let key = canonicalBrand(brand) else { return nil }
        return supportEmailByBrand[key]
    }

    func fact(brand: String, format: ProductFormat) -> ProductFact? {
        factsFor(brand: brand).first { $0.format == format }
    }

    // The set of valid prices (as whole dollars) for a brand. The auditor uses
    // this to decide whether a "$NN" in generated copy is a real catalog price
    // or an invented one.
    func validPrices(brand: String) -> Set<Int> {
        Set(factsFor(brand: brand).map { $0.priceDollars })
    }

    // The set of valid on-pack size strings for a brand, normalized lowercase.
    func validSizes(brand: String) -> Set<String> {
        Set(factsFor(brand: brand).map { $0.sizeText.lowercased() })
    }

    // The price a specific format should carry, for an expected-vs-found report.
    func expectedPrice(brand: String, format: ProductFormat) -> Int? {
        fact(brand: brand, format: format)?.priceDollars
    }

    // MARK: Grounding context block

    // The hard, retrievable fact block injected into a content/comms prompt. This
    // is the PRE half of the fix: the model is handed the real numbers and told,
    // in no uncertain terms, to use ONLY these and to never invent a missing one.
    // Returns an empty string for an unknown brand so the caller can decide to
    // skip injection rather than feed a misleading partial block.
    func contextBlock(brand: String) -> String {
        guard let key = canonicalBrand(brand) else { return "" }
        let rows = factsFor(brand: key).sorted { $0.format.rawValue < $1.format.rawValue }
        guard !rows.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("REAL \(key) PRODUCT FACTS (ground truth, retrieved from the catalog):")
        for r in rows {
            // e.g. "  Body Wash: 16.9 oz, $15, SKU <scent>-wash (single). Subscribe and Save 15% off, every 28 days."
            lines.append("  \(r.format.label): \(r.sizeText), \(r.priceString), SKU <scent>-\(r.format.skuSuffix) (\(r.packNote)). Subscribe and Save 15% off, every \(r.subscribeCadenceDays) days.")
        }
        let scentList = scents(brand: key)
        if !scentList.isEmpty {
            lines.append("  Scents (\(scentList.count)): \(scentList.joined(separator: ", ")).")
        }
        if let email = supportEmail(brand: key) {
            lines.append("  Support: \(email).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var facts: [ProductFact]
        var scentsByBrand: [String: [String]]
        var supportEmailByBrand: [String: String]
    }

    func load() {
        let snap = Persistence.load(Snapshot.self, from: storeURL,
                                    fallback: Snapshot(facts: [], scentsByBrand: [:], supportEmailByBrand: [:]))
        facts = snap.facts
        scentsByBrand = snap.scentsByBrand
        supportEmailByBrand = snap.supportEmailByBrand
    }

    private func save() {
        Persistence.save(Snapshot(facts: facts,
                                  scentsByBrand: scentsByBrand,
                                  supportEmailByBrand: supportEmailByBrand),
                         to: storeURL)
    }
}
