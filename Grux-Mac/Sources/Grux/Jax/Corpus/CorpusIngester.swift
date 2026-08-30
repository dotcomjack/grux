import Foundation

// Shared contract for every Jax corpus ingester (the "you-ness" data pipeline).
//
// An ingester reads ONE local source of the user's authored voice (sent mail,
// their own iMessages, Notes, Claude/ChatGPT exports, voice recordings),
// extracts the turns they actually WROTE or SAID, and indexes them into two
// stores:
//
//   1. SemanticMemory.shared (on-device NLEmbedding vectors, instant retrieval)
//   2. RAGClient (the durable Lance store on the configured RAG host; soft-fail
//      if unreachable)
//
// Everything stays LOCAL. No source ships the user's writing off-device except
// into the RAG host they configured themselves, which is their own
// infrastructure and not a third party. Nothing here ever sends anything
// externally.
//
// Permission posture: several sources sit behind macOS privacy gates (Full Disk
// Access for chat.db, Automation/Notes access for Apple Notes). Ingesters MUST
// detect the absence of permission and surface a clear status rather than crash.
// `probe()` is the cheap, side-effect-free permission/availability check the
// coordinator calls to render status without running a full ingest.

// Where a piece of corpus came from. Persisted in metadata["corpusSource"] on
// every SemanticMemory entry and as the RAGClient Document.source, so a later
// retrieval can tell user-authored voice (userAuthored == true) from context.
enum CorpusSource: String, Codable, CaseIterable, Sendable {
    case gmailSent      // the user's sent Gmail (their real writing voice)
    case iMessage       // the user's outbound iMessages/SMS (chat.db)
    case notes          // Apple Notes the user wrote
    case chatHistory    // the user's turns in Claude / ChatGPT exports (highest signal)
    case voiceRecording // transcribed voice memos / recordings

    var displayName: String {
        switch self {
        case .gmailSent:      return "Gmail (Sent)"
        case .iMessage:       return "iMessage"
        case .notes:          return "Apple Notes"
        case .chatHistory:    return "Claude / ChatGPT exports"
        case .voiceRecording: return "Voice recordings"
        }
    }

    // True when this source captures the user writing/speaking in their own
    // voice. Every current source qualifies; kept explicit so a future "context
    // only" source (e.g. inbound mail) can opt out and not pollute the voice
    // corpus.
    var isUserAuthored: Bool { true }

    // Maps to the dedicated `.corpus` SemanticMemory lane: uncapped, so a 10k+
    // turn voice corpus is retained in full locally and does NOT evict the
    // curated `.fact` profile facts (which share a 500 cap). The durable home is
    // still the RAG/Lance store; this is the on-device mirror.
    var semanticKind: SemanticMemoryKind { .corpus }
}

// Permission / availability state for one source.
enum CorpusPermission: String, Codable, Sendable {
    case ready              // can run right now
    case needsFullDiskAccess
    case needsAutomation    // Apple Notes / AppleScript automation consent
    case needsAccount       // no Gmail account configured in EmailAccountStore
    case noData             // reachable, but nothing to ingest (e.g. empty imports folder)
    case unknown

    var humanReason: String {
        switch self {
        case .ready:              return "Ready"
        case .needsFullDiskAccess:
            return "Needs Full Disk Access. Open Settings, Privacy and Security, Full Disk Access, and enable Grux."
        case .needsAutomation:
            return "Needs Automation access for Notes. Open Settings, Privacy and Security, Automation, and enable Grux."
        case .needsAccount:
            // Named one specific personal address, which is wrong on anyone
            // else's machine and put a private email on a visible surface.
            return "No Gmail account configured. Add your Gmail account in Mailbox, Accounts (IMAP app password)."
        case .noData:
            return "No data found yet for this source."
        case .unknown:
            return "Status unknown until first run."
        }
    }
}

// One ingest pass result.
struct CorpusRunResult: Sendable {
    var indexed: Int            // new items written to SemanticMemory this run
    var pushedToRAG: Int        // items durably indexed in the companion RAG store
    var skipped: Int            // already-seen / too-short / not-user-authored turns dropped
    var permission: CorpusPermission
    var note: String            // short human line for the activity log

    static func blocked(_ p: CorpusPermission) -> CorpusRunResult {
        CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: p, note: p.humanReason)
    }
}

// Every ingester is an actor (IO-bound, matches IMAPClient/RAGClient posture).
// The coordinator is @MainActor and awaits these.
protocol CorpusIngester: Actor {
    nonisolated var source: CorpusSource { get }

    // Cheap permission/availability check. No heavy IO, no full scan.
    func probe() async -> CorpusPermission

    // Full ingest pass. Idempotent: dedupes against what it has already seen
    // so repeated runs only index new material.
    func ingest() async -> CorpusRunResult
}

// Shared helpers every ingester uses to write into the two stores with a
// consistent metadata shape, plus a dedupe ledger so re-runs are cheap.
enum CorpusIndexer {
    static let sourceMetadataKey = "corpusSource"
    static let authoredMetadataKey = "userAuthored"

    // Index one chunk of user-authored text into SemanticMemory and (best
    // effort) the RAG store. Returns whether the RAG push succeeded.
    @discardableResult
    @MainActor
    static func indexLocal(
        source: CorpusSource,
        text: String,
        timestampMillis: Int? = nil,
        extraMetadata: [String: String] = [:]
    ) -> Bool {
        var meta = extraMetadata
        meta[sourceMetadataKey] = source.rawValue
        meta[authoredMetadataKey] = source.isUserAuthored ? "1" : "0"
        // Scrub secrets BEFORE they enter the retrievable store. The corpus is
        // the user's real mail / iMessage / notes / chat history, which can contain
        // a password or API key they once typed or emailed themselves. Without this, any
        // such secret would be retrievable straight into the model context. The
        // dedup key upstream is computed on the original text, so redaction here
        // does not affect dedup stability.
        let safeText = SecretRedactor.redact(text)
        SemanticMemory.shared.store(kind: source.semanticKind, text: safeText, metadata: meta)
        return true
    }

    // Push a batch to the RAG store. Soft-fail per the RAGClient contract: if
    // the host is asleep or the network is down, log and return 0, never throw
    // up into the ingest pass.
    static func pushToRAG(_ rag: RAGClient, source: CorpusSource, docs rawDocs: [RAGClient.Document]) async -> Int {
        guard !rawDocs.isEmpty else { return 0 }
        // Scrub secrets out of the durable RAG store too, with the same redactor
        // the local store uses, so the durable Lance copy can never serve a
        // secret back into context either.
        let docs = rawDocs.map { d in
            RAGClient.Document(id: d.id, source: d.source, text: SecretRedactor.redact(d.text), ts: d.ts, brandHint: d.brandHint)
        }
        // Batch the push. A single POST of thousands of docs blows past the HTTP
        // timeout (a 400-doc batch lands in well under the window, a 5k batch
        // times out). Chunk it, sum the indexed counts, and keep going if one
        // batch fails so a single hiccup never strands the rest of the corpus.
        let batchSize = 300
        var total = 0
        var start = 0
        var batchNo = 0
        while start < docs.count {
            let end = min(start + batchSize, docs.count)
            let batch = Array(docs[start..<end])
            do {
                let resp = try await rag.index(batch)
                total += resp.indexed
            } catch {
                WakeLog.shared.log("corpus[\(source.rawValue)]: RAG batch \(batchNo) push failed (\(error)); local index still saved, continuing")
            }
            start = end
            batchNo += 1
        }
        return total
    }

    // Deterministic doc id so re-ingesting the same item overwrites in place
    // rather than duplicating in the RAG store.
    static func docId(source: CorpusSource, key: String) -> String {
        "corpus-\(source.rawValue)-\(stableHash(key))"
    }

    // FNV-1a 64-bit, hex. Stable across launches (Swift's Hasher is seeded).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
