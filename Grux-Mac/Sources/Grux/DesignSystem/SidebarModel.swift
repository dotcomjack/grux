import Foundation
import SwiftUI

// MARK: - Sidebar information architecture (Blueprint section 02, Sidebar IA)
//
// Single source of truth for the launch-window sidebar AND the
// OrbCommandPalette tab-jump actions. Five blueprint groups (Command,
// Workspace, Intelligence, Ambient) plus a System group that holds every
// remaining tab so nothing existing becomes unreachable. The `key` strings
// are EXACTLY the applyTab names used by the --open-tab automation; do not
// rename them.

struct SidebarItem: Hashable {
    /// applyTab key. Must match LaunchRootView.applyTab cases verbatim.
    let key: String
    let label: String
    let icon: String
}

struct SidebarGroupDef: Identifiable {
    let id: String
    let title: String
    let items: [SidebarItem]
}

enum SidebarIA {
    static let groups: [SidebarGroupDef] = [
        SidebarGroupDef(id: "command", title: "Command", items: [
            SidebarItem(key: "home", label: "Today", icon: "house.fill"),
            SidebarItem(key: "reactor", label: "Reactor", icon: "atom"),
            SidebarItem(key: "chat", label: "Chat", icon: "bubble.left.fill"),
            SidebarItem(key: "jaxHQ", label: "Jax HQ", icon: "sparkle"),
            SidebarItem(key: "jaxCommand", label: "Jax Command", icon: "brain.head.profile"),
            SidebarItem(key: "cognitionMap", label: "Cognition Map", icon: "point.3.connected.trianglepath.dotted"),
            SidebarItem(key: "featureReview", label: "Feature Review", icon: "checklist"),
            SidebarItem(key: "projects", label: "Projects", icon: "square.stack.3d.up.fill"),
            SidebarItem(key: "tasks", label: "Tasks", icon: "list.bullet.rectangle.fill"),
            SidebarItem(key: "agents", label: "Agents", icon: "rectangle.stack.badge.play.fill"),
            SidebarItem(key: "social", label: "Social", icon: "at.circle.fill")
        ]),
        SidebarGroupDef(id: "workspace", title: "Workspace", items: [
            SidebarItem(key: "mailbox", label: "Mailbox", icon: "envelope.fill"),
            SidebarItem(key: "calendar", label: "Calendar", icon: "calendar"),
            SidebarItem(key: "notes", label: "Notes", icon: "note.text"),
            SidebarItem(key: "documents", label: "Documents", icon: "doc.text.fill"),
            SidebarItem(key: "contacts", label: "Contacts", icon: "person.crop.rectangle.stack.fill"),
            SidebarItem(key: "schedules", label: "Schedules", icon: "calendar.badge.clock"),
            SidebarItem(key: "folders", label: "Folders", icon: "folder.fill")
        ]),
        SidebarGroupDef(id: "intelligence", title: "Intelligence", items: [
            SidebarItem(key: "research", label: "Research", icon: "text.magnifyingglass"),
            SidebarItem(key: "skills", label: "Skills", icon: "graduationcap.fill"),
            SidebarItem(key: "compare", label: "Compare", icon: "rectangle.split.2x1.fill"),
            SidebarItem(key: "cookbook", label: "Local Models", icon: "cpu.fill"),
            SidebarItem(key: "creative", label: "Media Studio", icon: "wand.and.sparkles"),
            SidebarItem(key: "designStudio", label: "Design Studio", icon: "paintbrush.pointed.fill")
        ]),
        SidebarGroupDef(id: "ambient", title: "Ambient", items: [
            SidebarItem(key: "meetings", label: "Meetings", icon: "waveform.and.person.filled"),
            SidebarItem(key: "speakers", label: "Speakers", icon: "person.2.wave.2.fill")
        ]),
        SidebarGroupDef(id: "system", title: "System", items: [
            SidebarItem(key: "roadmap", label: "Roadmap", icon: "map.fill"),
            SidebarItem(key: "commands", label: "Commands", icon: "command.circle.fill"),
            SidebarItem(key: "workflows", label: "Workflows", icon: "flowchart.fill"),
            SidebarItem(key: "metaAds", label: "Meta Ads", icon: "megaphone.fill"),
            SidebarItem(key: "focus", label: "Focus log", icon: "eye.fill"),
            SidebarItem(key: "selfUpgrade", label: "Self-Upgrade", icon: "sparkles"),
            SidebarItem(key: "integrations", label: "Integrations", icon: "link.circle.fill"),
            SidebarItem(key: "settings", label: "Settings", icon: "gearshape.fill")
        ])
    ]

    /// Every tab in sidebar order, groups flattened.
    static let allItems: [SidebarItem] = groups.flatMap(\.items)

    static func item(forKey key: String) -> SidebarItem? {
        allItems.first(where: { $0.key == key })
    }
}

// MARK: - Persisted sidebar state (collapse + pins + recents)
//
// Tiny JSON store following the Persistence.supportDir pattern used by the
// rest of the app (config.json, tasks.json). Saves synchronously on every
// mutation; the file is a few hundred bytes so there is no need to debounce.

@MainActor
final class SidebarStateStore: ObservableObject {
    static let shared = SidebarStateStore()

    @Published private(set) var collapsedGroups: Set<String>
    @Published private(set) var pinned: [String]
    /// Most-recent-first applyTab keys, capped at `recentsCap`. Feeds the
    /// OrbCommandPalette recent-tabs section.
    @Published private(set) var recents: [String]

    private static let recentsCap = 6

    struct FilePayload: Codable, Equatable {
        var collapsedGroups: [String]
        var pinned: [String]
        var recents: [String]
    }

    /// Pinned and recent keys the live tab registry does not know (a retired
    /// surface such as `terminalFocus`, a hand edit). Never shown; written back
    /// as they were, so the file on disk keeps them.
    private var setAside = FilePayload(collapsedGroups: [], pinned: [], recents: [])

    private static var fileURL: URL {
        Persistence.supportDir.appendingPathComponent("sidebar.json")
    }

    /// Splits a saved payload into what the live registry knows and what it sets aside.
    static func split(_ payload: FilePayload) -> (live: FilePayload, setAside: FilePayload) {
        let known = { (k: String) in SidebarIA.item(forKey: k) != nil }
        return (FilePayload(collapsedGroups: payload.collapsedGroups,
                            pinned: payload.pinned.filter(known), recents: payload.recents.filter(known)),
                FilePayload(collapsedGroups: [],
                            pinned: payload.pinned.filter { !known($0) }, recents: payload.recents.filter { !known($0) }))
    }

    /// What `save` writes: the live state, then the set-aside keys after it.
    static func merged(_ live: FilePayload, _ setAside: FilePayload) -> FilePayload {
        FilePayload(collapsedGroups: live.collapsedGroups,
                    pinned: live.pinned + setAside.pinned.filter { !live.pinned.contains($0) },
                    recents: live.recents + setAside.recents.filter { !live.recents.contains($0) })
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
            let (live, aside) = Self.split(payload)
            collapsedGroups = Set(live.collapsedGroups)
            pinned = live.pinned
            recents = live.recents
            setAside = aside
        } else {
            collapsedGroups = Self.freshInstallCollapsed
            pinned = []
            recents = []
        }
    }

    /// A fresh install opens with both doors shut: "Developer (collapsed,
    /// counted); Labs (collapsed, counted)", 3.0 design section 3. Measured
    /// 2026-09-21 on a clean-state render: with nothing collapsed, the Labs
    /// door opened itself and a first run showed 21 rail lines, not 14. An
    /// install that already saved its own choices keeps them.
    static let freshInstallCollapsed: Set<String> = ["door.labs", "door.developer"]

    // MARK: Collapse

    func isExpanded(_ groupId: String) -> Bool {
        !collapsedGroups.contains(groupId)
    }

    func setExpanded(_ groupId: String, _ expanded: Bool) {
        if expanded {
            collapsedGroups.remove(groupId)
        } else {
            collapsedGroups.insert(groupId)
        }
        save()
    }

    // MARK: Pins

    func isPinned(_ key: String) -> Bool {
        pinned.contains(key)
    }

    func pin(_ key: String) {
        guard !pinned.contains(key), SidebarIA.item(forKey: key) != nil else { return }
        pinned.append(key)
        save()
    }

    func unpin(_ key: String) {
        pinned.removeAll { $0 == key }
        save()
    }

    // MARK: Recents

    func recordRecent(_ key: String) {
        guard SidebarIA.item(forKey: key) != nil else { return }
        var next = recents.filter { $0 != key }
        next.insert(key, at: 0)
        if next.count > Self.recentsCap {
            next = Array(next.prefix(Self.recentsCap))
        }
        guard next != recents else { return }
        recents = next
        save()
    }

    // MARK: Replace

    /// Sets the recents wholesale. Tests snapshot and restore them with it,
    /// because the store is process-wide and recents leak between classes.
    func replaceRecents(_ keys: [String]) {
        guard keys != recents else { return }
        recents = Array(keys.prefix(Self.recentsCap))
        save()
    }

    /// Sets the pins wholesale, keeping only keys the rail knows.
    func replacePins(_ keys: [String]) {
        let next = keys.filter { SidebarIA.item(forKey: $0) != nil }
        guard next != pinned else { return }
        pinned = next
        save()
    }

    // MARK: Persistence

    private func save() {
        let payload = Self.merged(FilePayload(
            collapsedGroups: collapsedGroups.sorted(),
            pinned: pinned,
            recents: recents
        ), setAside)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

// MARK: - The 3.0 rail, computed from dispositions
//
// `SidebarIA.groups` above is the 1.x rail: 35 hand-written keys in five
// groups, maintained by hand and related to the 39-row feature registry only
// by both being edited by the same person. The 3.0 rail is a PROJECTION of the
// disposition recorded on each registry row, so the question "where does this
// live" has exactly one answer and a test can prove nothing is orphaned.
//
// `groups` stays, because it is still the source of icons, labels and the
// locked `--open-tab` keys, and because every one of those 35 keys must keep
// resolving after a surface moves behind a door. Folding changes where a
// person FINDS something, never whether a script can still reach it.

/// One row in the 3.0 rail.
struct SidebarRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Opens a surface directly.
        case surface(key: String)
        /// A collapsed door with a count of what is behind it.
        case door(id: String)
    }

    let id: String
    let label: String
    let icon: String
    let kind: Kind
    /// Only a door carries one. Zero for a surface.
    let count: Int

    var isDoor: Bool { if case .door = kind { return true }; return false }
}

extension SidebarIA {
    /// The twelve surfaces, in rail order. Studio is a row rather than a
    /// registry id: it hosts Design Studio, Media Studio and Research.
    static let railOrder: [(key: String, label: String, icon: String)] = [
        ("home",         "Today",        "house.fill"),
        ("chat",         "Chat",         "bubble.left.fill"),
        ("mailbox",      "Mail",         "envelope.fill"),
        ("calendar",     "Calendar",     "calendar"),
        ("notes",        "Notes",        "note.text"),
        ("documents",    "Documents",    "doc.text.fill"),
        ("contacts",     "Contacts",     "person.crop.rectangle.stack.fill"),
        ("tasks",        "Tasks",        "list.bullet.rectangle.fill"),
        ("meetings",     "Meetings",     "waveform.and.person.filled"),
        ("schedules",    "Schedules",    "calendar.badge.clock"),
        ("integrations", "Integrations", "link.circle.fill"),
        ("designStudio", "Studio",       "paintbrush.pointed.fill"),
    ]

    /// SURFACES WHOSE NEW HOME DOES NOT HOST THEM YET, and why this exists.
    ///
    /// A fold is a MOVE. Until the parent surface actually hosts the child,
    /// taking the child's row out of the rail does not relocate it, it deletes
    /// it: measured on the running app after the rail first shipped, Speakers,
    /// Workflows, Folders, Projects, Skills and the Focus log were reachable
    /// only by firing `~/.grux/fire-open-tab` by hand.
    ///
    /// That is the same mistake as pulling the BETA pills before the Labs door
    /// existed, and the rule is the same: a gap between a removal and its
    /// replacement is a regression even when both halves are planned.
    ///
    /// So a fold that has not landed keeps its row. The list is SELF
    /// LIQUIDATING: each Phase C fold task removes its own entry as the parent
    /// starts hosting the child, and when the list empties this whole block
    /// renders nothing and can be deleted. `RailReachabilityTests` fails if a
    /// row is in neither the rail, a door, nor this list.
    /// Covers BOTH kinds of pending move: a fold into a parent, and the three
    /// surfaces that go behind the Studio row. Research and Media Studio were
    /// found by the test rather than by reading, which is the point of it.
    static let awaitingTheirNewHome: [(key: String, label: String, icon: String)] = []

    /// Brand-scoped rows, which appear only once a brand exists.
    static let brandScopedOrder: [(key: String, label: String, icon: String)] = [
        ("metaAds", "Meta Ads", "megaphone.fill"),
        ("social",  "Social",   "at.circle.fill"),
    ]

    /// The label the rail shows for a key ("Mail", "Studio"), falling back to
    /// the legacy table's label. Both shells and the palette read this one.
    static func railLabel(forKey key: String) -> String {
        if let r = railOrder.first(where: { $0.key == key }) { return r.label }
        if let b = brandScopedOrder.first(where: { $0.key == key }) { return b.label }
        switch key {
        case "settings": return "Settings"
        case "labs": return "Labs"
        // TuningCopy.title, spelled out: that enum is main-actor isolated and
        // this is not. CommandPanelRootTests pins the two equal.
        case "tuning": return "Tuning"
        default: return item(forKey: key)?.label ?? key
        }
    }

    /// The icon that goes with `railLabel(forKey:)`.
    static func railIcon(forKey key: String) -> String {
        if let r = railOrder.first(where: { $0.key == key }) { return r.icon }
        if let b = brandScopedOrder.first(where: { $0.key == key }) { return b.icon }
        return item(forKey: key)?.icon ?? "square"
    }

    /// The `roadmap` key has no registry row of its own and belongs with the
    /// Labs cluster, so the Labs count is the seven labs rows plus this one.
    static let labsOnlyKeys = ["roadmap"]

    /// The rail a person actually sees.
    ///
    /// Order: twelve surfaces, then any brand-scoped rows, then the Developer
    /// door when unlocked, then the Labs door, then Settings last. At first
    /// run with no brand and no developer tier that is fourteen rows, which is
    /// where the Definition of Done's number comes from.
    @MainActor
    static func rail(developerUnlocked: Bool, brands: [String]) -> [SidebarRow] {
        var out: [SidebarRow] = railOrder.map {
            SidebarRow(id: $0.key, label: $0.label, icon: $0.icon,
                       kind: .surface(key: $0.key), count: 0)
        }
        if !brands.isEmpty {
            out += brandScopedOrder.map {
                SidebarRow(id: $0.key, label: $0.label, icon: $0.icon,
                           kind: .surface(key: $0.key), count: 0)
            }
        }
        // Anything whose parent does not host it yet keeps its row, so a fold
        // in progress never costs a person access to a surface they had.
        out += awaitingTheirNewHome.map {
            SidebarRow(id: $0.key, label: $0.label, icon: $0.icon,
                       kind: .surface(key: $0.key), count: 0)
        }
        if developerUnlocked {
            out.append(SidebarRow(id: "door.developer", label: "Developer",
                                  icon: "hammer.fill", kind: .door(id: "developer"),
                                  count: behind(.developer).count))
        }
        out.append(SidebarRow(id: "door.labs", label: "Labs",
                              icon: "flask.fill", kind: .door(id: "labs"),
                              count: behind(.labs).count + labsOnlyKeys.count))
        out.append(SidebarRow(id: "settings", label: "Settings", icon: "gearshape.fill",
                              kind: .surface(key: "settings"), count: 0))
        return out
    }

    /// The registry rows behind a door, in registry order.
    @MainActor
    static func behind(_ disposition: FeatureRow.Disposition) -> [FeatureRow] {
        FeatureRegistry.rows.filter { $0.disposition == disposition }
    }
}
