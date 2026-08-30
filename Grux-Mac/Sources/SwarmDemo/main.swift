import Foundation
import GruxAgentCore

// SwarmDemo - end-to-end verification harness for the agent framework.
//
// Spawns a tiny single-worker swarm against a temp directory, waits for it
// to complete, and prints a pass/fail summary. Designed to run in <60s and
// cost <$0.05.
//
// Usage:
//   swift run SwarmDemo                      # smoke test (single worker)
//   swift run SwarmDemo --template parallel  # 3 parallel workers
//   swift run SwarmDemo --dry-run            # don't actually spawn claude

@main
struct SwarmDemoMain {

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        var template: SwarmTemplate = .singleWorker
        var dryRun = false
        var goal = "Write a tiny hello.txt file in the current directory containing exactly the words 'hello from swarm' (no quotes), then list the directory contents to verify."
        var rootDirOverride: String? = nil
        var budgetUSD: Double = 0.10
        var goalFile: String? = nil
        var forceModel: String? = nil
        var maxParallel: Int = 3
        var storeDirOverride: String? = nil   // override for AgentStore location
        var scratchStore: Bool = false        // if true, use rootDir/.grux-agents (scratch); else use central
        var jobTitle: String? = nil
        var ttlSecondsOverride: Int? = nil    // override worker TTL (default 1800s)

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--template":
                i += 1
                if i < args.count, let t = SwarmTemplate(rawValue: args[i]) { template = t }
            case "--dry-run":
                dryRun = true
            case "--goal":
                i += 1
                if i < args.count { goal = args[i] }
            case "--goal-file":
                i += 1
                if i < args.count { goalFile = args[i] }
            case "--root":
                i += 1
                if i < args.count { rootDirOverride = args[i] }
            case "--budget":
                i += 1
                if i < args.count, let b = Double(args[i]) { budgetUSD = b }
            case "--model":
                i += 1
                if i < args.count { forceModel = args[i] }
            case "--max-parallel":
                i += 1
                if i < args.count, let n = Int(args[i]) { maxParallel = n }
            case "--store-dir":
                i += 1
                if i < args.count { storeDirOverride = args[i] }
            case "--scratch-store":
                scratchStore = true
            case "--title":
                i += 1
                if i < args.count { jobTitle = args[i] }
            case "--ttl-seconds":
                i += 1
                if i < args.count, let n = Int(args[i]) { ttlSecondsOverride = n }
            default: break
            }
            i += 1
        }

        // If a goal file was passed, prefer it over --goal.
        if let path = goalFile {
            if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                goal = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                FileHandle.standardError.write(Data("[swarm-demo] WARN: could not read goal file \(path)\n".utf8))
            }
        }

        // Set up workspace.
        let rootDir = rootDirOverride ?? NSTemporaryDirectory() + "swarm-demo-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: rootDir, withIntermediateDirectories: true)
        print("[swarm-demo] root: \(rootDir)")

        // Default: use the central Grux agentsDir so jobs are visible in the
        // Grux app's Agents tab. Override with --store-dir <path> or
        // --scratch-store (which uses <rootDir>/.grux-agents/ for ephemeral runs).
        let storeDir: URL = {
            if let override = storeDirOverride {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            if scratchStore {
                return URL(fileURLWithPath: rootDir).appendingPathComponent(".grux-agents", isDirectory: true)
            }
            // Mirror Persistence.agentsDir from the main Grux app.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return support
                .appendingPathComponent("Grux", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
        }()
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        // Pass --ttl-seconds through to the orchestrator's per-worker TTL via
        // env var (orchestrator reads GRUX_WORKER_TTL_SECONDS).
        if let ttl = ttlSecondsOverride { setenv("GRUX_WORKER_TTL_SECONDS", "\(ttl)", 1) }
        let store = AgentStore(rootDir: storeDir)

        var workers = SwarmPlanFactory.expand(template: template, goal: goal, rootDir: rootDir)
        // If --model was passed, force every worker to that model.
        if let m = forceModel {
            for idx in workers.indices { workers[idx].model = m }
        }
        let job = AgentJob(
            title: jobTitle ?? "swarm-demo: \(template.rawValue)",
            goal: goal,
            budgetUSD: budgetUSD,
            maxParallelWorkers: maxParallel,
            workers: workers,
            rootDir: rootDir
        )
        try? await store.saveJob(job)

        print("[swarm-demo] template=\(template.rawValue) workers=\(workers.count) budget=$\(budgetUSD)")
        for w in workers {
            print("  - \(w.label) [\(w.role.rawValue)] cwd=\(w.cwd)\(w.dependsOn.isEmpty ? "" : " deps=\(w.dependsOn.map { String($0.prefix(8)) })")")
        }

        if dryRun {
            print("[swarm-demo] dry-run - exiting without spawning workers")
            print("[swarm-demo] would spawn: \(SwarmWorker.resolveClaudeBinary())")
            return
        }

        // Verify claude binary is reachable.
        let claudeBin = SwarmWorker.resolveClaudeBinary()
        if !FileManager.default.isExecutableFile(atPath: claudeBin) && claudeBin != "claude" {
            print("[swarm-demo] WARN: claude binary not found at expected path \(claudeBin) - will rely on PATH")
        } else {
            print("[swarm-demo] claude bin: \(claudeBin)")
        }

        let observer = ConsoleObserver()
        let orch = SwarmOrchestrator(job: job, store: store, observer: observer)
        let startedAt = Date()
        await orch.run()
        let dur = Date().timeIntervalSince(startedAt)

        let finalJob = await store.loadJob(job.id) ?? job
        print("\n[swarm-demo] === SUMMARY ===")
        print("status: \(finalJob.status.rawValue)")
        print("duration: \(String(format: "%.1f", dur))s")
        print("spent: $\(String(format: "%.4f", finalJob.spentUSD))")
        for w in finalJob.workers {
            print("  worker \(w.label) [\(w.role.rawValue)] → \(w.status.rawValue)\(w.errorMessage.map { " (\($0))" } ?? "") spent=$\(String(format: "%.4f", w.spentUSD))")
        }
        print("logs: \(storeDir.path)/\(finalJob.id)/")

        if finalJob.status == .done {
            // Verify the worker actually did the thing.
            let helloPath = (rootDir as NSString).appendingPathComponent("hello.txt")
            if FileManager.default.fileExists(atPath: helloPath) {
                let contents = (try? String(contentsOfFile: helloPath)) ?? ""
                print("\n[swarm-demo] ✅ verification: hello.txt exists, contents = \(String(reflecting: contents))")
            } else {
                print("\n[swarm-demo] ⚠️ verification: hello.txt was NOT written (status was 'done' but goal artifact missing)")
            }
            print("\n[swarm-demo] PASS")
        } else {
            print("\n[swarm-demo] FAIL - \(finalJob.errorMessage ?? "unknown")")
            exit(1)
        }
    }
}

// Console observer that streams orchestrator events to stdout.
final class ConsoleObserver: SwarmOrchestratorObserver, @unchecked Sendable {
    func orchestratorJobDidUpdate(_ job: AgentJob) async {
        // Quiet - only print on terminal transitions.
        if job.isTerminal {
            print("[swarm-demo] job → \(job.status.rawValue)")
        }
    }
    func orchestrator(_ jobId: String, didAppend step: AgentStep) async {
        let prefix: String
        switch step.kind {
        case .workerStart:        prefix = "▶"
        case .workerEnd:          prefix = "■"
        case .assistantText:      prefix = "💬"
        case .toolUse:            prefix = "🔧"
        case .toolResult:         prefix = "✓"
        case .usage:              prefix = "$"
        case .error:              prefix = "❌"
        case .orchestrator:       prefix = "🎼"
        case .approvalRequested:  prefix = "⏸"
        case .approvalGranted:    prefix = "▶▶"
        case .info:               prefix = "·"
        case .authLimitDetected:  prefix = "🔒"
        case .accountSwitched:    prefix = "🔄"
        case .workerResumed:      prefix = "▶▶"
        }
        let wid = step.workerId.map { String($0.prefix(8)) } ?? "----"
        let line = "[\(wid)] \(prefix) \(step.text)"
        print(line)
    }
}
