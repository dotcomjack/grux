//
//  CreativeFeedback.swift
//  Grux Creative Studio - self-learning feedback loop + adaptive model policy
//
//  You rate a generation (thumbs up/down, optional note). That feedback is
//  persisted and feeds an ADAPTIVE per-brand model preference:
//  when a brand keeps getting negatives on its current image model, the studio
//  escalates it up the sanctioned ladder (qwen-image-edit-plus ->
//  qwen-image-edit-max) for that brand's future renders. The policy is
//  deliberately swappable: today it is a simple net-score rule, tomorrow it can
//  be an LLM that reads the freeform notes. The raw log is kept so a smarter
//  policy has the full history to learn from. Not a static system.
//

import Foundation
import SwiftUI

enum AssetRating: String, Codable, Sendable {
    case none
    case up
    case down
}

/// Sanctioned image-model ladder the per-brand bandit arbitrates over. Spans
/// PROVIDERS: Replicate flux-dev is the pure-generation model, then the qwen
/// editing ladder for product-in-scene (qwen-image-edit-max is the strongest the
/// pipeline wires today; Nano Banana Pro is a future rung, separate integration).
enum ModelLadder {
    static let image: [String] = [ReplicateModels.defaultImage, "qwen-image-edit-plus", "qwen-image-edit-max"]

    /// The subset the configured render service understands. That render path must
    /// send one of these even when the cross-provider bandit currently prefers the
    /// generation model, so product-in-scene requests stay byte-identical.
    static let miniImage: [String] = ["qwen-image-edit-plus", "qwen-image-edit-max"]
}

struct FeedbackEntry: Codable, Sendable, Identifiable {
    var id: String          // "<bundleId>-<ts>"
    var bundleId: String
    var brand: String
    var model: String       // the image model that produced the rated asset
    var rating: String      // "up" | "down"
    var note: String?
    var at: Date
}

@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var log: [FeedbackEntry] = []

    /// Small cost bias so the cheaper model wins ties / cold start; a brand only
    /// climbs to the pricier model once feedback makes it clearly better.
    private let modelCost: [String: Double] = [
        "qwen-image-edit-plus": 0.0,
        "qwen-image-edit-max": 0.06,
        // ESTIMATED, NOT SETTLED, and it was already an estimate before the vendor moved:
        // the line it replaces read "fal flux/dev, about $0.03 per image (estimated)". The
        // house rule is to price a model from a settled charge rather than a pricing page,
        // and there is no Replicate invoice to read yet. It is carried at the same figure
        // because the bandit only uses it as a small tie-break bias, so being wrong by a
        // cent changes a cold-start preference and nothing that spends money. Replace it
        // with the real number off the first bill.
        ReplicateModels.defaultImage: 0.03,
    ]

    private var loadSucceeded = false
    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux/creative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feedback.json")
    }()

    init() { load() }

    /// The image model the studio should use for a brand's next render.
    /// Cost-aware greedy bandit over the ladder: each (brand, model) arm has a
    /// Laplace-smoothed success rate from the feedback log; we pick the arm with
    /// the best (successRate minus cost bias). Unlike the old escalate-only rule,
    /// this can also move BACK down the ladder if the pricier model underperforms.
    /// Computed live from the log so it always reflects the latest feedback.
    func preferredImageModel(forBrand slug: String) -> String {
        func successRate(_ model: String) -> Double {
            let arm = log.filter { $0.brand == slug && $0.model == model }
            let up = arm.filter { $0.rating == "up" }.count
            let down = arm.filter { $0.rating == "down" }.count
            return Double(up + 1) / Double(up + down + 2)   // Laplace prior 0.5
        }
        var best = ModelLadder.image.first ?? "qwen-image-edit-plus"
        var bestScore = -Double.greatestFiniteMagnitude
        for model in ModelLadder.image {
            let score = successRate(model) - (modelCost[model] ?? 0.0)
            if score > bestScore + 1e-9 {   // strict >, so ties keep the earlier (cheaper) arm
                bestScore = score; best = model
            }
        }
        return best
    }

    /// Record a rating. The log IS the policy state, so the next
    /// preferredImageModel call reflects this immediately. Returns the
    /// (possibly changed) preferred model so the caller can surface a bump.
    @discardableResult
    func record(bundleId: String, brand: String, model: String, rating: AssetRating, note: String?) -> String {
        guard rating != .none else { return preferredImageModel(forBrand: brand) }
        let entry = FeedbackEntry(
            id: "\(bundleId)-\(Int(Date().timeIntervalSince1970))",
            bundleId: bundleId, brand: brand, model: model,
            rating: rating.rawValue, note: note?.isEmpty == true ? nil : note, at: Date()
        )
        log.insert(entry, at: 0)
        persist()
        return preferredImageModel(forBrand: brand)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { loadSucceeded = true; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        struct Snapshot: Codable { var log: [FeedbackEntry] }
        if let snap = try? dec.decode(Snapshot.self, from: data) {
            log = snap.log; loadSucceeded = true
        }
    }

    private func persist() {
        guard loadSucceeded else { return }
        struct Snapshot: Codable { var log: [FeedbackEntry] }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Snapshot(log: log)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
