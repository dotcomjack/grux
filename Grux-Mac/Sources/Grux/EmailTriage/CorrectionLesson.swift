import Foundation
import Combine

// CorrectionLesson: one durable thing Jax learned from a correction the user made
// to a support draft. When they edit a draft before sending, the delta between what
// Jax wrote and what they actually sent is distilled into a single imperative,
// brand-voice-safe rule ("lesson") so the next draft for that brand starts closer
// to how they would write it. The before/after snippets and source subject are
// kept as provenance so a lesson is auditable and reversible instead of an opaque
// nudge. Persisted to ~/.grux/jax so lessons survive relaunch and are greppable
// from the CLI.
struct CorrectionLesson: Codable, Identifiable, Equatable {
    var id: String              // stable unique id
    var learnedAt: Date
    var brand: String           // brand voice slug, as configured by the user
    var category: String?       // SupportCategory.rawValue, or nil
    var lesson: String          // the durable imperative rule, brand-voice-safe
    var subject: String         // source email subject (provenance)
    var beforeSnippet: String   // short snippet of the original draft
    var afterSnippet: String    // short snippet of what the user sent
    // The exact JaxProfile heuristic this lesson created, so forgetting a lesson
    // removes precisely that heuristic (not another that happens to share the
    // same rule text). Optional so older persisted lessons decode cleanly.
    var heuristicID: UUID? = nil
}

// JSON-backed store at ~/.grux/jax/correction-lessons.json. @MainActor
// ObservableObject so any Jax surface reacts as lessons are learned and cleared.
// Newest first, capped so the file stays small and the drafter prompt stays tight.
@MainActor
final class CorrectionLessonStore: ObservableObject {
    static let shared = CorrectionLessonStore()

    @Published private(set) var lessons: [CorrectionLesson] = []

    private let maxLessons = 60

    static var rootDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("jax")
    }
    private static var fileURL: URL { rootDir.appendingPathComponent("correction-lessons.json") }

    private init() { load() }

    func load() {
        lessons = Persistence.load([CorrectionLesson].self, from: Self.fileURL, fallback: [])
            .sorted { $0.learnedAt > $1.learnedAt }
    }

    // Upsert by id (re-learning the same lesson refreshes it in place, newest
    // first), then cap so the oldest lessons fall off.
    func add(_ lesson: CorrectionLesson) {
        lessons.removeAll { $0.id == lesson.id }
        lessons.insert(lesson, at: 0)
        if lessons.count > maxLessons { lessons = Array(lessons.prefix(maxLessons)) }
        persist()
    }

    func remove(_ id: String) {
        lessons.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        lessons.removeAll()
        persist()
    }

    // Lessons for one brand, exact match on the lowercased brand id, newest first
    // (the backing array is already newest first, so filtering preserves order).
    func lessons(forBrand brand: String) -> [CorrectionLesson] {
        let b = brand.lowercased()
        return lessons.filter { $0.brand.lowercased() == b }
    }

    // The most recent `limit` lessons for the brand, rendered as a block to splice
    // into the drafter prompt, or nil when the brand has no lessons. Exact format:
    //   "LESSONS FROM THE USER'S EDITS (apply these to this reply):\n  - <lesson>\n  - <lesson>"
    func promptBlock(forBrand brand: String, limit: Int) -> String? {
        let picked = Array(lessons(forBrand: brand).prefix(max(0, limit)))
        guard !picked.isEmpty else { return nil }
        let bullets = picked.map { "  - " + $0.lesson }.joined(separator: "\n")
        return "LESSONS FROM THE USER'S EDITS (apply these to this reply):\n" + bullets
    }

    private func persist() {
        // Ensure ~/.grux/jax exists before writing: on a fresh machine no sibling
        // store may have created it yet, and Persistence.save swallows the write
        // error, which would silently drop every learned lesson.
        try? FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        Persistence.save(lessons, to: Self.fileURL)
    }
}
