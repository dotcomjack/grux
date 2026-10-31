import SwiftUI

/// Renders what `Relevance.now` decided. One line, a glyph, one action.
struct PanelNowList: View {
    let items: [PanelItem]
    var onAction: (PanelAction) -> Void
    @Environment(\.gruxChipCuts) private var cuts

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
                    HStack(spacing: GruxSpacing.xs) {
                    Button { onAction(item.action) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.s) {
                            Image(systemName: item.icon)
                                .font(GruxType.caption)
                                .foregroundStyle(color(for: item.cls))
                                .frame(width: GruxSpacing.l)
                            // The detail is what to do about the row, so it
                            // reads whole: beside the title when both fit, and
                            // otherwise under it, wrapped. On one line it read
                            // "Agents cannot run until you si..." on every pane
                            // at the default window (D68).
                            GruxTitleActionsLayout(spacing: GruxSpacing.s) {
                                Text(item.title)
                                    .font(GruxType.body)
                                    .foregroundStyle(GruxTheme.textPrimary)
                                    .lineLimit(1)
                                if !item.detail.isEmpty {
                                    GruxTextCutProbe(text: item.detail, cuts: cuts) {
                                        detail(item.detail).fixedSize(horizontal: false, vertical: true)
                                        detail(item.detail).fixedSize(horizontal: false, vertical: true).hidden()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, GruxSpacing.s)
                        .padding(.horizontal, GruxSpacing.m)
                        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                            .fill(GruxTheme.textTertiary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    // The one row with a second choice (the update offer's Not now).
                    if let dismiss = item.dismiss {
                        Button(PanelCopy.notNow) { onAction(dismiss) }
                            .buttonStyle(.plain)
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                            .accessibilityLabel(PanelCopy.notNowLabel(item.title))
                    }
                    }
                }
            }
        }
        .task(id: items) {
            await Task.yield()
            RenderedNow.note(items)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(GruxType.caption)
            .foregroundStyle(GruxTheme.textTertiary)
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
        items.map { item in
            let dismiss = item.dismiss.map { " | \(PanelCopy.notNow): \($0)" } ?? ""
            return "\(item.cls) | \(item.title) | \(item.detail) | \(item.action)\(dismiss)\n"
        }.joined()
    }
    static func note(_ items: [PanelItem]) {
        try? text(items).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
