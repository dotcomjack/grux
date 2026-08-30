import Foundation

// User-editable mapping from overlay corner to a Claude Code session UUID.
// Persisted as part of TerminalFocusConfig; nil per-corner means unassigned.
//
// Using a flat struct (rather than [OverlayCorner: String]) because
// OverlayCorner is not Codable out of the box and round-tripping an enum
// dictionary via JSONSerialization reads poorly in the persisted file.
struct SlotMapping: Codable, Equatable {
    var topLeft: String?
    var topRight: String?
    var bottomLeft: String?
    var bottomRight: String?

    static let empty = SlotMapping(topLeft: nil, topRight: nil, bottomLeft: nil, bottomRight: nil)

    func sessionId(for corner: OverlayCorner) -> String? {
        switch corner {
        case .topLeft:     return topLeft
        case .topRight:    return topRight
        case .bottomLeft:  return bottomLeft
        case .bottomRight: return bottomRight
        }
    }

    mutating func set(_ sessionId: String?, for corner: OverlayCorner) {
        switch corner {
        case .topLeft:     topLeft = sessionId
        case .topRight:    topRight = sessionId
        case .bottomLeft:  bottomLeft = sessionId
        case .bottomRight: bottomRight = sessionId
        }
    }

    // Every corner with an assigned sessionId. Useful for settings UI.
    var assigned: [(OverlayCorner, String)] {
        var out: [(OverlayCorner, String)] = []
        if let t = topLeft     { out.append((.topLeft, t)) }
        if let t = topRight    { out.append((.topRight, t)) }
        if let t = bottomLeft  { out.append((.bottomLeft, t)) }
        if let t = bottomRight { out.append((.bottomRight, t)) }
        return out
    }
}

// Pure projection: for each corner that has a sessionId assigned AND that
// session is present in the snapshot dictionary, return the snapshot.
// Stale mappings (sessionId pointing at a session that no longer exists or
// hasn't been indexed yet) are silently dropped from the output - the caller
// surfaces this as "- unassigned -" or keeps the slot empty.
enum ClaudeSessionSlotMapper {
    static func map(
        mapping: SlotMapping,
        snapshots: [String: ClaudeSessionSnapshot]
    ) -> [OverlayCorner: ClaudeSessionSnapshot] {
        var out: [OverlayCorner: ClaudeSessionSnapshot] = [:]
        for corner in OverlayCorner.allCases {
            guard let sid = mapping.sessionId(for: corner),
                  let snap = snapshots[sid] else { continue }
            out[corner] = snap
        }
        return out
    }
}
