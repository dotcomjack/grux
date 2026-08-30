import SwiftUI

// Blueprint 02: the consistent tab/pane header. Title (or display-size hero
// title) plus optional subtitle on the left, caller-supplied controls in the
// trailing builder. The toolbar does NOT inject a Spacer: callers place one
// in `trailing` so leading-aligned controls (search fields, filters) stay
// possible. Standard gutter: GruxSpacing.m horizontal, GruxSpacing.s vertical.
struct GruxToolbar<Trailing: View>: View {
    enum Style { case title, display }

    let title: String
    var subtitle: String? = nil
    var style: Style = .title
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String,
         subtitle: String? = nil,
         style: Style = .title,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: GruxSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                // A page title truncates with an ellipsis; it never wraps. The
                // trailing() cluster competes for the same row, so without a
                // line limit a long title pushes the actions off the edge or
                // stacks itself into two lines and shoves the whole header
                // taller.
                Text(title)
                    .font(style == .display ? GruxType.display : GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            trailing()
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.vertical, GruxSpacing.s)
    }
}

extension GruxToolbar where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, style: Style = .title) {
        self.init(title, subtitle: subtitle, style: style) { EmptyView() }
    }
}

// The compact pill "New / action" button every tab header reinvented.
// Prominent (iridescent) or quiet (frosted) tone, 11pt semibold label.
struct GruxToolbarButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    var helpText: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GruxSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    // lineLimit only, matching GruxChip and for the same
                    // measured reason: fixedSize here makes the toolbar rigid,
                    // which over-commits the row and pushes the fixed nav rail
                    // into being drawn wider than the slot it was handed, where
                    // SwiftUI centres it and it bleeds off both edges.
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : GruxTheme.textSecondary)
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.xs + 2)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(GruxTheme.iridescent)
                                         : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(prominent ? 0.25 : 0.10), lineWidth: 0.8)
            )
            .shadow(color: prominent ? GruxTheme.violetGlow() : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
    }
}

// The standard frosted search field used in list columns and headers.
//
// `width` is optional and callers that pass one get a hard frame. That is a
// reflow hazard in a toolbar, so it is applied as an IDEAL with a floor and no
// ceiling below: a search field that cannot shrink pushes the buttons beside it
// off the edge at the 840pt window floor.
struct GruxSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: GruxSpacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(GruxTheme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(GruxTheme.textPrimary)
        }
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs + 2)
        // The caller's number is the CEILING, not a licence to grow. An earlier
        // version of this used `maxWidth: .infinity`, which turned a 220pt
        // field into the greediest thing in the header: idealWidth is ignored
        // under a definite proposal, so on a wide window the field and the
        // Spacer split everything the buttons left and Documents' search box
        // ballooned across the header. Ceiling at the ask, floor at
        // searchFieldMin, so it renders exactly as before and only gives ground
        // when the row genuinely runs out.
        .frame(minWidth: width == nil ? nil : GruxLayout.searchFieldMin,
               idealWidth: width, maxWidth: width)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
