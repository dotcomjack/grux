//
//  CreativeRecipe.swift
//  Grux Creative Studio - forkable, personal scene recipes
//
//  A recipe is a saved "look": the structured controls + freeform addon +
//  aspect that produced a render you liked. Grux is built for one person, so
//  the store leans personal: favorites pin to the front, recents sort next, and
//  recipes can be brand specific or global. Persisted to
//  ~/.grux/creative/recipes.json alongside the rendered bundles.
//
//  No em dashes, no en dashes.
//

import Foundation
import SwiftUI

struct CreativeRecipe: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var brandSlug: String          // "" or "untagged" means global (any brand)
    var controls: SceneControls
    var freeformAddon: String
    var aspect: AspectPreset
    var favorite: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    var forkedFrom: String?
}

@MainActor
final class RecipeStore: ObservableObject {
    static let shared = RecipeStore()

    @Published private(set) var recipes: [CreativeRecipe] = []

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux/creative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recipes.json")
    }()

    // Guards against silently overwriting a recipes.json that failed to decode
    // (e.g. a future schema change): until we have a known-good load, no write
    // is allowed, so a bad file is never replaced with an empty array.
    private var loadSucceeded = false

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            loadSucceeded = true  // no file yet is a legitimate blank slate
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let loaded = try? dec.decode([CreativeRecipe].self, from: data) {
            recipes = loaded
            loadSucceeded = true
        }
        // On decode failure loadSucceeded stays false: we keep the file intact.
    }

    private func persist() {
        guard loadSucceeded else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(recipes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    @discardableResult
    func add(
        name: String,
        brandSlug: String,
        controls: SceneControls,
        freeformAddon: String,
        aspect: AspectPreset,
        forkedFrom: String? = nil
    ) -> CreativeRecipe {
        let recipe = CreativeRecipe(
            id: "rec-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled look" : name,
            brandSlug: brandSlug,
            controls: controls,
            freeformAddon: freeformAddon,
            aspect: aspect,
            favorite: false,
            createdAt: Date(),
            lastUsedAt: nil,
            forkedFrom: forkedFrom
        )
        recipes.insert(recipe, at: 0)
        persist()
        return recipe
    }

    func delete(_ id: String) {
        recipes.removeAll { $0.id == id }
        persist()
    }

    func toggleFavorite(_ id: String) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].favorite.toggle()
        persist()
    }

    func markUsed(_ id: String) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].lastUsedAt = Date()
        persist()
    }

    @discardableResult
    func fork(_ id: String, newName: String) -> CreativeRecipe? {
        guard let src = recipes.first(where: { $0.id == id }) else { return nil }
        return add(
            name: newName,
            brandSlug: src.brandSlug,
            controls: src.controls,
            freeformAddon: src.freeformAddon,
            aspect: src.aspect,
            forkedFrom: src.id
        )
    }

    /// Recipes applicable to a brand (its own plus global), favorites first then
    /// most recently used. This is the row the composer shows.
    func recipes(forBrand slug: String) -> [CreativeRecipe] {
        recipes
            .filter { $0.brandSlug.isEmpty || $0.brandSlug == "untagged" || $0.brandSlug == slug }
            .sorted { a, b in
                if a.favorite != b.favorite { return a.favorite }
                let au = a.lastUsedAt ?? a.createdAt
                let bu = b.lastUsedAt ?? b.createdAt
                return au > bu
            }
    }
}
