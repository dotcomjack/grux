import Foundation
import GruxShellCore

// Single source of truth for which iOS projects Grux is allowed to ship.
//
// One file: ~/.grux/projects.json. Per-project metadata still lives at
// <projectDir>/.grux/project.json - that's owned by `LocalProjectMarker`
// in GruxShellCore, written by `IOSProjectGen.scaffold` and updated by
// the build/run/screenshot tools. We do NOT duplicate that here.
//
// Only projects with `createdByGrux: true` are eligible for the ship-ios-app
// workflow. Everything the user built by hand is off-limits to the swarm,
// after the incident where an agent picked the wrong directory and started
// rewriting an existing shipping app's source.
//
// Canonical scaffold root for new Grux apps:
//   ~/Projects/<Name>/
// Matches ios_scaffold's existing convention and ProjectsIndex.scanRoots.
// Apps the user built by hand live wherever they keep them, which is the
// point: separate roots, clear ownership boundary.

struct ProjectRegistryEntry: Codable, Equatable {
    var name: String
    var displayName: String
    var root: String           // absolute path
    var bundleId: String
    var createdByGrux: Bool
    var createdAt: Date
    var lastSeenAt: Date?
}

struct ProjectRegistry: Codable {
    var version: Int
    var entries: [ProjectRegistryEntry]

    static let current = 1
    static let empty = ProjectRegistry(version: ProjectRegistry.current, entries: [])
}

enum ProjectRegistryStore {
    // ~/.grux/projects.json - visible at the same path as wake.log, fire-*
    // triggers, and workflow-runs/. Shell users can inspect / edit it without
    // diving into Library/Application Support.
    static var registryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    static func load() -> ProjectRegistry {
        Persistence.load(ProjectRegistry.self, from: registryURL, fallback: .empty)
    }

    static func save(_ reg: ProjectRegistry) {
        let dir = registryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Persistence.save(reg, to: registryURL)
    }

    // MARK: - Lookups

    static func find(name: String) -> ProjectRegistryEntry? {
        let needle = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return load().entries.first(where: { $0.name.lowercased() == needle })
    }

    /// Projects Grux scaffolded itself - the only ones the ship-ios-app
    /// workflow may freely modify (build swarm, file generation, etc.).
    static func gruxCreatedProjects() -> [ProjectRegistryEntry] {
        load().entries.filter { $0.createdByGrux }
    }

    /// Workflow guard. True iff the project is registered as Grux-created
    /// AND the directory still exists on disk (defends against stale registry
    /// entries left over from deletes).
    ///
    /// Self-healing fallback: if the project isn't in the registry but a
    /// `LocalProjectMarker` exists at <canonicalScaffoldRoot>/<name>/.grux/project.json,
    /// the project was scaffolded by `ios_scaffold` (the only writer of that
    /// marker). Backfill the registry entry on the spot so this and every
    /// future ship works without a one-shot migration.
    static func canShipEndToEnd(name: String) -> Bool {
        if let entry = find(name: name) {
            guard entry.createdByGrux else { return false }
            return FileManager.default.fileExists(atPath: entry.root)
        }
        // Registry miss - check for a Grux-scaffolded marker on disk.
        // macOS is case-insensitive by default, so the user typing "jordan2"
        // matches the directory `Jordan2`. Use the marker's `projectName` to
        // record the canonical (case-correct) path in the registry.
        let candidate = defaultRoot(forName: name)
        guard FileManager.default.fileExists(atPath: candidate),
              let marker = LocalProjectMarker.read(projectDir: candidate),
              marker.projectName.lowercased() == name.lowercased()
        else { return false }
        let canonicalRoot = canonicalScaffoldRoot + "/" + marker.projectName
        upsert(ProjectRegistryEntry(
            name: marker.projectName,
            displayName: marker.projectName,
            root: canonicalRoot,
            bundleId: marker.bundleId,
            createdByGrux: true,
            createdAt: marker.scaffoldedAt,
            lastSeenAt: Date()
        ))
        return true
    }

    // MARK: - Mutations

    @discardableResult
    static func upsert(_ entry: ProjectRegistryEntry) -> ProjectRegistryEntry {
        var reg = load()
        let lower = entry.name.lowercased()
        reg.entries.removeAll { $0.name.lowercased() == lower }
        reg.entries.append(entry)
        save(reg)
        return entry
    }

    static func remove(name: String) {
        var reg = load()
        let lower = name.lowercased()
        reg.entries.removeAll { $0.name.lowercased() == lower }
        save(reg)
    }

    // Touch lastSeenAt - call when a workflow successfully completes a phase
    // for this project. Used to surface "active" apps in the picker.
    static func touch(name: String) {
        var reg = load()
        guard let idx = reg.entries.firstIndex(where: { $0.name.lowercased() == name.lowercased() })
        else { return }
        reg.entries[idx].lastSeenAt = Date()
        save(reg)
    }

    // MARK: - Canonical paths

    /// Where new Grux-scaffolded apps land. Matches `IOSProjectGen.scaffold`'s
    /// existing layout (it appends `<projectName>` to whatever rootDir it's
    /// given) and `ProjectsIndex.scanRoots`. Apps the user built by hand live
    /// outside this root, which keeps a clean ownership boundary.
    static var canonicalScaffoldRoot: String {
        return NSHomeDirectory() + "/Projects"
    }

    /// Compose <canonicalScaffoldRoot>/<name>.
    static func defaultRoot(forName name: String) -> String {
        return canonicalScaffoldRoot + "/" + name
    }

    /// Default bundle ID for a Grux-scaffolded app: `<prefix>.<lowername>`.
    /// `com.example` is the placeholder prefix; the real one is the user's
    /// bundle prefix in Settings, iOS developer.
    static func defaultBundleId(forName name: String) -> String {
        return "com.example." + name.lowercased()
    }
}
