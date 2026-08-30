import Foundation

// Asks Ollama's own library what exists, and reports what this app's catalog has
// not heard of.
//
// WHY THIS EXISTS. Cookbook.catalog is a hardcoded list of a moving target. On
// 2026-08-21 it was found recommending gemma3 and qwen3 while Ollama had shipped
// gemma4, qwen3.5 and qwen3.6, so the app said "Recommended" about a model two
// generations old and nothing in the product could notice. A curated list is the
// right call for offline use and known-good figures; going quietly stale is the
// price, and this is how that price gets paid.
//
// WHY THE REGISTRY AND NOT A WEB SEARCH. A search engine will happily return
// models you cannot install. Ollama's library is the exact set `ollama pull`
// accepts, it needs no API key and costs nothing, so the answer is both cheaper
// and more correct.
//
// The parsing and the comparison are pure and separately testable. Only `fetch`
// touches the network, which is the same split HardwareProfile uses.
enum ModelRegistryCheck {

    static let libraryURL = URL(string: "https://ollama.com/library")!

    /// What the registry has that beats what we recommend.
    struct Upgrade: Equatable {
        let have: String        // a family in our catalog, e.g. "gemma3"
        let newer: [String]     // higher versioned siblings, e.g. ["gemma4"]
    }

    struct Result: Equatable {
        let registryCount: Int
        let upgrades: [Upgrade]
        var isStale: Bool { !upgrades.isEmpty }
    }

    // MARK: - Pure

    /// Every model family named on the library page, deduplicated, first seen
    /// order preserved.
    ///
    /// Anchored on the `/library/<name>` href rather than on any rendered text,
    /// because the text is a marketing surface that changes and the href is the
    /// thing `ollama pull` actually consumes.
    static func parseLibrary(_ html: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let pattern = #"href="/library/([a-z0-9._-]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            let name = ns.substring(with: m.range(at: 1))
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// The family part of a catalog id: "qwen3.5:27b" -> "qwen3.5".
    static func family(of catalogID: String) -> String {
        catalogID.split(separator: ":").first.map(String.init) ?? catalogID
    }

    /// Splits a family into the part that names the model and the part that
    /// versions it: "qwen3.5" -> ("qwen", [3, 5]), "qwen3-coder" -> ("qwen-coder", [3]).
    ///
    /// The suffix rejoins the base on purpose, so qwen3-coder is compared against
    /// qwen4-coder and never against plain qwen4. A coder model and a chat model of
    /// the same generation are different products and calling one an upgrade of the
    /// other would be a wrong recommendation, not a slightly noisy one.
    ///
    /// Returns nil for an unversioned name like "gpt-oss" or "mistral", which
    /// simply means this check has nothing to say about it.
    static func baseAndVersion(_ name: String) -> (base: String, version: [Int])? {
        let pattern = #"^([a-z]+(?:-[a-z]+)*?)(\d+(?:\.\d+)*)((?:-[a-z0-9]+)*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4 else { return nil }
        let prefix = ns.substring(with: m.range(at: 1))
        let nums = ns.substring(with: m.range(at: 2))
        let suffix = ns.substring(with: m.range(at: 3))
        let version = nums.split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty, !prefix.isEmpty else { return nil }
        return (prefix + suffix, version)
    }

    /// Compares two dotted versions. [3, 6] beats [3, 5] beats [3].
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// For each family we recommend, any higher versioned sibling in the registry.
    ///
    /// THIS IS NOT "what is in the registry that we do not list". That question was
    /// tried first and answered 211, almost all of them OLDER models the catalog
    /// omits on purpose: llama3.1, gemma3, qwen2.5, phi3. A list like that buries
    /// the one useful row in noise and trains the reader to ignore the button.
    ///
    /// It also makes no claim about quality, only about version numbers, which is
    /// the only thing that can be established without opinion. gemma4 is a later
    /// release than gemma3. Whether it is better for you is yours to decide.
    ///
    /// KNOWN LIMIT, stated rather than hidden: this compares FAMILIES, not sizes.
    /// If the catalog carries qwen3.5 at 2B and the registry has qwen3.8 only at
    /// 27B, this still reports an upgrade, and for the 2B user there is not one.
    /// Making it size aware means parsing every tag of every family on every
    /// check, which is a great deal of network and parsing for a button, so the
    /// banner says plainly that it compares versions and leaves the reader to
    /// look. A loud, slightly over-eager check beats a quiet one that misses the
    /// generation gap this whole feature exists to catch.
    static func compare(registry: [String], catalog: [CookbookModel]) -> Result {
        var byBase: [String: [(name: String, version: [Int])]] = [:]
        for name in registry {
            guard let (base, v) = baseAndVersion(name) else { continue }
            byBase[base, default: []].append((name, v))
        }

        var upgrades: [Upgrade] = []
        var reported = Set<String>()
        for fam in catalog.map({ family(of: $0.id) }) {
            guard !reported.contains(fam), let (base, mine) = baseAndVersion(fam) else { continue }
            reported.insert(fam)
            let newer = (byBase[base] ?? [])
                .filter { isNewer($0.version, than: mine) }
                .map(\.name)
                .sorted()
            if !newer.isEmpty { upgrades.append(Upgrade(have: fam, newer: newer)) }
        }
        return Result(registryCount: registry.count, upgrades: upgrades)
    }

    // MARK: - IO

    /// Fetches the library and compares. Throws rather than returning an empty
    /// result on failure, because "the network is down" and "you are up to date"
    /// are opposite answers and a check that conflates them is worse than none.
    static func check(catalog: [CookbookModel] = Cookbook.catalog,
                      session: URLSession = .shared) async throws -> Result {
        var req = URLRequest(url: libraryURL)
        req.timeoutInterval = 15
        req.setValue("Grux OS model check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RegistryError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw RegistryError.undecodable
        }
        let families = parseLibrary(html)
        guard !families.isEmpty else { throw RegistryError.noModelsParsed }
        return compare(registry: families, catalog: catalog)
    }

    enum RegistryError: LocalizedError, Equatable {
        case badResponse(Int)
        case undecodable
        case noModelsParsed

        var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return "Ollama's library answered \(code). Try again in a minute."
            case .undecodable:
                return "Could not read the reply from Ollama's library."
            case .noModelsParsed:
                // The page shape changed. Say so rather than reporting "up to
                // date", which is the one wrong answer that looks like success.
                return "Read the page but found no models in it, so the check cannot be trusted. The library layout has probably changed."
            }
        }
    }
}
