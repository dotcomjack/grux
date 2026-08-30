import Foundation

// Fills the ambient-transcript retention gap. AmbientState.recentChunks is a
// ring buffer of 200 - a full workday of chatter evicts most of the morning
// before the 6am WorkdayLog rollup runs.
//
// Every hour, this summarizer pulls the last hour's chunks from the ring
// buffer, asks Claude Haiku for a one-sentence summary, and appends an NDJSON
// line to `ambient-summaries/<dayKey>.ndjson`. Raw chunks stay ring-buffered
// as before; summaries are the long-term record WorkdayLogAssembler reads.
//
// `dayKey` is the 6am-anchored workday date of the hour - so hours 00:00-05:59
// are attributed to the PREVIOUS calendar day (the workday that hasn't rolled
// over yet). See `dayKey(forHourStart:calendar:)`.

@MainActor
final class AmbientHourlySummarizer {
    static let shared = AmbientHourlySummarizer()

    private var timer: Timer?
    // Track hours we've already written so a manual tick / app relaunch
    // doesn't duplicate a line. Key = "<dayKey>|<hourStart ISO>".
    private var writtenHourKeys: Set<String> = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Align to the top of the NEXT hour, then fire every 3600s.
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0; comps.second = 0
        let thisHour = cal.date(from: comps) ?? now
        let nextHour = thisHour.addingTimeInterval(3600)
        let delay = max(1, nextHour.timeIntervalSince(now))
        let t = Timer(fire: Date().addingTimeInterval(delay),
                      interval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        WakeLog.shared.log("ambientHourlySummarizer: scheduled, first tick in \(Int(delay))s")
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    // Exposed for menubar "summarize last hour now" diagnostics and tests.
    func tick() async {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0; comps.second = 0
        let thisHourStart = cal.date(from: comps) ?? now
        let lastHourStart = thisHourStart.addingTimeInterval(-3600)
        let lastHourEnd = thisHourStart
        await summarize(hourStart: lastHourStart, hourEnd: lastHourEnd)
    }

    // MARK: - Core

    func summarize(hourStart: Date, hourEnd: Date) async {
        let chunks = AmbientState.shared.recentChunks.filter {
            $0.timestamp >= hourStart && $0.timestamp < hourEnd
        }
        // Skip filler. Less than 2 chunks is almost certainly noise.
        guard chunks.count >= 2 else { return }

        let dayKey = Self.dayKey(forHourStart: hourStart, calendar: Calendar.current)
        let hourKey = "\(dayKey)|\(ISO8601DateFormatter().string(from: hourStart))"
        guard !writtenHourKeys.contains(hourKey) else { return }

        // Per-app dwell from ScreenTimeWatcher NDJSON. Top 5 only. Empty when
        // ScreenTimeWatcher hasn't run yet or AX denied + only 1 app.
        let topApps = Array(
            ScreenTimeWatcher.perAppDwell(between: hourStart, and: hourEnd).prefix(5)
        )

        // Per-domain dwell from ChromeTabWatcher NDJSON. Top 5 only. Empty
        // when Chrome wasn't frontmost this hour or Apple Events permission
        // hasn't been granted yet.
        let topDomains = Array(
            ChromeTabWatcher.perDomainDwell(between: hourStart, and: hourEnd).prefix(5)
        )

        let summary = await buildSummary(
            chunks: chunks, topApps: topApps, topDomains: topDomains
        ) ?? fallbackSummary(chunks: chunks)
        append(
            dayKey: dayKey,
            hourStart: hourStart,
            hourEnd: hourEnd,
            summary: summary,
            chunkCount: chunks.count,
            topApps: topApps,
            topDomains: topDomains
        )
        writtenHourKeys.insert(hourKey)
    }

    private func buildSummary(
        chunks: [AmbientChunk],
        topApps: [(app: String, seconds: Int)] = [],
        topDomains: [(domain: String, seconds: Int)] = []
    ) async -> String? {
        let cfg = AppState.shared.config
        let cloudKeyEmpty = AppState.shared.anthropicKey.isEmpty
        // When the local Qwen toggle is off we still need a cloud key to call
        // Claude. When the toggle is on, an empty cloud key only blocks the
        // fallback - the primary local path can still answer.
        if !cfg.useLocalQwenForAmbient && cloudKeyEmpty { return nil }
        let joined = chunks.map { "- \($0.text)" }.joined(separator: "\n")
        let sys = """
        You are Grux summarizing one hour of the user's ambient speech (raw Whisper transcript chunks). Produce ONE short sentence (≤40 words) naming topics/people/projects they discussed. If the hour was pure filler/silence/music, reply exactly: "quiet". No emoji, no markdown.
        """
        let appsLine: String
        if topApps.isEmpty {
            appsLine = ""
        } else {
            let parts = topApps.map { "\($0.app) \(Int($0.seconds / 60))m" }
            appsLine = "\nSCREEN_TIME_TOP_APPS (this hour): " + parts.joined(separator: ", ")
        }
        let domainsLine: String
        if topDomains.isEmpty {
            domainsLine = ""
        } else {
            let parts = topDomains.map { "\($0.domain) \(Int($0.seconds / 60))m" }
            domainsLine = "\nCHROME_TOP_DOMAINS (this hour): " + parts.joined(separator: ", ")
        }
        let user = """
        TRANSCRIPT_CHUNKS (chronological):
        \(String(joined.prefix(4000)))\(appsLine)\(domainsLine)

        One-sentence summary:
        """
        do {
            let reply = try await AmbientLLM.complete(
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 80,
                temperature: 0.3,
                featureTag: "ambient_hourly_summary"
            )
            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            WakeLog.shared.log("ambientHourlySummarizer: LLM failed - \(error.localizedDescription)")
            return nil
        }
    }

    private func fallbackSummary(chunks: [AmbientChunk]) -> String {
        let joined = chunks.map { $0.text }.joined(separator: " ")
        return String(joined.prefix(500))
    }

    private func append(dayKey: String, hourStart: Date, hourEnd: Date,
                        summary: String, chunkCount: Int,
                        topApps: [(app: String, seconds: Int)] = [],
                        topDomains: [(domain: String, seconds: Int)] = []) {
        // Restore kill switch: the summaries tree is backed up and restored.
        guard !Persistence.writesSuspended else { return }
        let url = Persistence.ambientSummariesDir.appendingPathComponent("\(dayKey).ndjson")
        let iso = ISO8601DateFormatter()
        var line: [String: Any] = [
            "hourStart": iso.string(from: hourStart),
            "hourEnd": iso.string(from: hourEnd),
            "summary": summary,
            "chunkCount": chunkCount
        ]
        if !topApps.isEmpty {
            line["topApps"] = topApps.map { ["app": $0.app, "seconds": $0.seconds] }
        }
        if !topDomains.isEmpty {
            line["topDomains"] = topDomains.map { ["domain": $0.domain, "seconds": $0.seconds] }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: line),
              let str = String(data: json, encoding: .utf8) else { return }
        let payload = (str + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } catch {
                    WakeLog.shared.log("ambientHourlySummarizer: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
        WakeLog.shared.log("ambientHourlySummarizer: wrote \(dayKey) hour=\(iso.string(from: hourStart)) chunks=\(chunkCount)")
    }

    // MARK: - Pure helpers (unit-tested)

    // A workday runs 6:00 local → 5:59:59.999 local next day. Hours before
    // 6am belong to the PREVIOUS dayKey (the workday still in progress).
    nonisolated static func dayKey(forHourStart hour: Date, calendar: Calendar) -> String {
        let hr = calendar.component(.hour, from: hour)
        let anchor: Date
        if hr < 6 {
            anchor = calendar.date(byAdding: .day, value: -1, to: hour) ?? hour
        } else {
            anchor = hour
        }
        let comps = calendar.dateComponents([.year, .month, .day], from: anchor)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

// Struct representing one NDJSON line, used by WorkdayLogAssembler to load
// back a day's summaries.
struct AmbientHourlySummaryRecord: Codable {
    let hourStart: Date
    let hourEnd: Date
    let summary: String
    let chunkCount: Int
    // `var ... = nil` so the synthesized memberwise init keeps these as
    // optional parameters defaulting to nil. `let foo: T? = nil` would
    // delete the field from the synthesized init entirely (constant), which
    // breaks the loadSummaries construction below. WorkdayLogAssemblerTests
    // also relies on omitting both fields in the 4-arg init form.
    var topApps: [TopAppEntry]? = nil
    var topDomains: [TopDomainEntry]? = nil
}

struct TopAppEntry: Codable, Equatable {
    let app: String
    let seconds: Int
}

struct TopDomainEntry: Codable, Equatable {
    let domain: String
    let seconds: Int
}

extension AmbientHourlySummarizer {
    nonisolated static func loadSummaries(forDayKey dayKey: String) -> [AmbientHourlySummaryRecord] {
        let url = Persistence.ambientSummariesDir.appendingPathComponent("\(dayKey).ndjson")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [AmbientHourlySummaryRecord] = []
        for raw in text.split(separator: "\n") {
            guard let jsonData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let hsStr = obj["hourStart"] as? String,
                  let heStr = obj["hourEnd"] as? String,
                  let hs = iso.date(from: hsStr),
                  let he = iso.date(from: heStr),
                  let summary = obj["summary"] as? String else { continue }
            let count = (obj["chunkCount"] as? Int) ?? 0
            var topApps: [TopAppEntry]? = nil
            if let raw = obj["topApps"] as? [[String: Any]] {
                topApps = raw.compactMap {
                    guard let app = $0["app"] as? String,
                          let secs = $0["seconds"] as? Int else { return nil }
                    return TopAppEntry(app: app, seconds: secs)
                }
            }
            var topDomains: [TopDomainEntry]? = nil
            if let raw = obj["topDomains"] as? [[String: Any]] {
                topDomains = raw.compactMap {
                    guard let domain = $0["domain"] as? String,
                          let secs = $0["seconds"] as? Int else { return nil }
                    return TopDomainEntry(domain: domain, seconds: secs)
                }
            }
            out.append(AmbientHourlySummaryRecord(
                hourStart: hs, hourEnd: he, summary: summary,
                chunkCount: count, topApps: topApps, topDomains: topDomains
            ))
        }
        out.sort { $0.hourStart < $1.hourStart }
        return out
    }
}
