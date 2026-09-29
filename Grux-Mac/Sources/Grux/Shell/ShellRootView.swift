import SwiftUI
import Combine

/// The launch window's root: the Command Panel, or the classic sidebar shell
/// when `legacyShell` is on. The switch is live. A toggle rebuilds the root
/// (keyed on the flag, so no state leaks between the two) and resizes the
/// window to the new shell's floor.
struct ShellRootView: View {
    @State private var legacy: Bool
    @State private var tab: String

    init(defaultTab: String) {
        _legacy = State(initialValue: AppState.shared.config.legacyShell)
        _tab = State(initialValue: defaultTab)
    }

    var body: some View {
        Group {
            if legacy {
                LaunchRootView(defaultTab: tab)
            } else {
                CommandPanelRoot(defaultTab: tab)
            }
        }
        .id(legacy)
        // Only the flag, not every config change: the root must not redraw
        // the whole window for a slider in Settings.
        .onReceive(AppState.shared.$config.map(\.legacyShell).removeDuplicates()) { flag in
            guard flag != legacy else { return }
            // Each shell lands where it lands at launch.
            tab = flag ? "home" : PanelKeys.none
            legacy = flag
            // The classic shell applies its launch tab without writing it
            // back, so requestedTab would keep the pane's key and a later
            // request for that key would be no change at all. The panel
            // clears its own on landing (R5.18).
            if flag, AppState.shared.requestedTab != "home" { AppState.shared.requestedTab = "home" }
            AppDelegate.shared?.applyLaunchWindowShell(legacy: flag)
            AppDelegate.shared?.applyLaunchWindowLevel()
        }
        .onReceive(AppState.shared.$config.map(\.keepOnTop).removeDuplicates()) { _ in
            AppDelegate.shared?.applyLaunchWindowLevel()
        }
    }
}
