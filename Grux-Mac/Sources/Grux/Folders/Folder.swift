import Foundation

// Flat, user-owned grouping bucket for meetings (and - via metadata - any
// SemanticEntry). Mirrors Omi's shape so feature-parity is obvious: name +
// natural-language `description` double as the steering prompt for the AI
// classifier that auto-assigns new captures. `isSystem` marks seeded folders
// that can't be deleted (only renamed / recoloured); `isDefault` marks the
// fallback bucket when the classifier has nothing better.
struct Folder: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var description: String       // User-written instruction for the AI classifier. Free-form.
    var colorHex: String          // "#RRGGBB", no alpha. Used for chips + accents.
    var icon: String              // SF Symbol name, e.g. "folder.fill", "briefcase.fill".
    var order: Int                // Display order (lower first). Default folders sort ahead.
    var isSystem: Bool            // Seeded by Grux; can't be deleted.
    var isDefault: Bool           // Catch-all fallback. Exactly one folder should have this true.
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        colorHex: String = "#8B5CF6",
        icon: String = "folder.fill",
        order: Int = 1_000,
        isSystem: Bool = false,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = colorHex
        self.icon = icon
        self.order = order
        self.isSystem = isSystem
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Persistence {
    static var foldersURL: URL { supportDir.appendingPathComponent("folders.json") }
}
