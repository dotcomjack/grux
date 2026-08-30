import Foundation
import SwiftUI

// Codable models for the live Brands Poster service (the brands-poster service
// on the companion host, port 3856). This is the AUTONOMOUS posting engine: the
// per-brand account that actually publishes, distinct from
// the legacy per-platform health grid in SocialOpsModels.swift. The wire shape
// is REST-style snake_case (updated_at, cadence_per_day), so unlike SocialOps
// these types carry explicit CodingKeys instead of matching property names 1:1.
//
// Read-only observability: there are NO cadence or ramp controls anywhere in
// this feature. The status pill, remaining-today count, and circuit state are
// all DERIVED client-side from the raw record (see statusPill / remainingToday)
// so the silent-darkness failure (a posting account quietly stalling) always
// shows up on the Empire dashboard.
//
// GET <configured-host>:3856/api/brands-poster/status returns:
// { updated_at, service, owned_brands[], cdp_up, brands[ {per-brand record} ] }
// last_error and circuit_open_until are null when healthy: both decode optional.

/// A full point-in-time status of the autonomous posting engine.
struct BrandsPosterStatus: Codable {
    var updatedAt: String
    var service: String
    var ownedBrands: [String]
    var cdpUp: Bool
    var brands: [BrandPostingRecord]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case service
        case ownedBrands = "owned_brands"
        case cdpUp = "cdp_up"
        case brands
    }
}

/// Per-brand posting health, as reported by the remote service's brands-poster service.
/// last_error and circuit_open_until are null when the account is healthy, so
/// both are decoded as optional String?.
struct BrandPostingRecord: Codable, Identifiable, Hashable {
    var brand: String
    var handle: String
    var ready: Bool
    var paused: Bool
    var ymlPaused: Bool
    var cadencePerDay: Int
    var postsToday: Int
    var lastPostedAt: String?
    var needsReauth: Bool
    var consecutiveFailures: Int
    var lastError: String?
    var circuitState: String
    var circuitOpenUntil: String?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case brand
        case handle
        case ready
        case paused
        case ymlPaused = "yml_paused"
        case cadencePerDay = "cadence_per_day"
        case postsToday = "posts_today"
        case lastPostedAt = "last_posted_at"
        case needsReauth = "needs_reauth"
        case consecutiveFailures = "consecutive_failures"
        case lastError = "last_error"
        case circuitState = "circuit_state"
        case circuitOpenUntil = "circuit_open_until"
        case updatedAt = "updated_at"
    }

    /// Stable identity for SwiftUI lists. One record per brand.
    var id: String { brand }

    /// Posts still allowed today given the cadence. Never negative: a brand that
    /// already overshot its cadence (posts_today > cadence) reads as 0 remaining.
    var remainingToday: Int {
        max(0, cadencePerDay - postsToday)
    }

    /// Derived health pill. Precedence (worst first): a re-auth wall and an open
    /// circuit are both hard red, then not-ready/paused reads gray, then any
    /// failure signal reads amber, else green. yml_paused is intentionally
    /// ignored (it is a config toggle, not a live-health signal).
    var statusPill: BrandPostingPill {
        if needsReauth { return .reauth }
        if circuitState == "open" { return .circuit }
        if !ready || paused { return .paused }
        if consecutiveFailures > 0 || (lastError?.isEmpty == false) { return .degraded }
        return .healthy
    }
}

/// The derived health pill for one brand. Tint + glyph follow the schema rule:
/// healthy green, degraded amber, reauth + circuit red, paused gray.
enum BrandPostingPill {
    case healthy
    case degraded
    case reauth
    case circuit
    case paused

    /// Short label shown inside the pill.
    var label: String {
        switch self {
        case .healthy:  return "healthy"
        case .degraded: return "degraded"
        case .reauth:   return "reauth"
        case .circuit:  return "circuit"
        case .paused:   return "paused"
        }
    }

    /// Tint per pill: green / amber / red / red / gray. GruxTheme tokens where a
    /// brand color exists, system colors for the rest, matching the SocialOps
    /// system-token convention this surface ships with.
    var tint: Color {
        switch self {
        case .healthy:  return .green
        case .degraded: return .orange
        case .reauth:   return .red
        case .circuit:  return .red
        case .paused:   return Color(nsColor: .systemGray)
        }
    }
}
