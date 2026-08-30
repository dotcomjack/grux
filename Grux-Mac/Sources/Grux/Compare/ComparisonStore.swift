import Foundation

// JSON-on-disk history of model comparisons. Same pattern as FolderStore /
// InboxStore: @MainActor singleton, @Published records, debounced scheduleSave
// (0.3s coalesce) so vote / reveal / synthesis updates don't thrash the disk.
// Default file: ~/Library/Application Support/Grux/comparisons.json. Tests
// inject a temp fileURL so they never touch real history.
@MainActor
final class ComparisonStore: ObservableObject {
    static let shared = ComparisonStore()

    @Published private(set) var records: [ComparisonRecord] = []

    // Keep history bounded, comparisons carry full output text and would
    // otherwise grow without limit. Oldest records fall off past the cap.
    static let maxRecords = 200

    private let fileURL: URL
    private var saveToken: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Persistence.supportDir.appendingPathComponent("comparisons.json")
        self.records = Persistence.load([ComparisonRecord].self, from: self.fileURL, fallback: [])
    }

    // MARK: - Read

    // Newest first, the order the history list wants.
    var ordered: [ComparisonRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    func record(id: UUID?) -> ComparisonRecord? {
        guard let id else { return nil }
        return records.first(where: { $0.id == id })
    }

    // Vote tally per backend name across all voted records. Drives the
    // "win rate" summary in CompareView.
    func winCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for rec in records {
            guard let winner = rec.votedOutput else { continue }
            counts[winner.backendName, default: 0] += 1
        }
        return counts
    }

    var votedCount: Int {
        records.filter { $0.votedOutputId != nil }.count
    }

    // MARK: - Write

    func add(_ record: ComparisonRecord) {
        records.append(record)
        if records.count > Self.maxRecords {
            let overflow = records.count - Self.maxRecords
            let sorted = ordered
            let keep = Set(sorted.prefix(Self.maxRecords).map { $0.id })
            records.removeAll { !keep.contains($0.id) }
            _ = overflow
        }
        scheduleSave()
    }

    // Record which output won. Returns false when the record or output id is
    // unknown so callers can surface a miss instead of silently no-opping.
    @discardableResult
    func recordVote(recordId: UUID, outputId: UUID) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == recordId }),
              records[idx].outputs.contains(where: { $0.id == outputId }) else {
            return false
        }
        records[idx].votedOutputId = outputId
        scheduleSave()
        return true
    }

    func setRevealed(recordId: UUID, revealed: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].revealed = revealed
        scheduleSave()
    }

    func setSynthesis(recordId: UUID, text: String, by backendName: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].synthesis = text
        records[idx].synthesizedBy = backendName
        scheduleSave()
    }

    func delete(recordId: UUID) {
        records.removeAll { $0.id == recordId }
        scheduleSave()
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
        Persistence.save(records, to: fileURL)
    }
}
