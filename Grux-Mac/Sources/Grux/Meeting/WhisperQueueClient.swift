import Foundation

// Client for a self-hosted WhisperKit transcription queue. Grux uploads a
// recording, the server transcribes it with large-v3_turbo, Grux polls for the
// result.
//
// Fallback posture (per spec hygiene rule #5): every call is SOFT. If the server
// is asleep, the network is down, the upload fails, or the job errors, the
// caller keeps the local live transcript instead. Nothing here ever throws into
// the meeting-stop path, failures return nil and are logged.
//
// NO host ships baked in. Set GRUX_WHISPER_QUEUE_URL to the queue's base URL
// (a LAN box, a tunnel, a staging server) to turn offload on. Unset means no
// candidate hosts, which is a supported state: nothing is reachable, so every
// call soft-fails to the local transcript exactly as it does when the server is
// down.
actor WhisperQueueClient {
    static let shared = WhisperQueueClient()

    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Result: Sendable {
        let text: String
        let segments: [Segment]
        let model: String
        let usedFallback: Bool
        let transcribeSeconds: Double?
    }

    // Decoded job shape from the queue. Optional fields cover the queued/running
    // states where the result isn't there yet.
    private struct Job: Codable {
        let id: String
        let status: String          // queued | running | done | error
        let text: String?
        let segments: [Segment]?
        let model: String?
        let language: String?
        let usedFallback: Bool?
        let transcribeSeconds: Double?
        let error: String?
    }

    private struct Health: Codable { let ok: Bool; let model: String?; let cliPresent: Bool? }
    private struct EnqueueResponse: Codable { let id: String; let status: String }

    private let decoder = JSONDecoder()

    // Resolved-good base URL, cached after the first reachable host answers so
    // polling sticks to the host that took the upload.
    private var resolvedBase: URL?

    private var candidateBases: [URL] {
        if let override = ProcessInfo.processInfo.environment["GRUX_WHISPER_QUEUE_URL"],
           let u = URL(string: override) {
            return [u]
        }
        // Empty means unconfigured: reachableBase() finds nothing and every
        // caller soft-falls back to the local transcript.
        return []
    }

    private var isDisabled: Bool {
        ProcessInfo.processInfo.environment["GRUX_WHISPER_QUEUE_DISABLED"] == "1"
    }

    private func session(timeout: TimeInterval) -> URLSession {
        session(requestTimeout: timeout, resourceTimeout: timeout)
    }

    // Split-timeout variant. Uploads want a short per-stall request timeout but
    // a long overall resource ceiling that scales with the payload.
    private func session(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: cfg)
    }

    private func authorize(_ req: inout URLRequest) {
        if let token = ProcessInfo.processInfo.environment["GRUX_WHISPER_QUEUE_TOKEN"], !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    // Quick reachability + readiness probe. Returns the first base URL whose
    // /health says ok AND has the CLI binary present, else nil.
    @discardableResult
    func reachableBase() async -> URL? {
        if isDisabled { return nil }
        let s = session(timeout: 5)
        for base in candidateBases {
            var req = URLRequest(url: base.appendingPathComponent("health"))
            authorize(&req)
            do {
                let (data, resp) = try await s.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let h = try decoder.decode(Health.self, from: data)
                if h.ok && (h.cliPresent ?? true) {
                    resolvedBase = base
                    return base
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // Upload an audio file and poll until the transcript is ready. Returns nil
    // on any failure (caller falls back to the local transcript). `pollDeadline`
    // is derived from the audio length by the caller; turbo runs faster than
    // real time, so 2x duration + slack is generous.
    func transcribe(
        audioFileURL: URL,
        meetingId: String? = nil,
        model: String? = nil,
        language: String = "en",
        pollDeadlineSeconds: TimeInterval
    ) async -> Result? {
        if isDisabled {
            WakeLog.shared.log("whisper-queue: disabled via env, skipping offload")
            return nil
        }
        var resolved = resolvedBase
        if resolved == nil { resolved = await reachableBase() }
        guard let base = resolved else {
            WakeLog.shared.log("whisper-queue: no reachable transcription host, skipping offload")
            return nil
        }
        // Read the size only (not the bytes) so a 170 MB+ meeting WAV never
        // has to sit fully resident in the laptop's RAM. The upload streams
        // from disk below via upload(for:fromFile:).
        let audioBytes = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? Int) ?? nil
        guard let audioBytes, audioBytes > 0 else {
            WakeLog.shared.log("whisper-queue: could not stat audio at \(audioFileURL.lastPathComponent)")
            return nil
        }

        // --- enqueue ---
        guard var comps = URLComponents(
            url: base.appendingPathComponent("api/whisper/jobs"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = [URLQueryItem(name: "filename", value: audioFileURL.lastPathComponent),
                     URLQueryItem(name: "language", value: language)]
        if let model { items.append(URLQueryItem(name: "model", value: model)) }
        if let meetingId { items.append(URLQueryItem(name: "meetingId", value: meetingId)) }
        comps.queryItems = items
        guard let enqueueURL = comps.url else { return nil }

        var post = URLRequest(url: enqueueURL)
        post.httpMethod = "POST"
        post.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        authorize(&post)

        // Scale the upload's resource timeout with the payload (a 170 MB WAV
        // over the tailnet can take well over the old flat 120 s). Budget a
        // conservative ~1 MB/s floor plus headroom, clamped to a sane range.
        let uploadResourceTimeout = min(1800.0, max(180.0, Double(audioBytes) / (1024 * 1024) * 2 + 60))
        let uploadSession = session(requestTimeout: 90, resourceTimeout: uploadResourceTimeout)

        let jobId: String
        do {
            // upload(for:fromFile:) streams the file from disk, so the bytes are
            // never fully loaded into memory.
            let (data, resp) = try await uploadSession.upload(for: post, fromFile: audioFileURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                WakeLog.shared.log("whisper-queue: enqueue HTTP \(code)")
                resolvedBase = nil  // host may be wedged; re-probe next time
                return nil
            }
            jobId = try decoder.decode(EnqueueResponse.self, from: data).id
        } catch {
            WakeLog.shared.log("whisper-queue: enqueue failed \(error.localizedDescription)")
            resolvedBase = nil  // host unreachable mid-upload; don't pin it
            return nil
        }
        WakeLog.shared.log("whisper-queue: enqueued job \(jobId) (\(audioBytes) bytes), polling")

        // --- poll ---
        let pollSession = session(timeout: 10)
        let deadline = Date().addingTimeInterval(pollDeadlineSeconds)
        var intervalNs: UInt64 = 2_000_000_000  // start at 2s
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: intervalNs)
            // Gentle backoff up to 8s so a 30-min file doesn't hammer the server.
            intervalNs = min(intervalNs + 1_000_000_000, 8_000_000_000)

            var get = URLRequest(url: base.appendingPathComponent("api/whisper/jobs/\(jobId)"))
            authorize(&get)
            do {
                let (data, resp) = try await pollSession.data(for: get)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let job = try decoder.decode(Job.self, from: data)
                switch job.status {
                case "done":
                    let text = job.text ?? ""
                    guard !text.isEmpty else {
                        WakeLog.shared.log("whisper-queue: job \(jobId) done but empty transcript")
                        return nil
                    }
                    return Result(
                        text: text,
                        segments: job.segments ?? [],
                        model: job.model ?? (model ?? "unknown"),
                        usedFallback: job.usedFallback ?? false,
                        transcribeSeconds: job.transcribeSeconds
                    )
                case "error":
                    WakeLog.shared.log("whisper-queue: job \(jobId) errored, \(job.error ?? "?")")
                    return nil
                default:
                    continue  // queued / running
                }
            } catch {
                continue  // transient poll failure; keep trying until deadline
            }
        }
        WakeLog.shared.log("whisper-queue: job \(jobId) timed out after \(Int(pollDeadlineSeconds))s")
        return nil
    }

    // MARK: - On-demand smoke test (fire-whisper-queue-test)

    // End-to-end round trip to the queue without waiting for a real long meeting.
    // Resolves an audio file (priority: ~/.grux/whisper-test-audio.wav fixture,
    // else a freshly synthesized short `say` clip, same 16 kHz mono WAV format
    // AudioExportStore writes for meetings, so it exercises the identical path),
    // uploads it, polls, and writes the outcome to
    // ~/.grux/whisper-queue-test-result.txt for CLI verification. Returns a
    // one-line human summary (also surfaced in chat by the trigger).
    //
    // Deliberately does NOT grab the newest meeting WAV: those run to 170 MB+
    // for a long meeting and wouldn't finish inside a smoke window. The 10-min
    // acceptance path already proves the server handles long real audio.
    func runSmokeTest() async -> String {
        let gruxDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grux")
        let resultPath = gruxDir.appendingPathComponent("whisper-queue-test-result.txt")

        func writeResult(_ s: String) {
            try? FileManager.default.createDirectory(at: gruxDir, withIntermediateDirectories: true)
            try? s.data(using: .utf8)?.write(to: resultPath)
        }

        guard let base = await reachableBase() else {
            let msg = "whisper-queue smoke: NO reachable transcription host. Set GRUX_WHISPER_QUEUE_URL and check the server is awake + deployed."
            WakeLog.shared.log(msg)
            writeResult(msg + "\n")
            return msg
        }

        guard let audioURL = resolveSmokeAudio(gruxDir: gruxDir) else {
            let msg = "whisper-queue smoke: could not find or synthesize test audio"
            WakeLog.shared.log(msg)
            writeResult(msg + "\n")
            return msg
        }
        WakeLog.shared.log("whisper-queue smoke: host=\(base.absoluteString) audio=\(audioURL.lastPathComponent)")

        let result = await transcribe(
            audioFileURL: audioURL,
            meetingId: "smoke-test",
            pollDeadlineSeconds: 600
        )
        guard let result else {
            let msg = "whisper-queue smoke: FAILED (no transcript, see WakeLog). host=\(base.absoluteString)"
            writeResult(msg + "\n")
            return msg
        }
        let summary = """
        whisper-queue smoke: OK
        host: \(base.absoluteString)
        audio: \(audioURL.lastPathComponent)
        model: \(result.model)  fallback: \(result.usedFallback)
        transcribeSeconds: \(result.transcribeSeconds.map { String(format: "%.1f", $0) } ?? "?")
        text: \(result.text)
        """
        writeResult(summary + "\n")
        WakeLog.shared.log("whisper-queue smoke: OK model=\(result.model) chars=\(result.text.count)")
        return "whisper-queue smoke OK (\(result.model)): \(result.text.prefix(120))"
    }

    private func resolveSmokeAudio(gruxDir: URL) -> URL? {
        let fm = FileManager.default
        // 1. Explicit test fixture (user opted in, any size).
        let fixture = gruxDir.appendingPathComponent("whisper-test-audio.wav")
        if fm.fileExists(atPath: fixture.path) { return fixture }
        // 2. Synthesize a short clip with `say` + `afconvert` (built-in, no ffmpeg).
        let aiff = gruxDir.appendingPathComponent("whisper-smoke.aiff")
        let wav = gruxDir.appendingPathComponent("whisper-smoke.wav")
        try? fm.createDirectory(at: gruxDir, withIntermediateDirectories: true)
        let sayOK = runProcess("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path,
            "Grux whisper queue smoke test. The quick brown fox jumps over the lazy dog."])
        guard sayOK else { return nil }
        let convOK = runProcess("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        try? fm.removeItem(at: aiff)
        return (convOK && fm.fileExists(atPath: wav.path)) ? wav : nil
    }

    private func runProcess(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
