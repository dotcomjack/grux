import Foundation

// Platform-free brand identity for the Grux Orb. Lives in GruxShellCore so
// the iOS Glasses companion, a future web surface, or any non-AppKit host
// can render the same visual language without pulling in SwiftUI/AppKit.
//
// Colors are expressed as linear sRGB components (0.0…1.0) + alpha so
// callers on any platform can map them to their native color type.
// Values were sampled from GruxOrbState (Sources/Grux/OrbView.swift) on
// 2026-04-24 and must stay in sync: if the macOS palette changes, update
// here too so the glasses app doesn't drift.

public enum OrbStateKind: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case muted
}

public struct OrbRGBA: Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public enum OrbPalette {
    // Primary hue for each state - matches GruxOrbState.primary on macOS.
    public static func primary(_ kind: OrbStateKind) -> OrbRGBA {
        switch kind {
        case .idle:      return OrbRGBA(r: 0.596, g: 0.349, b: 0.949, a: 0.55) // .purple @55%
        case .listening: return OrbRGBA(r: 0.000, g: 0.780, b: 0.565)          // .mint
        case .thinking:  return OrbRGBA(r: 0.988, g: 0.843, b: 0.000)          // .yellow
        case .speaking:  return OrbRGBA(r: 0.000, g: 0.737, b: 0.831)          // .cyan
        case .muted:     return OrbRGBA(r: 0.556, g: 0.556, b: 0.576, a: 0.45) // .gray @45%
        }
    }

    // Secondary hue for gradient orbit - matches GruxOrbState.secondary.
    public static func secondary(_ kind: OrbStateKind) -> OrbRGBA {
        switch kind {
        case .idle:      return OrbRGBA(r: 0.345, g: 0.337, b: 0.839)          // .indigo
        case .listening: return OrbRGBA(r: 0.196, g: 0.843, b: 0.294)          // .green
        case .thinking:  return OrbRGBA(r: 1.000, g: 0.584, b: 0.000)          // .orange
        case .speaking:  return OrbRGBA(r: 0.000, g: 0.478, b: 1.000)          // .blue
        case .muted:     return OrbRGBA(r: 0.556, g: 0.556, b: 0.576, a: 0.30) // .gray @30%
        }
    }

    // Short canonical label, re-used by the glasses companion so Grux's
    // "state vocabulary" is identical across surfaces.
    public static func label(_ kind: OrbStateKind) -> String {
        switch kind {
        case .idle:      return "idle"
        case .listening: return "listening"
        case .thinking:  return "thinking"
        case .speaking:  return "speaking"
        case .muted:     return "muted"
        }
    }
}
