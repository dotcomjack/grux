import Foundation

// BYTE-FOR-BYTE copy of the Mac's Sources/Grux/SocialOps/SocialOpsModels.swift.
// The GruxPhone target has no SPM link to the Grux target, so it keeps its own
// copy. The ChatEnvelope wire (.socialOpsPanelSnapshot carries [SocialHealthRecord])
// requires these types to stay identical to the Mac copy: same field names, same
// Codable conformances. Keep in lockstep.

/// The social platforms Grux operates per brand.
enum SocialPlatform: String, Codable, CaseIterable {
    case threads
    case instagram
    case tiktok
    case linkedin
}

/// Roll-up health status for a single (brand, platform) cell.
/// green: healthy. amber: degraded (rate limited or reach trending down).
/// red: broken (logged out, session invalid, 2FA challenge, post failed).
/// muted: operator silenced this cell. unknown: not yet checked.
enum SocialStatus: String, Codable {
    case green
    case amber
    case red
    case muted
    case unknown
}

/// The operator action a two-tap control issues for a cell.
/// `sweep` is not a per-cell action: it asks the Mini to re-check every cell now.
/// It rides the same socialOpsAction envelope (brand/platform empty) so the phone
/// can trigger a live sweep without a new wire type.
enum SocialOpAction: String, Codable {
    case retry
    case reauth
    case mute
    case approve
    case sweep
}

/// Health of one brand on one platform, as reported by the Mini sweep.
struct SocialHealthRecord: Codable, Identifiable, Hashable {
    var brand: String
    var platform: SocialPlatform
    var status: SocialStatus
    var loggedIn: Bool
    var sessionValid: Bool
    var lastPostResult: String
    var rateLimited: Bool
    var twoFAChallenge: Bool
    var switchable: Bool
    var reachTrend: String
    var muted: Bool
    var lastChecked: Int64   // unix-epoch SECONDS (Mini sweep clock), not millis
    var lastError: String

    /// Stable identity for SwiftUI lists and the grid. A brand only has one
    /// record per platform, so brand|platform uniquely identifies a cell.
    var id: String { "\(brand)|\(platform.rawValue)" }
}

/// A full point-in-time snapshot of every tracked cell.
struct SocialOpsSnapshot: Codable {
    var generatedAt: Int64   // unix-epoch MILLISECONDS (Mac relay clock)
    var source: String
    var records: [SocialHealthRecord]
}

/// A pre-built operator command (label + action) targeting one cell.
struct SocialOpCommand: Codable, Identifiable, Hashable {
    var id: String
    var brand: String
    var platform: SocialPlatform
    var label: String
    var action: SocialOpAction
}
