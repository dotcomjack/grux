import Foundation

// Auto-discovers the user's project roster so Grux never has to ask "what's X?"
// about something they actually own. Everything here is DISCOVERED from the
// machine it runs on, never compiled in: a roster in the binary would be one
// person's roster on everybody's install.
//
// Pulls from two sources:
//   1. An optional agent registry at ~/.grux/projects-registry.json, in Grux's
//      own directory rather than a vendor-specific one. Shape is
//      {"agents": {"<key>": {"name": "...", "description": "..."}}}, both
//      fields optional. Grux never writes this file; absent is the normal case
//      and is not an error, so no capability id is involved.
//   2. Top-level directories under ~/Projects, which catches work in flight.
//
// Cached in memory for 60s so we don't hit disk every chat turn.
enum KnownProjects {
    struct Entry: Hashable {
        let name: String
        let description: String
    }

    private static var cache: [Entry] = []
    private static var cachedAt: Date = .distantPast
    private static let ttl: TimeInterval = 60

    static func list() -> [Entry] {
        if Date().timeIntervalSince(cachedAt) < ttl, !cache.isEmpty { return cache }
        var entries: [Entry] = []
        var seen = Set<String>()

        entries.append(contentsOf: fromRegistry(seen: &seen))
        entries.append(contentsOf: fromProjectsDir(seen: &seen))

        cache = entries
        cachedAt = Date()
        return entries
    }

    // Rendered section for the stable system prompt. Cheap to rebuild per
    // call - hashes the same across calls unless the registry / project
    // directory changes, so prompt caching still hits.
    static func asSystemContext() -> String {
        let entries = list()
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { e in
            e.description.isEmpty
                ? "- \(e.name)"
                : "- \(e.name) - \(e.description)"
        }
        return """
        KNOWN_PROJECTS (projects found on this Mac - if the user mentions any of these, you already know what they are; do NOT ask "what's X?"):
        \(lines.joined(separator: "\n"))
        """
    }

    // Also exposed for Whisper vocab biasing so the ASR decoder learns the
    // names too. De-duplicated, case preserved.
    static func displayNames() -> [String] {
        list().map { $0.name }
    }

    // MARK: - Sources

    private static func fromRegistry(seen: inout Set<String>) -> [Entry] {
        let path = NSHomeDirectory() + "/.grux/projects-registry.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = obj["agents"] as? [String: [String: Any]]
        else { return [] }
        var out: [Entry] = []
        for (key, def) in agents {
            // The name the user wrote, or their entry's own key title cased.
            // Both come out of their file. Do not reach for the prose
            // description instead: pulling a name out of that needs a
            // compiled-in list of role phrases to strip, which is one person's
            // roster in the binary wearing a different hat, and it garbles the
            // name for anyone whose phrasing differs.
            let name = (def["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? displayName(forSlug: key)
            let description = def["description"] as? String ?? ""
            guard !name.isEmpty, !seen.contains(name.lowercased()) else { continue }
            seen.insert(name.lowercased())
            out.append(Entry(name: name, description: description))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func fromProjectsDir(seen: inout Set<String>) -> [Entry] {
        let path = NSHomeDirectory() + "/Projects"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var out: [Entry] = []
        for item in items {
            let full = path + "/" + item
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            if item.hasPrefix(".") { continue }
            if item.contains(".archived") || item.contains("-backup-") { continue }
            let display = displayName(forSlug: item)
            guard !seen.contains(display.lowercased()) else { continue }
            seen.insert(display.lowercased())
            out.append(Entry(name: display, description: "local project at ~/Projects/\(item)"))
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - Helpers

    // Turns a directory name or a registry key into something a person would
    // write. "acme-ios" → "Acme iOS"; "northwind-site-refresh" → "Northwind
    // Site Refresh"; already-mixed-case input such as "NorthwindKit" is left
    // exactly as it is, since somebody chose that capitalization on purpose.
    private static func displayName(forSlug dir: String) -> String {
        if dir == dir.lowercased() || dir == dir.uppercased() {
            // Looks like kebab-case or lowercase - titlecase parts.
            return dir
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { token -> String in
                    let s = String(token)
                    // Keep short all-caps acronyms (AI, ML, DJ, API) uppercase.
                    if s.count <= 3 { return s.uppercased() }
                    return s.prefix(1).uppercased() + s.dropFirst()
                }
                .joined(separator: " ")
        }
        return dir
    }
}
