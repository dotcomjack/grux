import Foundation

// SkillFolderBackend: a human-readable SKILL.md folder mirror that sits BESIDE
// skills.json, never replacing it.
//
//   Application Support/Grux/skills/
//     <kebab-name>/SKILL.md
//
// Each SKILL.md carries a small YAML-ish front matter (name / trigger /
// updatedAt) and a markdown body that is the skill's procedure. skills.json
// stays the fast index; these folders are what the user (or a teammate) can read,
// edit, or hand-drop in.
//
// Import is MERGE, not wipe: a folder that is newer than the store's copy of a
// same-named skill wins, an older folder is ignored, and a folder for a skill
// the store never had is added. This mirrors MemoryPortability.importAll.
//
// Merge uses only SkillStore's public API (skill(named:) + upsert), so this
// file needs no privileged access to the store's internals and the store keeps
// every existing signature and its debounce/flush semantics intact.
enum SkillFolderBackend {

    // Render/parse with fractional-second precision so a round-trip preserves a
    // skill's exact updatedAt. Without it the stamp truncates to a whole second,
    // and an equal-second edit compares as older-or-equal and never re-imports.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Fallback for files written before fractional seconds (or hand-authored
    // front matter with none): .withFractionalSeconds fails to parse a stamp
    // that has no milliseconds, so try plain internet-date-time second.
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ value: String) -> Date? {
        iso.date(from: value) ?? isoNoFraction.date(from: value)
    }

    // MARK: - Export (index -> folders)

    // Write one folder per skill. Additive: this updates or creates a folder for
    // each current skill and never deletes other folders (so a hand-dropped
    // folder survives an export).
    static func export(_ skills: [Skill], to root: URL = Persistence.skillsDir) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for skill in skills {
            let folder = root.appendingPathComponent(folderName(for: skill.name), isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = render(skill).data(using: .utf8) else { continue }
            Persistence.write(data, to: folder.appendingPathComponent("SKILL.md"))
        }
    }

    // Best-effort mirror hook for SkillStore.saveNow. Non-fatal by construction:
    // every write goes through try?/Persistence.write, so a failure here never
    // disturbs the authoritative skills.json save that just happened.
    //
    // Edit-preserving, unlike the blind `export`: an unrelated skill save must not
    // revert a hand edit to some other skill's SKILL.md. For each skill, if the
    // on-disk file carries a different body AND is newer than the store's copy of
    // that skill (a hand edit landed after the store last touched it), skip the
    // write. A genuinely newer edit is pulled back into the store by importFolders.
    static func exportAfterSave(_ skills: [Skill], to root: URL = Persistence.skillsDir) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for skill in skills {
            let folder = root.appendingPathComponent(folderName(for: skill.name), isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            let rendered = render(skill)
            if let onDisk = try? String(contentsOf: file, encoding: .utf8),
               onDisk != rendered,
               fileIsNewer(file, than: skill.updatedAt) {
                continue
            }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = rendered.data(using: .utf8) else { continue }
            Persistence.write(data, to: file)
        }
    }

    // True when the file's on-disk modification time is strictly after `date`.
    // Catches a body-only hand edit (which does not bump the front-matter stamp)
    // that the store has not seen yet. Missing/unreadable mtime resolves to false
    // so a fresh or opaque file is always (re)written.
    private static func fileIsNewer(_ url: URL, than date: Date) -> Bool {
        guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return mod > date
    }

    // MARK: - Delete (propagate a removal to the mirror)

    // Remove a skill's SKILL.md folder so a deletion in the store propagates to
    // disk. Without this the mirror is additive-only and importFolders /
    // reindexIfDriftDetected would resurrect a skill the store deleted. Kebab
    // name resolution matches `export`, so the same skill maps to the same folder.
    static func removeFolder(for name: String, from root: URL = Persistence.skillsDir) {
        let folder = root.appendingPathComponent(folderName(for: name), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Read (folders -> skills)

    static func readFolders(from root: URL = Persistence.skillsDir) -> [Skill] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [Skill] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let file = item.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let skill = parse(markdown: text, folderName: item.lastPathComponent) {
                out.append(skill)
            }
        }
        return out
    }

    // MARK: - Import (merge, not wipe)

    @MainActor
    static func importFolders(into store: SkillStore, from root: URL = Persistence.skillsDir) {
        for incoming in readFolders(from: root) {
            merge(incoming, into: store)
        }
    }

    // Only pull in folders the store has never seen. Used to self-heal after a
    // hand-drop without touching skills the store already tracks.
    @MainActor
    static func reindexIfDriftDetected(into store: SkillStore, from root: URL = Persistence.skillsDir) {
        for incoming in readFolders(from: root) where store.skill(named: incoming.name) == nil {
            store.upsert(name: incoming.name, trigger: incoming.trigger, procedure: incoming.procedure)
        }
    }

    // Newest-wins merge via the public store API. An incoming folder overwrites
    // the store's copy only when it is strictly newer; a missing/unparseable
    // timestamp resolves to distantPast so it can never clobber a live skill.
    @MainActor
    private static func merge(_ incoming: Skill, into store: SkillStore) {
        if let existing = store.skill(named: incoming.name) {
            guard incoming.updatedAt > existing.updatedAt else { return }
        }
        store.upsert(name: incoming.name, trigger: incoming.trigger, procedure: incoming.procedure)
    }

    // MARK: - SKILL.md render / parse

    static func render(_ skill: Skill) -> String {
        let trigger = skill.trigger
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var md = "---\n"
        md += "name: \(skill.name)\n"
        md += "trigger: \(trigger)\n"
        md += "updatedAt: \(iso.string(from: skill.updatedAt))\n"
        md += "---\n\n"
        md += skill.procedure
        if !skill.procedure.hasSuffix("\n") { md += "\n" }
        return md
    }

    static func parse(markdown: String, folderName: String) -> Skill? {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var name = ""
        var trigger = ""
        var updatedAt: Date? = nil
        var body = normalized

        if normalized.hasPrefix("---\n") {
            let afterOpen = normalized.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n---") {
                let front = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                let afterClose = afterOpen[closeRange.upperBound...]
                if let firstNewline = afterClose.firstIndex(of: "\n") {
                    body = String(afterClose[afterClose.index(after: firstNewline)...])
                } else {
                    body = ""
                }
                for line in front.components(separatedBy: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "name":      name = value
                    case "trigger":   trigger = value
                    case "updatedat": updatedAt = parseTimestamp(value)
                    default:          break
                    }
                }
            }
        }

        let resolvedName = name.isEmpty ? folderName : name
        guard !resolvedName.isEmpty else { return nil }
        let procedure = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return Skill(
            name: resolvedName,
            trigger: trigger,
            procedure: procedure,
            updatedAt: updatedAt ?? Date.distantPast
        )
    }

    // MARK: - Helpers

    // Kebab folder name. Local (not shared with the design slugger) so the
    // memory subsystem stays self-contained.
    private static func folderName(for name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}

// MARK: - Persistence root

extension Persistence {
    // SKILL.md folder mirror lives beside skills.json under Application Support.
    static var skillsDir: URL {
        let dir = supportDir.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
