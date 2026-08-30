import Foundation

// Shared security audit trail for the Security module (items 30 + 31).
//
// Every PromptSecurity scan that flags or strips, every URLGuard denial, and
// every SensitiveActionGate decision lands here as one JSONL line in
// ~/Library/Application Support/Grux/security-audit.log, mirroring the
// fs-audit.log convention in FilesystemTool.swift.
//
// PRIVACY INVARIANT: this log records tags, counts, hosts, verdicts, and a
// short content hash. It NEVER records the scanned content itself, so a
// flagged tool result containing a secret cannot leak through the audit
// trail. (Groundtruth item 30 risk note: "Audit log must not leak redacted
// content.")

struct SecurityAuditEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var ts: Date = Date()
    /// "prompt_scan" | "url_guard" | "action_gate"
    var kind: String
    /// Where the event came from: tool name, URL purpose, gate category.
    var source: String
    /// "allow" | "flag" | "strip" | "denied" | "granted" | "refused"
    var verdict: String
    /// Heuristic tags that fired (e.g. INSTRUCTION_OVERRIDE, PRIVATE_IP).
    var tags: [String]
    /// Short human-readable detail. Hosts and reasons only, never content.
    var detail: String
}

actor SecurityAuditLog {
    static let shared = SecurityAuditLog()

    private var recentEntries: [SecurityAuditEntry] = []
    private let recentCap = 100

    private lazy var logURL: URL? = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base = appSupport else { return nil }
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("security-audit.log")
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func record(kind: String, source: String, verdict: String, tags: [String], detail: String) {
        let entry = SecurityAuditEntry(kind: kind, source: source, verdict: verdict, tags: tags, detail: detail)
        recentEntries.append(entry)
        if recentEntries.count > recentCap {
            recentEntries.removeFirst(recentEntries.count - recentCap)
        }
        appendToDisk(entry)
    }

    /// Most-recent-first slice for the Security settings pane.
    func recent(limit: Int = 30) -> [SecurityAuditEntry] {
        Array(recentEntries.suffix(limit).reversed())
    }

    // MARK: - Disk

    private func appendToDisk(_ entry: SecurityAuditEntry) {
        guard let url = logURL else { return }
        let record: [String: Any] = [
            "ts": isoFormatter.string(from: entry.ts),
            "kind": entry.kind,
            "source": entry.source,
            "verdict": entry.verdict,
            "tags": entry.tags,
            "detail": entry.detail
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        LogRotation.appendRotating(json + "\n", to: url)
    }
}
