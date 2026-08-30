import Foundation

// On-disk persistence for agent jobs. One directory per job:
//
//   <root>/<jobId>/
//     job.json                - canonical AgentJob
//     log.ndjson              - top-level append-only step log
//     workers/<workerId>/log.ndjson  - per-worker append-only stream-json
//
// The store is an actor so concurrent worker writes serialize per file.

public actor AgentStore {

    public let rootDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Injected write gate. GruxAgentCore is platform-free and cannot see the
    // app's Persistence.writesSuspended restore kill switch, so the app
    // passes `{ !Persistence.writesSuspended }`: a running agent job must not
    // keep writing pre-restore state into a just-restored agents tree.
    private let writeGate: @Sendable () -> Bool

    public init(rootDir: URL, writeGate: @escaping @Sendable () -> Bool = { true }) {
        self.rootDir = rootDir
        self.writeGate = writeGate
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func jobDir(_ id: String) -> URL {
        rootDir.appendingPathComponent(id, isDirectory: true)
    }
    public func jobURL(_ id: String) -> URL {
        jobDir(id).appendingPathComponent("job.json")
    }
    public func logURL(_ id: String) -> URL {
        jobDir(id).appendingPathComponent("log.ndjson")
    }
    public func workerLogURL(jobId: String, workerId: String) -> URL {
        jobDir(jobId)
            .appendingPathComponent("workers", isDirectory: true)
            .appendingPathComponent(workerId, isDirectory: true)
            .appendingPathComponent("log.ndjson")
    }

    // MARK: - Job CRUD

    public func saveJob(_ job: AgentJob) throws {
        guard writeGate() else { return }
        let dir = jobDir(job.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(job)
        try data.write(to: jobURL(job.id), options: .atomic)
    }

    public func loadJob(_ id: String) -> AgentJob? {
        guard let data = try? Data(contentsOf: jobURL(id)) else { return nil }
        return try? decoder.decode(AgentJob.self, from: data)
    }

    public func listJobs() -> [AgentJob] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)
        else { return [] }
        var jobs: [AgentJob] = []
        for url in entries where url.hasDirectoryPath {
            if let job = loadJob(url.lastPathComponent) {
                jobs.append(job)
            }
        }
        return jobs.sorted { $0.createdAt > $1.createdAt }
    }

    public func deleteJob(_ id: String) {
        try? FileManager.default.removeItem(at: jobDir(id))
    }

    // MARK: - Step append

    public func appendStep(jobId: String, step: AgentStep) {
        guard writeGate() else { return }
        let dir = jobDir(jobId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        appendNDJSON(step: step, to: logURL(jobId))
        if let wid = step.workerId {
            let wDir = dir.appendingPathComponent("workers", isDirectory: true)
                .appendingPathComponent(wid, isDirectory: true)
            try? FileManager.default.createDirectory(at: wDir, withIntermediateDirectories: true)
            appendNDJSON(step: step, to: workerLogURL(jobId: jobId, workerId: wid))
        }
    }

    public func loadSteps(jobId: String, limit: Int? = nil) -> [AgentStep] {
        readNDJSON(at: logURL(jobId), limit: limit)
    }

    public func loadWorkerSteps(jobId: String, workerId: String, limit: Int? = nil) -> [AgentStep] {
        readNDJSON(at: workerLogURL(jobId: jobId, workerId: workerId), limit: limit)
    }

    // MARK: - Internals

    private func appendNDJSON(step: AgentStep, to url: URL) {
        // Force compact JSON for the line, then append.
        let compactEnc = JSONEncoder()
        compactEnc.dateEncodingStrategy = .iso8601
        guard let compact = try? compactEnc.encode(step) else { return }
        var line = compact
        line.append(0x0A) // newline
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: line)
                return
            }
        }
        try? line.write(to: url, options: .atomic)
    }

    private func readNDJSON(at url: URL, limit: Int?) -> [AgentStep] {
        guard let raw = try? String(contentsOf: url) else { return [] }
        var steps: [AgentStep] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let step = try? decoder.decode(AgentStep.self, from: data)
            else { continue }
            steps.append(step)
        }
        if let n = limit, steps.count > n {
            return Array(steps.suffix(n))
        }
        return steps
    }
}
