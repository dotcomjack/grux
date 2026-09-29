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
    // The decision engine's probability that this message needs the person
    // (`mail.needsYou`, P-R-5). nil until judged, 0.5 when judged on device.
    // Optional so every messages.json written before it decodes unchanged.
    var needsYouProbability: Double?

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

    @Published private(set) var messages: [EmailMessage] = [] {
        didSet { needsYouMemo = nil }
    }

    static let cap = 1000
    private static var fileURL: URL { EmailAccountStore.rootDir.appendingPathComponent("messages.json") }

    private var saveToken: DispatchWorkItem?
    private let persists: Bool

    private init() {
        persists = true
        load()
    }

    /// A store that never reads or writes disk. The shared store's file is the
    /// operator's real mailbox cache under `~/.grux`, which `Persistence`'s test
    /// root does not cover, so a test must never mutate `shared`.
    init(inMemory seed: [EmailMessage]) {
        persists = false
        messages = seed.sorted { $0.date > $1.date }
    }

    // MARK: - What needs you

    private var needsYouMemo: Int?

    /// The rail's Mail badge: `MailNeedsYou.count`, the floor less what the
    /// engine judged asks nothing (see `judgeNeedsYou`). Memoized, because the
    /// rail reads it on EVERY render
    /// and `MailNeedsYou.count` lowercases and scans the body of every message it
    /// is given, up to `cap` of them. Measured 2026-09-21 in a 5 second `sample`
    /// of the idle app: 58 main thread samples inside `railBadge` running that
    /// scan over a mailbox that had not changed. Any write to `messages`
    /// invalidates it, so it can never be staler than the array it describes.
    var needsYouCount: Int {
        if let n = needsYouMemo { return n }
        let n = MailNeedsYou.count(messages)
        needsYouMemo = n
        return n
    }

    private var judgingNeedsYou = false

    /// Asks the engine about each message the floor counts and nobody has
    /// judged, ONE call per message, and stores the answer on the message. The
    /// write goes through `update`, so the memo above is invalidated and the
    /// badge follows; the rail never waits on this.
    ///
    /// Keyless, nothing is asked at all: no call, no ledger row, the badge is
    /// the floor exactly as before. Returns how many messages were judged.
    @discardableResult
    func judgeNeedsYou(engine: DecisionEngine, limit: Int = MailNeedsYou.judgePassLimit) async -> Int {
        guard !judgingNeedsYou, engine.hasRemoteKey else { return 0 }
        judgingNeedsYou = true
        defer { judgingNeedsYou = false }
        let pending = MailNeedsYou.awaitingJudgement(messages).prefix(limit)
        for m in pending {
            let result = await engine.decide(surface: MailNeedsYou.surface, state: MailNeedsYou.state(m),
                                             questions: MailNeedsYou.questions)
            update(m.id) { $0.needsYouProbability = MailNeedsYou.probability(from: result) }
        }
        return pending.count
    }

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
        guard persists else { return }
        try? FileManager.default.createDirectory(at: EmailAccountStore.rootDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(messages) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
