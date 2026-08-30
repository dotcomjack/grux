import Foundation

// Shared Codable models for the Social Ops Cockpit. These types are a contract:
// the field names match the social-ops service JSON (port 3856) and
// this file is copied byte-for-byte into the GruxPhone iOS target. Keep field
// names stable. No behavior here, just the wire/UI shapes the rest of the
// feature (service client, store, Empire section, phone cockpit) builds on.

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
/// `sweep` is not a per-cell action: it asks the companion service to re-check every cell now.
/// It rides the same socialOpsAction envelope (brand/platform empty) so the phone
/// can trigger a live sweep without a new wire type.
enum SocialOpAction: String, Codable {
    case retry
    case reauth
    case mute
    case approve
    case sweep
}

/// Health of one brand on one platform, as reported by the remote service sweep.
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
    var lastChecked: Int64   // unix-epoch SECONDS (companion sweep clock), not millis
    var lastError: String

    /// Stable identity for SwiftUI lists and the grid. A brand only has one
    /// record per platform, so brand|platform uniquely identifies a cell.
    var id: String { "\(brand)|\(platform.rawValue)" }
}

/// How a snapshot ENTERED this Mac: pulled from a host this machine asked,
/// or pushed by the companion into Grux's local inbox. Grux-side provenance,
/// stamped by SocialOpsStore on each write path and persisted with the
/// cache. The wire never sends it (the decoder below defaults it), and it
/// exists so a later failed pull can tell "a pull host stopped answering",
/// an outage worth a technical banner, from "no pull host was ever
/// configured over push-fed data", which is the normal state. Distinct from
/// `source`, which is the companion's own account of what produced the
/// snapshot over there.
enum SocialOpsIngress: String, Codable {
    case pull
    case push
}

/// A full point-in-time snapshot of every tracked cell.
struct SocialOpsSnapshot: Codable {
    var generatedAt: Int64   // unix-epoch MILLISECONDS (Mac relay clock)
    var source: String
    var records: [SocialHealthRecord]
    var ingress: SocialOpsIngress = .pull
}

// Decoding stays open to a social-ops.json (and a wire body) written before
// `ingress` existed. Same shape HardwareProfile.init(from:) set for
// cookbook.json: decodeIfPresent with an honest backfill, synthesized
// encoding so a cache written by this build carries the real value, and the
// initializer in an extension so the memberwise initializer survives for
// fixtures. The backfill is .pull deliberately: guessing pull for a cache
// that was really push-fed surfaces a technical banner where silence was
// normal, while guessing push the other way would hide a real outage behind
// absence prose, and only one of those mistakes loses information.
//
// The decoded value is trusted ONLY for the persisted legacy cache. Every
// live entry point stamps over it after decode (SocialOpsStore.ingest writes
// .push, refresh adoption and the command echo write .pull), so a wire body
// claiming an ingress never chooses its own provenance.
extension SocialOpsSnapshot {
    private enum DecodeKeys: String, CodingKey {
        case generatedAt, source, records, ingress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodeKeys.self)
        generatedAt = try c.decode(Int64.self, forKey: .generatedAt)
        source = try c.decode(String.self, forKey: .source)
        records = try c.decode([SocialHealthRecord].self, forKey: .records)
        ingress = try c.decodeIfPresent(SocialOpsIngress.self, forKey: .ingress) ?? .pull
    }
}

/// A pre-built operator command (label + action) targeting one cell.
struct SocialOpCommand: Codable, Identifiable, Hashable {
    var id: String
    var brand: String
    var platform: SocialPlatform
    var label: String
    var action: SocialOpAction
}
