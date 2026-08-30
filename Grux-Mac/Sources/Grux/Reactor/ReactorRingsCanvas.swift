import SwiftUI

// The reactor instrument layer: four concentric telemetry arc-gauges plus a
// slow radar sweep, all drawn in ONE Canvas inside ONE TimelineView so the
// whole animated ring assembly costs a single timeline tick per frame (the
// CognitionConstellation budget discipline). Each ring binds to a real Grux
// store value via ReactorMetrics; no mock data. Motion is gated on
// GruxTheme.reduceMotion so an opted-out user gets a still, readable instrument.

// One ring's resolved state, computed by ReactorView from live stores.
struct ReactorRing: Equatable {
    let label: String
    let fraction: Double      // 0...1 arc fill (the HONEST data value, no render floor)
    let readout: String       // precomputed label value ("29/56", "83", "$0.42")
    let tint: Color
    let dashed: Bool          // agents "data-ring" reads as a dashed flow
    let dim: Bool             // true when the underlying store has nothing (honest empty)
}

struct ReactorMetrics: Equatable {
    var tasks: ReactorRing
    var mail: ReactorRing
    var agents: ReactorRing

    var rings: [ReactorRing] { [tasks, mail, agents] }
}

struct ReactorRingsCanvas: View {
    let metrics: ReactorMetrics
    let accent: Color
    var reduceMotion: Bool = false
    /// Radius of the innermost ring (just outside the orb). Outer rings step out.
    var innerRadius: CGFloat = 130
    var ringSpacing: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let t = reduceMotion
                    ? 0
                    : timeline.date.timeIntervalSinceReferenceDate

                // Radar sweep first so the rings draw over its faint wedge.
                drawRadar(ctx, center: center, t: t)

                for (i, ring) in metrics.rings.enumerated() {
                    let radius = innerRadius + CGFloat(i) * ringSpacing
                    // Each ring counter-rotates at a slightly different slow rate
                    // so the assembly feels alive without spinning fast.
                    let dir: Double = (i % 2 == 0) ? 1 : -1
                    let baseAngle = t * (4.0 + Double(i) * 1.5) * dir
                    drawRing(ctx, center: center, radius: radius, ring: ring, baseAngleDeg: baseAngle)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawRing(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat,
                          ring: ReactorRing, baseAngleDeg: Double) {
        let lineWidth: CGFloat = ring.dim ? 1.5 : 3.0
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)

        // Faint full track so an empty/low ring still reads as an instrument.
        var track = Path()
        track.addEllipse(in: rect)
        ctx.stroke(track, with: .color(.white.opacity(0.06)),
                   style: StrokeStyle(lineWidth: 1, dash: ring.dashed ? [2, 6] : []))

        guard ring.fraction > 0.001 else { return }

        // The value arc, starting at the top and sweeping clockwise, offset by
        // the ring's slow base rotation. A render-only floor keeps a tiny real
        // value visible without inflating the underlying data (the readout label
        // still shows the honest number).
        let sweep = max(min(1, ring.fraction), 0.025)
        let start = Angle(degrees: -90 + baseAngleDeg)
        let end = Angle(degrees: -90 + baseAngleDeg + 360 * sweep)
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)

        let opacity = ring.dim ? 0.35 : 0.95
        let dash: [CGFloat] = ring.dashed ? [6, 5] : []
        ctx.stroke(arc, with: .color(ring.tint.opacity(opacity)),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))

        // Glowing leading tip: a soft filled dot at the arc's end angle.
        if !ring.dim {
            let tipAngle = end.radians
            // CGFloat(...) around the trig result, not around the angle. `radius`
            // is CGFloat and `tipAngle` is Double, and `CGFloat * cos(Double)`
            // is genuinely ambiguous: the compiler can reach the result through
            // the Double overload plus a CGFloat conversion, or the CGFloat
            // overload directly. Swift 6.3 happens to pick one and Swift 6.0 on
            // a GitHub macos-15 runner refuses, so this built on the author's
            // machine and failed for everyone else. Converting once, explicitly,
            // makes every operand CGFloat and removes the choice.
            let tip = CGPoint(x: center.x + radius * CGFloat(cos(tipAngle)),
                              y: center.y + radius * CGFloat(sin(tipAngle)))
            var glow = ctx
            glow.addFilter(.blur(radius: 5))
            glow.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)),
                      with: .color(ring.tint.opacity(0.9)))
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5)),
                     with: .color(.white.opacity(0.95)))
        }
    }

    // A 70-degree fading wedge that sweeps once every several seconds, the
    // classic HUD radar tell. Drawn as a thin leading line plus a faint trail.
    private func drawRadar(_ ctx: GraphicsContext, center: CGPoint, t: Double) {
        let maxR = innerRadius + CGFloat(metrics.rings.count - 1) * ringSpacing + 8
        let sweep = (t * 36).truncatingRemainder(dividingBy: 360) // 10s per rev
        let trailDeg = 70.0
        var wedge = Path()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: maxR,
                     startAngle: .degrees(sweep - trailDeg), endAngle: .degrees(sweep),
                     clockwise: false)
        wedge.closeSubpath()
        ctx.fill(wedge, with: .radialGradient(
            Gradient(colors: [accent.opacity(0.0), accent.opacity(0.10)]),
            center: center, startRadius: 0, endRadius: maxR))

        let leadAngle = sweep * .pi / 180
        let lead = CGPoint(x: center.x + maxR * CGFloat(cos(leadAngle)),
                           y: center.y + maxR * CGFloat(sin(leadAngle)))
        var line = Path()
        line.move(to: center)
        line.addLine(to: lead)
        ctx.stroke(line, with: .linearGradient(
            Gradient(colors: [accent.opacity(0.0), accent.opacity(0.35)]),
            startPoint: center, endPoint: lead), lineWidth: 1)
    }
}
