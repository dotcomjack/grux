import SwiftUI

/// C10: Approvals are a tray, not a place. A badge at the foot of the rail,
/// on every tab, whenever something is waiting on the person; the cards open
/// in a popover right there, approve or skip without leaving what they were
/// doing. There is no rail row, and nothing is drawn while nothing waits.
///
/// Today's Watching card used to say "38 approvals waiting on you" too. That
/// was the same fact twice in one view, which the operator's rule forbids, so
/// the tray owns it and Watching no longer carries it.
enum ApprovalsTray {
    static func badge(_ count: Int) -> String { "\(count) waiting" }
    static let help = "Approvals waiting on you. Grux pauses and asks here before anything it should not do alone."
    static let panelTitle = "Waiting on you"
    /// `fire-open-tab approvals` (and `--open-tab=approvals`): Today, with the
    /// tray open. Approvals have no tab, so the key opens the tray instead of
    /// falling back to Chat the way an unknown key does.
    static let openKey = "approvals"
}

/// Whether the tray is open, shared so a trigger can open it even when the
/// window appears after the request.
@MainActor
final class ApprovalsTrayState: ObservableObject {
    static let shared = ApprovalsTrayState()
    @Published var isOpen = false
}

/// The badge. It observes the queue itself, so the rail's root view never
/// redraws for an approval (see `RootObservesOnlyWhatItReadsTests`).
struct ApprovalsTrayButton: View {
    @ObservedObject private var queue = ApprovalQueue.shared
    @ObservedObject private var tray = ApprovalsTrayState.shared

    var body: some View {
        let count = queue.pendingCount
        if count > 0 {
            Button { tray.isOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(ApprovalsTray.badge(count))
                        .font(.caption2)
                }
                .foregroundStyle(GruxTheme.warnAmber)
            }
            .buttonStyle(.borderless)
            .help(ApprovalsTray.help)
            .accessibilityLabel("\(count) approvals waiting")
            .popover(isPresented: $tray.isOpen, arrowEdge: .trailing) {
                ApprovalsTrayPanel(queue: queue)
            }
        }
    }
}

/// What the badge opens: the same cards Jax HQ shows, wired the same way.
struct ApprovalsTrayPanel: View {
    @ObservedObject var queue: ApprovalQueue

    var body: some View {
        ScrollView {
            JaxApprovalsSection(
                approvals: queue.pending,
                onApprove: { id in Task { await queue.approveAndExecute(id) } },
                onSkip: { queue.skip($0) }
            )
            .padding(14)
        }
        .frame(width: GruxLayout.trayPopoverWidth)
        .frame(minHeight: 180, maxHeight: 560)
    }
}
