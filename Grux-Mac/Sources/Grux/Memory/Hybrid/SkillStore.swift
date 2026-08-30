import Foundation

// Learned skills: durable "how Grux does X" procedures captured from chat.
// A skill is a named trigger + a markdown procedure. Claude saves one with
// the save_skill tool the moment the user walks it through a workflow ("here's
// how I want release notes written"), and every future conversation sees
// the compact skills block via asSystemContext().
//
// Separate from ProfileMemoryStore on purpose: facts are single sentences
// about the user's WORLD, skills are multi-step procedures about Grux's WORK.
//
// Storage: ~/Library/Application Support/Grux/skills.json

public struct Skill: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String        // short handle, e.g. "release-notes"
    public var trigger: String     // one or two sentences: when to apply it
    public var procedure: String   // markdown steps, the actual playbook
    public var usageCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, trigger: String, procedure: String, usageCount: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.procedure = procedure
        self.usageCount = usageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Persistence {
    static var skillsURL: URL { supportDir.appendingPathComponent("skills.json") }
}

@MainActor
public final class SkillStore: ObservableObject {
    public static let shared = SkillStore()

    @Published public private(set) var skills: [Skill] = []

    private let maxSkills = 200
    private let fileURL: URL
    // True only for the real shared store. The SKILL.md folder mirror is written
    // only by the default store so a test seam pointed at a temp file never
    // touches the real Application Support/Grux/skills/ folder tree.
    private let isDefaultStore: Bool
    private let writeQueue = DispatchQueue(label: "com.gruxai.grux.skill-store-write", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        self.fileURL = Persistence.skillsURL
        self.isDefaultStore = true
        load()
    }

    // Test seam: point the store at a scratch file so unit tests never
    // touch the real ~/Library/Application Support/Grux/skills.json.
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.isDefaultStore = (fileURL == Persistence.skillsURL)
        load()
    }

    // MARK: - Mutations

    // Upsert by name (case-insensitive). Re-teaching a skill replaces its
    // trigger + procedure but preserves identity and usage count.
    //
    // A re-teach whose trimmed trigger and procedure already match the stored
    // copy returns that skill untouched. Measured: `grux add skill` on a
    // byte-identical SKILL.md printed "already there, unchanged" while this
    // path still stamped updatedAt = Date(). asSystemContext ranks on
    // updatedAt once usageCount ties, and usageCount only moves via
    // recordUsage, so with 13 or more never-used skills that silent bump
    // pushed whichever skill sat twelfth out of the LEARNED_SKILLS block: the
    // next chat turn lost a procedure the command had just said it did not
    // touch. Nothing changed, so there is nothing to save either, and the
    // identical save_skill path from chat takes the same early return.
    @discardableResult
    public func upsert(name: String, trigger: String, procedure: String) -> Skill {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = procedure.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = skills.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            guard skills[idx].trigger != t || skills[idx].procedure != p else { return skills[idx] }
            skills[idx].trigger = t
            skills[idx].procedure = p
            skills[idx].updatedAt = Date()
            scheduleSave()
            return skills[idx]
        }
        let skill = Skill(name: n, trigger: t, procedure: p)
        skills.insert(skill, at: 0)
        if skills.count > maxSkills { skills = Array(skills.prefix(maxSkills)) }
        scheduleSave()
        return skill
    }

    public func remove(_ id: UUID) {
        let removed = skills.first { $0.id == id }
        skills.removeAll { $0.id == id }
        scheduleSave()
        // Propagate the deletion to the SKILL.md mirror so importFromFolders
        // cannot resurrect it. Only the default store mirrors (the test seam
        // never touches the real Application Support/Grux/skills tree).
        if isDefaultStore, let name = removed?.name {
            SkillFolderBackend.removeFolder(for: name)
        }
    }

    // Bump the counter when a skill actually gets applied. Drives the
    // ordering in asSystemContext so the most-used skills survive the cap.
    public func recordUsage(name: String) {
        guard let idx = skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        skills[idx].usageCount += 1
        skills[idx].updatedAt = Date()
        scheduleSave()
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - System prompt context

    // Compact skills block for the stable system prompt, alongside
    // ProfileMemoryStore.asSystemContext(). Most-used first so the cap
    // keeps the highest-value procedures in context. Procedures are
    // truncated; list_skills returns them in full on demand.
    public func asSystemContext() -> String {
        guard !skills.isEmpty else { return "" }
        let ranked = skills.sorted {
            if $0.usageCount != $1.usageCount { return $0.usageCount > $1.usageCount }
            return $0.updatedAt > $1.updatedAt
        }
        var lines: [String] = []
        lines.append("LEARNED_SKILLS (procedures the user taught Grux | apply when the trigger matches, call list_skills for the full text, call save_skill whenever they teach a new one):")
        for (i, s) in ranked.prefix(12).enumerated() {
            let proc = s.procedure.count > 400 ? String(s.procedure.prefix(400)) + "…" : s.procedure
            let indented = proc
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "     \($0)" }
                .joined(separator: "\n")
            lines.append("  \(i + 1). \(s.name) | when: \(s.trigger)")
            lines.append(indented)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Claude tools

    nonisolated static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "save_skill",
                description: "Save (or update) a learned skill: a reusable multi-step procedure the user taught you. Use the moment they walk you through HOW they want something done ('here's how I want X handled', 'next time do it like this', 'remember this workflow'). Different from remember_fact (single-sentence truths) | a skill is a playbook. Saving an existing name replaces its trigger and procedure.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Short kebab-case handle, e.g. 'release-notes'. Reuse an existing name to update that skill."],
                        "trigger": ["type": "string", "description": "One or two sentences: when this skill applies."],
                        "procedure": ["type": "string", "description": "The full procedure as markdown steps. Be concrete; future conversations rely on this verbatim."]
                    ],
                    "required": ["name", "trigger", "procedure"]
                ]
            ),
            ClaudeTool(
                name: "list_skills",
                description: "List every learned skill with its full procedure text. Use when the user asks 'what skills do you know', 'how do you do X', or when the LEARNED_SKILLS block shows a truncated procedure you need in full before applying it.",
                inputSchema: ["type": "object", "properties": [:]]
            )
        ]
    }

    // Tool dispatch for the skills tools. Returns nil for unrelated names
    // so ChatService can fall through to its own default case.
    public func executeTool(name: String, input: [String: Any]) -> String? {
        switch name {
        case "save_skill":
            let n = (input["name"] as? String) ?? ""
            let t = (input["trigger"] as? String) ?? ""
            let p = (input["procedure"] as? String) ?? ""
            guard !n.isEmpty, !t.isEmpty, !p.isEmpty else { return "error: save_skill needs name, trigger, and procedure" }
            let s = upsert(name: n, trigger: t, procedure: p)
            return "ok: saved skill '\(s.name)'"

        case "list_skills":
            guard !skills.isEmpty else { return "(no learned skills yet)" }
            return skills.prefix(30).map { s in
                "## \(s.name) (used \(s.usageCount)x)\nWhen: \(s.trigger)\n\(s.procedure)"
            }.joined(separator: "\n\n")

        default:
            return nil
        }
    }

    // MARK: - Persistence

    private func load() {
        skills = Persistence.load([Skill].self, from: fileURL, fallback: [])
        skills.sort { $0.updatedAt > $1.updatedAt }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        pendingSave = work
        writeQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func saveNow() {
        Persistence.save(skills, to: fileURL)
        // Best-effort, non-fatal mirror to the SKILL.md folder tree. Only the
        // real shared store mirrors; the temp-file test seam skips it.
        if isDefaultStore {
            SkillFolderBackend.exportAfterSave(skills)
        }
    }

    // Merge any hand-dropped or teammate-authored SKILL.md folders into the
    // store (newest-wins, dedupe by name). Settings and the skills tools call
    // this; the store itself never wipes, only merges.
    public func importFromFolders() {
        SkillFolderBackend.importFolders(into: self)
    }

    // Cancel any pending debounced save and write immediately. Used by
    // MemoryPortability before export and by tests for determinism.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }
}
