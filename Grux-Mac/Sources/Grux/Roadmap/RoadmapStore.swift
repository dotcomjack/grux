import Foundation

// Grux self-build roadmap. Persisted to ~/Library/Application Support/Grux/roadmap.json,
// a file that does not exist until the user adds their first item.
//
// The compiled-in default is EMPTY, and that is load-bearing rather than a
// simplification. This file used to carry 14 rows of one person's private
// product plan and WRITE them to disk on first launch, so a brand-new install
// opened on somebody else's build plan, presented as the new owner's own, in
// tiers that promised delivery dates nobody had agreed to. It also meant the
// app created a personal-data file before onboarding had asked for anything.
//
// So: nothing is ever seeded here again. An absent file means an empty board
// and a needs-setup view (RoadmapView), never a fabricated plan, and reading
// must never write. Anything that repopulates this from a compiled-in list
// re-ships the same bug under a different symbol name.

enum RoadmapTier: String, Codable, CaseIterable, Identifiable {
    case S, A, B, C
    var id: String { rawValue }

    var shortLabel: String { "Tier \(rawValue)" }

    var horizonLabel: String {
        switch self {
        case .S: return "Ship this month"
        case .A: return "Next 30-60 days"
        case .B: return "Next 60-120 days"
        case .C: return "When you feel like it"
        }
    }
}

enum RoadmapStatus: String, Codable, CaseIterable {
    case notStarted, inProgress, done

    func next() -> RoadmapStatus {
        switch self {
        case .notStarted: return .inProgress
        case .inProgress: return .done
        case .done:       return .notStarted
        }
    }

    var systemImage: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done:       return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .done:       return "Done"
        }
    }
}

struct RoadmapItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var tier: RoadmapTier
    var order: Int
    var title: String
    var subtitle: String
    var notes: String
    var status: RoadmapStatus
    var addedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        tier: RoadmapTier,
        order: Int,
        title: String,
        subtitle: String = "",
        notes: String = "",
        status: RoadmapStatus = .notStarted,
        addedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.tier = tier
        self.order = order
        self.title = title
        self.subtitle = subtitle
        self.notes = notes
        self.status = status
        self.addedAt = addedAt
        self.completedAt = completedAt
    }
}

@MainActor
final class RoadmapStore: ObservableObject {
    static let shared = RoadmapStore()

    @Published private(set) var items: [RoadmapItem] = []
    private var loaded = false

    private let jsonURL: URL

    // storageURL is injectable so tests can exercise the absent-file branch
    // without reading, and above all without writing, the real file in
    // Application Support. The absent-file branch is the one that shipped the
    // bug, so it is the one that has to be provable.
    init(storageURL: URL = Persistence.supportDir.appendingPathComponent("roadmap.json")) {
        jsonURL = storageURL
    }

    // Reading is READ-ONLY. No file, or a file we cannot decode, leaves the
    // board empty and touches nothing on disk. The old else-branch here wrote
    // a compiled-in seed, which is how a first launch produced a roadmap.json
    // full of content the user never typed. A file we failed to decode is left
    // exactly as found: overwriting it would destroy whatever the user has,
    // and a decode failure is far more likely to be a bug in us than garbage
    // in their data.
    func load() {
        guard !loaded else { return }
        loaded = true

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: jsonURL),
              let arr = try? dec.decode([RoadmapItem].self, from: data) else { return }
        items = arr
    }

    func items(in tier: RoadmapTier) -> [RoadmapItem] {
        items.filter { $0.tier == tier }.sorted { $0.order < $1.order }
    }

    func progress(in tier: RoadmapTier? = nil) -> (done: Int, inProgress: Int, total: Int) {
        let pool = tier.map { t in items.filter { $0.tier == t } } ?? items
        let done = pool.filter { $0.status == .done }.count
        let inProg = pool.filter { $0.status == .inProgress }.count
        return (done, inProg, pool.count)
    }

    @discardableResult
    func cycleStatus(id: UUID) -> RoadmapStatus? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[idx].status = items[idx].status.next()
        items[idx].completedAt = items[idx].status == .done ? Date() : nil
        save()
        return items[idx].status
    }

    func setStatus(id: UUID, _ status: RoadmapStatus) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
        items[idx].completedAt = status == .done ? Date() : nil
        save()
    }

    func updateNotes(id: UUID, notes: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].notes = notes
        save()
    }

    func updateTitle(id: UUID, title: String, subtitle: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].title = title
        items[idx].subtitle = subtitle
        save()
    }

    func add(tier: RoadmapTier, title: String, subtitle: String = "") {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let nextOrder = (items.filter { $0.tier == tier }.map(\.order).max() ?? 0) + 1
        items.append(RoadmapItem(tier: tier, order: nextOrder, title: t, subtitle: subtitle))
        save()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func move(id: UUID, to tier: RoadmapTier) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].tier != tier else { return }
        items[idx].tier = tier
        let nextOrder = (items.filter { $0.tier == tier && $0.id != id }.map(\.order).max() ?? 0) + 1
        items[idx].order = nextOrder
        save()
    }

    // Reorder within a tier. `indices` is IndexSet from List.onMove, `offset`
    // is the drop index. Uses the currently-sorted items(in:) view as source
    // of truth, then rewrites `order` to match.
    func reorder(within tier: RoadmapTier, indices: IndexSet, to offset: Int) {
        var tierItems = items(in: tier)
        tierItems.move(fromOffsets: indices, toOffset: offset)
        for (newOrder, item) in tierItems.enumerated() {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].order = newOrder + 1
            }
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }
}
