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
            SidebarItem(key: "home", label: "Home", icon: "house.fill"),
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
            SidebarItem(key: "terminalFocus", label: "Terminal Focus", icon: "rectangle.inset.filled.on.rectangle"),
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

    private struct FilePayload: Codable {
        var collapsedGroups: [String]
        var pinned: [String]
        var recents: [String]
    }

    private static var fileURL: URL {
        Persistence.supportDir.appendingPathComponent("sidebar.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
            collapsedGroups = Set(payload.collapsedGroups)
            pinned = payload.pinned
            recents = payload.recents
        } else {
            collapsedGroups = []
            pinned = []
            recents = []
        }
    }

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

    // MARK: Persistence

    private func save() {
        let payload = FilePayload(
            collapsedGroups: collapsedGroups.sorted(),
            pinned: pinned,
            recents: recents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
