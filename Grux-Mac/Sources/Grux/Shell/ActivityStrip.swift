import SwiftUI

// Slim persistent activity strip (blueprint section 03). Sits at the bottom
// of the main window content area: live swarm jobs as phase dots, an
// estimated-cost ticker, and a Foundry cycle chip when the governor is mid
// pass. Auto-hides with a smooth height collapse when nothing is alive.
//
// Integration (LaunchRootView): wrap the detail Group in a VStack(spacing: 0)
// and append:
//
//   ActivityStripView { kind in
//       selection = (kind == .foundry) ? .selfUpgrade : .agents
//   }
//
// Clicking a dot or the strip background jumps to the Agents tab; clicking
// the Foundry chip jumps to Self-Upgrade.

struct ActivityStripView: View {

    @ObservedObject private var model = ActivityStripModel.shared

    // Click-through router. The host decides what "open" means (tab
    // selection in LaunchRootView, window open elsewhere).
    var onOpen: (ActivityDot.Kind) -> Void = { _ in }

    static let stripHeight: CGFloat = 28

    var body: some View {
        strip
            .frame(height: model.isVisible ? Self.stripHeight : 0)
            .opacity(model.isVisible ? 1 : 0)
            .clipped()
            .animation(MotionTokens.gated(MotionTokens.easeOutSlow), value: model.isVisible)
            .accessibilityHidden(!model.isVisible)
    }

    private var strip: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: GruxSpacing.s) {
                if let pass = model.foundryPass {
                    foundryChip(pass)
                }
                dotsRow
                Spacer(minLength: GruxSpacing.s)
                if let label = model.costLabel {
                    Text(label)
                        .font(GruxType.microCaps)
                        .kerning(0.8)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .help("Sum of live jobs' token-spend estimates at API-equivalent rates. Never billed; subscription powered.")
                }
            }
            .padding(.horizontal, GruxSpacing.m)
            .frame(maxHeight: .infinity)
        }
        .background(GruxTheme.base)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(.swarm) }
    }

    // MARK: Dots

    private var dotsRow: some View {
        HStack(spacing: GruxSpacing.xs + 2) {
            ForEach(model.dots) { dot in
                Button {
                    onOpen(dot.kind)
                } label: {
                    Circle()
                        .fill(Self.color(for: dot.phase))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(dot.tooltip)
                .accessibilityLabel(dot.tooltip)
            }
        }
    }

    static func color(for phase: ActivityDot.Phase) -> Color {
        switch phase {
        case .queued: return GruxTheme.textTertiary
        case .running: return GruxTheme.accentPrimary
        case .waiting: return GruxTheme.warnAmber
        case .done: return GruxTheme.successMint
        case .failed: return GruxTheme.destructiveRose
        case .cancelled: return GruxTheme.textTertiary.opacity(0.6)
        }
    }

    // MARK: Foundry cycle chip

    private func foundryChip(_ pass: FoundryCyclePass) -> some View {
        Button {
            onOpen(.foundry)
        } label: {
            HStack(spacing: GruxSpacing.xs) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(pass.displayName.uppercased())
                    .font(GruxType.microCaps)
                    .kerning(0.8)
            }
            .foregroundStyle(GruxTheme.accentCo)
            .padding(.horizontal, GruxSpacing.s).padding(.vertical, 3)
            .background(Capsule().fill(GruxTheme.accentCo.opacity(0.12)))
            .overlay(Capsule().stroke(GruxTheme.accentCo.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("Foundry \(pass.displayName) in progress. Click for Self-Upgrade.")
    }
}

// MARK: - Orb-adjacent swarm badge

// FoundryStatusBadge-style count of RUNNING swarm jobs, for the sidebar hero
// next to the orb. Integration (LaunchRootView.sidebarHero, beside the
// existing FoundryStatusBadge call):
//
//   ActivitySwarmBadge { selection = .agents }
//
struct ActivitySwarmBadge: View {
    @ObservedObject private var model = ActivityStripModel.shared
    var action: (() -> Void)? = nil

    var body: some View {
        if model.runningCount > 0 {
            Button {
                action?()
            } label: {
                HStack(spacing: GruxSpacing.xs) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(model.runningCount)")
                        .font(GruxType.microCaps)
                        .kerning(0.5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, GruxSpacing.s).padding(.vertical, GruxSpacing.xs)
                .background(Capsule().fill(GruxTheme.iridescent))
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                .shadow(color: GruxTheme.violetGlow(), radius: 6)
            }
            .buttonStyle(.plain)
            .help("\(model.runningCount) swarm \(model.runningCount == 1 ? "job" : "jobs") running")
        }
    }
}
