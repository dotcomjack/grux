import Foundation
import SwiftUI

// Broadcaster for tool-call-driven Orb status hints. Claude can call the
// `grux_orb_hint` tool to push a transient status label (e.g. "indexing docs",
// "waiting for confirmation") and optionally an orb state override.
// OrbAnywhereView, the AmbientHUD header pill, and the menu-bar orb can all
// subscribe. Single active hint at a time (new pushes replace the old).
//
// Safety notes: the `message` string is clamped to 40 chars and treated as
// display-only - it's not executed, rendered as markdown, or passed to any
// shell. Duration is clamped to [500ms, 8000ms] so a hostile prompt can't
// pin a rude label forever. This matches the approved blueprint review.
@MainActor
final class OrbHintBus: ObservableObject {
    static let shared = OrbHintBus()

    struct OrbHint: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let state: GruxOrbState?
        let createdAt: Date
        let expiresAt: Date

        static func == (lhs: OrbHint, rhs: OrbHint) -> Bool { lhs.id == rhs.id }
    }

    @Published var latestHint: OrbHint?

    private var clearTask: Task<Void, Never>?

    private init() {}

    func show(message: String, state: GruxOrbState? = nil, duration: TimeInterval = 3.0) {
        // Clamp message to 40 display chars (blueprint §7 safety-gate).
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedMsg = String(trimmed.prefix(40))
        guard !clampedMsg.isEmpty else { return }
        let clampedDur = max(0.5, min(8.0, duration))

        let now = Date()
        let hint = OrbHint(
            message: clampedMsg,
            state: state,
            createdAt: now,
            expiresAt: now.addingTimeInterval(clampedDur)
        )
        latestHint = hint

        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clampedDur * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only clear if we're still showing this hint (a newer one would
            // have installed its own clear task and replaced latestHint).
            if self?.latestHint?.id == hint.id {
                self?.latestHint = nil
            }
        }
    }

    func clear() {
        clearTask?.cancel()
        clearTask = nil
        latestHint = nil
    }

    // Map an Anthropic-supplied state string to a GruxOrbState. Unknown values
    // fall back to .thinking (the most benign "I'm working" signal).
    static func parseState(_ raw: String?) -> GruxOrbState? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "idle":      return .idle
        case "listening": return .listening
        case "thinking":  return .thinking
        case "speaking":  return .speaking
        case "muted":     return .muted
        case "alert":     return .thinking // alias - reuse thinking's amber pulse
        default:          return .thinking
        }
    }
}
