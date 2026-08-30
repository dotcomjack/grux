import Foundation

extension Persistence {
    // Jax corpus subsystem state lives under Application Support/Grux/jax/.
    static var jaxCorpusDir: URL {
        let dir = supportDir.appendingPathComponent("jax", isDirectory: true)
            .appendingPathComponent("corpus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Per-source dedupe ledger (set of already-ingested item keys) + the
    // coordinator's status snapshot.
    static func jaxCorpusLedgerURL(_ source: String) -> URL {
        jaxCorpusDir.appendingPathComponent("ledger-\(source).json")
    }
    static var jaxCorpusStatusURL: URL { jaxCorpusDir.appendingPathComponent("status.json") }
}

// Bounded, persisted set of item keys an ingester has already indexed, so a
// re-run is cheap and never re-indexes the same sent email / message / note.
// Newest-first eviction once it exceeds `cap` (older keys re-appearing would at
// worst cause a single duplicate, which the RAG deterministic docId absorbs).
//
// Not an ObservableObject: ledgers are internal ingester state, written from
// within the owning actor, never bound to UI. JSON on disk via Persistence.
struct CorpusLedger: Codable {
    private(set) var keys: [String]            // insertion order, newest appended
    private var keySet: Set<String>
    let cap: Int

    init(cap: Int = 50_000) {
        self.keys = []
        self.keySet = []
        self.cap = cap
    }

    enum CodingKeys: String, CodingKey { case keys, cap }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let loadedKeys = try c.decode([String].self, forKey: .keys)
        self.keys = loadedKeys
        self.keySet = Set(loadedKeys)
        self.cap = (try? c.decode(Int.self, forKey: .cap)) ?? 50_000
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keys, forKey: .keys)
        try c.encode(cap, forKey: .cap)
    }

    func contains(_ key: String) -> Bool { keySet.contains(key) }

    // Returns true if this is a NEW key (and records it). False if already seen.
    @discardableResult
    mutating func insert(_ key: String) -> Bool {
        guard !keySet.contains(key) else { return false }
        keySet.insert(key)
        keys.append(key)
        if keys.count > cap {
            let drop = keys.count - cap
            for k in keys.prefix(drop) { keySet.remove(k) }
            keys.removeFirst(drop)
        }
        return true
    }

    static func load(source: CorpusSource) -> CorpusLedger {
        Persistence.load(CorpusLedger.self, from: Persistence.jaxCorpusLedgerURL(source.rawValue), fallback: CorpusLedger())
    }

    func save(source: CorpusSource) {
        Persistence.save(self, to: Persistence.jaxCorpusLedgerURL(source.rawValue))
    }
}
