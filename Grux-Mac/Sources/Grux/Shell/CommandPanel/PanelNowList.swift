import SwiftUI

/// Renders what `Relevance.now` decided. One line, a glyph, one action.
struct PanelNowList: View {
    let items: [PanelItem]
    var onAction: (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text(PanelCopy.nowHeading.uppercased())
                .font(GruxType.microCaps)
                .kerning(GruxType.microCapsTracking)
                .foregroundStyle(GruxTheme.textTertiary)
            if items.isEmpty {
                // The empty state names the palette, the path to everything
                // that has not earned a Recent chip (spec 3.5).
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    Text(PanelCopy.nothingNeedsYou)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                    Text(PanelCopy.paletteHint)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                .padding(.vertical, GruxSpacing.s)
            } else {
                ForEach(items) { item in
                    Button { onAction(item.action) } label: {
                        HStack(spacing: GruxSpacing.s) {
                            Image(systemName: item.icon)
                                .font(GruxType.caption)
                                .foregroundStyle(color(for: item.cls))
                                .frame(width: GruxSpacing.l)
                            Text(item.title)
                                .font(GruxType.body)
                                .foregroundStyle(GruxTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: GruxSpacing.s)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, GruxSpacing.s)
                        .padding(.horizontal, GruxSpacing.m)
                        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                            .fill(GruxTheme.textTertiary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .task(id: items) {
            await Task.yield()
            RenderedNow.note(items)
        }
    }

    private func color(for cls: PanelItem.Class) -> Color {
        switch cls {
        case .needsYou: return GruxTheme.warnAmber
        case .running: return GruxTheme.accentPrimary
        case .next: return GruxTheme.textPrimary
        case .suggested: return GruxTheme.textSecondary
        }
    }
}

/// `~/.grux/rendered-now.txt`: the rows the Now list last drew, one per line
/// as `class | title | detail | action`, empty when Now is empty. Written after
/// the list updates, like `rendered-tab.txt`, so a headless check reads what
/// the person would see.
enum RenderedNow {
    static var fileURL: URL { Persistence.gruxDir.appendingPathComponent("rendered-now.txt") }
    static func text(_ items: [PanelItem]) -> String {
        items.map { "\($0.cls) | \($0.title) | \($0.detail) | \($0.action)\n" }.joined()
    }
    static func note(_ items: [PanelItem]) {
        try? text(items).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
