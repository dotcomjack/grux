import Foundation
import CryptoKit

// One synced inbox message. `id` is the dedupe key: the RFC Message-ID when
// the server exposed one, otherwise a deterministic SHA256 of
// account|from|subject|date (same stable-across-relaunches trick
// EmailTriageEngine.draftId uses; Swift's seeded hashValue would silently
// break dedupe every launch).
struct EmailMessage: Codable, Identifiable, Equatable {
    let id: String
    let accountId: UUID
    var sequenceNumber: Int       // server sequence at fetch time (informational)
    var messageId: String         // RFC Message-ID, "" when absent
    var fromName: String
    var fromEmail: String
    var to: String
    var subject: String
    var date: Date
    var snippet: String           // first ~160 chars of the body for list rows
    var bodyText: String          // best-effort plain text body
    var isUnread: Bool
    var fetchedAt: Date
    var triageDraftId: String?    // SupportDraft id once routed through triage

    static func dedupeId(accountId: UUID, messageId: String, fromEmail: String, subject: String, date: Date?) -> String {
        let trimmed = messageId.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return "mid-" + stableHash("\(accountId.uuidString)|\(trimmed)")
        }
        let stamp = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return "syn-" + stableHash("\(accountId.uuidString)|\(fromEmail.lowercased())|\(subject.lowercased())|\(stamp)")
    }

    private static func stableHash(_ basis: String) -> String {
        let digest = SHA256.hash(data: Data(basis.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

// Persistent JSON store for synced messages, shared across accounts. Lives at
// ~/.grux/email/messages.json next to accounts.json. Debounced scheduleSave
// like FolderStore/CookbookStore. Capped so years of mail cannot balloon the
// file; the IMAP server remains the source of truth, this is a working set.
@MainActor
final class MailStore: ObservableObject {
    static let shared = MailStore()

    @Published private(set) var messages: [EmailMessage] = []

    static let cap = 1000
    private static var fileURL: URL { EmailAccountStore.rootDir.appendingPathComponent("messages.json") }

    private var saveToken: DispatchWorkItem?

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([EmailMessage].self, from: data) {
            messages = decoded.sorted { $0.date > $1.date }
        }
    }

    func contains(id: String) -> Bool {
        messages.contains { $0.id == id }
    }

    // Inserts new messages and refreshes flags on known ones. Returns only
    // the genuinely NEW messages so the sync engine can route just those
    // through triage instead of re-drafting the whole inbox every sweep.
    @discardableResult
    func upsert(_ batch: [EmailMessage]) -> [EmailMessage] {
        var fresh: [EmailMessage] = []
        for msg in batch {
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx].isUnread = msg.isUnread
                messages[idx].sequenceNumber = msg.sequenceNumber
                if messages[idx].bodyText.isEmpty && !msg.bodyText.isEmpty {
                    messages[idx].bodyText = msg.bodyText
                    messages[idx].snippet = msg.snippet
                }
            } else {
                messages.append(msg)
                fresh.append(msg)
            }
        }
        messages.sort { $0.date > $1.date }
        if messages.count > Self.cap {
            messages.removeLast(messages.count - Self.cap)
        }
        scheduleSave()
        return fresh
    }

    func update(_ id: String, _ mutate: (inout EmailMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[idx])
        scheduleSave()
    }

    func markRead(_ id: String) {
        update(id) { $0.isUnread = false }
    }

    func remove(accountId: UUID) {
        messages.removeAll { $0.accountId == accountId }
        scheduleSave()
    }

    func messages(for accountId: UUID?) -> [EmailMessage] {
        guard let accountId else { return messages }
        return messages.filter { $0.accountId == accountId }
    }

    func unreadCount(for accountId: UUID? = nil) -> Int {
        messages(for: accountId).filter { $0.isUnread }.count
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        objectWillChange.send()
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: EmailAccountStore.rootDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(messages) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
