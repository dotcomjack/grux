import Foundation

// BM25 keyword lane over the same memory records the cosine lane scans.
//
// Why a second lane at all? NLEmbedding cosine similarity is great at
// paraphrase ("what soap cadence did we pick" finds "bar soap ships every
// 49 days") but weak at exact rare tokens: SKU slugs, error codes, project
// code names, "qwen-image-edit-plus". BM25 is the mirror image: exact-term
// recall is near perfect, paraphrase recall is zero. HybridRetriever fuses
// both lanes so each covers the other's blind spot.
//
// Pure value type, no I/O, no actor isolation. Build it from a snapshot of
// entries, score queries against it. Rebuilding for a few thousand docs is
// sub-millisecond on M-series, so HybridRetriever rebuilds per retrieval
// rather than maintaining an incremental index.
public struct KeywordIndex {

    public struct Hit {
        public let id: UUID
        public let score: Double
    }

    // Standard BM25 free parameters. k1 controls term-frequency saturation,
    // b controls document-length normalization.
    private let k1: Double = 1.2
    private let b: Double = 0.75

    private struct Doc {
        let id: UUID
        let termFreq: [String: Int]
        let length: Int
    }

    private let docs: [Doc]
    private let docFreq: [String: Int]
    private let avgDocLength: Double

    public init(documents: [(id: UUID, text: String)]) {
        var built: [Doc] = []
        built.reserveCapacity(documents.count)
        var df: [String: Int] = [:]
        var totalLength = 0

        for (id, text) in documents {
            let tokens = Self.tokenize(text)
            guard !tokens.isEmpty else { continue }
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            for term in tf.keys { df[term, default: 0] += 1 }
            totalLength += tokens.count
            built.append(Doc(id: id, termFreq: tf, length: tokens.count))
        }

        self.docs = built
        self.docFreq = df
        self.avgDocLength = built.isEmpty ? 0 : Double(totalLength) / Double(built.count)
    }

    public init(entries: [SemanticEntry]) {
        self.init(documents: entries.map { ($0.id, $0.text) })
    }

    public var documentCount: Int { docs.count }

    // Lowercased alphanumeric tokens, length >= 2. Splits on every
    // non-alphanumeric character so "qwen-image-edit-plus" yields
    // ["qwen", "image", "edit", "plus"] and matches however the user types it.
    public static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    // BM25+style idf with the +1 inside the log so it never goes negative
    // for terms that appear in most documents.
    public func idf(term: String) -> Double {
        let n = Double(docs.count)
        guard n > 0 else { return 0 }
        let df = Double(docFreq[term] ?? 0)
        return Foundation.log(1.0 + (n - df + 0.5) / (df + 0.5))
    }

    // Score every document against the query, return topK hits with
    // score > 0 in descending score order.
    public func score(query: String, topK: Int = 8) -> [Hit] {
        let qTerms = Self.tokenize(query)
        guard !qTerms.isEmpty, !docs.isEmpty, avgDocLength > 0 else { return [] }

        // Deduplicate query terms but keep a count so repeated terms in the
        // query weigh slightly more, matching classic BM25 query handling.
        var qtf: [String: Int] = [:]
        for t in qTerms { qtf[t, default: 0] += 1 }

        var hits: [Hit] = []
        for doc in docs {
            var s = 0.0
            for (term, qCount) in qtf {
                guard let tf = doc.termFreq[term] else { continue }
                let i = idf(term: term)
                guard i > 0 else { continue }
                let tfd = Double(tf)
                let norm = tfd * (k1 + 1.0)
                    / (tfd + k1 * (1.0 - b + b * Double(doc.length) / avgDocLength))
                s += i * norm * Double(qCount)
            }
            if s > 0 { hits.append(Hit(id: doc.id, score: s)) }
        }

        return hits
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }
}
