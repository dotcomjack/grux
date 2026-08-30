import SwiftUI

// Read-only continuity tab: what the Mac knows right now. Lists the 7-day
// calendar agenda, live reminders, recent meeting summaries, and notes, all
// pushed by the Mac's SurfaceSyncEngine over the encrypted 0x40 channel.
// Pull to refresh asks the Mac for a fresh snapshot.

struct SurfacesView: View {
    @ObservedObject private var store = SurfaceStore.shared
    @ObservedObject private var approvals = ApprovalStore.shared
    @ObservedObject private var transport = TransportService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                activityStrip
                Group {
                    if store.snapshot == nil {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("Surfaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let updated = store.lastUpdated {
                        Text(updated, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        List {
            if !approvals.pending.isEmpty {
                approvalsSection
            }
            agendaSection
            remindersSection
            meetingsSection
            notesSection
        }
        .listStyle(.insetGrouped)
        .refreshable {
            TransportService.shared.sendSurface(.surfacesRequest)
            // Give the Mac a beat to answer so the spinner doesn't vanish
            // before the push lands.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    // MARK: - Activity strip (wire v2 mirror of the Mac's ActivityStripView)

    // Thin strip atop the tab: one 7pt dot per live swarm job, an optional
    // Foundry pass chip, and the Mac's pre-rendered "$N estimated" cost
    // label. Hidden entirely when nothing is running.
    @ViewBuilder
    private var activityStrip: some View {
        if let activity = store.activity,
           !(activity.jobs.isEmpty && activity.foundryPass == nil) {
            HStack(spacing: 8) {
                if let pass = activity.foundryPass {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 9))
                        Text(pass.capitalized)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.purple)
                }
                HStack(spacing: 5) {
                    ForEach(activity.jobs) { job in
                        Circle()
                            .fill(dotColor(for: job.phase))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer(minLength: 0)
                if !activity.estimatedCostLabel.isEmpty {
                    Text(activity.estimatedCostLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    private func dotColor(for phase: String) -> Color {
        switch phase {
        case "running": return Color(red: 0.55, green: 0.45, blue: 0.95)
        case "waiting", "paused": return .orange
        case "done": return .mint
        case "failed": return Color(red: 0.95, green: 0.35, blue: 0.45)
        case "cancelled": return .gray.opacity(0.6)
        default: return .gray // queued
        }
    }

    // MARK: - Sections

    // Foundry install approvals (Phase C): one card per pending request,
    // pushed by the Mac after a proposal builds and verifies. Approve fires
    // GruxUpdater.selfInstall behind the 24h rollback keeper.
    private var approvalsSection: some View {
        Section("Install approvals") {
            ForEach(approvals.pending) { req in
                approvalRow(req)
            }
        }
    }

    private func approvalRow(_ req: FoundryApprovalRequestDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("READY TO INSTALL")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(.orange)
                Spacer()
                Text(req.createdAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(req.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
            Text("\(req.lane) | \(req.domain) | \(req.risk) risk")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(req.estCostLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    decide(req, approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.seal")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                Button {
                    decide(req, approved: false)
                } label: {
                    Label("Reject", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private func decide(_ req: FoundryApprovalRequestDTO, approved: Bool) {
        TransportService.shared.sendApproval(.approvalResponse(
            version: FoundryApprovalWire.version, id: req.id, approved: approved
        ))
        // Optimistic local removal; the Mac's approvalResolved echo is a no-op.
        ApprovalStore.shared.remove(id: req.id)
    }

    private var agendaSection: some View {
        Section("Next 7 days") {
            if store.agendaByDay.isEmpty {
                placeholderRow("No calendar events")
            } else {
                ForEach(store.agendaByDay, id: \.day) { group in
                    ForEach(group.events) { ev in
                        agendaRow(ev)
                    }
                }
            }
        }
    }

    private func agendaRow(_ ev: SurfaceAgendaEventDTO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.start, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(ev.isAllDay ? "all day" : ev.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                if let loc = ev.location, !loc.isEmpty {
                    Text(loc).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var remindersSection: some View {
        Section("Reminders") {
            if store.pendingReminders.isEmpty {
                placeholderRow("No reminders")
            } else {
                ForEach(store.pendingReminders) { r in
                    reminderRow(r)
                }
            }
        }
    }

    private func reminderRow(_ r: SurfaceReminderDTO) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(r.kind.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(r.firedAt == nil ? Color.cyan : Color.secondary)
                if let when = r.scheduledFor, r.firedAt == nil {
                    Text(when, style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if r.accepted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Text(r.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
            if !r.body.isEmpty {
                Text(r.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var meetingsSection: some View {
        Section("Meetings") {
            let meetings = store.snapshot?.meetings ?? []
            if meetings.isEmpty {
                placeholderRow("No meetings captured")
            } else {
                ForEach(meetings) { m in
                    meetingRow(m)
                }
            }
        }
    }

    private func meetingRow(_ m: SurfaceMeetingDTO) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(m.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Text(m.startedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let excerpt = m.summaryExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("\(m.utteranceCount) utterances")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var notesSection: some View {
        Section("Notes") {
            let notes = store.snapshot?.notes ?? []
            if notes.isEmpty {
                placeholderRow("No notes")
            } else {
                ForEach(notes) { n in
                    noteRow(n)
                }
            }
        }
    }

    private func noteRow(_ n: SurfaceNoteDTO) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if n.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9)).foregroundStyle(.cyan)
                }
                Text(n.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Text(n.updatedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !n.preview.isEmpty {
                Text(n.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !n.tags.isEmpty {
                Text(n.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.cyan.opacity(0.8)).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.7))
            Text("Waiting for your Mac")
                .font(.system(size: 20, weight: .bold))
            Text(connectionHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if case .streaming = transport.state {
                Button {
                    TransportService.shared.sendSurface(.surfacesRequest)
                } label: {
                    Text("Refresh now")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionHint: String {
        switch transport.state {
        case .streaming:
            return "Connected. Reminders, meetings, notes, and your 7-day agenda will appear when the Mac pushes them."
        case .idle, .failed:
            return "Connect to your Mac (Mic tab > Start) to sync reminders, meetings, notes, and your agenda."
        default:
            return "Connecting to your Mac..."
        }
    }
}
