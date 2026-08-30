import Foundation
import SQLite3

// Indexes the user's SENT iMessages and SMS (their short-form voice) from the
// local Messages database at ~/Library/Messages/chat.db.
//
// We read ONLY messages where is_from_me = 1 (user outbound). Inbound messages
// are other people's words and are skipped. The DB is opened READ-ONLY and we
// never write to it.
//
// Permission: reading chat.db requires Full Disk Access at runtime, even with
// the sandbox off. Without it, sqlite3_open_v2 succeeds on the path but the
// first read returns SQLITE_AUTH / SQLITE_CANTOPEN, or the file simply is not
// readable. We detect that and surface needsFullDiskAccess rather than crashing.
//
// Body text: modern macOS stores message bodies in the `attributedBody` BLOB
// (NSAttributedString archive) and leaves `text` NULL for many rows. We prefer
// `text` and fall back to extracting the plain string out of attributedBody.
actor IMessageIngester: CorpusIngester {
    nonisolated let source: CorpusSource = .iMessage

    private let rag: RAGClient
    private var ledger: CorpusLedger
    private let perRunCap = 5_000   // newest N outbound messages per pass

    private var dbPath: String {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    init(rag: RAGClient) {
        self.rag = rag
        self.ledger = CorpusLedger.load(source: .iMessage)
    }

    func probe() async -> CorpusPermission {
        guard FileManager.default.fileExists(atPath: dbPath) else { return .noData }
        // FDA check: try to actually read one row. A bare isReadableFile is not
        // reliable under TCC, so we open + run a trivial query.
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(dbPath, &db, openFlags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return .needsFullDiskAccess
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        defer { sqlite3_finalize(stmt) }
        if !ok { return .needsFullDiskAccess }
        return sqlite3_step(stmt) == SQLITE_ROW ? .ready : .needsFullDiskAccess
    }

    func ingest() async -> CorpusRunResult {
        guard FileManager.default.fileExists(atPath: dbPath) else { return .blocked(.noData) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return .blocked(.needsFullDiskAccess)
        }
        defer { sqlite3_close(db) }

        // ROWID + date (Apple epoch nanoseconds since 2001) + text + attributedBody,
        // outbound only, newest first.
        let sql = """
        SELECT ROWID, date, text, attributedBody
        FROM message
        WHERE is_from_me = 1
        ORDER BY date DESC
        LIMIT \(perRunCap)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .blocked(.needsFullDiskAccess)
        }
        defer { sqlite3_finalize(stmt) }

        var indexed = 0, skipped = 0
        var docs: [RAGClient.Document] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let appleDate = sqlite3_column_int64(stmt, 1)
            let unixMillis = Self.appleDateToUnixMillis(appleDate)

            var body = ""
            if let cText = sqlite3_column_text(stmt, 2) {
                body = String(cString: cText)
            }
            if body.isEmpty, sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                let bytes = sqlite3_column_bytes(stmt, 3)
                if bytes > 0, let blob = sqlite3_column_blob(stmt, 3) {
                    let data = Data(bytes: blob, count: Int(bytes))
                    body = Self.extractAttributedBody(data)
                }
            }

            let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 8 else { skipped += 1; continue }   // drop "ok", "lol", reactions

            let key = "imsg-\(rowId)"
            guard ledger.insert(key) else { skipped += 1; continue }

            await MainActor.run {
                CorpusIndexer.indexLocal(source: .iMessage, text: cleaned, timestampMillis: unixMillis)
            }
            docs.append(RAGClient.Document(
                id: CorpusIndexer.docId(source: .iMessage, key: key),
                source: "chat",
                text: cleaned,
                ts: unixMillis.map { $0 / 1000 },
                brandHint: ""
            ))
            indexed += 1
        }

        let pushed = await CorpusIndexer.pushToRAG(rag, source: .iMessage, docs: docs)
        ledger.save(source: .iMessage)
        return CorpusRunResult(indexed: indexed, pushedToRAG: pushed, skipped: skipped, permission: .ready,
                               note: "Indexed \(indexed) sent messages (\(skipped) skipped)")
    }

    // Apple's message date column is nanoseconds since 2001-01-01 on modern
    // macOS (older rows used seconds). Detect by magnitude and normalize to
    // unix milliseconds.
    static func appleDateToUnixMillis(_ appleDate: Int64) -> Int? {
        guard appleDate > 0 else { return nil }
        let appleEpochOffset: Int64 = 978_307_200  // seconds between 1970 and 2001
        let seconds: Double
        if appleDate > 1_000_000_000_000 {          // nanoseconds
            seconds = Double(appleDate) / 1_000_000_000.0
        } else {                                    // seconds
            seconds = Double(appleDate)
        }
        return Int((seconds + Double(appleEpochOffset)) * 1000)
    }

    // Pull the readable string out of a Messages `attributedBody` BLOB. The blob
    // is a typedstream (NSArchiver) NSAttributedString. We unarchive it with the
    // unsecure path (these are local, trusted files) and fall back to a byte
    // scan if that fails.
    static func extractAttributedBody(_ data: Data) -> String {
        if let s = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.plain],
            documentAttributes: nil
        ), !s.string.isEmpty {
            return s.string
        }
        // typedstream fallback: the visible text follows the "NSString" marker
        // as a length-prefixed run of bytes. Extract the longest printable ASCII
        // run as a pragmatic recovery.
        let scalars = data.map { $0 }
        var best = "", current: [UInt8] = []
        for b in scalars {
            if b >= 0x20 && b < 0x7f {
                current.append(b)
            } else {
                if current.count > best.utf8.count, let s = String(bytes: current, encoding: .utf8) { best = s }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count > best.utf8.count, let s = String(bytes: current, encoding: .utf8) { best = s }
        // Drop typedstream class-name noise that can leak into the scan.
        let noise = ["NSString", "NSAttributedString", "NSDictionary", "NSObject", "NSNumber", "streamtyped", "__kIM"]
        var out = best
        for n in noise { out = out.replacingOccurrences(of: n, with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
