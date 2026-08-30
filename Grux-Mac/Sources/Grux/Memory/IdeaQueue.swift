import Foundation

// Spoken or typed ideas land in ~/.grux/ideas/<id>.md as markdown with
// frontmatter. Each new idea is queried against the configured Lance vector
// store (server.py uses bge-base-en-v1.5, 768d, cosine metric,
// score = 1 - distance / 2 so 1.0 is identical and 0.5 is unrelated). If the top hit's score meets duplicateThreshold,
// we mark the new idea as a duplicate and surface the prior id + date
// without blocking the capture.
//
// Companion-unavailable fallback: still write the markdown file, mark
// memory_available=false in frontmatter, treat as non-duplicate. The
// on-disk file is the source of truth; the vector index is a lookup cache.
public actor IdeaQueue {
    public static let shared = IdeaQueue()

    public struct CaptureResult: Sendable {
        public let id: String                    // idea file id (also the RAG doc id)
        public let filePath: String              // absolute path to ~/.grux/ideas/<id>.md
        public let isDuplicate: Bool             // true when score >= duplicateThreshold
        public let priorId: String?              // matched prior idea id (when duplicate)
        public let priorDate: Date?              // when the prior idea was captured
        public let priorText: String?            // up to 140 chars of the prior idea body
        public let score: Double?                // top similarity score from RAG (0..1)
        public let memoryAvailable: Bool         // false when the companion was unreachable
    }

    public static let duplicateThreshold: Double = 0.85

    private let rag: RAGClient
    private let ideasDir: URL

    public init(
        rag: RAGClient = RAGClient(),
        ideasDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("ideas")
    ) {
        self.rag = rag
        self.ideasDir = ideasDir
        try? FileManager.default.createDirectory(at: ideasDir, withIntermediateDirectories: true)
    }

    public func capture(content rawContent: String) async -> CaptureResult {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let id = Self.makeId(at: now)

        guard !content.isEmpty else {
            return CaptureResult(
                id: id,
                filePath: "",
                isDuplicate: false,
                priorId: nil,
                priorDate: nil,
                priorText: nil,
                score: nil,
                memoryAvailable: false
            )
        }

        // 1. Query the RAG index BEFORE we add this idea so a self-match
        //    cannot pollute the duplicate check. Soft-fail when the companion
        //    service is asleep or off-LAN.
        var topHit: RAGClient.Hit? = nil
        var memoryAvailable = true
        do {
            let res = try await rag.query(content, k: 1, source: "idea")
            topHit = res.hits.first
        } catch {
            memoryAvailable = false
            WakeLog.shared.log("idea-queue: RAG query failed (render service unreachable?): \(error)")
        }

        let isDuplicate: Bool
        let priorId: String?
        let priorDate: Date?
        let priorText: String?
        let score: Double?
        if let hit = topHit, hit.score >= Self.duplicateThreshold {
            isDuplicate = true
            priorId = hit.id
            priorDate = Date(timeIntervalSince1970: TimeInterval(hit.ts))
            priorText = String(hit.text.prefix(140))
            score = hit.score
        } else {
            isDuplicate = false
            priorId = nil
            priorDate = nil
            priorText = nil
            score = topHit?.score
        }

        // 2. Write the markdown file with frontmatter. Happens whether or
        //    not the companion answered, so the on-disk record always exists.
        let url = ideasDir.appendingPathComponent("\(id).md")
        let md = Self.renderMarkdown(
            id: id,
            content: content,
            capturedAt: now,
            isDuplicate: isDuplicate,
            priorId: priorId,
            priorDate: priorDate,
            score: score,
            memoryAvailable: memoryAvailable
        )
        try? md.write(to: url, atomically: true, encoding: .utf8)

        // 3. Index in the Lance store so future ideas can dedup against
        //    this one. Duplicates are indexed too so a third paraphrase
        //    still finds a hit; the file frontmatter remembers the duplicate flag.
        if memoryAvailable {
            do {
                let doc = RAGClient.Document(
                    id: id,
                    source: "idea",
                    text: content,
                    ts: Int(now.timeIntervalSince1970),
                    brandHint: ""
                )
                _ = try await rag.index(doc)
            } catch {
                WakeLog.shared.log("idea-queue: RAG index failed for \(id): \(error)")
            }
        }

        return CaptureResult(
            id: id,
            filePath: url.path,
            isDuplicate: isDuplicate,
            priorId: priorId,
            priorDate: priorDate,
            priorText: priorText,
            score: score,
            memoryAvailable: memoryAvailable
        )
    }

    public func listIdeas() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: ideasDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    // MARK: - Formatting helpers

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f
    }()

    private static func makeId(at date: Date) -> String {
        let stamp = idFormatter.string(from: date)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "idea-\(stamp)-\(suffix)"
    }

    private static let displayDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        f.timeZone = .current
        return f
    }()

    static func renderMarkdown(
        id: String,
        content: String,
        capturedAt: Date,
        isDuplicate: Bool,
        priorId: String?,
        priorDate: Date?,
        score: Double?,
        memoryAvailable: Bool
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("---")
        lines.append("id: \(id)")
        lines.append("captured_at: \(iso.string(from: capturedAt))")
        lines.append("duplicate: \(isDuplicate)")
        if let pid = priorId { lines.append("prior_id: \(pid)") }
        if let pd = priorDate {
            lines.append("prior_date: \(iso.string(from: pd))")
        }
        if let s = score {
            lines.append(String(format: "score: %.4f", s))
        }
        lines.append("memory_available: \(memoryAvailable)")
        lines.append("---")
        lines.append("")
        lines.append(content)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func spokenResult(_ r: CaptureResult) -> String {
        if r.isDuplicate, let pd = r.priorDate {
            let when = displayDate.string(from: pd)
            return "Captured. You said something very similar on \(when). Logged as a duplicate."
        }
        if !r.memoryAvailable {
            return "Captured locally. Memory is offline so I could not check for duplicates."
        }
        return "Idea captured."
    }
}
