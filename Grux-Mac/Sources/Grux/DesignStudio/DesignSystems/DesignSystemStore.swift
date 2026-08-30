import Foundation

// MARK: - Persistence root
//
// Design systems are user-visible, portable, editable artifacts (a folder of
// DESIGN.md files the user may open in an editor or hand to Open Design), so they
// live under the ~/Documents/Grux tree like memory exports, NOT in the app
// private Application Support store. Additive extension, mirrors the
// MemoryPortability.exportsDir construction, keeps Persistence.swift untouched.
extension Persistence {
    /// NON-CREATING, for the reason spelled out on `Persistence.designDir`: a store whose
    /// init reads this is constructed when the view hierarchy is built, which is at launch,
    /// so a creating getter here puts a folder in the person's Documents before they have
    /// opened anything. Whatever writes a design system creates it.
    static var designSystemsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Grux", isDirectory: true)
            .appendingPathComponent("design-systems", isDirectory: true)
    }
}

// A compact index row so the picker never parses every DESIGN.md to list them.
struct DesignSystemIndexEntry: Codable, Identifiable, Hashable, Sendable {
    var slug: String
    var name: String
    var updatedAt: Date

    var id: String { slug }
}

// MARK: - DesignSystemStore
//
// Disk-backed store for portable design systems. Layout:
//
//   design-systems/
//     index.json                 compact [DesignSystemIndexEntry]
//     active-systems.json        { brandSlug: systemSlug } active bindings
//     <slug>/
//       DESIGN.md                the portable, Open-Design-compatible system
//
// House pattern (DocumentStore): @MainActor ObservableObject singleton, a
// non-private init(rootDir:) test seam, an index self-heal for hand-dropped
// folders, and all writes routed through Persistence.save / Persistence.write
// so the restore kill switch is honored.
@MainActor
final class DesignSystemStore: ObservableObject {
    static let shared = DesignSystemStore()

    @Published private(set) var entries: [DesignSystemIndexEntry] = []

    private let rootDir: URL

    // Cached DESIGN.md character counts, keyed by slug, so the per-keystroke run
    // estimate can fold the active system's length without re-reading the file
    // from disk each call. Invalidated whenever a system is saved or imported.
    private var markdownCharCounts: [String: Int] = [:]

    private init() {
        // Not created here. See the getter: this init runs at launch, not when somebody
        // opens the picker.
        self.rootDir = Persistence.designSystemsDir
        loadIndex()
        reindexIfDriftDetected()
    }

    // Test seam: run against a temp directory without touching ~/Documents.
    init(rootDir: URL) {
        self.rootDir = rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Listing

    // Alphabetized by name (stable, human-friendly for a picker).
    func list() -> [DesignSystemIndexEntry] {
        entries.sorted { a, b in
            if a.name.lowercased() != b.name.lowercased() {
                return a.name.lowercased() < b.name.lowercased()
            }
            return a.slug < b.slug
        }
    }

    func entry(slug: String) -> DesignSystemIndexEntry? {
        entries.first { $0.slug == slug }
    }

    // MARK: - Load

    // Read and parse a system's DESIGN.md. The folder slug is authoritative.
    func load(slug: String) -> DesignSystem? {
        let url = designURL(slug: slug)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return DesignSystem.parse(markdown: text, slug: slug)
    }

    // The raw DESIGN.md text for a system, unparsed.
    func markdown(slug: String) -> String? {
        try? String(contentsOf: designURL(slug: slug), encoding: .utf8)
    }

    // MARK: - Save

    // Write a system to disk (canonical rendered markdown) and update the index.
    @discardableResult
    func save(system: DesignSystem) -> DesignSystemIndexEntry {
        let dir = systemDir(slug: system.slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rendered = system.render()
        if let data = rendered.data(using: .utf8) {
            Persistence.write(data, to: designURL(slug: system.slug))
        }
        markdownCharCounts[system.slug] = rendered.count
        let entry = DesignSystemIndexEntry(slug: system.slug, name: system.name, updatedAt: Date())
        upsertEntry(entry)
        return entry
    }

    // MARK: - Import

    // Copy an external DESIGN.md into the store. Validates that it parses to a
    // non-empty system, derives a clean slug, and writes the ORIGINAL bytes
    // verbatim (a faithful copy, so nothing a foreign file carries is lost).
    // Returns the parsed system, or nil when the file is missing or empty.
    @discardableResult
    func importFile(url: URL) -> DesignSystem? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let probe = DesignSystem.parse(markdown: text)
        guard !probe.name.isEmpty || !probe.sections.isEmpty || !probe.extras.isEmpty else { return nil }

        let baseName = probe.name.isEmpty ? url.deletingPathExtension().lastPathComponent : probe.name
        // Never clobber an existing system. A byte-identical re-import of a system
        // already at the base slug is a no-op (so re-importing the same file does
        // not pile up numbered duplicates); otherwise a colliding base slug gets a
        // -2, -3, ... suffix until unique, mirroring DesignProjectStore.
        let baseSlug = DesignSystem.slugify(baseName)
        if entry(slug: baseSlug) != nil, markdown(slug: baseSlug) == text {
            return DesignSystem.parse(markdown: text, slug: baseSlug)
        }
        let slug = makeUniqueSlug(from: baseSlug)
        let dir = systemDir(slug: slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8), Persistence.write(data, to: designURL(slug: slug)) else { return nil }
        markdownCharCounts[slug] = text.count

        let name = probe.name.isEmpty ? baseName : probe.name
        upsertEntry(DesignSystemIndexEntry(slug: slug, name: name, updatedAt: Date()))
        return DesignSystem.parse(markdown: text, slug: slug)
    }

    // MARK: - Active system per brand

    // The active system slug bound to a brand, if any.
    func activeSystemSlug(brandSlug: String) -> String? {
        activeMap()[normalizeBrand(brandSlug)]
    }

    // The system a brand should use: its explicit active binding, or, when none
    // is bound, a system on disk whose slug matches the brand slug. The fallback
    // means a freshly generated same-named system (see the generate-brand tool,
    // which auto-activates) still applies even if the active map was never set.
    func resolvedActiveSystemSlug(brandSlug: String) -> String? {
        if let active = activeSystemSlug(brandSlug: brandSlug) { return active }
        let normalized = normalizeBrand(brandSlug)
        return entry(slug: normalized) != nil ? normalized : nil
    }

    // Bind a brand to a system. Returns false if the system slug is unknown.
    @discardableResult
    func setActiveSystem(brandSlug: String, slug: String) -> Bool {
        guard entry(slug: slug) != nil else { return false }
        var map = activeMap()
        map[normalizeBrand(brandSlug)] = slug
        Persistence.save(map, to: activeMapURL)
        return true
    }

    func clearActiveSystem(brandSlug: String) {
        var map = activeMap()
        map[normalizeBrand(brandSlug)] = nil
        Persistence.save(map, to: activeMapURL)
    }

    // The DESIGN.md markdown of the brand's active (or slug-fallback) system.
    // This is what the studio engine binds as its DesignSystemProviding seam, so
    // a generated artifact carries the right brand's system into its prompt.
    func activeSystemMarkdown(brandSlug: String) -> String? {
        guard let slug = resolvedActiveSystemSlug(brandSlug: brandSlug) else { return nil }
        return markdown(slug: slug)
    }

    // Character count of a system's DESIGN.md, served from a per-slug cache so
    // the estimate does not re-read the file on every keystroke.
    func markdownCharCount(slug: String) -> Int? {
        if let cached = markdownCharCounts[slug] { return cached }
        guard let md = markdown(slug: slug) else { return nil }
        markdownCharCounts[slug] = md.count
        return md.count
    }

    // Character count of the brand's active (or slug-fallback) system markdown,
    // or 0 when none resolves. Powers the estimate's design-system folding.
    func activeSystemCharCount(brandSlug: String) -> Int {
        guard let slug = resolvedActiveSystemSlug(brandSlug: brandSlug) else { return 0 }
        return markdownCharCount(slug: slug) ?? 0
    }

    // MARK: - Drift self-heal

    // Surface any <slug>/DESIGN.md folders present on disk but missing from the
    // index (hand-dropped systems, an interrupted write). Copy this DocumentStore
    // pattern so a folder the user drops in is picked up on next launch.
    func reindexIfDriftDetected() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var changed = false
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let slug = item.lastPathComponent
            guard entry(slug: slug) == nil else { continue }
            let designFile = item.appendingPathComponent("DESIGN.md")
            guard let text = try? String(contentsOf: designFile, encoding: .utf8) else { continue }
            let parsed = DesignSystem.parse(markdown: text, slug: slug)
            let name = parsed.name.isEmpty ? slug : parsed.name
            entries.append(DesignSystemIndexEntry(slug: slug, name: name, updatedAt: Date()))
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: - Paths

    private func systemDir(slug: String) -> URL {
        rootDir.appendingPathComponent(slug, isDirectory: true)
    }

    private func designURL(slug: String) -> URL {
        systemDir(slug: slug).appendingPathComponent("DESIGN.md")
    }

    private var indexURL: URL {
        rootDir.appendingPathComponent("index.json")
    }

    private var activeMapURL: URL {
        rootDir.appendingPathComponent("active-systems.json")
    }

    // MARK: - Index + active map persistence

    private func loadIndex() {
        entries = Persistence.load([DesignSystemIndexEntry].self, from: indexURL, fallback: [])
    }

    private func saveIndex() {
        Persistence.save(entries, to: indexURL)
    }

    private func upsertEntry(_ entry: DesignSystemIndexEntry) {
        if let idx = entries.firstIndex(where: { $0.slug == entry.slug }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        saveIndex()
    }

    private func activeMap() -> [String: String] {
        Persistence.load([String: String].self, from: activeMapURL, fallback: [:])
    }

    private func normalizeBrand(_ brandSlug: String) -> String {
        DesignSystem.slugify(brandSlug)
    }

    // MARK: - Helpers

    // Never reuse a slug already in the index or present on disk: suffix -2, -3,
    // ... until unique. Mirrors DesignProjectStore.makeUniqueSlug so a colliding
    // import lands beside the existing system instead of overwriting it.
    private func makeUniqueSlug(from baseSlug: String) -> String {
        // DesignSystem.slugify never returns empty (it falls back to "system").
        let root = baseSlug.isEmpty ? "system" : baseSlug
        let existing = Set(entries.map { $0.slug })
        var candidate = root
        var n = 2
        while existing.contains(candidate)
            || FileManager.default.fileExists(atPath: systemDir(slug: candidate).path)
            || FileManager.default.fileExists(atPath: designURL(slug: candidate).path) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }
}
