import Foundation

// YouTube transcript fetching.
//
//   OFF UNTIL ASKED FOR: `fetch` refuses on `step.youtube_transcripts_enabled`
//      before it reads a video id, spawns yt-dlp or opens a socket. Reading
//      captions out of a third party's site is a thing the user decides to do,
//      not a thing that happens because a link went past, so the refusal is a
//      real error carrying the capability's remediation and never an empty
//      transcript that looks like the video had no captions.
//
//   PRIMARY: yt-dlp via Process. As of the 2026-06-10 live verify, YouTube's
//      POT-token enforcement makes the direct timedtext path return HTTP 200
//      with a 0-byte body for every video, so yt-dlp now carries every real
//      transcript. We require the binary on disk (we never install it) and
//      surface a clear "yt-dlp not installed" error when it is missing, so the
//      failure mode is actionable rather than a silent empty transcript.
//   LAST RESORT: parse the public watch page for the player response's
//      captionTracks, then fetch the timedtext payload (json3 preferred, XML
//      fallback). Kept behind an explicit flag (allowTimedTextFallback) and
//      OFF by default because POT-token enforcement returns empty bodies (see
//      the 2026-06-10 finding above). A 0-byte body is treated as a failure,
//      never a successful empty transcript.
//
// All parsing helpers are pure statics so tests can run against canned
// fixtures with zero network.

struct YouTubeCaptionSegment: Equatable {
    let start: Double      // seconds from video start
    let duration: Double   // seconds
    let text: String
}

struct YouTubeTranscriptResult {
    let videoId: String
    let title: String
    let segments: [YouTubeCaptionSegment]
    let source: String     // "timedtext-json3" | "timedtext-xml" | "yt-dlp"

    // Flowing prose, whitespace collapsed. Good for embedding / summarizing.
    var plainText: String {
        segments.map { $0.text }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // One "[m:ss] text" line per segment. Good for the model to cite moments.
    var textWithTimestamps: String {
        segments.map { "[\(YouTubeTranscript.formatTimestamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }
}

enum YouTubeTranscriptError: Error, LocalizedError {
    case notEnabled
    case invalidURL(String)
    case watchPageFetchFailed(Int)
    case noCaptionTracks
    case captionFetchFailed(Int)
    case emptyTranscript
    case ytDlpNotInstalled
    case ytDlpFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            // The capability's own sentence, never a second wording of it, so
            // whatever surface reports this teaches the same thing the setup
            // card would.
            return "YouTube transcripts are turned off. "
                + SetupRequirement.stepYoutubeTranscriptsEnabled.remediation
        case .invalidURL(let s):
            return "Could not extract a YouTube video ID from '\(s.prefix(120))'."
        case .watchPageFetchFailed(let code):
            return "YouTube watch page fetch failed (HTTP \(code))."
        case .noCaptionTracks:
            return "This video has no caption tracks (music, live stream, or captions disabled)."
        case .captionFetchFailed(let code):
            return "Caption track fetch failed (HTTP \(code))."
        case .emptyTranscript:
            return "Caption track was present but parsed to an empty transcript."
        case .ytDlpNotInstalled:
            return "yt-dlp is not installed. YouTube's direct caption path is blocked by POT-token enforcement (verified 2026-06-10), so transcripts require yt-dlp. Install it with 'brew install yt-dlp' (or place the binary on PATH) and retry."
        case .ytDlpFailed(let msg):
            return "yt-dlp fallback failed: \(msg.prefix(200))"
        }
    }
}

enum YouTubeTranscript {

    struct CaptionTrack: Equatable {
        let baseUrl: String
        let languageCode: String
        let kind: String   // "asr" = auto-generated, "" = manual
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Entry point

    // yt-dlp is the primary path. The direct timedtext path is OFF by default:
    // POT-token enforcement makes it return empty bodies (2026-06-10 finding),
    // so it is only worth a last-resort attempt when the caller opts in AND
    // yt-dlp is unavailable.
    static func fetch(urlOrId: String, allowTimedTextFallback: Bool = false) async throws -> YouTubeTranscriptResult {
        // The opt in gate, and it sits at this function rather than at the one
        // tool that calls it today. This is the single point every path to
        // YouTube passes through, so a caller added later inherits the refusal
        // instead of quietly reopening the hole.
        let enabled = await MainActor.run {
            CapabilityResolver.isSatisfied(.stepYoutubeTranscriptsEnabled)
        }
        guard enabled else { throw YouTubeTranscriptError.notEnabled }

        guard let videoId = extractVideoId(from: urlOrId) else {
            throw YouTubeTranscriptError.invalidURL(urlOrId)
        }

        // Primary: yt-dlp. Require the binary up front so the failure mode is a
        // clear "yt-dlp not installed" rather than a silent empty transcript.
        if let ytDlp = ytDlpPath() {
            return try await fetchViaYtDlp(videoId: videoId, binary: ytDlp)
        }

        // No yt-dlp. Only try the dead-on-arrival timedtext path if the caller
        // explicitly opted in; otherwise tell them exactly what to install.
        guard allowTimedTextFallback else {
            throw YouTubeTranscriptError.ytDlpNotInstalled
        }
        NSLog("[YouTubeTranscript] yt-dlp not found, attempting last-resort timedtext path (POT-token enforcement usually returns empty bodies)")
        return try await fetchViaWatchPage(videoId: videoId)
    }

    // MARK: - Video ID extraction (pure)

    // Accepts: bare 11-char IDs, watch?v=, youtu.be/, /shorts/, /embed/,
    // /live/, /v/, with or without scheme / www. / m. / music. prefixes and
    // trailing query params.
    static func extractVideoId(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Bare video ID.
        if isValidVideoId(s) { return s }

        // Normalize: tolerate missing scheme so URLComponents can parse host.
        let candidate = s.contains("://") ? s : "https://\(s)"
        guard let comps = URLComponents(string: candidate), let host = comps.host?.lowercased() else {
            return nil
        }
        let isYouTubeHost = host == "youtu.be"
            || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        guard isYouTubeHost else { return nil }

        // youtu.be/<id>
        if host == "youtu.be" {
            let id = comps.path.split(separator: "/").first.map(String.init) ?? ""
            return isValidVideoId(id) ? id : nil
        }

        // watch?v=<id>
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, isValidVideoId(v) {
            return v
        }

        // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
        let parts = comps.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]), isValidVideoId(parts[1]) {
            return parts[1]
        }
        return nil
    }

    static func isValidVideoId(_ s: String) -> Bool {
        guard s.count == 11 else { return false }
        return s.allSatisfy { c in
            c.isLetter || c.isNumber || c == "-" || c == "_"
        } && s.allSatisfy { $0.isASCII }
    }

    // MARK: - Watch page parsing (pure)

    // The player response embeds:
    //   "captionTracks":[{"baseUrl":"https:\/\/www.youtube.com\/api\/timedtext?...","languageCode":"en","kind":"asr",...},...]
    // We locate the array, slice it with a balanced-bracket scan (string and
    // escape aware), and hand the slice to JSONSerialization so all JSON
    // escapes (&, \/) decode for free.
    static func captionTracks(fromWatchPage html: String) -> [CaptionTrack] {
        guard let keyRange = html.range(of: "\"captionTracks\":") else { return [] }
        guard let arrayJSON = balancedArraySlice(in: html, from: keyRange.upperBound) else { return [] }
        guard let data = arrayJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj in
            guard let base = obj["baseUrl"] as? String, !base.isEmpty else { return nil }
            return CaptionTrack(
                baseUrl: base,
                languageCode: (obj["languageCode"] as? String ?? "").lowercased(),
                kind: obj["kind"] as? String ?? ""
            )
        }
    }

    // Preference order: manual English > auto-generated English > first
    // manual track of any language > whatever is left.
    static func pickBestTrack(_ tracks: [CaptionTrack]) -> CaptionTrack? {
        guard !tracks.isEmpty else { return nil }
        let isEnglish: (CaptionTrack) -> Bool = { $0.languageCode == "en" || $0.languageCode.hasPrefix("en-") }
        if let t = tracks.first(where: { isEnglish($0) && $0.kind != "asr" }) { return t }
        if let t = tracks.first(where: { isEnglish($0) }) { return t }
        if let t = tracks.first(where: { $0.kind != "asr" }) { return t }
        return tracks.first
    }

    static func videoTitle(fromWatchPage html: String) -> String? {
        // Prefer og:title meta. Attribute order varies, so match the tag and
        // pull content out of it.
        if let tagRange = html.range(of: #"<meta[^>]+property=["']og:title["'][^>]*>"#, options: .regularExpression) {
            let tag = String(html[tagRange])
            if let contentRange = tag.range(of: #"content=["']([^"']*)["']"#, options: .regularExpression) {
                let attr = String(tag[contentRange])
                let value = attr
                    .replacingOccurrences(of: #"^content=["']"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"["']$"#, with: "", options: .regularExpression)
                let decoded = decodeHTMLEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        // Fallback: <title>Foo - YouTube</title>
        if let titleRange = html.range(of: #"<title>(.*?)</title>"#, options: [.regularExpression]) {
            var t = String(html[titleRange])
            t = t.replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: "</title>", with: "")
            t = decodeHTMLEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix(" - YouTube") { t = String(t.dropLast(" - YouTube".count)) }
            if !t.isEmpty { return t }
        }
        return nil
    }

    // Balanced-bracket scanner. `start` must point at or just before the
    // opening '['. String-literal and escape aware so brackets inside titles
    // do not end the array early.
    static func balancedArraySlice(in s: String, from start: String.Index) -> String? {
        guard let open = s[start...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(s[open...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: - Timedtext parsing (pure)

    // Classic timedtext XML:
    //   <transcript><text start="0.08" dur="4.96">I&amp;#39;m here</text>...</transcript>
    // Attribute order can vary; dur is sometimes absent. Entities are often
    // DOUBLE encoded (apostrophe arrives as &amp;#39;), so we decode twice.
    static func parseTimedTextXML(_ xml: String) -> [YouTubeCaptionSegment] {
        var out: [YouTubeCaptionSegment] = []
        let pattern = #"(?is)<text\b([^>]*)>(.*?)</text>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let attrs = ns.substring(with: m.range(at: 1))
            let rawBody = ns.substring(with: m.range(at: 2))
            let start = attributeValue("start", in: attrs).flatMap(Double.init) ?? 0
            let dur = attributeValue("dur", in: attrs).flatMap(Double.init) ?? 0
            // Decode entities twice (apostrophes often arrive double encoded
            // as &amp;#39;), THEN strip inner tags so entity-encoded spans
            // like &lt;b&gt; vanish along with raw nested <font> tags.
            let decoded = decodeHTMLEntities(decodeHTMLEntities(rawBody))
            let text = decoded
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            out.append(YouTubeCaptionSegment(start: start, duration: dur, text: text))
        }
        return out
    }

    private static func attributeValue(_ name: String, in attrs: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = attrs as NSString
        guard let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // json3 timedtext:
    //   {"events":[{"tStartMs":80,"dDurationMs":4960,"segs":[{"utf8":"hello "},{"utf8":"world"}]},...]}
    static func parseJSON3(_ data: Data) -> [YouTubeCaptionSegment] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else {
            return []
        }
        var out: [YouTubeCaptionSegment] = []
        for ev in events {
            guard let segs = ev["segs"] as? [[String: Any]] else { continue }
            let text = segs.compactMap { $0["utf8"] as? String }
                .joined()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            let startMs = (ev["tStartMs"] as? Double) ?? Double(ev["tStartMs"] as? Int ?? 0)
            let durMs = (ev["dDurationMs"] as? Double) ?? Double(ev["dDurationMs"] as? Int ?? 0)
            out.append(YouTubeCaptionSegment(start: startMs / 1000.0, duration: durMs / 1000.0, text: text))
        }
        return out
    }

    // MARK: - Formatting helpers (pure)

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // Graceful truncation for tool output. Cuts on a line boundary when one
    // is nearby so we never split a timestamped line mid-word.
    static func truncated(_ text: String, limit: Int = 50_000) -> String {
        guard text.count > limit else { return text }
        let hardCut = text.index(text.startIndex, offsetBy: limit)
        let window = text[..<hardCut]
        let cut = window.lastIndex(of: "\n").map { window[..<$0] } ?? window
        return String(cut) + "\n\n[transcript truncated: showing \(cut.count) of \(text.count) characters]"
    }

    static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        // Named entities first, EXCEPT &amp; which must go last so we do not
        // manufacture new entities mid-pass.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'")
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities: decimal and hex.
        if out.contains("&#") {
            let pattern = #"&#(x?)([0-9a-fA-F]+);"#
            if let re = try? NSRegularExpression(pattern: pattern) {
                let ns = out as NSString
                let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
                var mutable = out
                for m in matches {
                    guard m.numberOfRanges >= 3,
                          let whole = Range(m.range(at: 0), in: mutable) else { continue }
                    let isHex = ns.substring(with: m.range(at: 1)).lowercased() == "x"
                    let digits = ns.substring(with: m.range(at: 2))
                    guard let code = UInt32(digits, radix: isHex ? 16 : 10),
                          let scalar = Unicode.Scalar(code) else { continue }
                    mutable.replaceSubrange(whole, with: String(Character(scalar)))
                }
                out = mutable
            }
        }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    // MARK: - Strategy A: watch page + timedtext (network)

    private static func fetchViaWatchPage(videoId: String) async throws -> YouTubeTranscriptResult {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        var req = URLRequest(url: watchURL)
        // Pre-acknowledge the consent interstitial some regions get.
        req.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeTranscriptError.watchPageFetchFailed((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let title = videoTitle(fromWatchPage: html) ?? videoId

        let tracks = captionTracks(fromWatchPage: html)
        guard let track = pickBestTrack(tracks) else {
            throw YouTubeTranscriptError.noCaptionTracks
        }

        // json3 first (cleaner), raw XML fallback. A 200 with a 0-byte body is
        // the POT-token-enforcement signature (2026-06-10): treat it as a miss
        // and fall through, never as a successful empty transcript.
        if let json3URL = URL(string: track.baseUrl + (track.baseUrl.contains("fmt=") ? "" : "&fmt=json3")) {
            if let (d, r) = try? await session.data(from: json3URL),
               let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode), !d.isEmpty {
                let segs = parseJSON3(d)
                if !segs.isEmpty {
                    return YouTubeTranscriptResult(videoId: videoId, title: title, segments: segs, source: "timedtext-json3")
                }
            }
        }
        guard let xmlURL = URL(string: track.baseUrl) else {
            throw YouTubeTranscriptError.captionFetchFailed(-1)
        }
        let (xmlData, xmlResp) = try await session.data(from: xmlURL)
        guard let xmlHttp = xmlResp as? HTTPURLResponse, (200..<300).contains(xmlHttp.statusCode) else {
            throw YouTubeTranscriptError.captionFetchFailed((xmlResp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // 0-byte XML body is the same POT-token miss: fail, do not return empty.
        guard !xmlData.isEmpty else { throw YouTubeTranscriptError.emptyTranscript }
        let segs = parseTimedTextXML(String(data: xmlData, encoding: .utf8) ?? "")
        guard !segs.isEmpty else { throw YouTubeTranscriptError.emptyTranscript }
        return YouTubeTranscriptResult(videoId: videoId, title: title, segments: segs, source: "timedtext-xml")
    }

    // MARK: - Strategy B: yt-dlp (only if already installed)

    // Checks well-known install dirs plus PATH. Never installs.
    static func ytDlpPath() -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("yt-dlp")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func fetchViaYtDlp(videoId: String, binary: String) async throws -> YouTubeTranscriptResult {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-yt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Explicit English variants only: a glob like "en.*" also matches
        // auto-translated tracks (en-de etc.) which rate-limit and fail the run.
        let args = [
            "--no-simulate", "--skip-download",
            "--write-subs", "--write-auto-subs",
            "--sub-langs", "en,en-orig,en-US,en-GB",
            "--sub-format", "json3",
            "--print", "title",
            "-P", tmpDir.path,
            "-o", "%(id)s",
            "https://www.youtube.com/watch?v=\(videoId)"
        ]
        let (status, stdout, stderr) = try await runProcess(binary, args, timeout: 90)
        let title = stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? videoId

        // A nonzero exit can still leave a fully usable transcript on disk
        // (one requested track 429s after another already downloaded), so
        // salvage before throwing.
        let files = (try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? []
        if let subFile = files.first(where: { $0.pathExtension == "json3" }),
           let data = try? Data(contentsOf: subFile) {
            let segs = parseJSON3(data)
            if !segs.isEmpty {
                return YouTubeTranscriptResult(videoId: videoId, title: title, segments: segs, source: "yt-dlp")
            }
        }
        guard status == 0 else {
            throw YouTubeTranscriptError.ytDlpFailed(stderr.isEmpty ? stdout : stderr)
        }
        throw YouTubeTranscriptError.noCaptionTracks
    }

    // Lock-guarded accumulator shared across pipe handlers, the termination
    // handler, and the timeout closure. @unchecked Sendable is safe: every
    // mutation goes through the internal lock.
    private final class ProcessIOBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private var resumed = false

        func appendOut(_ d: Data) { lock.lock(); outData.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); errData.append(d); lock.unlock() }

        func snapshot() -> (String, String) {
            lock.lock(); defer { lock.unlock() }
            return (
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // Returns true exactly once; later callers get false.
        func claimResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // Pipe-draining Process runner with a hard timeout. readabilityHandler
    // drains continuously so a chatty process can never deadlock the 64KB
    // pipe buffer.
    private static func runProcess(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let box = ProcessIOBox()

            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { box.appendOut(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { box.appendErr(d) }
            }

            let finish: @Sendable (Result<(Int32, String, String), Error>) -> Void = { result in
                guard box.claimResume() else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(with: result)
            }

            proc.terminationHandler = { p in
                // Drain whatever is left after termination.
                if let tail = try? outPipe.fileHandleForReading.readToEnd() { box.appendOut(tail) }
                if let tail = try? errPipe.fileHandleForReading.readToEnd() { box.appendErr(tail) }
                let (so, se) = box.snapshot()
                finish(.success((p.terminationStatus, so, se)))
            }

            do {
                try proc.run()
            } catch {
                finish(.failure(error))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning {
                    proc.terminate()
                    finish(.failure(YouTubeTranscriptError.ytDlpFailed("timed out after \(Int(timeout))s")))
                }
            }
        }
    }
}
