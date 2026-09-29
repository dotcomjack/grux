import SwiftUI

/// The button at the trailing end of the launch window's title bar. With a
/// pane open it closes it back to the panel; with none, it brings the last
/// one back. It reads the open state from `requestedTab`, which the panel
/// writes on every open and resets on every close, and it acts through
/// `.gruxTogglePane`, so the panel model stays the one owner of the pane.
struct PaneToggleButton: View {
    @EnvironmentObject private var state: AppState

    private var paneOpen: Bool { state.requestedTab != PanelKeys.none }

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .gruxTogglePane, object: nil)
        } label: {
            Image(systemName: "sidebar.right")
                .font(GruxType.body)
                .foregroundStyle(paneOpen ? GruxTheme.accentPrimary : GruxTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs)
        .help(paneOpen ? PanelCopy.hidePane : PanelCopy.showPane)
        .accessibilityLabel(paneOpen ? PanelCopy.hidePane : PanelCopy.showPane)
    }
}

/// The title bar accessory that holds the button, for the Command Panel's
/// launch window only.
@MainActor
enum PaneToggleAccessory {
    static func make(hidden: Bool) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        let host = NSHostingView(rootView: PaneToggleButton().environmentObject(AppState.shared))
        // The accessory's width is its view's frame. Without one it is zero
        // wide and the button draws nowhere.
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        accessory.view = host
        accessory.layoutAttribute = .trailing
        accessory.isHidden = hidden
        return accessory
    }
}
