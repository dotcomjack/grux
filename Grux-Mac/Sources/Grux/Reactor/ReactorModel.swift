import SwiftUI

// Shared, pure helpers for the Reactor surface. No store access here so these
// stay nonisolated and trivially testable; the views read the live @MainActor
// stores directly via @ObservedObject and pass resolved values in.
enum ReactorSignals {
    /// mint / amber / rose pacing ladder, matching MetaAdsPacingBar semantics
    /// (under 80% calm, 80-100% warn, at/over cap critical).
    static func tint(_ fraction: Double) -> Color {
        if fraction >= 1.0 { return GruxTheme.destructiveRose }
        if fraction >= 0.8 { return GruxTheme.warnAmber }
        return GruxTheme.successMint
    }

    /// Resolve the live 0...1 amplitude from already-observed speech/voice
    /// values. Speaking uses the real TTS outputLevel; when that is dead
    /// (system voice / offline TTS leaves it at 0) a gentle synthetic pulse
    /// keeps the core breathing while Grux talks. Listening uses the mic level.
    static func amplitude(isSpeaking: Bool, isBuffering: Bool, outputLevel: Float,
                          isRecording: Bool, liveLevel: Float, t: Double) -> Float {
        if isSpeaking || isBuffering {
            if outputLevel > 0.001 { return min(1, outputLevel) }
            return Float(0.16 + 0.10 * (0.5 + 0.5 * sin(t * 6.0)))
        }
        if isRecording {
            // Open mic: track the live level, but keep a gentle floor pulse so
            // the core still breathes during a silent pause instead of flatlining.
            let floor = Float(0.10 + 0.06 * (0.5 + 0.5 * sin(t * 5.0)))
            return min(1, max(liveLevel, floor))
        }
        return 0
    }
}
