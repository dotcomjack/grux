import SwiftUI

// CognitionConstellation: the "map" header. A constellation-style layout built
// PURELY from real data:
//   * one node per most-fired heuristic, sized by how often it fired,
//   * edges drawn from each recent decision to the heuristics it actually used,
//   * node + edge color from the real computed confidence of those decisions.
//
// This is a visual index of real provenance, NOT a depiction of a brain or any
// neural signal. Pure SwiftUI Canvas + shapes, no external assets. If there is no
// real data the parent shows an empty state instead of this view.
//
// VISUAL: the constellation is ALIVE, never static (a TimelineView drives ambient
// motion): nodes breathe and drift gently, a soft sheen sweeps the field, and the
// decision-to-heuristic edges flow. Crucially, the motion is DECORATIVE ambient
// life, not a depiction of neural firing: every node, edge, size and color still
// comes only from the real trace (heuristic fire counts + real decision
// confidence), and the honesty caption stays. The animation makes the surface
// feel current; it never invents or implies a signal.
//
// Inputs are the published CognitionTrace rollup/event types (referenced, not
// redefined): topHeuristics are (name, count) pairs; recent events expose their
// fired-heuristic names and a confidence score.

struct CognitionConstellation: View {
    let nodes: [CognitionHeuristicStat]   // most-fired heuristics, desc by count
    let events: [CognitionEvent]          // a few most-recent decisions

    private static let height: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetaAdsEyebrow(text: "Heuristic constellation", icon: "point.3.connected.trianglepath.dotted", tint: GruxTheme.accentPrimaryLight)

            // TimelineView drives continuous ambient motion. Being on screen is
            // NOT on its own a reason to keep ticking: the tab stays instantiated
            // while the app sits in the background, where 40fps buys nobody
            // anything. `paused:` is what the three Reactor timelines already do,
            // and this one was the only ambient timeline missing it.
            TimelineView(.animation(minimumInterval: 1.0 / 40.0,
                                    paused: GruxTheme.reduceMotion)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let layout = self.layout(in: geo.size)
                    ZStack {
                        sheen(t: t)
                        edges(layout: layout, size: geo.size, t: t)
                        ForEach(layout.placed) { p in
                            nodeView(p, t: t)
                                .position(drift(p.point, name: p.name, t: t))
                        }
                    }
                }
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [GruxTheme.accentPrimary.opacity(0.12), Color.white.opacity(0.02)],
                                center: .center, startRadius: 8, endRadius: 300
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
            }

            Text("Node size = how often that heuristic fired. Lines = recent decisions that used it. Color = the real confidence of those decisions. The motion is ambient, not a neural signal.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ambient motion helpers

    // Stable per-node phase so each node breathes/drifts on its own offset.
    private func phase(for name: String) -> Double {
        Double(abs(name.hashValue % 1000)) / 1000.0 * 2 * .pi
    }

    // A small orbital sway applied to BOTH the node and its edge endpoints, so
    // the edges stay visually attached as nodes drift.
    private func drift(_ pt: CGPoint, name: String, t: Double) -> CGPoint {
        let ph = phase(for: name)
        let dx = CGFloat(sin(t * 0.40 + ph)) * 3.0
        let dy = CGFloat(cos(t * 0.33 + ph)) * 3.0
        return CGPoint(x: pt.x + dx, y: pt.y + dy)
    }

    // A slow angular sheen sweeping the field, low opacity, additive. Ambient
    // depth, carries no data.
    private func sheen(t: Double) -> some View {
        // Performance: the gradient + 26pt gaussian blur are built at a FIXED
        // angle so SwiftUI can rasterize and cache them once; the sweep is then a
        // cheap per-frame rotation transform of that cached layer, instead of
        // recomputing the blur every tick (which a t-dependent gradient angle
        // would force).
        AngularGradient(
            gradient: Gradient(colors: [
                GruxTheme.accentPrimary.opacity(0.0),
                GruxTheme.accentPrimaryLight.opacity(0.10),
                GruxTheme.accentPrimary.opacity(0.0)
            ]),
            center: .center,
            angle: .radians(0)
        )
        .blendMode(.plusLighter)
        .blur(radius: 26)
        .padding(10)
        .rotationEffect(.radians(t * 0.18))
    }

    // MARK: Edges

    private func edges(layout: ConstellationLayout, size: CGSize, t: Double) -> some View {
        Canvas { ctx, _ in
            // For each recent event, connect it to the placed nodes for the
            // heuristics it actually fired. Edge brightness tracks real confidence;
            // the flowing dash is ambient life, not a fabricated intensity.
            for (i, event) in events.enumerated() {
                let baseAnchor = layout.eventAnchor(index: i, count: events.count, size: size)
                let anchor = drift(baseAnchor, name: "event-\(i)", t: t)
                let conf = event.confidence ?? 0
                let tint = CognitionFormat.confidenceTint(conf)
                for name in event.firedHeuristicNames {
                    guard let base = layout.point(forHeuristic: name) else { continue }
                    let target = drift(base, name: name, t: t)
                    var path = Path()
                    path.move(to: anchor)
                    let mid = CGPoint(x: (anchor.x + target.x) / 2,
                                      y: (anchor.y + target.y) / 2 - 18)
                    path.addQuadCurve(to: target, control: mid)
                    // Flowing dashes travel from decision toward the heuristic it
                    // used. Real confidence still drives the glow.
                    let flow = StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                           dash: [3, 7], dashPhase: CGFloat(-t * 16))
                    ctx.stroke(path,
                               with: .color(tint.opacity(0.16 + 0.34 * max(0, min(1, conf)))),
                               style: flow)
                }
                // The decision spark itself, gently pulsing.
                let pulse = 0.5 + 0.5 * sin(t * 2.0 + Double(i) * 0.9)
                let r = 3.0 + 1.6 * pulse
                let dot = Path(ellipseIn: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(tint.opacity(0.55 + 0.35 * pulse)))
            }
        }
    }

    // MARK: Node

    private func nodeView(_ p: PlacedNode, t: Double) -> some View {
        let d = p.diameter
        let ph = phase(for: p.name)
        // Breathing scale + a glow that swells with the breath; busier nodes glow
        // harder. Decorative, derived from the real fire count.
        let breath = 0.5 + 0.5 * sin(t * 1.15 + ph)
        let scale = 1.0 + 0.06 * breath
        // Performance: hold the shadow RADIUS constant (so its blur rasterizes
        // once and is reused) and breathe the glow via the shadow color's opacity
        // instead, which is a cheap retint rather than a per-frame blur recompute.
        let glowRadius: CGFloat = p.count >= 3 ? 11 : 6
        let glowOpacity = 0.35 + 0.45 * breath
        return ZStack {
            Circle()
                .fill(GruxTheme.iridescent)
                .opacity(0.30)
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(GruxTheme.accentPrimaryLight.opacity(0.60), lineWidth: 1))
                .shadow(color: GruxTheme.violetGlow(strong: p.count >= 3).opacity(glowOpacity), radius: glowRadius)
            Text("\(p.count)")
                .font(.system(size: min(13, max(9, d * 0.35)), weight: .heavy, design: .rounded))
                .foregroundStyle(GruxTheme.textPrimary)
        }
        .scaleEffect(scale)
        .overlay(alignment: .bottom) {
            Text(p.shortName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(GruxTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .offset(y: d / 2 + 9)
        }
        .help(p.name)
    }

    // MARK: Layout

    private struct PlacedNode: Identifiable {
        let id = UUID()
        let name: String
        let shortName: String
        let count: Int
        let point: CGPoint
        let diameter: CGFloat
    }

    private struct ConstellationLayout {
        let placed: [PlacedNode]
        private let byName: [String: CGPoint]

        init(placed: [PlacedNode]) {
            self.placed = placed
            var m: [String: CGPoint] = [:]
            for p in placed { m[p.name] = p.point }
            byName = m
        }

        func point(forHeuristic name: String) -> CGPoint? { byName[name] }

        // Decisions anchor across the top of the canvas, evenly spread.
        func eventAnchor(index: Int, count: Int, size: CGSize) -> CGPoint {
            let span = size.width - 48
            let step = count > 1 ? span / CGFloat(count - 1) : 0
            let x = 24 + (count > 1 ? CGFloat(index) * step : span / 2)
            return CGPoint(x: x, y: 22)
        }
    }

    private func layout(in size: CGSize) -> ConstellationLayout {
        let cap = min(nodes.count, 9)
        let shown = Array(nodes.prefix(cap))
        guard !shown.isEmpty else { return ConstellationLayout(placed: []) }

        let maxCount = max(1, shown.map(\.count).max() ?? 1)
        let cx = size.width / 2
        let cy = size.height * 0.58
        let radius = min(size.width, size.height * 1.4) * 0.30

        var placed: [PlacedNode] = []
        if shown.count == 1 {
            placed.append(node(shown[0], maxCount: maxCount, point: CGPoint(x: cx, y: cy)))
        } else {
            for (i, stat) in shown.enumerated() {
                // Distribute on a ring; the busiest node sits nearest center-bottom.
                let angle = (Double(i) / Double(shown.count)) * 2 * .pi - .pi / 2
                let r = radius * (0.7 + 0.5 * (1 - Double(stat.count) / Double(maxCount)))
                let x = cx + CGFloat(cos(angle)) * r
                let y = cy + CGFloat(sin(angle)) * r * 0.72
                placed.append(node(stat, maxCount: maxCount, point: CGPoint(x: x, y: y)))
            }
        }
        return ConstellationLayout(placed: placed)
    }

    private func node(_ stat: CognitionHeuristicStat, maxCount: Int, point: CGPoint) -> PlacedNode {
        let ratio = Double(stat.count) / Double(maxCount)
        let diameter = CGFloat(28 + ratio * 30)   // 28..58 by fire count
        return PlacedNode(
            name: stat.name,
            shortName: Self.shorten(stat.name),
            count: stat.count,
            point: point,
            diameter: diameter
        )
    }

    private static func shorten(_ name: String) -> String {
        name.count <= 16 ? name : String(name.prefix(15)) + "\u{2026}"
    }
}
