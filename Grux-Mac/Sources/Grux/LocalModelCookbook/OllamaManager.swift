import Foundation

// What a pull would cost on disk, whether the volume can take it, and the
// numbers that decided.
//
// WHY THIS EXISTS. Measured across `Sources/` before it did:
// `volumeAvailableCapacityForImportantUsage` appeared zero times,
// `systemFreeSize` zero times, `availableCapacity` zero times. Every
// `CookbookModel` carries a `diskGB` and nothing in the app ever compared it to
// anything, so somebody on a 256 GB Mac with 18 GB free could press PULL on
// gpt-oss:120b, which is a 65 GB download, and find out slowly: the bar climbs
// for an hour, the volume fills, and macOS starts complaining about things that
// have nothing to do with Grux. Every line of code did what it was told and the
// user still met it as the app being broken.
//
// A FILE SCOPE VALUE TYPE, and the rule kept apart from the reading, for the
// reason `MachineLoad` splits `headroom(thermalState:lowPowerMode:memoryPressure:)`
// out of the observable that reads those three facts. `OllamaManager` is a
// @MainActor singleton that owns a child process and a health loop, and a test
// that had to stand all of that up to ask whether 18 GB is enough for a 65 GB
// model would be testing the wrong thing. Every number here is passed in, so
// the refusal can be driven on a development machine with a half empty disk.
struct OllamaDiskCheck: Equatable {
    // The catalog's published download size for the model.
    let downloadGB: Double

    // Free space the pull has to leave behind.
    let reserveGB: Double

    // What the volume says it can give up right now.
    let availableGB: Double

    // Where the reading was taken: the models directory when it exists, its
    // nearest existing ancestor when it does not. In the refusal because the
    // number alone can be a true statement about the WRONG disk: a reader
    // whose models really land on a roomy external volume can see at a glance
    // that the figure was measured somewhere else, instead of being handed a
    // bare "18 GB" that no volume they know about reports.
    let measuredPath: String

    var requiredGB: Double { downloadGB + reserveGB }

    var fits: Bool { availableGB >= requiredGB }

    // The refusal, said with the numbers rather than as a verdict.
    //
    // "Insufficient disk space" tells somebody they cannot have the thing and
    // nothing about what would change that, so the only move it leaves them is
    // to try again and watch it fail the same way. All four numbers are here
    // because the reserve is the one a reader would otherwise call arithmetic
    // they cannot reproduce: 65 and 18 do not explain why a 66 GB volume is
    // also a no.
    //
    // THE ACTIONABLE PAIR COMES FIRST, and that ordering is not stylistic.
    // A refusal is skimmed before it is read: "needs this much, you have this
    // much" is the part somebody acts on, so it leads, and the reserve
    // breakdown and the measured path follow as the explanation.
    // `CookbookView.pullProgressRow` lets a failed status wrap, so the tail is
    // readable rather than truncated, but the opening words are still the ones
    // a glance lands on.
    var refusal: String {
        String(format: "Needs %.1f GB free, this disk has %.1f GB (%.1f GB model plus %.0f GB spare), measured at %@",
               requiredGB, availableGB, downloadGB, reserveGB, measuredPath)
    }

    // Free space a pull must leave behind, over and above the model itself.
    //
    // A BLUNT NUMBER, AND SAID SO, in the same spirit as
    // `HardwareProfile.budgetFraction`: there is no measurement that turns "the
    // Mac is still usable afterwards" into a byte count, and inventing a precise
    // looking one would only make the guess harder to argue with later. What it
    // has to get right is that it is not zero. macOS pages to the same volume
    // the models land on, Grux writes its own config and session files there,
    // and a Mac with a few hundred megabytes left is already failing at things
    // that have nothing to do with Ollama. 5 GB is room for swap to grow and an
    // OS update to stage, and small enough that it never refuses a pull a Mac
    // with any real free space could have taken.
    //
    // IT IS ONE COPY PLUS THE RESERVE, NOT TWO COPIES. The obvious version of
    // this guard demands room for a download AND for the unpacked model, which
    // is right for an archive and wrong for Ollama: the binary on the machine
    // this was written against (0.32.15) carries the `-partial` suffix it hangs
    // on the blob it is fetching, and the finished blob is that same file in
    // that same blobs directory. Demanding twice the size would refuse pulls
    // that would have completed, which is its own way of looking broken.
    static let reserveGB: Double = 5.0

    // Bytes per GB, DECIMAL, and not the 2^30 that `HardwareProfile` converts
    // RAM with.
    //
    // The two units genuinely differ and the wrong one here would be visible to
    // a user. RAM is a power of two and `hw.memsize` reports it that way, so
    // gibibytes are right for the memory budget. A download size is not: read
    // off the Ollama install this was written against, llama3.2:3b is published
    // as 2.0 GB and its manifest layers total 2,019,393,189 bytes, which is
    // 2.019 decimal GB and 1.881 GiB. macOS reports disk capacity the same
    // decimal way, so 1e9 is also what makes this refusal match the number the
    // user can go and read in Finder. Converting with 2^30 would demand 7.4
    // percent more than the model actually needs and print a figure nothing
    // else on the machine agrees with.
    static let bytesPerGB: Double = 1_000_000_000

    static func forPull(downloadGB: Double, availableBytes: Int64, measuredPath: String) -> OllamaDiskCheck {
        OllamaDiskCheck(downloadGB: downloadGB,
                        reserveGB: reserveGB,
                        availableGB: Double(availableBytes) / bytesPerGB,
                        measuredPath: measuredPath)
    }

    // Where a pull lands.
    //
    // Ollama honours OLLAMA_MODELS and otherwise writes under ~/.ollama/models.
    // Grux spawns `ollama serve` as a child process, so it inherits this
    // process's environment and reading the variable here reaches the same
    // answer the server will. An EXTERNAL server (the menu bar app, a terminal
    // session) could have been launched with a different one, and that is the
    // case this cannot see: it would then measure the wrong volume, which is
    // why `diskShortfall` stands down entirely when the serving Ollama is not
    // Grux's own.
    static func modelsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let custom = (environment["OLLAMA_MODELS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".ollama/models")
    }

    // Free capacity on the volume a pull would write to, or nil when the
    // platform will not say.
    //
    // `volumeAvailableCapacityForImportantUsage` rather than the raw free byte
    // count, and the difference is not cosmetic: the important-usage figure
    // counts purgeable space, the caches and local Time Machine snapshots macOS
    // evicts on demand, and on a Mac that has been running a while that is
    // routinely tens of gigabytes. The raw number treats all of it as spent, so
    // it would refuse pulls the machine could comfortably take, which is the
    // guard failing in the direction nobody notices.
    static func availableCapacityBytes(at directory: URL) -> Int64? {
        guard let values = try? nearestExistingAncestor(of: directory).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // The deepest ancestor of `directory` that exists on disk.
    //
    // The models directory does not exist until the first pull, and
    // `resourceValues` throws on a path that is not there, so the reading is
    // taken on the nearest ancestor that IS there: that is the volume the pull
    // would land on, because creating the directory happens inside it. Split
    // out of the capacity read because the refusal now names the measured
    // path, and the name has to be the exact path the number came from rather
    // than a second derivation that could drift.
    static func nearestExistingAncestor(of directory: URL) -> URL {
        var probe = directory.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }   // reached the root
            probe = parent
        }
        return probe
    }

    // Whether a base URL points at THIS machine. Anything else is a server on
    // different hardware, whose disks this process cannot stat, so the disk
    // gate has nothing true to say about where its pulls land. A URL this
    // cannot parse counts as not-loopback for the same reason the capacity
    // read returns nil on a volume it cannot stat: a reading that could not be
    // taken must never harden into a refusal.
    //
    // Brackets trimmed for the reason SocialOpsService.isServiceTrustedLoopback
    // documents: URL.host has returned the IPv6 literal both ways ("::1" and
    // "[::1]") across Foundation versions. That helper learned it and this
    // one did not, so a base of http://[::1]:11434 on a toolchain returning
    // the bracketed form read as a REMOTE host, the gate stood down as
    // designed for hardware it cannot stat, and the 65 GB-onto-18 GB pull
    // this whole guard exists to refuse went through unchecked.
    static func isLoopbackHost(_ baseURL: String) -> Bool {
        guard let raw = URL(string: baseURL)?.host?.lowercased() else { return false }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}

// Owns the local Ollama lifecycle for the Cookbook tab: find the binary,
// start and stop `ollama serve` as a managed child process, poll health on
// localhost:11434, and pull models with streamed progress via /api/pull.
//
// Mirrors the discovery posture of ModelRegistry.discoverLocal() (fail fast,
// never crash chat) and the LocalLLM.swift convention that the endpoint comes
// from GruxConfig at call time. If a server is already running (the Ollama
// menu bar app, a terminal session), we mark it external and never kill it;
// we only ever terminate a process we spawned ourselves.
@MainActor
final class OllamaManager: ObservableObject {
    static let shared = OllamaManager()

    enum ServerState: Equatable {
        case stopped
        case starting
        case runningManaged   // we own the `ollama serve` child process
        case runningExternal  // something else is serving on the port
        case stopping

        var isRunning: Bool { self == .runningManaged || self == .runningExternal }

        var label: String {
            switch self {
            case .stopped:         return "Stopped"
            case .starting:        return "Starting"
            case .runningManaged:  return "Running (Grux-managed)"
            case .runningExternal: return "Running (external)"
            case .stopping:        return "Stopping"
            }
        }
    }

    struct PullProgress: Equatable {
        var status: String = "queued"
        var fraction: Double? = nil   // nil while Ollama hasn't reported sizes yet
        var failed: Bool = false
    }

    @Published private(set) var binaryPath: String? = nil
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var installedTags: [String] = []
    @Published private(set) var pulls: [String: PullProgress] = [:]
    @Published private(set) var lastError: String? = nil

    private var serveProcess: Process? = nil
    private var pullTasks: [String: Task<Void, Never>] = [:]
    // Per-pull generation token: completion cleanup and cancelPull only
    // remove bookkeeping for THEIR OWN registration, so a cancelled task
    // unwinding late can never clobber a restarted pull's entry.
    private var pullGenerations: [String: UUID] = [:]

    // Bumped by every stop() call. `pull()` captures it before the disk gate
    // suspends and refuses to register anything if it moved: for the length
    // of that probe the pull is in no collection stop() can reach, so the
    // counter is the only evidence that a stop happened in the gap.
    private var stopEpoch: UInt64 = 0

    // Bumped by every cancelPull. Its twin, stopEpoch, records that the SERVER
    // was stopped during the disk gate; this records that THIS PULL was
    // cancelled during it. The gate publishes a row before it suspends (so the
    // press is answered immediately), and that row renders the CANCEL chip, so
    // for ~2s the reader is offered a control whose press had nowhere to
    // land: cancelPull wrote "cancelled", no task existed to cancel, and the
    // resuming gate overwrote the row with "starting" and began a multi-GB
    // download the reader had explicitly stopped.
    private var cancelEpochs: [String: UInt64] = [:]
    private var healthLoop: Task<Void, Never>? = nil

    // The free-capacity reading and the path it was taken at, injected.
    //
    // The reading is the one input the guard below turns on and the one thing a
    // test cannot control on a real machine. A test that asserted the refusal by
    // hoping the host disk was full would pass on a full disk, pass on an empty
    // one for a different reason, and report nothing either way, which is the
    // same as not asserting it at all. Same reason `HardwareProfile` is a pure
    // value type and `MachineLoad.headroom` takes its three facts as arguments:
    // the interesting states are exactly the ones no development machine is in.
    //
    // ONE CLOSURE FOR BOTH, not a bytes seam and a path seam, because the
    // refusal prints the path as the provenance of the number, and two seams
    // that swap independently would let a fabricated figure ship wearing a
    // path it was never read from.
    //
    // @Sendable so `pullRefusal` can run it OFF the main actor. The default
    // walks ancestor directories and asks the file system for
    // purgeable-aware free capacity, which is a slow synchronous call
    // exactly on the near-full disks this gate exists for, and it used to
    // make it on the main actor. Every injection is a closure over plain
    // values and already satisfies this.
    var availableDisk: @Sendable () -> (bytes: Int64, path: String)? = {
        let probe = OllamaDiskCheck.nearestExistingAncestor(of: OllamaDiskCheck.modelsDirectory())
        guard let bytes = OllamaDiskCheck.availableCapacityBytes(at: probe) else { return nil }
        return (bytes, probe.path)
    }

    // Whether anything answers at the base URL right now, injected.
    //
    // The adoption question `pullRefusal` settles turns on this single fact,
    // and it is the other reading a test cannot control on a real machine: a
    // development Mac may genuinely have the menu bar app serving on 11434, or
    // genuinely have nothing there, and either truth silently decides which
    // branch a test exercised. The default is the probe `runPull` itself
    // trusts, reached through `shared` because the manager is a singleton, so
    // the assertable path and the shipping path stay one path.
    var serverAnswers: () async -> Bool = { await OllamaManager.shared.isHealthy() }

    // One reused session for all health probes. A fresh ephemeral URLSession
    // per call is never invalidated, so its connection pool, cache, and
    // worker resources accrue forever; the health loop probes every 10s for
    // the app's lifetime.
    private static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // Base URL convention matches ModelRegistry: the durable preference in
    // GruxConfig, defaulting to localhost:11434.
    private var baseURL: String {
        let raw = AppState.shared.config.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "http://localhost:11434" : raw
    }

    // MARK: - Binary discovery

    // Well-known install locations first (Homebrew arm64, Homebrew x86,
    // the Ollama.app bundle), then a `which` fallback through the login
    // shell PATH. Same spirit as ModelRegistry's best-effort discovery.
    func detectBinary() {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            binaryPath = path
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ollama"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            binaryPath = (proc.terminationStatus == 0 && !path.isEmpty) ? path : nil
        } catch {
            binaryPath = nil
        }
    }

    // MARK: - Health

    // GET {base}/api/version with a 2 second budget. True means something is
    // answering like Ollama on the port.
    func isHealthy() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await Self.probeSession.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // One-shot reconciliation: figure out what's true right now. Called on
    // view appear and after serve/stop transitions.
    func refresh() async {
        if binaryPath == nil { detectBinary() }
        let healthy = await isHealthy()
        if healthy {
            if serverState != .runningManaged { serverState = .runningExternal }
            await refreshInstalled()
        } else {
            if serveProcess?.isRunning != true { serverState = .stopped }
            installedTags = []
        }
    }

    // MARK: - Serve lifecycle

    // One-click serve. If a server is already healthy we adopt it as
    // external (no child process). Otherwise spawn `ollama serve`, then poll
    // health until it answers or the 20 second budget runs out.
    func serve() async {
        // Reentrancy guard: serve() suspends repeatedly (health probe,
        // startup poll) and runPull auto-calls it, so two concurrent calls
        // would spawn duplicate `ollama serve` children and orphan one
        // forever. Followers WAIT for the in-flight startup to settle
        // instead of returning instantly: callers (runPull) treat serve()'s
        // return as "startup settled" and read serverState right after.
        if serverState == .starting {
            await waitForServeToSettle()
            return
        }
        if serverState.isRunning {
            // Never trust a stale running state: an external server (Ollama
            // menu bar app, a terminal session) can quit without anything
            // updating serverState, and the health loop only watches the
            // managed child. Verify before short-circuiting so PULL can
            // self-heal by spawning a managed server.
            if await isHealthy() { return }
            // Re-check after the await: another caller may have started
            // (or stopped) the lifecycle while we were probing.
            if serverState == .starting {
                await waitForServeToSettle()
                return
            }
            if serverState == .stopping { return }
            if serverState.isRunning { serverState = .stopped }
        }
        lastError = nil
        serverState = .starting
        if await isHealthy() {
            serverState = .runningExternal
            await refreshInstalled()
            return
        }
        guard let bin = binaryPath else {
            serverState = .stopped
            lastError = "Ollama binary not found. Install from ollama.com or `brew install ollama`."
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve"]
        // Discard server logs; health polling is our signal. Keeping pipes
        // attached without draining them would eventually block the child.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                // Identity check: only the CURRENT managed child may clear
                // state. A superseded process exiting late must not nil out
                // a live successor's handle (which would make stop() and
                // shutdownSync() unable to ever terminate it).
                guard self.serveProcess === p else { return }
                self.serveProcess = nil
                if self.serverState == .runningManaged || self.serverState == .starting {
                    self.serverState = .stopped
                }
            }
        }
        do {
            try proc.run()
        } catch {
            serverState = .stopped
            lastError = "Failed to launch ollama serve: \(error.localizedDescription)"
            return
        }
        serveProcess = proc

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if await isHealthy() {
                serverState = .runningManaged
                await refreshInstalled()
                startHealthLoop()
                return
            }
            if !proc.isRunning {
                serverState = .stopped
                serveProcess = nil
                lastError = "ollama serve exited during startup (port already bound or bad install)."
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        lastError = "Ollama did not become healthy within 20s."
        stopManagedProcess()
        serverState = .stopped
    }

    // Follower wait: the original starter owns the spawn and its 20s health
    // budget; concurrent callers just poll until serverState leaves
    // .starting. Deadline is a backstop above the starter's own budget so a
    // logic bug can never park a follower forever.
    private func waitForServeToSettle() async {
        let deadline = Date().addingTimeInterval(25)
        while serverState == .starting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // Graceful shutdown of the managed process only. External servers are
    // left alone (we did not start them, we do not kill them).
    func stop() async {
        guard serverState == .runningManaged || serverState == .starting else {
            // External server: just forget about it locally.
            if serverState == .runningExternal { serverState = .stopped }
            return
        }
        // Bumped ONLY on the arm that actually stops something. It used to be
        // bumped above the guard, including on the external arm, which never
        // calls stopManagedProcess: that server keeps running and keeps
        // serving, so a pull suspended in its disk gate was refused with
        // "server stopped before the download started" about a server that
        // was not stopped. The old justification (the external arm "leaves
        // the server unreachable too") is measurably false; Grux deliberately
        // never kills a server it did not start.
        stopEpoch &+= 1
        serverState = .stopping
        healthLoop?.cancel()
        healthLoop = nil
        // THE TERMINAL ROW IS WRITTEN HERE, BEFORE THE GENERATIONS ARE
        // CLEARED, and the order is the fix. Cancelling a pull unwinds
        // `runPull` through its GENERIC catch as URLError(.cancelled) rather
        // than CancellationError, so the failed:true row it publishes is the
        // one that used to land. Clearing pullGenerations first orphans that
        // write behind `publish`'s generation guard, and the row then froze
        // mid-download: a live progress bar and a CANCEL chip for a pull that
        // is dead, with the PULL button never coming back, because only
        // `failed` restores it. Same shape and wording as cancelPull, which
        // is the other writer of this row.
        //
        // A pull that already reached a TERMINAL row is left alone, and that
        // one guard is the difference between stamping a live pull and lying
        // about a finished one. `pull()` removes its entry in a TRAILING
        // MainActor hop after runPull returns, so a model that published
        // "installed" and returned is still sitting in pullTasks when this
        // loop reads it. Overwriting it wrote a failed "cancelled" over a
        // model that really did install: the PULL button came back, and
        // `installedTags = []` at the end of this function removed the one
        // piece of evidence that said otherwise. Cancelling a task that has
        // already returned is a no-op, so the cancel stays unconditional.
        for (modelId, task) in pullTasks {
            task.cancel()
            if let row = pulls[modelId], row.failed || row.status == "installed" { continue }
            pulls[modelId] = PullProgress(status: "cancelled", fraction: nil, failed: true)
        }
        pullTasks = [:]
        pullGenerations = [:]
        stopManagedProcess()
        // Give SIGTERM up to 3 seconds before escalating.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, serveProcess?.isRunning == true {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let proc = serveProcess, proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        serveProcess = nil
        serverState = .stopped
        installedTags = []
    }

    // Synchronous best-effort kill for app termination paths. Safe to call
    // from applicationWillTerminate; no awaits.
    func shutdownSync() {
        healthLoop?.cancel()
        guard let proc = serveProcess, proc.isRunning else { return }
        proc.terminate()
    }

    private func stopManagedProcess() {
        guard let proc = serveProcess, proc.isRunning else { return }
        proc.terminate()
    }

    // Background watcher: if the managed server stops answering (crash,
    // upgrade replacing the binary), flip state so the UI shows the truth.
    private func startHealthLoop() {
        healthLoop?.cancel()
        healthLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                guard self.serverState.isRunning else { continue }
                let healthy = await self.isHealthy()
                if !healthy, self.serveProcess?.isRunning != true {
                    self.serverState = .stopped
                }
            }
        }
    }

    // MARK: - Installed models

    // GET {base}/api/tags, same shape ModelRegistry.discoverLocal() reads.
    func refreshInstalled() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return }
        installedTags = models.compactMap { $0["name"] as? String }
    }

    // A catalog id counts as installed when any installed tag matches it
    // exactly or as the ":latest" expansion ("llama3.1:8b" vs "llama3.1:8b",
    // "mistral-small3.1" vs "mistral-small3.1:latest").
    func isInstalled(_ modelId: String) -> Bool {
        installedTags.contains { $0 == modelId || $0 == "\(modelId):latest" }
    }

    // MARK: - Pull with streamed progress

    // The arithmetic half of the gate: what the disk says about a pull at a
    // given posture, or nil to go ahead. `pull` reaches it through
    // `pullRefusal` below, which settles what the posture actually IS first.
    //
    // Internal rather than private because the version of this that FITS has
    // to be assertable without starting a real pull: the proceed path spawns
    // `ollama serve` and opens a 3600 second stream, so a test that drove it
    // would be a network call and a child process, not a test. The serve
    // posture and base URL are parameters rather than reads of `serverState`
    // and the config, for the same reason: the postures this gate stands down
    // for (an external server, a remote base URL) are exactly the ones a unit
    // test cannot put the shared manager into.
    func diskShortfall(for modelId: String, serverState: ServerState, baseURL: String) -> OllamaDiskCheck? {
        diskShortfall(for: modelId, serverState: serverState, baseURL: baseURL,
                      disk: gateApplies(to: modelId, serverState: serverState, baseURL: baseURL)
                          ? availableDisk() : nil)
    }

    // The same gate over a reading somebody else already took. Exists so
    // `pullRefusal` can take that reading off the main actor without the
    // arithmetic growing a second copy; the sync entry point above is the
    // shape every test drives.
    func diskShortfall(for modelId: String, serverState: ServerState, baseURL: String,
                       disk: (bytes: Int64, path: String)?) -> OllamaDiskCheck? {
        guard gateApplies(to: modelId, serverState: serverState, baseURL: baseURL) else { return nil }
        // NO READING IS NOT A REFUSAL. `volumeAvailableCapacityForImportantUsage`
        // is unreported on some volumes (network mounts, and anything that is
        // not APFS or HFS+), and an OLLAMA_MODELS pointing at a volume this
        // process cannot stat reads nil too. Refusing on a number we could not
        // take would block a pull that would have worked, and this guard exists
        // to refuse the pull that is KNOWN doomed, not the one we cannot price.
        guard let disk, let model = Cookbook.catalog.first(where: { $0.id == modelId }) else { return nil }
        let check = OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                            availableBytes: disk.bytes,
                                            measuredPath: disk.path)
        return check.fits ? nil : check
    }

    // Everything the gate can settle WITHOUT a disk reading. Split out so the
    // reading, which is the expensive part, is only paid for in the postures
    // that would use it.
    private func gateApplies(to modelId: String, serverState: ServerState, baseURL: String) -> Bool {
        // THE GATE ONLY FIRES WHEN THE DESTINATION VOLUME IS OURS TO KNOW.
        // `modelsDirectory()` reads THIS process's environment, and that is
        // only the truth about where a pull lands when the serving Ollama
        // shares that environment: the child this manager spawned
        // (.runningManaged), or the child it is about to spawn because nothing
        // is serving yet (.stopped). The `.stopped` label alone does not prove
        // that second reading, which is why `pullRefusal` probes the port and
        // adopts any answering server BEFORE handing this gate a posture to
        // judge. An EXTERNAL server was launched with an
        // environment this process never saw, so its OLLAMA_MODELS can point
        // at any volume, and a base URL that is not loopback is a server on a
        // DIFFERENT MACHINE, whose disks this process cannot stat at all.
        // Refusing on a reading from the wrong volume would permanently block
        // a pull the real destination could absorb, so both cases stand down
        // and say nothing, the same posture as a nil reading: this guard
        // refuses the pull that is KNOWN doomed, and a measurement of the
        // wrong disk knows nothing. The transient states stand down too:
        // `.starting` may be one health probe away from adopting an external
        // server it has not identified yet, and neither window outlasts a few
        // seconds, while a wrong refusal is permanent.
        guard OllamaDiskCheck.isLoopbackHost(baseURL),
              serverState == .runningManaged || serverState == .stopped else { return false }
        // A tag outside the catalog carries no published size, so there is
        // nothing to compare and this says nothing rather than guessing. Every
        // PULL button in the app renders from a `CookbookModel`, so this is the
        // hand-typed-tag case and not a hole in the coverage.
        return Cookbook.catalog.contains { $0.id == modelId }
    }

    // What `pull` refuses on once the adoption question is settled, or nil to
    // go ahead.
    //
    // THE PROBE COMES BEFORE THE GATE, AND THE ORDER IS THE FIX. `.stopped` is
    // not one posture, it is two wearing the same label: nothing is serving
    // and Grux is about to spawn a child with this process's environment, or
    // an external server (the menu bar app started after Grux did) is already
    // answering and no health loop was running to notice, because the loop
    // only runs for a managed child. `runPull` always resolved that honestly,
    // since its first act is the health probe and a healthy answer means the
    // pull is served by whatever answered, wherever its OLLAMA_MODELS points.
    // The gate used to run before any of that, on the label alone, so it
    // measured this process's volume and refused a pull the external server
    // on its roomy drive would have absorbed, naming a disk the download was
    // never going to touch. So the same probe runs first here: a healthy
    // answer while `.stopped` is the external posture `refresh()` already
    // adopts, and `diskShortfall` then stands down on its own. Only when
    // nothing answers is the child Grux would spawn, and therefore this
    // process's environment, the truth about where the pull lands.
    func pullRefusal(for modelId: String) async -> OllamaDiskCheck? {
        if serverState == .stopped, await serverAnswers() {
            // The same adoption `refresh()` performs on a healthy probe,
            // re-checked after the await (serve()'s own discipline): the
            // probe suspends up to 2s, and a concurrent serve() can move the
            // state to .starting or .runningManaged in that window. Stamping
            // .runningExternal over it would tell stop() the child is not
            // ours to reap (orphaning Grux's own process) and stand the disk
            // gate down for a pull landing on this process's own volume.
            if serverState == .stopped { serverState = .runningExternal }
        }
        let base = baseURL
        // THE READING IS TAKEN OFF THE MAIN ACTOR, and only when the gate is
        // going to use it. `availableDisk`'s default walks ancestor
        // directories and asks for purgeable-aware free capacity, a
        // synchronous file-system call whose cost RISES with how full the
        // volume is, so it was blocking the UI thread on exactly the disks
        // this gate exists for. This is the only async caller, which is why
        // the hop lives here rather than in `diskShortfall`, whose sync shape
        // is what every test drives.
        guard gateApplies(to: modelId, serverState: serverState, baseURL: base) else { return nil }
        let read = availableDisk
        let disk = await Task.detached(priority: .userInitiated) { read() }.value
        return diskShortfall(for: modelId, serverState: serverState, baseURL: base, disk: disk)
    }

    // Whether a pull is registered under this tag.
    //
    // Exists so the refusal can be shown to have started NOTHING, which is the
    // whole difference between refusing a pull and failing one after it began.
    func isPulling(_ modelId: String) -> Bool { pullTasks[modelId] != nil }

    // POST {base}/api/pull with stream:true. Ollama answers with one JSON
    // object per line: {"status": "...", "total": n, "completed": n}. The
    // download phase carries total/completed so we can show a real fraction.
    func pull(_ modelId: String) async {
        guard pullTasks[modelId] == nil else { return }
        // Captured BEFORE the probe suspends. `pull()` became async to run
        // the disk gate first, and for the up-to-2s that gate probes, the
        // pull exists nowhere `stop()` can see it: stop() only walks
        // pullTasks. So Stop server during that window killed the child,
        // cleared the (empty) task list, and then this function resumed,
        // registered a task, found the server unhealthy and called serve(),
        // restarting the server the user had just stopped and downloading
        // anyway. The epoch is the evidence a stop happened in the gap.
        let epoch = stopEpoch
        let cancelEpoch = cancelEpochs[modelId] ?? 0
        // ANSWER THE PRESS NOW. `pull` became async to run the disk gate
        // first, and that gate probes for up to ~2s, during which the chip is
        // not disabled and no row exists: the press read as ignored on a
        // control that used to respond synchronously. This row is replaced by
        // whatever the gate decides.
        pulls[modelId] = PullProgress(status: "checking free space", fraction: nil)
        // REFUSE BEFORE STARTING, and before publishing a "starting" state, so
        // the row never shows a progress spinner for a pull that was never going
        // to finish. The failed flag is what puts the PULL button back, so the
        // user can free space and press it again and get a fresh reading.
        let refusal = await pullRefusal(for: modelId)
        // EVERY GUARD COMES FIRST, including the dedupe. Publishing the
        // refusal before them stamped a disk-space message over the
        // "cancelled" row the reader's own CANCEL had just written, and it
        // also let a SECOND press inside the ~2s gate window stamp a failed
        // row over the first press's live download: both presses clear the
        // entry guard (neither has registered a task yet), each takes its own
        // capacity reading, and on a volume near the reserve boundary the
        // later reading refuses while the earlier one is already downloading.
        // The failed row restores the PULL chip over a running pull, and the
        // next press returns silently on the dedupe guard below.
        // ALL THREE RACERS RE-CHECKED ON THIS SIDE OF THE AWAIT, and stated
        // once: a second press of the same tag, a CANCEL, and a Stop server.
        guard pullTasks[modelId] == nil else { return }
        guard cancelEpochs[modelId] ?? 0 == cancelEpoch else {
            // The reader cancelled while the gate probed. cancelPull already
            // wrote the row that puts the PULL button back, so this only has
            // to not start anything.
            return
        }
        guard stopEpoch == epoch else {
            // REFUSED IS NOT DROPPED, the same rule MetaAdsStore.runCommand
            // holds. This returned silently: the press vanished with no
            // status text, no failed row and an unchanged PULL button, which
            // is the invisible-refusal defect one tab over. `failed` is what
            // puts the button back, so the reader can press again.
            pulls[modelId] = PullProgress(
                status: "server stopped before the download started", fraction: nil, failed: true)
            return
        }
        // Published LAST, after every guard, so it cannot land on a row a
        // CANCEL wrote or over a live download a first press registered.
        if let short = refusal {
            pulls[modelId] = PullProgress(status: short.refusal, fraction: nil, failed: true)
            return
        }
        pulls[modelId] = PullProgress(status: "starting", fraction: nil)
        let base = baseURL
        let generation = UUID()
        let task = Task { [weak self] in
            await self?.runPull(modelId: modelId, base: base, generation: generation)
            await MainActor.run { [weak self] in
                // A cancel-then-repull registers a NEW generation under the
                // same key; this (old) task unwinding late must not wipe it,
                // or the dedupe guard above would admit a duplicate pull.
                guard self?.pullGenerations[modelId] == generation else { return }
                self?.pullTasks[modelId] = nil
                self?.pullGenerations[modelId] = nil
            }
        }
        pullTasks[modelId] = task
        pullGenerations[modelId] = generation
    }

    func cancelPull(_ modelId: String) {
        cancelEpochs[modelId, default: 0] &+= 1
        pullTasks[modelId]?.cancel()
        pullTasks[modelId] = nil
        pullGenerations[modelId] = nil
        pulls[modelId] = PullProgress(status: "cancelled", fraction: nil, failed: true)
    }

    private func runPull(modelId: String, base: String, generation: UUID) async {
        // Every progress write goes through this guard, the same generation
        // rule the completion cleanup already holds: a cancelled-then-
        // superseded task unwinding LATE (as a URLError rather than
        // CancellationError, when the wire genuinely dropped) must not
        // overwrite the restarted pull's live row with its stale failure.
        // cancelPull's own write stays direct: it runs under the OLD
        // generation on purpose, as the row the cancel leaves behind.
        func publish(_ progress: PullProgress) {
            guard pullGenerations[modelId] == generation else { return }
            pulls[modelId] = progress
        }
        // Pull needs a live server; one-click means we bring it up ourselves.
        if !(await isHealthy()) {
            await serve()
            guard serverState.isRunning else {
                publish(PullProgress(status: "server unavailable", fraction: nil, failed: true))
                return
            }
        }
        guard let url = URL(string: "\(base)/api/pull") else {
            publish(PullProgress(status: "bad base URL", fraction: nil, failed: true))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600   // big models on slow links take a while
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelId, "stream": true])

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                publish(PullProgress(status: "HTTP \(code)", fraction: nil, failed: true))
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let status = (obj["status"] as? String) ?? "working"
                var fraction: Double? = pulls[modelId]?.fraction
                if let total = obj["total"] as? Double, total > 0,
                   let completed = obj["completed"] as? Double {
                    fraction = min(1.0, completed / total)
                }
                if let err = obj["error"] as? String {
                    publish(PullProgress(status: err, fraction: fraction, failed: true))
                    return
                }
                publish(PullProgress(status: status, fraction: fraction))
                if status == "success" {
                    publish(PullProgress(status: "installed", fraction: 1.0))
                    await refreshInstalled()
                    CookbookStore.shared.notePulled(modelId)
                    return
                }
            }
            // Stream ended without an explicit success line; trust /api/tags.
            await refreshInstalled()
            if isInstalled(modelId) {
                publish(PullProgress(status: "installed", fraction: 1.0))
                CookbookStore.shared.notePulled(modelId)
            } else {
                publish(PullProgress(status: "stream ended early", fraction: nil, failed: true))
            }
        } catch is CancellationError {
            // Nothing to write: both cancellers, cancelPull and stop(), stamp
            // the terminal row themselves before clearing this pull's
            // generation, so a write here would either duplicate theirs or be
            // dropped by the guard above.
        } catch {
            publish(PullProgress(status: error.localizedDescription, fraction: nil, failed: true))
        }
    }
}
