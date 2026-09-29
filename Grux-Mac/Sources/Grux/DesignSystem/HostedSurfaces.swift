import SwiftUI

/// One surface a rail row hosts, and the words its switch shows.
struct HostedSurface: Identifiable {
    let tab: LaunchRootView.Tab
    let label: String
    var id: LaunchRootView.Tab { tab }

    init(_ tab: LaunchRootView.Tab, _ label: String) {
        self.tab = tab
        self.label = label
    }
}

/// ONE RAIL ROW, MORE THAN ONE SURFACE.
///
/// Phase C folds a surface into a parent instead of deleting its row. Tasks
/// hosts Projects, and Studio hosts Design Studio, Media Studio and Research.
/// The switch at the top is the visible label that keeps each one findable
/// after its own row is gone. It is the same segmented control Data and
/// Security uses for its sub-panes, so a fold moves a surface and restyles
/// nothing.
///
/// The switch is bound to the window's own tab selection rather than to a
/// state of its own. That is what keeps every locked `--open-tab` key
/// working: `research` still selects the research tab, and the research tab
/// renders Studio with Research showing.
struct HostedSurfaces<Content: View>: View {
    let surfaces: [HostedSurface]
    @Binding var selection: LaunchRootView.Tab
    @ViewBuilder let content: (LaunchRootView.Tab) -> Content

    init(_ surfaces: [HostedSurface],
         selection: Binding<LaunchRootView.Tab>,
         @ViewBuilder content: @escaping (LaunchRootView.Tab) -> Content) {
        self.surfaces = surfaces
        self._selection = selection
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented where its labels fit beside the badge, a menu where
            // they do not: at the pane's 360pt floor the Studio row's three
            // labels pushed the BETA badge off the edge.
            ViewThatFits(in: .horizontal) {
                switchRow { picker.pickerStyle(.segmented) }
                switchRow { picker.pickerStyle(.menu).frame(maxWidth: GruxLayout.settingsMenuPickerMax) }
            }
            .padding(.horizontal, GruxSpacing.l)
            .padding(.top, GruxSpacing.m)
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(surfaces) { Text($0.label).tag($0.tab) }
        }
        .labelsHidden()
    }

    private func switchRow<P: View>(@ViewBuilder _ styled: () -> P) -> some View {
        HStack(spacing: GruxSpacing.s) {
            // Sized to its labels rather than stretched across the pane,
            // so it reads as a switch between places and not as one more
            // row of the surface underneath it.
            styled()
                .fixedSize()
            // A labs surface keeps its label when it loses its rail row.
            // Onboarding promises labs features are labelled before
            // anybody relies on one, and the row's pill was that label.
            if FeatureRegistry.isLabs(forTab: LaunchRootView.tabKey(for: selection)) {
                BetaBadge()
            }
            Spacer(minLength: 0)
        }
    }
}
