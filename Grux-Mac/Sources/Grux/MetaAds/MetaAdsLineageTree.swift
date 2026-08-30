import SwiftUI

// The lineage visualizer: the single-parent forest as an indented tree. Gen-0
// roots at the left, children indented under their parent, each node a
// status-tinted dot with a label and a CPA tag, each edge labeled with the ONE
// changed variable. Self-contained layout, no extra dependencies.
struct MetaAdsLineageTree: View {
    let nodes: [LineageNode]
    var onSelectNode: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetaAdsEyebrow(text: "Lineage forest", icon: "point.3.connected.trianglepath.dotted", tint: GruxTheme.accentPrimary)
            if nodes.isEmpty {
                // Names what would fill it. "No lineage yet." on its own left
                // a reader unable to tell an unconfigured engine from a working
                // one that has simply not branched an ad.
                VStack(alignment: .leading, spacing: 3) {
                    Text("No lineage yet.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GruxTheme.textTertiary)
                    Text("The forest fills in once the engine branches a winning ad into variants.")
                        .font(.system(size: 10))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(roots) { root in
                    VStack(alignment: .leading, spacing: 5) {
                        nodeRow(root, depth: 0)
                        ForEach(descendants(of: root.id)) { child in
                            nodeRow(child, depth: child.generation)
                        }
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                }
            }
        }
    }

    private var roots: [LineageNode] {
        nodes.filter { $0.parentId == nil }.sorted { $0.crid < $1.crid }
    }

    // Children in a stable depth-first order under a root. A visited set guards
    // against a cyclic parent_id (which the single-parent forest invariant should
    // prevent, but a corrupted local snapshot file could violate) so a cycle can
    // never hang the main thread.
    private func descendants(of rootId: String) -> [LineageNode] {
        var out: [LineageNode] = []
        var visited: Set<String> = [rootId]
        func walk(_ parentId: String) {
            let kids = nodes.filter { $0.parentId == parentId }.sorted { $0.generation < $1.generation }
            for k in kids where !visited.contains(k.id) {
                visited.insert(k.id)
                out.append(k)
                walk(k.id)
            }
        }
        walk(rootId)
        return out
    }

    private func nodeRow(_ node: LineageNode, depth: Int) -> some View {
        Button { onSelectNode(node.id) } label: {
            HStack(spacing: 8) {
                if depth > 0 {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)
                        .padding(.leading, CGFloat(depth) * 14)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                Circle().fill(tint(node.status)).frame(width: 8, height: 8)
                    .shadow(color: tint(node.status).opacity(0.6), radius: 3)
                Text(node.label ?? node.id)
                    .font(.system(size: 12, weight: depth == 0 ? .bold : .medium))
                    .foregroundStyle(depth == 0 ? GruxTheme.textPrimary : GruxTheme.textSecondary)
                    .lineLimit(1)
                if let v = node.changedVariable, depth > 0 {
                    Text(v.uppercased())
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.14)))
                }
                Spacer(minLength: 6)
                if let cpa = node.cpaCents {
                    Text(MetaAdsFormat.dollars(cpa))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GruxTheme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func tint(_ status: String?) -> Color {
        switch (status ?? "").lowercased() {
        case "winner", "scaling", "scale": return GruxTheme.successMint
        case "killed", "killing", "archived": return GruxTheme.destructiveRose
        case "paused": return GruxTheme.textTertiary
        case "learning", "do_not_judge", "testing": return GruxTheme.accentPrimaryLight
        default: return GruxTheme.accentCo
        }
    }
}
