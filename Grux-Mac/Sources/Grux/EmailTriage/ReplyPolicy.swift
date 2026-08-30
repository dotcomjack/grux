import Foundation
import Combine

// ReplyPolicy: the per-brand opt-out gate for autonomous email replies. Jax can
// stage drafts for any inbox, but a brand only gets a draft for a given email
// kind / support category when the brand's policy allows it. The posture is
// opt-out by safety: personal mail is the only kind enabled by default, and a
// missing key (a partial persisted file, or a kind/category added after the
// file was written) resolves to the same defaults value, never to a silent
// "yes". Persisted to ~/.grux/support/reply-policy.json as [String: BrandReplyPolicy]
// keyed by brand voice (whatever keys the accounts use), the same convention the
// support drafts store uses.

struct BrandReplyPolicy: Codable, Equatable {
    var kinds: [String: Bool]       // EmailKind.rawValue -> enabled
    var categories: [String: Bool]  // SupportCategory.rawValue -> enabled

    // Opt-out defaults: personal replies on, automated + marketing off; all four
    // support categories on. New brands and partial files resolve here.
    static var defaults: BrandReplyPolicy {
        BrandReplyPolicy(
            kinds: [
                EmailKind.personal.rawValue: true,
                EmailKind.automated.rawValue: false,
                EmailKind.marketing.rawValue: false
            ],
            categories: [
                SupportCategory.refund.rawValue: true,
                SupportCategory.shipping.rawValue: true,
                SupportCategory.product.rawValue: true,
                SupportCategory.other.rawValue: true
            ]
        )
    }

    // Missing key falls back to the defaults value for that key, so a partial
    // persisted file or a newly-added kind resolves to the opt-out posture.
    func allows(kind: EmailKind) -> Bool {
        if let v = kinds[kind.rawValue] { return v }
        return BrandReplyPolicy.defaults.kinds[kind.rawValue] ?? (kind == .personal)
    }

    // Missing category defaults to true (all categories are on out of the box).
    func allows(category: SupportCategory) -> Bool {
        if let v = categories[category.rawValue] { return v }
        return true
    }
}

// JSON-backed store for the per-brand policies. Lives at
// ~/.grux/support/reply-policy.json so it survives relaunches and is greppable
// from the CLI, the same convention the support draft store uses. @MainActor
// ObservableObject so the SwiftUI settings surface reacts to toggles.
@MainActor
final class ReplyPolicyStore: ObservableObject {
    static let shared = ReplyPolicyStore()

    @Published private(set) var policies: [String: BrandReplyPolicy] = [:]

    private static var rootDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("support")
    }
    private let url: URL = {
        let dir = ReplyPolicyStore.rootDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reply-policy.json")
    }()

    private init() {
        policies = Persistence.load([String: BrandReplyPolicy].self, from: url, fallback: [:])
    }

    // Returns the brand's stored policy, or .defaults when the brand has none.
    func policy(for brand: String) -> BrandReplyPolicy {
        policies[brand.lowercased()] ?? .defaults
    }

    func setKind(_ kind: EmailKind, enabled: Bool, for brand: String) {
        let key = brand.lowercased()
        var p = policies[key] ?? .defaults
        p.kinds[kind.rawValue] = enabled
        policies[key] = p
        save()
    }

    func setCategory(_ category: SupportCategory, enabled: Bool, for brand: String) {
        let key = brand.lowercased()
        var p = policies[key] ?? .defaults
        p.categories[category.rawValue] = enabled
        policies[key] = p
        save()
    }

    private func save() { Persistence.save(policies, to: url) }
}
