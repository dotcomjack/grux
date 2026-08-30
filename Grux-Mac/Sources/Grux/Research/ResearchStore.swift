import Foundation

// JSON-on-disk store for deep research jobs. Mirrors NotesStore's shape:
// @MainActor singleton, @Published items, atomic JSON writes via the
// Persistence helpers, debounced scheduleSave so the engine's frequent
// progress updates collapse into one disk write.
@MainActor
final class ResearchStore: ObservableObject {
    static let shared = ResearchStore()

    @Published private(set) var jobs: [ResearchJob] = []

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    // Directory for the store JSON plus exported per-job report markdown.
    // nonisolated so the default init argument (evaluated outside the actor)
    // and background callers can compute paths without a hop.
    nonisolated static var researchDir: URL {
        let dir = Persistence.supportDir.appendingPathComponent("research", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static var jobsURL: URL { researchDir.appendingPathComponent("jobs.json") }

    nonisolated static func reportURL(for id: UUID) -> URL {
        researchDir.appendingPathComponent("report-\(id.uuidString).md")
    }

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = ResearchStore.jobsURL) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        jobs = Persistence.load([ResearchJob].self, from: storageURL, fallback: [])
    }

    // MARK: - CRUD

    @discardableResult
    func create(question: String) -> ResearchJob {
        let job = ResearchJob(question: question)
        jobs.insert(job, at: 0)
        scheduleSave()
        return job
    }

    func job(id: UUID) -> ResearchJob? {
        jobs.first { $0.id == id }
    }

    // Single mutation seam: the engine updates phase / progress / report
    // through here so every change publishes plus persists consistently.
    func update(id: UUID, _ mutate: (inout ResearchJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[idx])
        scheduleSave()
    }

    func appendProgress(id: UUID, _ line: String) {
        update(id: id) { $0.progressLines.append(line) }
    }

    func delete(id: UUID) {
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.reportURL(for: id))
        scheduleSave()
    }

    // Newest first.
    var ordered: [ResearchJob] {
        jobs.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Report markdown on disk

    // Persist the finished report as a standalone .md alongside the store so
    // the chat tool can hand back a real file path.
    @discardableResult
    func writeReportFile(for id: UUID) -> URL? {
        guard let job = job(id: id), !job.reportMarkdown.isEmpty else { return nil }
        let url = Self.reportURL(for: id)
        // Guarded write: reports live in the backed-up-and-restored tree.
        guard let data = job.reportMarkdown.data(using: .utf8),
              Persistence.write(data, to: url) else { return nil }
        return url
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = jobs
        let url = storageURL
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot, to: url)
        }
    }

    // Force a synchronous write (tests, app termination paths).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(jobs, to: storageURL)
    }
}
