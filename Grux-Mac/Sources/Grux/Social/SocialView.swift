import SwiftUI
import WebKit

// SocialView: the Command-group tab that embeds a self-hosted social tuning
// dashboard (an autonomous posting orchestrator's control surface) directly
// inside Grux via a WKWebView, so the social posting + engagement tuning lives
// next to the rest of the command tabs instead of a separate browser tab.
//
// The dashboard is the USER'S OWN service and its address comes from
// `GruxConfig.socialDashboardURL`, which is EMPTY by default. Unconfigured, the
// tab renders a "not configured" panel rather than reaching for a host it
// cannot resolve. Grux permits arbitrary loads (Info.plist
// NSAllowsArbitraryLoads) and outbound client networking (Grux.entitlements
// com.apple.security.network.client), so a plain-http host on a private network
// loads without extra config. The web view follows the same NSViewRepresentable
// pattern as BrandedEmailWebView in JaxDraftsSection.
struct SocialView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var reloadToken = 0

    // nil when nothing is configured, or when what is configured is not a
    // loadable absolute URL. Both cases land on the same setup panel, which is
    // why this resolves to an Optional instead of force-unwrapping.
    @MainActor
    private var dashboardURL: URL? {
        let raw = appState.config.socialDashboardURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Social")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                // Says what the tab DOES, for someone who has never seen it.
                // "Threads orchestrator tuning" named one operator's own
                // posting pipeline: three words, none of which tell a stranger
                // that this tab embeds a dashboard they point at themselves.
                Text("Your posting dashboard, embedded")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                if dashboardURL != nil {
                    Button("Reload") { reloadToken += 1 }
                        .buttonStyle(.borderless)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .help("Reload the dashboard")
                }
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            if let url = dashboardURL {
                SocialDashboardWebView(url: url, reloadToken: reloadToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                notConfigured
            }
        }
    }

    // Was an icon, "No social dashboard configured", and "Point Settings at your
    // own tuning dashboard to embed it here." Both lines were true and neither
    // helped: a stranger cannot know that "your own tuning dashboard" means a
    // board the author runs for his own brands, so the tab read as broken.
    private var notConfigured: some View {
        OperatorToolNoticeView(tool: .social)
    }
}

// Loads the dashboard once and reloads on demand when reloadToken changes.
// Mirrors BrandedEmailWebView (JaxDraftsSection.swift): a thin NSViewRepresentable
// wrapper around WKWebView. The dashboard renders its own dark theme, so the
// web view keeps its default opaque background rather than drawing transparent.
private struct SocialDashboardWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return w
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reload only when the token changes (the Reload button), so SwiftUI
        // re-renders do not thrash the page or lose scroll position.
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken = -1
    }
}
