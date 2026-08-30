import SwiftUI
import AppKit

// Ported + tuned from Omi's refocus glow (BasedHardware/omi desktop app). We
// use 4 edge windows (top/bottom/left/right) positioned AROUND the target
// window so the center stays click-through and doesn't block hover events.
// Red = distracted/off-task, green = back on track.

enum GlowColorMode {
    case focused    // green - locked in
    case distracted // red - drifting
    case speaking   // cyan - Grux is talking; glow pulses with TTS level

    var baseHue: Double {
        switch self {
        case .focused:    return 0.38 // green
        case .distracted: return 0.0  // red
        // Speaking mirrors the orb's speaking state, so its hue comes from
        // OrbGlowMap (the single orb-state to glow-hue table) and can never
        // drift from the orb's cyan.
        case .speaking:   return OrbGlowMap.entry(for: .speaking).glowHue
        }
    }
}

enum GlowEdge {
    case top, bottom, left, right
}

// A transparent, click-through NSWindow that sits on ONE edge of the target
// window. Four of these wrap a window without covering its interior.
@MainActor
final class GlowEdgeWindow: NSWindow {
    let edge: GlowEdge

    // Outward thickness from the target window edge.
    static let glowThickness: CGFloat = 20
    // How far the edge window overlaps INTO the target window (seamless edge).
    static let overlap: CGFloat = 4

    init(edge: GlowEdge) {
        self.edge = edge
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .popUpMenu
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isMovableByWindowBackground = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.animationBehavior = .none
    }

    func calculateFrame(for targetRect: NSRect) -> NSRect {
        let thickness = Self.glowThickness
        let overlap = Self.overlap
        switch edge {
        case .top:
            return NSRect(
                x: targetRect.minX - thickness,
                y: targetRect.maxY - overlap,
                width: targetRect.width + (thickness * 2),
                height: thickness + overlap
            )
        case .bottom:
            return NSRect(
                x: targetRect.minX - thickness,
                y: targetRect.minY - thickness,
                width: targetRect.width + (thickness * 2),
                height: thickness + overlap
            )
        case .left:
            return NSRect(
                x: targetRect.minX - thickness,
                y: targetRect.minY - thickness,
                width: thickness + overlap,
                height: targetRect.height + (thickness * 2)
            )
        case .right:
            return NSRect(
                x: targetRect.maxX - overlap,
                y: targetRect.minY - thickness,
                width: thickness + overlap,
                height: targetRect.height + (thickness * 2)
            )
        }
    }

    func updateFrame(for targetRect: NSRect) {
        self.setFrame(calculateFrame(for: targetRect), display: true)
    }
}

// SwiftUI glow for a single edge. Uses MeshGradient on macOS 15+, falls back
// to an animated AngularGradient on macOS 14.
struct GlowEdgeView: View {
    let edge: GlowEdge
    let colorMode: GlowColorMode

    @State private var phase: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        GeometryReader { _ in
            ZStack {
                animatedGradient
                    .mask(edgeFadeMask)
                    .blur(radius: 8)
                animatedGradient
                    .mask(edgeFadeMask)
                    .blur(radius: 2)
                    .opacity(0.8)
            }
            .opacity(opacity)
        }
        .onAppear { startAnimation() }
    }

    // Fade the glow toward the interior of the target window so edges blend
    // into the content rather than forming a hard inner edge.
    @ViewBuilder
    private var edgeFadeMask: some View {
        switch edge {
        case .top:
            LinearGradient(colors: [.white, .white, .clear], startPoint: .top, endPoint: .bottom)
        case .bottom:
            LinearGradient(colors: [.clear, .white, .white], startPoint: .top, endPoint: .bottom)
        case .left:
            LinearGradient(colors: [.white, .white, .clear], startPoint: .leading, endPoint: .trailing)
        case .right:
            LinearGradient(colors: [.clear, .white, .white], startPoint: .leading, endPoint: .trailing)
        }
    }

    @ViewBuilder
    private var animatedGradient: some View {
        if #available(macOS 15.0, *) {
            meshGradientView
        } else {
            fallbackGradientView
        }
    }

    @available(macOS 15.0, *)
    private var meshGradientView: some View {
        let animatedPhase = phase
        return MeshGradient(
            width: 3,
            height: 3,
            points: meshPoints(phase: animatedPhase),
            colors: meshColors(phase: animatedPhase)
        )
    }

    private var fallbackGradientView: some View {
        let shift = phase
        let base = colorMode.baseHue
        return AngularGradient(
            gradient: Gradient(colors: [
                Color(hue: normalizeHue(base + shift * 0.05), saturation: 0.9, brightness: 0.9),
                Color(hue: normalizeHue(base + 0.04 + shift * 0.03), saturation: 0.85, brightness: 0.95),
                Color(hue: normalizeHue(base - 0.03 - shift * 0.05), saturation: 0.9, brightness: 0.85),
                Color(hue: normalizeHue(base + 0.07 + shift * 0.04), saturation: 0.8, brightness: 0.9),
                Color(hue: normalizeHue(base + 0.02), saturation: 0.7, brightness: 1.0),
                Color(hue: normalizeHue(base - 0.05 - shift * 0.04), saturation: 0.85, brightness: 0.9),
                Color(hue: normalizeHue(base + shift * 0.05), saturation: 0.9, brightness: 0.9)
            ]),
            center: .center,
            startAngle: .degrees(phase * 360),
            endAngle: .degrees(phase * 360 + 360)
        )
    }

    private func normalizeHue(_ hue: Double) -> Double {
        var h = hue
        while h < 0 { h += 1 }
        while h > 1 { h -= 1 }
        return h
    }

    private func meshPoints(phase: CGFloat) -> [SIMD2<Float>] {
        let wobble = Float(sin(phase * .pi * 2) * 0.05)
        let wobble2 = Float(cos(phase * .pi * 2) * 0.05)
        return [
            SIMD2(0.0, 0.0),
            SIMD2(0.5 + wobble, 0.0),
            SIMD2(1.0, 0.0),
            SIMD2(0.0, 0.5 + wobble2),
            SIMD2(0.5 + wobble2, 0.5 + wobble),
            SIMD2(1.0, 0.5 - wobble2),
            SIMD2(0.0, 1.0),
            SIMD2(0.5 - wobble, 1.0),
            SIMD2(1.0, 1.0)
        ]
    }

    private func meshColors(phase: CGFloat) -> [Color] {
        let shift = phase
        let base = colorMode.baseHue
        return [
            Color(hue: normalizeHue(base + shift * 0.05), saturation: 0.9, brightness: 0.9),
            Color(hue: normalizeHue(base + 0.04 + shift * 0.03), saturation: 0.85, brightness: 0.95),
            Color(hue: normalizeHue(base - 0.03 - shift * 0.05), saturation: 0.9, brightness: 0.85),
            Color(hue: normalizeHue(base + 0.07 + shift * 0.04), saturation: 0.8, brightness: 0.9),
            Color(hue: normalizeHue(base + 0.02), saturation: 0.7, brightness: 1.0),
            Color(hue: normalizeHue(base - 0.05 - shift * 0.04), saturation: 0.85, brightness: 0.9),
            Color(hue: normalizeHue(base - 0.02 - shift * 0.03), saturation: 0.9, brightness: 0.85),
            Color(hue: normalizeHue(base + 0.02 + shift * 0.05), saturation: 0.85, brightness: 0.9),
            Color(hue: normalizeHue(base + 0.06 + shift * 0.03), saturation: 0.9, brightness: 0.88)
        ]
    }

    private func startAnimation() {
        // Appearance: decorative-motion opt-out. Show a steady glow for the
        // same dwell time, but skip the hue wobble pulses and the fades.
        guard !GruxTheme.reduceMotion else {
            opacity = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionTokens.ambient) {
                opacity = 0.0
            }
            return
        }
        withAnimation(.easeIn(duration: MotionTokens.slow)) {
            opacity = 1.0
        }
        withAnimation(.easeInOut(duration: MotionTokens.glowWobblePeriod).repeatCount(3, autoreverses: true)) {
            phase = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionTokens.ambient) {
            withAnimation(.easeOut(duration: MotionTokens.glowFadeOut)) {
                opacity = 0.0
            }
        }
    }
}
