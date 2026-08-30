import Foundation
import SwiftUI

// Long-lived profile memory that survives across ambient sessions. Separate
// from AmbientState.memories (which is a running log of the current work
// session). This is the user's durable context: slang they use, facts about
// their world, preferences Grux should remember.

struct ProfileSlang: Codable, Identifiable, Hashable {
    let id: UUID
    var term: String
    var meaning: String
    var addedAt: Date
    init(id: UUID = UUID(), term: String, meaning: String, addedAt: Date = Date()) {
        self.id = id; self.term = term; self.meaning = meaning; self.addedAt = addedAt
    }
}

struct ProfileFact: Codable, Identifiable, Hashable {
    let id: UUID
    var text: String
    var addedAt: Date
    init(id: UUID = UUID(), text: String, addedAt: Date = Date()) {
        self.id = id; self.text = text; self.addedAt = addedAt
    }
}

extension Persistence {
    static var profileDir: URL {
        let d = supportDir.appendingPathComponent("profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var profileSlangURL: URL { profileDir.appendingPathComponent("slang.json") }
    static var profileFactsURL: URL { profileDir.appendingPathComponent("facts.json") }
}

@MainActor
final class ProfileMemoryStore: ObservableObject {
    static let shared = ProfileMemoryStore()
    @Published var slang: [ProfileSlang] = []
    @Published var facts: [ProfileFact] = []

    private let maxSlang = 500
    private let maxFacts = 500

    private init() { load() }

    func load() {
        slang = Persistence.load([ProfileSlang].self, from: Persistence.profileSlangURL, fallback: [])
        facts = Persistence.load([ProfileFact].self, from: Persistence.profileFactsURL, fallback: [])
    }

    func save() {
        Persistence.save(slang, to: Persistence.profileSlangURL)
        Persistence.save(facts, to: Persistence.profileFactsURL)
    }

    // MARK: - Slang

    @discardableResult
    func addSlang(term: String, meaning: String) -> ProfileSlang {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace existing entry if term already known (case-insensitive)
        if let idx = slang.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            slang[idx].meaning = m
            slang[idx].addedAt = Date()
            save()
            return slang[idx]
        }
        let entry = ProfileSlang(term: t, meaning: m)
        slang.insert(entry, at: 0)
        if slang.count > maxSlang { slang = Array(slang.prefix(maxSlang)) }
        save()
        return entry
    }

    func removeSlang(_ id: UUID) {
        slang.removeAll { $0.id == id }
        save()
    }

    func slangMatch(_ text: String) -> ProfileSlang? {
        let lower = text.lowercased()
        return slang.first { lower.contains($0.term.lowercased()) }
    }

    // MARK: - Facts

    @discardableResult
    func addFact(_ text: String) -> ProfileFact {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deduplicate exact matches
        if let existing = facts.first(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) {
            return existing
        }
        let entry = ProfileFact(text: t)
        facts.insert(entry, at: 0)
        if facts.count > maxFacts { facts = Array(facts.prefix(maxFacts)) }
        save()
        return entry
    }

    func removeFact(_ id: UUID) {
        facts.removeAll { $0.id == id }
        save()
    }

    // MARK: - System prompt context

    // Rendered into the Claude system prompt so every conversation sees the
    // user's slang and durable facts. Kept compact to preserve context budget.
    func asSystemContext() -> String {
        var lines: [String] = []
        if !slang.isEmpty {
            lines.append("USER_SLANG_GLOSSARY (treat these as the canonical meanings):")
            for s in slang.prefix(60) {
                lines.append("  - \"\(s.term)\" = \(s.meaning)")
            }
        }
        if !facts.isEmpty {
            lines.append("")
            lines.append("LONG_TERM_FACTS_ABOUT_USER (persistent truths):")
            for f in facts.prefix(60) {
                lines.append("  - \(f.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
