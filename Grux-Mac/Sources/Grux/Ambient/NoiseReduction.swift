import Foundation

/// Rolling noise-floor VAD gate.
///
/// Learns the ambient noise level from frames that look like silence and
/// classifies incoming frames against a floor-relative threshold with
/// hysteresis. Replaces the prior hard-coded `rms > 0.006` check - that
/// threshold worked in a quiet room but tripped constantly against a
/// 3700-4000 RPM fan, so `lastVoiceAt` never got stale and the
/// ambient listener never flushed the turn.
///
/// Frame model: one call per audio-tap buffer delivery (~85 ms at 48 kHz
/// native with bufferSize 4096). Warmup runs ~2 s before floor-relative
/// thresholds kick in, which covers the common "just opened the mic"
/// startup transient without delaying the first real utterance.
final class AdaptiveNoiseGate {
    // Current estimated noise floor in RMS units, updated only when the
    // gate does NOT classify a frame as voice. A short EMA during warmup
    // lets it lock on quickly; a slow EMA afterward prevents a single word
    // from dragging the floor up and gating out the rest of the sentence.
    private var noiseFloor: Float

    private var framesSeen: Int = 0
    private var inVoice: Bool = false

    // Warmup: fixed threshold + aggressive floor learning.
    private let warmupFrames: Int = 25
    private let warmupFloorAlpha: Float = 0.15
    private let warmupThreshold: Float = 0.010

    // Steady state: slow EMA so the user's own speech doesn't bias the floor.
    private let idleFloorAlpha: Float = 0.03

    // Asymmetric hysteresis. Have to clear enterMultiplier*floor to start
    // voicing; stay voiced until we drop below releaseMultiplier*floor.
    // The gap is what keeps mid-word consonants (/s/, /t/) or natural
    // pauses from flipping us out of voice state and resetting the
    // silence-flush timer prematurely.
    private let enterMultiplier: Float = 2.8
    private let releaseMultiplier: Float = 1.6

    // Clamp bounds. Without these, a single anomalous frame can pin the
    // floor at zero (nothing ever gated) or at speech level (nothing ever
    // passes). 0.0008..0.015 covers "dead-silent studio" to "loud café."
    private let minFloor: Float = 0.0008
    private let maxFloor: Float = 0.015

    // Below this absolute RMS we refuse to classify as voice no matter
    // what the floor-relative multiplier says. Defends against the edge
    // case where the floor underflows toward zero in a freakishly quiet
    // room and mic self-noise starts tripping the relative threshold.
    private let absoluteMinThreshold: Float = 0.003

    init(initialFloor: Float = 0.0025) {
        self.noiseFloor = initialFloor
    }

    /// Returns true if this frame should be treated as voice (ie reset the
    /// silence timer). False means "steady noise or silence - let the
    /// silence timer advance toward flush."
    func classify(rms: Float) -> Bool {
        framesSeen += 1
        let warmup = framesSeen <= warmupFrames

        let threshold: Float
        if warmup {
            threshold = warmupThreshold
        } else {
            let mult = inVoice ? releaseMultiplier : enterMultiplier
            threshold = max(noiseFloor * mult, absoluteMinThreshold)
        }

        let isVoiced = rms > threshold

        // Update floor only on non-voiced frames. Updating during voiced
        // frames is what biases the floor upward and causes the "fan gets
        // louder after you talk" failure mode.
        if !isVoiced {
            let alpha = warmup ? warmupFloorAlpha : idleFloorAlpha
            let updated = (1 - alpha) * noiseFloor + alpha * rms
            noiseFloor = min(max(updated, minFloor), maxFloor)
        }

        inVoice = isVoiced
        return isVoiced
    }

    /// Diagnostic accessor - useful for smoke tests and status logging.
    var currentNoiseFloor: Float { noiseFloor }
    var isInVoice: Bool { inVoice }
    var framesProcessed: Int { framesSeen }

    func reset() {
        noiseFloor = 0.0025
        framesSeen = 0
        inVoice = false
    }
}
