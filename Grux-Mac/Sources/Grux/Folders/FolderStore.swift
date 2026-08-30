import Foundation
import SwiftUI

// Persistent folder registry. Local-first - everything lives as a single JSON
// blob at ~/Library/Application Support/Grux/folders.json. Seeds three system
// folders on first launch (Work / Personal / Projects) so empty-state never
// happens. Delete is constrained: system folders are immovable, and deleting
// a user folder reassigns every member meeting to the default folder.
@MainActor
final class FolderStore: ObservableObject {
    static let shared = FolderStore()

    @Published private(set) var folders: [Folder] = []

    // Hard cap - matches Omi's 50-custom-folder ceiling. Keeps the classifier
    // prompt short enough to stay inside a single cache block.
    static let maxCustomFolders = 50

    private var saveToken: DispatchWorkItem?

    private init() {
        self.folders = Persistence.load([Folder].self, from: Persistence.foldersURL, fallback: [])
        seedSystemFoldersIfNeeded()
        ensureSingleDefault()
    }

    // MARK: - Read

    var ordered: [Folder] {
        folders.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var defaultFolder: Folder {
        folders.first(where: { $0.isDefault })
            ?? folders.first(where: { $0.isSystem })
            ?? folders.first
            ?? Folder(name: "General", isSystem: true, isDefault: true)
    }

    func folder(id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first(where: { $0.id == id })
    }

    // Resolve a natural-language hint ("work", "the personal folder", uuid
    // string) to a concrete folder. Returns nil if nothing matches so callers
    // can surface a useful error instead of silently falling back.
    func resolve(_ hint: String) -> Folder? {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if let id = UUID(uuidString: h), let f = folder(id: id) { return f }
        let lower = h.lowercased()
        // Exact (case-insensitive) name match wins.
        if let f = folders.first(where: { $0.name.lowercased() == lower }) { return f }
        // Substring match as a fallback - least surprising for "put it in work".
        return folders.first(where: { $0.name.lowercased().contains(lower) })
    }

    // MARK: - Write

    @discardableResult
    func create(
        name: String,
        description: String = "",
        colorHex: String = "#8B5CF6",
        icon: String = "folder.fill"
    ) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // De-dup by case-insensitive name so the user doesn't end up with three
        // "Work" folders if the classifier prompt gets creative.
        if let existing = folders.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return existing
        }
        let customCount = folders.filter { !$0.isSystem }.count
        guard customCount < Self.maxCustomFolders else { return nil }
        let nextOrder = (folders.map { $0.order }.max() ?? 1_000) + 10
        let folder = Folder(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: normalizeHex(colorHex),
            icon: icon.isEmpty ? "folder.fill" : icon,
            order: nextOrder,
            isSystem: false,
            isDefault: false
        )
        folders.append(folder)
        scheduleSave()
        return folder
    }

    @discardableResult
    func update(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        colorHex: String? = nil,
        icon: String? = nil,
        order: Int? = nil
    ) -> Folder? {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return nil }
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            folders[idx].name = n
        }
        if let d = description { folders[idx].description = d }
        if let c = colorHex, !c.isEmpty { folders[idx].colorHex = normalizeHex(c) }
        if let ic = icon, !ic.isEmpty { folders[idx].icon = ic }
        if let o = order { folders[idx].order = o }
        folders[idx].updatedAt = Date()
        scheduleSave()
        return folders[idx]
    }

    // Deleting a user folder moves its members to the default folder (or a
    // caller-specified target). System folders are immovable - callers get
    // nil back and must surface an error.
    @discardableResult
    func delete(id: UUID, reassignTo: UUID? = nil) -> (deleted: Folder, newHome: Folder)? {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return nil }
        let victim = folders[idx]
        guard !victim.isSystem else { return nil }
        let home: Folder = {
            if let target = reassignTo, let f = folder(id: target), f.id != id { return f }
            return defaultFolder
        }()
        folders.remove(at: idx)
        // Cascade: every meeting whose folderId == victim.id is repointed.
        MeetingStore.shared.reassignAll(fromFolder: id, toFolder: home.id)
        SemanticMemory.shared.reassignFolder(from: id, to: home.id)
        scheduleSave()
        return (victim, home)
    }

    func setDefault(id: UUID) {
        for i in folders.indices { folders[i].isDefault = folders[i].id == id }
        scheduleSave()
    }

    func reorder(orderedIds: [UUID]) {
        var step = 100
        for id in orderedIds {
            if let i = folders.firstIndex(where: { $0.id == id }) {
                folders[i].order = step
                step += 10
            }
        }
        scheduleSave()
    }

    // MARK: - Seeding

    private func seedSystemFoldersIfNeeded() {
        guard folders.isEmpty else { return }
        let now = Date()
        folders = [
            Folder(
                name: "Work",
                description: "Meetings, project discussions, client calls, shipping updates, engineering and product decisions.",
                colorHex: "#3B82F6",
                icon: "briefcase.fill",
                order: 100,
                isSystem: true,
                isDefault: false,
                createdAt: now, updatedAt: now
            ),
            Folder(
                name: "Personal",
                description: "Personal life, family, health, finances, appointments, and anything outside work or projects.",
                colorHex: "#10B981",
                icon: "person.crop.circle.fill",
                order: 110,
                isSystem: true,
                isDefault: false,
                createdAt: now, updatedAt: now
            ),
            Folder(
                name: "Projects",
                description: "Catch-all for product and side-project work: the things you are building. Default bucket for uncategorized captures.",
                colorHex: "#8B5CF6",
                icon: "square.stack.3d.up.fill",
                order: 120,
                isSystem: true,
                isDefault: true,
                createdAt: now, updatedAt: now
            )
        ]
        scheduleSave()
    }

    private func ensureSingleDefault() {
        let defaults = folders.enumerated().filter { $0.element.isDefault }
        if defaults.isEmpty {
            if let idx = folders.indices.first {
                folders[idx].isDefault = true
                scheduleSave()
            }
        } else if defaults.count > 1 {
            for (i, (idx, _)) in defaults.enumerated() where i > 0 {
                folders[idx].isDefault = false
            }
            scheduleSave()
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        objectWillChange.send()
    }

    func saveNow() {
        Persistence.save(folders, to: Persistence.foldersURL)
    }

    // MARK: - Helpers

    private func normalizeHex(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !s.hasPrefix("#") { s = "#" + s }
        // Accept "#RGB" shorthand by expanding to "#RRGGBB".
        if s.count == 4 {
            let chars = Array(s.dropFirst())
            s = "#" + chars.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 7 else { return "#8B5CF6" }
        return s
    }
}

// Testable helper for SwiftUI colour resolution from the stored hex.
extension Folder {
    var color: Color {
        let hex = colorHex.hasPrefix("#") ? String(colorHex.dropFirst()) : colorHex
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
            return Color.purple
        }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
