import Foundation

// Local audit timeline for the Self-Upgrade tab. Mirrors the NotesStore /
// InboxStore shape: @MainActor singleton, @Published entries, atomic JSON
// writes through Persistence with a debounced scheduleSave. Every stage of
// the Foundry loop appends here, per the hard rail: "audit entry per
// self-change, recorded in the Self-Upgrade tab timeline."

enum FoundryTimelineKind: String, Codable, CaseIterable {
    case cycle        // sense/synthesize pass ran
    case proposed     // new proposal filed
    case accepted     // the user accepted a proposal
    case rejected     // the user rejected a proposal
    case built        // upgrade/ branch built + verified
    case landed       // change installed
    case rollback     // auto-rollback fired
    case promotion    // trust tier promoted
    case demotion     // trust tier demoted
}

struct FoundryTimelineEntry: Identifiable, Codable, Equatable {
    var id: String
    var date: Date
    var kind: FoundryTimelineKind
    var title: String
    var detail: String
    var lane: String
    var domain: String

    init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        kind: FoundryTimelineKind,
        title: String,
        detail: String = "",
        lane: String = "",
        domain: String = ""
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.lane = lane
        self.domain = domain
    }
}

@MainActor
final class FoundryTimelineStore: ObservableObject {
    static let shared = FoundryTimelineStore()

    // Cap so a chatty engine can't grow the file unbounded; oldest fall off.
    static let maxEntries = 1000

    @Published private(set) var entries: [FoundryTimelineEntry] = []

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = Persistence.supportDir.appendingPathComponent("foundry-timeline.json")) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        entries = Persistence.load([FoundryTimelineEntry].self, from: storageURL, fallback: [])
    }

    // MARK: - Mutation

    func append(_ entry: FoundryTimelineEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - Read

    // Reverse-chron for the timeline pane: newest first.
    var ordered: [FoundryTimelineEntry] {
        entries.sorted { $0.date > $1.date }
    }

    // MARK: - Persistence

    // Debounced write: bursts of audit entries (a whole cycle landing at
    // once) collapse into one disk write roughly 0.4s after the last append.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
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
        Persistence.save(entries, to: storageURL)
    }
}
