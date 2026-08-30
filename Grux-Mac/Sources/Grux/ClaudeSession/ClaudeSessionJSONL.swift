import Foundation

// Parser for Claude Code's native JSONL session log. Each line is a JSON
// object with a `type` discriminator. We fold a stream of lines into a
// `ClaudeSessionSnapshot` - a roll-up view of what the session is doing
// right now (cwd, current tool in flight, token totals, 1-line summary).
//
// This parser is deliberately lenient: malformed lines, unknown `type`s,
// and missing fields are skipped rather than raised. Claude Code appends
// incrementally; a tail reader may witness a half-written final line, so
// resilience to partial / invalid lines is a hard requirement.

// MARK: - Usage totals

struct ClaudeSessionUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int

    static let zero = ClaudeSessionUsage(
        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0
    )

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens
        )
    }
}

// MARK: - Snapshot

struct ClaudeSessionSnapshot: Equatable {
    var sessionId: String
    var cwd: String?
    var gitBranch: String?
    var title: String
    var lastMessageAt: Date
    var currentTool: String?
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCacheReadTokens: Int
    var totalCacheCreationTokens: Int
    var totalCostUSD: Double
    var lastAssistantSummary: String
    var model: String?
}

// MARK: - Entry

enum ClaudeSessionEntry {
    case user(ts: Date, text: String, cwd: String?, gitBranch: String?)
    case assistant(
        ts: Date,
        text: String?,
        toolUseName: String?,
        usage: ClaudeSessionUsage?,
        model: String?,
        stopReason: String?,
        cwd: String?,
        gitBranch: String?
    )
    case attachment
    case permissionMode(sessionId: String)
    case other
}

// MARK: - Parser

enum ClaudeSessionJSONL {

    private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        iso8601Frac.date(from: s) ?? iso8601Plain.date(from: s)
    }

    static func parseLine(_ line: String) -> ClaudeSessionEntry? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            return nil
        }

        let type = obj["type"] as? String
        switch type {
        case "permission-mode":
            guard let sid = obj["sessionId"] as? String else { return .other }
            return .permissionMode(sessionId: sid)

        case "attachment":
            return .attachment

        case "user":
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = parseDate(tsStr) else { return .other }
            let cwd = obj["cwd"] as? String
            let branch = obj["gitBranch"] as? String
            let msg = obj["message"] as? [String: Any]
            let text = extractUserText(msg?["content"])
            return .user(ts: ts, text: text, cwd: cwd, gitBranch: branch)

        case "assistant":
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = parseDate(tsStr) else { return .other }
            let cwd = obj["cwd"] as? String
            let branch = obj["gitBranch"] as? String
            let msg = obj["message"] as? [String: Any]
            let model = msg?["model"] as? String
            let stopReason = msg?["stop_reason"] as? String
            let content = msg?["content"] as? [[String: Any]] ?? []

            var text: String? = nil
            var toolUseName: String? = nil
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { text = t }
                case "tool_use":
                    if let name = block["name"] as? String { toolUseName = name }
                default:
                    continue
                }
            }

            var usage: ClaudeSessionUsage? = nil
            if let u = msg?["usage"] as? [String: Any] {
                usage = .init(
                    inputTokens: (u["input_tokens"] as? Int) ?? 0,
                    outputTokens: (u["output_tokens"] as? Int) ?? 0,
                    cacheReadTokens: (u["cache_read_input_tokens"] as? Int) ?? 0,
                    cacheCreationTokens: (u["cache_creation_input_tokens"] as? Int) ?? 0
                )
            }

            return .assistant(
                ts: ts,
                text: text,
                toolUseName: toolUseName,
                usage: usage,
                model: model,
                stopReason: stopReason,
                cwd: cwd,
                gitBranch: branch
            )

        default:
            return .other
        }
    }

    // Content is either a plain string or an array of block objects. For
    // tool_result blocks the interesting payload is `content` (often a string).
    private static func extractUserText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let arr = raw as? [[String: Any]] else { return "" }
        for block in arr {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { return t }
            case "tool_result":
                if let s = block["content"] as? String { return s }
                if let inner = block["content"] as? [[String: Any]] {
                    for b in inner {
                        if (b["type"] as? String) == "text",
                           let t = b["text"] as? String { return t }
                    }
                }
            default:
                continue
            }
        }
        return ""
    }

    // MARK: - Fold

    static func snapshot(fromLines lines: [String], sessionId: String) -> ClaudeSessionSnapshot? {
        snapshot(fromEntries: lines.compactMap(parseLine), sessionId: sessionId)
    }

    /// Everything the fold below carries between entries.
    ///
    /// This exists because the fold is INCREMENTAL and was being run as if it were not.
    /// Every field here is either last-wins or accumulating, so folding entries 1...n then
    /// folding n+1 gives the same answer as folding 1...n+1 in one pass. `ClaudeSessionTailer`
    /// was re-folding the entire accumulated history on a 1.5 second timer, against session
    /// transcripts that reach several hundred megabytes, which is where the app's idle CPU
    /// was going. Keeping the accumulator lets it fold only what is new.
    ///
    /// One implementation, used by both paths, so the incremental and whole-history answers
    /// cannot drift apart.
    struct SnapshotAccumulator {
        var id: String
        var cwd: String? = nil
        var branch: String? = nil
        var lastTs: Date? = nil
        var lastUserText: String? = nil
        var lastAssistantText: String? = nil
        var model: String? = nil
        var total = ClaudeSessionUsage.zero
        var totalCost: Double = 0
        var pendingTool: String? = nil

        init(sessionId: String) { self.id = sessionId }
    }

    static func snapshot(fromEntries entries: [ClaudeSessionEntry], sessionId: String) -> ClaudeSessionSnapshot? {
        var acc = SnapshotAccumulator(sessionId: sessionId)
        fold(entries, into: &acc)
        return build(acc)
    }

    /// Fold new entries into an accumulator. Safe to call repeatedly with successive slices.
    static func fold(_ entries: [ClaudeSessionEntry], into acc: inout SnapshotAccumulator) {
        var id = acc.id
        var cwd = acc.cwd
        var branch = acc.branch
        var lastTs = acc.lastTs
        var lastUserText = acc.lastUserText
        var lastAssistantText = acc.lastAssistantText
        var model = acc.model
        var total = acc.total
        var totalCost = acc.totalCost
        var pendingTool = acc.pendingTool

        for entry in entries {
            switch entry {
            case .permissionMode(let sid):
                id = sid
            case .user(let ts, let text, let c, let b):
                if let c = c { cwd = c }
                if let b = b { branch = b }
                lastTs = ts
                if !text.isEmpty && !text.hasPrefix("[Request interrupted") {
                    lastUserText = text
                }
                pendingTool = nil
            case .assistant(let ts, let text, let toolUseName, let usage, let m, let stopReason, let c, let b):
                if let c = c { cwd = c }
                if let b = b { branch = b }
                lastTs = ts
                if let m = m { model = m }
                if let text = text { lastAssistantText = text }
                if let usage = usage {
                    total = total + usage
                    totalCost += ClaudeModelPricing.cost(model: m ?? model ?? "", usage: usage)
                }
                pendingTool = (stopReason == "tool_use") ? toolUseName : nil
            case .attachment, .other:
                continue
            }
        }

        acc.id = id
        acc.cwd = cwd
        acc.branch = branch
        acc.lastTs = lastTs
        acc.lastUserText = lastUserText
        acc.lastAssistantText = lastAssistantText
        acc.model = model
        acc.total = total
        acc.totalCost = totalCost
        acc.pendingTool = pendingTool
    }

    /// Render an accumulator as a snapshot. Cheap: no iteration over history.
    static func build(_ acc: SnapshotAccumulator) -> ClaudeSessionSnapshot? {
        let id = acc.id
        let cwd = acc.cwd
        let branch = acc.branch
        let lastUserText = acc.lastUserText
        let lastAssistantText = acc.lastAssistantText
        let model = acc.model
        let total = acc.total
        let totalCost = acc.totalCost
        let pendingTool = acc.pendingTool

        guard let ts = acc.lastTs else { return nil }

        let title: String = {
            if let cwd = cwd, !cwd.isEmpty {
                return (cwd as NSString).lastPathComponent
            }
            if let t = lastUserText, !t.isEmpty {
                return String(t.prefix(60))
            }
            return String(id.prefix(8))
        }()

        let summary: String = {
            guard let text = lastAssistantText else { return "" }
            let firstLine = text.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.count > 120 {
                return String(trimmed.prefix(117)) + "..."
            }
            return trimmed
        }()

        return ClaudeSessionSnapshot(
            sessionId: id,
            cwd: cwd,
            gitBranch: branch,
            title: title,
            lastMessageAt: ts,
            currentTool: pendingTool,
            totalInputTokens: total.inputTokens,
            totalOutputTokens: total.outputTokens,
            totalCacheReadTokens: total.cacheReadTokens,
            totalCacheCreationTokens: total.cacheCreationTokens,
            totalCostUSD: totalCost,
            lastAssistantSummary: summary,
            model: model
        )
    }
}

// MARK: - Pricing

enum ClaudeModelPricing {
    // Dollars per million tokens. Indicative only - not a billing source
    // of truth. The rate values now come from the canonical ModelRates table
    // (this used to keep its own copy that drifted from the others); the exact
    // Claude ids resolve to identical numbers, so replay cost is unchanged.
    private struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheCreate: Double
    }

    static func cost(model: String, usage: ClaudeSessionUsage) -> Double {
        guard let rate = matchRate(model) else { return 0 }
        let m = 1_000_000.0
        return Double(usage.inputTokens) * rate.input / m
             + Double(usage.outputTokens) * rate.output / m
             + Double(usage.cacheReadTokens) * rate.cacheRead / m
             + Double(usage.cacheCreationTokens) * rate.cacheCreate / m
    }

    // Delegates to ModelRates.knownRates, keeping this API's contract that an
    // unrecognized model returns nil (so cost() bills $0 on the replay path
    // rather than falling back to a cheapest-known rate). ModelRates.cacheWrite
    // maps onto this struct's cacheCreate.
    private static func matchRate(_ model: String) -> Rate? {
        guard let r = ModelRates.knownRates(forModelID: model) else { return nil }
        return Rate(input: r.input, output: r.output, cacheRead: r.cacheRead, cacheCreate: r.cacheWrite)
    }
}

// MARK: - Display helpers

extension ClaudeSessionSnapshot {

    var displayTokens: String {
        "\(Self.format(totalInputTokens)) in · \(Self.format(totalOutputTokens)) out"
    }

    var displayCost: String {
        totalCostUSD < 0.005 ? "-" : String(format: "$%.2f", totalCostUSD)
    }

    var relativeLastMessage: String {
        let secs = Int(Date().timeIntervalSince(lastMessageAt))
        if secs < 0 { return "now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    private static func format(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000.0) }
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    }
}
