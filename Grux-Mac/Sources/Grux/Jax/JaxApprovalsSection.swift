import SwiftUI

// JaxApprovalsSection: the decision gate's pending queue (ApprovalQueue.shared).
// Jax NEVER acts on a guardrailed action autonomously (move money, send important
// docs, post publicly, send mail without the right disclosure). The gate queues
// the action here for the user's one-tap verdict. Each card shows the action
// summary, the resolved comms persona (assistant or the user themselves), the
// reason it was paused, the queued $N for a spend, and tight [approve] [edit]
// [skip] controls.
//
// approve/skip call back into ApprovalQueue (which marks the item and, on approve,
// hands the sanctioned ProposedAction back to the gate to perform). The queue is
// approve/skip only, so [edit] expands the full action payload for review before
// the tap; it never mutates the item (see risks).
struct JaxApprovalsSection: View {
    let approvals: [PendingApproval]
    let onApprove: (UUID) -> Void
    let onSkip: (UUID) -> Void

    /// The empty queue's copy, static so it can be asserted on.
    ///
    /// An empty approvals queue is the NORMAL state and the good one, so the
    /// sentence has to say that rather than leave a heading over nothing. It
    /// follows the configured assistant name because it describes the assistant
    /// pausing, not a tab.
    static func emptyCopy(assistantName: String) -> String {
        "Nothing waiting. \(assistantName) pauses and asks here whenever it is unsure."
    }

    var body: some View {
        JaxSection(
            title: "Pending approvals",
            icon: "checkmark.seal.fill",
            tint: GruxTheme.warnAmber,
            count: approvals.isEmpty ? nil : approvals.count
        ) {
            if approvals.isEmpty {
                JaxEmptyLine(icon: "checkmark.circle",
                             text: Self.emptyCopy(assistantName: UserIdentity.assistantName))
            } else {
                VStack(spacing: 10) {
                    ForEach(approvals) { approval in
                        JaxApprovalCard(
                            approval: approval,
                            onApprove: { onApprove(approval.id) },
                            onSkip: { onSkip(approval.id) }
                        )
                    }
                }
            }
        }
    }
}

struct JaxApprovalCard: View {
    let approval: PendingApproval
    let onApprove: () -> Void
    let onSkip: () -> Void

    @State private var expanded = false

    private var action: ProposedAction { approval.action }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: kind badge + urgent flag + persona + brand + queued amount.
            HStack(spacing: 8) {
                kindBadge
                if approval.urgent { urgentBadge }
                if approval.persona != .none { personaChip }
                Spacer()
                if let cents = action.amountCents {
                    Text(MetaAdsFormat.dollars(cents))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                if let brand = action.brand, !brand.isEmpty { JaxBrandTag(brand: brand) }
            }

            // Action summary: one plain line a human reads.
            Text(action.summary.isEmpty ? "Action pending your review" : action.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Why the gate paused instead of proceeding.
            if !approval.reason.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 10)).foregroundStyle(GruxTheme.warnAmber)
                        .padding(.top, 1)
                    Text(approval.reason)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Persona disclosure line: who this would be signed as.
            if approval.persona != .none {
                HStack(spacing: 6) {
                    Image(systemName: "signature").font(.system(size: 10)).foregroundStyle(GruxTheme.textTertiary)
                    (
                        Text("Goes out as ")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(GruxTheme.textTertiary)
                        + Text(approval.persona.signature)
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(approval.persona.tint)
                    )
                }
            }

            // Expanded review (the [edit] affordance): full target + payload so
            // the exact detail is readable before the tap. Read-only.
            if expanded { reviewDetail }

            controls

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(GruxTheme.textTertiary)
                Text("Queued \(JaxTime.ago(approval.createdAt))")
                    .font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder((approval.urgent ? GruxTheme.warnAmber : action.kind.tint).opacity(0.30), lineWidth: 1)
        )
    }

    private var kindBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: action.kind.icon).font(.system(size: 10, weight: .bold))
            Text(action.kind.label).font(GruxTheme.Font.microCaps).kerning(1.0)
        }
        .foregroundStyle(action.kind.tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(action.kind.tint.opacity(0.16)))
    }

    private var urgentBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
            Text("URGENT").font(GruxTheme.Font.microCaps).kerning(0.8)
        }
        .foregroundStyle(GruxTheme.destructiveRose)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(GruxTheme.destructiveRose.opacity(0.16)))
    }

    private var personaChip: some View {
        HStack(spacing: 4) {
            Image(systemName: approval.persona.icon).font(.system(size: 9, weight: .bold))
            Text(approval.persona.chipLabel).font(GruxTheme.Font.microCaps).kerning(0.8)
        }
        .foregroundStyle(approval.persona.tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(approval.persona.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(approval.persona.tint.opacity(0.3), lineWidth: 0.8))
    }

    // Read-only payload review. Hides the spend amount (already shown) and renders
    // the rest of the structured detail as label/value rows.
    private var reviewDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !action.target.isEmpty {
                detailRow(label: "Target", value: action.target)
            }
            ForEach(action.detail.keys.sorted(), id: \.self) { key in
                if key != "amount_cents", let value = action.detail[key], !value.isEmpty {
                    detailRow(label: key, value: value)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.20))
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.uppercased())
                .font(GruxTheme.Font.microCaps).kerning(0.6)
                .foregroundStyle(GruxTheme.textTertiary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(GruxTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // Tight pill controls, never chunky. Approve is the iridescent primary.
    private var controls: some View {
        HStack(spacing: 8) {
            GruxChip(title: "Approve", systemImage: "checkmark", style: .primary, action: onApprove)
            GruxChip(
                title: expanded ? "Hide" : "Edit",
                systemImage: expanded ? "chevron.up" : "pencil",
                style: .secondary,
                action: { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } }
            )
            GruxChip(title: "Skip", systemImage: "xmark", style: .secondary, action: onSkip)
            Spacer()
        }
        .padding(.top, 2)
    }
}
