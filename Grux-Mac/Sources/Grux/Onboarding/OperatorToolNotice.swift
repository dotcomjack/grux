import SwiftUI
import AppKit

/// The treatment for a surface that is somebody else's tooling.
///
/// WHY THIS EXISTS, AND WHY CapabilityGate COULD NOT DO IT.
///
/// The gate fires on a row's BLOCKING requirements. A feature whose requirements
/// are all optional is `.ready` by definition, so the gate is a no-op for it and
/// the tab renders whatever it renders with no data. For most tabs that is
/// correct and `GruxEmptyState` already covers it: an empty Notes tab is a Notes
/// tab you have not written in yet, and it says so.
///
/// Four surfaces are not that. Social, Meta Ads, Feature Review and Workflows are
/// tooling built to run one person's business. They are empty for a stranger not
/// because the stranger has not got round to it, but because the thing they point
/// at is somebody else's dashboard, somebody else's ad account, somebody else's
/// repository. "No social dashboard configured. Point Settings at your own tuning
/// dashboard to embed it here." is true and useless: it reads like a bug, and a
/// reader has no way to know that the author knows.
///
/// So this says it plainly, and then, at the end, hands over a prompt. A reader
/// who cannot use the tab as shipped is one paste away from an agent that reads
/// the actual source and retargets it at their own business. A dead end becomes
/// the strongest argument the project has: the code is right there and it is
/// yours to point somewhere else.
///
/// WORKFLOWS IS DELIBERATELY NOT IN THIS LIST, and it was, until the tab was
/// actually opened. Jack names it among his eight operator tools and that is true
/// of who it was built for, but it is not an empty state problem: CommandV2Engine
/// registers EIGHT builtin definitions on boot (smoke, ship an iOS app, localize,
/// TestFlight feedback, capture an idea and the rest), so `definitions.isEmpty` is
/// never true for anybody and a notice there would have been unreachable code
/// whose prompt claimed, falsely, that none ship. Those builtins are ordinary iOS
/// shipping workflows, useful to any Mac developer. Workflows needs nothing here.
///
/// IT REPLACES RATHER THAN OVERLAYS, which is the deliberate difference from
/// CapabilityGate. That gate dims the real feature and floats a card over it, so
/// a stranger can see what they are being asked to unlock. Here there is nothing
/// behind to see: the surface is empty, and dimming an empty pane teaches nobody
/// anything.
struct OperatorTool: Equatable {
    /// The FeatureRegistry row id, not the sidebar tab key. Checked against the
    /// registry by test, so a typo here cannot ship as a silently missing notice.
    let id: String
    let label: String
    /// What the surface does for the person it was built for, said plainly.
    let plainly: String
    /// The prompt a reader hands to their own coding agent.
    ///
    /// IT DELIBERATELY DOES NOT NAME THE REPOSITORY URL. The first draft opened
    /// "from source at github.com/<author>/grux" and that string put the author's
    /// handle into the shipped binary, which ShippedBundleHygieneTests bans and
    /// caught. The URL was never load bearing: the reader is running the app and
    /// the prompt already names the files to read, so "I have its source checked
    /// out" says the thing that actually matters. Do not add the URL back. The
    /// hygiene test's own comment is right that an exemption would be a hole.
    ///
    /// It names real files,
    /// because a prompt that says "look around the codebase" wastes a turn, and
    /// it carries one bracketed blank so the reader has to say what their
    /// business is, which is the whole point of it being tailored.
    let prompt: String

    static let social = OperatorTool(
            id: "social",
            label: "Social",
            plainly: "Social embeds a posting dashboard by URL. The one it was built around is a tuning board I run for my own brands. It is not in this repository, and it would not fit your business if it were.",
            prompt: """
            I am running Grux OS, an open source macOS assistant, and I have its source checked out.

            Its Social tab embeds an external dashboard by URL, and the author pointed it at his own, so it is empty for me.

            Read Sources/Grux/Social/SocialView.swift and find where dashboardURL is supplied from Settings. Then make this tab useful for MY business, which is: [describe your business, what you post, and where you post it].

            Either point it at a dashboard I already have, or replace the embed with a native view that pulls my own numbers. Build it, run the test suite, and tell me exactly what you changed and how to configure it.
            """)

    static let metaAds = OperatorTool(
            id: "meta.ads",
            label: "Meta Ads",
            plainly: "Meta Ads drives real ad accounts for my brands through a service I run. With no brands configured it has nothing to show you, and the numbers it is shaped around are mine.",
            prompt: """
            I am running Grux OS, an open source macOS assistant, and I have its source checked out.

            Its Meta Ads tab drives ad accounts through a service the author runs, so it shows me no brands and no data.

            Read Sources/Grux/MetaAds/, starting with MetaAdsService.swift and MetaAdsStore.swift, and find where brands and the service endpoint are configured. Then make this tab work for MY business, which is: [describe your business and where you advertise].

            Either wire it to my own Meta ad account, or strip it back to the parts that are useful without the author's service. Build it, run the test suite, and tell me exactly what you changed.
            """)

    static let featureReview = OperatorTool(
            id: "feature.review",
            label: "Feature Review",
            plainly: "Feature Review reads the commits of the repository it was pointed at and turns each one into a pitch you approve or reject. Pointed at nothing, it starts empty.",
            prompt: """
            I am running Grux OS, an open source macOS assistant, and I have its source checked out.

            Its Feature Review tab turns commits into pitches I approve or reject, but it is empty because it has not been pointed at a repository.

            Read Sources/Grux/Jax/Review/ and find where FeatureReviewEngine gets its commits and how it generates a pitch. Then point it at MY repository at [absolute path to your repo], and if the pitch generation needs a model key, tell me which one and where it goes.

            Build it, run the test suite, and tell me exactly what you changed.
            """)

    /// Every operator tool. The bidirectional registry test walks this list, so a
    /// fifth one added below is checked against FeatureRegistry automatically and
    /// a fifth one NOT added here is caught from the other direction.
    static let all: [OperatorTool] = [social, metaAds, featureReview]
}

struct OperatorToolNoticeView: View {
    let tool: OperatorTool
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                header
                Text(tool.plainly)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                shipsAnyway
                Divider().padding(.vertical, GruxSpacing.xs)
                handover
            }
            .padding(GruxSpacing.xl)
            .frame(maxWidth: GruxLayout.contentMax, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GruxTheme.base)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text("BUILT FOR ONE DESK")
                .font(GruxType.caption)
                .kerning(1.3)
                .foregroundStyle(GruxTheme.accentPrimary)
            Text("\(tool.label) is tooling from one person's business")
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Answers the question the plain statement provokes, which is "then why is it
    // in my sidebar at all". Removing these four would make the download smaller
    // and the screenshot tidier, and it would also be a lie about what this is.
    private var shipsAnyway: some View {
        Text("It ships because taking it out would misrepresent the download. This is the app I actually use, not a demo of it.")
            .font(GruxType.caption)
            .foregroundStyle(GruxTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var handover: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text("Make it yours")
                .font(GruxType.body.weight(.bold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text("Hand this to your own coding agent. It reads the real source and rebuilds the tab around your business instead of mine. Fill in the bracket before you send it.")
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(tool.prompt)
                .font(GruxType.mono)
                .foregroundStyle(GruxTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(GruxSpacing.m)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GruxTheme.textTertiary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GruxTheme.textTertiary.opacity(0.20), lineWidth: 1)
                )

            HStack(spacing: GruxSpacing.s) {
                Button(copied ? "Copied" : "Copy prompt") { copy() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(GruxTheme.accentPrimary)
                // Only offered when Chat is actually usable. Routing a stranger
                // with no key to a gated Chat tab would answer a dead end with a
                // second dead end.
                if FeatureRegistry.state(forTab: "chat") == .ready {
                    Button("Open in Grux chat") { sendToChat() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tool.prompt, forType: .string)
        copied = true
    }

    private func sendToChat() {
        AppState.shared.pendingChatPrompt = tool.prompt
        AppState.shared.requestedTab = "chat"
    }
}

