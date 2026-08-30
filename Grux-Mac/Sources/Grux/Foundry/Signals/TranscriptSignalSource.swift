import Foundation

// Transcript lane of the Sense pass. Scans the ChatThreadStore JSON files on
// disk (never the live @MainActor store, so it can run from any task) for two
// patterns the blueprint calls out:
//
//   1. Corrections: a user message that opens with a correction marker
//      ("no", "wrong", "I meant", "again", "you forgot", ...) within 2 turns
//      of an assistant message. Each cluster of corrections in a thread is
//      evidence the assistant misread intent.
//   2. Repeats: near-identical user asks repeated within a thread, which
//      means the first answer didn't stick or the capability is missing.
struct TranscriptSignalSource: FoundrySignalSource {

    let sourceName = "transcript"

    // Directory of per-thread JSON files (ChatThreadStore layout). Injectable
    // so tests write fixture threads into a temp dir.
    var threadsDir: URL
    // Only threads updated inside the lookback window are scanned.
    var lookback: TimeInterval
    var now: @Sendable () -> Date

    init(
        threadsDir: URL = Persistence.chatThreadsDir,
        lookback: TimeInterval = 14 * 24 * 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threadsDir = threadsDir
        self.lookback = lookback
        self.now = now
    }

    static let correctionPrefixes: [String] = [
        "no", "no,", "no.", "nope", "wrong", "that's wrong", "thats wrong",
        "i meant", "again", "you forgot", "not that", "not what i",
        "try again", "incorrect", "still wrong"
    ]

    func harvest() async throws -> [FoundrySignal] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = now().addingTimeInterval(-lookback)
        var signals: [FoundrySignal] = []
        let sentinel = UUID()
        for url in items where url.pathExtension == "json" && url.lastPathComponent != "index.json" {
            let fallback = ChatThread(id: sentinel)
            let thread = Persistence.load(ChatThread.self, from: url, fallback: fallback)
            if thread.id == sentinel { continue }
            if thread.updatedAt < cutoff { continue }
            signals += Self.signals(in: thread)
        }
        return signals.sorted { $0.summary < $1.summary }
    }

    // Exposed for tests: pure function over one thread.
    static func signals(in thread: ChatThread) -> [FoundrySignal] {
        var out: [FoundrySignal] = []
        if let corrections = correctionSignal(in: thread) { out.append(corrections) }
        if let repeats = repeatSignal(in: thread) { out.append(repeats) }
        return out
    }

    // MARK: - Corrections

    static func correctionSignal(in thread: ChatThread) -> FoundrySignal? {
        let messages = thread.messages
        var hits: [String] = []
        for (idx, msg) in messages.enumerated() where msg.role == .user {
            let normalized = msg.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard correctionPrefixes.contains(where: { prefix in
                normalized == prefix || normalized.hasPrefix(prefix + " ")
            }) else { continue }
            // Within 2 turns of an assistant message: one of the two messages
            // immediately before this user turn must be from the assistant.
            let window = messages[max(0, idx - 2)..<idx]
            guard window.contains(where: { $0.role == .assistant }) else { continue }
            hits.append(String(msg.content.prefix(140)))
        }
        guard !hits.isEmpty else { return nil }
        let severity: FoundrySignal.Severity = hits.count >= 4 ? .high : (hits.count >= 2 ? .medium : .low)
        return FoundrySignal(
            source: "transcript",
            severity: severity,
            summary: "Thread '\(thread.title)': \(hits.count) user correction(s) right after assistant replies",
            evidence: hits.prefix(5).joined(separator: "\n"),
            suggestedLane: .capability,
            suggestedDomain: "chat"
        )
    }

    // MARK: - Repeats

    static func repeatSignal(in thread: ChatThread) -> FoundrySignal? {
        let userAsks = thread.messages.filter { $0.role == .user }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
        guard userAsks.count >= 2 else { return nil }

        var groups: [String: [String]] = [:]
        for ask in userAsks {
            let key = normalizeForRepeat(ask)
            groups[key, default: []].append(ask)
        }
        let repeated = groups.values.filter { $0.count >= 2 }
        guard !repeated.isEmpty else { return nil }
        let worst = repeated.max(by: { $0.count < $1.count })!
        let totalRepeats = repeated.reduce(0) { $0 + $1.count }
        let severity: FoundrySignal.Severity = worst.count >= 3 ? .high : .medium
        return FoundrySignal(
            source: "transcript",
            severity: severity,
            summary: "Thread '\(thread.title)': \(repeated.count) ask(s) repeated near-identically (\(totalRepeats) messages)",
            evidence: worst.prefix(4).map { String($0.prefix(140)) }.joined(separator: "\n"),
            suggestedLane: .capability,
            suggestedDomain: "chat"
        )
    }

    // Lowercase, strip punctuation, collapse whitespace. Two asks that differ
    // only in casing/punctuation/spacing collapse to one key.
    static func normalizeForRepeat(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }
}
