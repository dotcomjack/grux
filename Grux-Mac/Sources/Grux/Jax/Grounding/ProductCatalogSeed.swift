import Foundation

/// The single canonical source of product ground truth, loaded from disk.
///
/// Both the `@MainActor` `ProductCatalog` (the real retrieval service) and the
/// nonisolated `JaxProductFacts` / `ungroundedFact` check read from HERE, so the
/// numbers live in exactly one place and cannot drift apart.
///
/// ## Why this is empty by default
///
/// This file used to be `MCOCatalogSeed`, and it carried one real company's
/// price list, pack sizes, SKU patterns, scent ids and support address compiled
/// into the binary. That is that company's data, not Grux's, and it shipped to
/// everyone who installed the app.
///
/// Emptying it is also the SAFE default rather than a lossy one, which is the
/// part worth understanding before anyone "helpfully" adds rows back. The whole
/// purpose of the grounding gate is to refuse to state a product fact that is
/// not in this seed. It exists because the assistant once invented a $18 price
/// for a $15 product. With no seed, every product claim is ungrounded and the
/// gate refuses all of them. Silence is the correct behavior for a catalog Grux
/// has never been told about; inventing plausible numbers is not.
///
/// ## Why static lets and not a singleton
///
/// `ConfidenceGateGrounding.ungroundedFact` is `nonisolated static`, runs off
/// the main actor with no async, and cannot touch a `@MainActor` singleton. A
/// plain enum with static constants carries no actor isolation, so it is freely
/// readable from both the main-actor catalog seed and the nonisolated check.
/// That seam is why the loaded state is a lazily-initialized `static let` rather
/// than something observable.
enum ProductCatalogSeed {

    /// One seed row per format.
    ///   priceDollars : whole-dollar list price
    ///   sizeText     : exact on-pack display string ("2 x 4.95 oz", "5.5 oz jar")
    ///   sizeOz       : numeric net size of ONE unit, for size-grounding math
    ///   packCount    : units per SKU
    ///   skuSuffix    : SKU pattern suffix, "<variant>-<suffix>"
    ///   cadenceDays  : subscription cadence in days
    struct Row: Equatable, Sendable, Codable {
        let formatKey: String
        let label: String
        let priceDollars: Int
        let sizeText: String
        let sizeOz: Double
        let packCount: Int
        let skuSuffix: String
        let cadenceDays: Int

        var totalOz: Double { sizeOz * Double(packCount) }
    }

    /// The on-disk shape. Absent file means an empty catalog, which is a
    /// supported state and never an error.
    struct Catalog: Codable, Sendable {
        var brand: String = ""
        var rows: [Row] = []
        /// Variant ids. A SKU is "<variant>-<suffix>"; both halves must be real
        /// for the SKU to be grounded.
        var variants: [String] = []
        var subscribeSavePercent: Int = 0
        var supportEmail: String = ""
        /// Format keys whose rows ship as a multi-unit pack, so copy never
        /// claims a single unit. Was hardcoded to one company's bar soap.
        var multiPackFormatKeys: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            brand = try c.decodeIfPresent(String.self, forKey: .brand) ?? ""
            rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
            variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
            subscribeSavePercent = try c.decodeIfPresent(Int.self, forKey: .subscribeSavePercent) ?? 0
            supportEmail = try c.decodeIfPresent(String.self, forKey: .supportEmail) ?? ""
            multiPackFormatKeys = try c.decodeIfPresent([String].self, forKey: .multiPackFormatKeys) ?? []
        }
    }

    /// `~/.grux/product-catalog.json`, in Grux's own directory. Read once.
    ///
    /// A malformed file yields an empty catalog rather than a crash or a
    /// partial one: half a price list is more dangerous than none, because the
    /// gate would ground some claims and silently refuse others.
    static let catalog: Catalog = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux/product-catalog.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return Catalog() }
        return decoded
    }()

    static var brand: String { catalog.brand }
    static var rows: [Row] { catalog.rows }
    static var variants: [String] { catalog.variants }
    static var subscribeSavePercent: Int { catalog.subscribeSavePercent }
    static var supportEmail: String { catalog.supportEmail }

    /// True when there is nothing to ground against, so callers can say so
    /// plainly instead of rendering an empty catalog as though it were a real
    /// one with no matches.
    static var isEmpty: Bool { catalog.rows.isEmpty }

    static func packNote(forFormatKey key: String) -> String {
        catalog.multiPackFormatKeys.contains(key) ? "multi-pack" : "single"
    }

    static func row(forFormatKey key: String) -> Row? {
        rows.first { $0.formatKey == key }
    }
}
