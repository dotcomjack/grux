import SwiftUI

// A tiny reusable line/area sparkline. Feed it an Int series (oldest to newest)
// and it draws a smoothed area + line, with an optional cap reference line and a
// dot on the last point. Pure init-arg view, no store dependency, so the ad row,
// the ad detail, and the forecast card all share it.
struct MetaAdsSparkline: View {
    let series: [Int]
    var tint: Color = GruxTheme.accentCo
    var capLine: Int? = nil
    var showLastDot: Bool = true

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count >= 2 {
                    // Area fill under the line.
                    areaPath(pts, height: geo.size.height)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    // The line itself.
                    linePath(pts)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    // Cap reference line.
                    if let cap = capLine, let y = capY(cap, height: geo.size.height) {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(GruxTheme.textTertiary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    }
                    if showLastDot, let last = pts.last {
                        Circle().fill(tint).frame(width: 4, height: 4).position(last)
                    }
                } else {
                    Rectangle().fill(Color.clear)
                }
            }
        }
    }

    private var bounds: (lo: Double, hi: Double) {
        var values = series.map(Double.init)
        if let cap = capLine { values.append(Double(cap)) }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        return (lo, hi == lo ? hi + 1 : hi)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard series.count >= 2 else { return [] }
        let (lo, hi) = bounds
        let stepX = size.width / CGFloat(series.count - 1)
        return series.enumerated().map { i, v in
            let x = CGFloat(i) * stepX
            let norm = (Double(v) - lo) / (hi - lo)
            let y = size.height - CGFloat(norm) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func capY(_ cap: Int, height: CGFloat) -> CGFloat? {
        let (lo, hi) = bounds
        let norm = (Double(cap) - lo) / (hi - lo)
        return height - CGFloat(norm) * height
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        Path { p in
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        Path { p in
            guard let first = pts.first, let last = pts.last else { return }
            p.move(to: CGPoint(x: first.x, y: height))
            for pt in pts { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.closeSubpath()
        }
    }
}
