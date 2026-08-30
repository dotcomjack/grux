import SwiftUI
import AppKit

// Left-rail thread picker for the Chat tab. Lists every persisted thread
// from AppState.threads with starred threads pinned at the top, then sorted
// by last-activity. Provides: create new thread, switch, rename inline,
// toggle star, delete, and a manual "compact now" button for the active
// thread. Filter box matches on title + last-message preview.
struct ChatThreadsSidebar: View {
    @EnvironmentObject var state: AppState

    @State private var query: String = ""
    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""
    @State private var compacting: Bool = false
    @State private var compactToast: String?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            searchField
            hairline
            if filtered.isEmpty {
                emptyState
            } else {
                threadList
            }
            hairline
            footer
        }
        // Flexible width so the chat pane reflows when the window narrows
        // instead of clipping. Prefers 256pt, shrinks to 210 when cramped,
        // caps at 300 so the conversation pane takes the extra on wide windows.
        .frame(minWidth: 210, idealWidth: 256, maxWidth: 300)
        .background(
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                GruxTheme.base.opacity(0.55)
                LinearGradient(
                    colors: [
                        GruxTheme.accentPrimary.opacity(0.06),
                        Color.clear,
                        GruxTheme.accentCo.opacity(0.04)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
        .overlay(alignment: .top) { toastOverlay }
    }

    // Faint iridescent seam matching the rest of the chat surface, replacing the
    // stock macOS Divider so the rail reads as one piece of glass.
    private var hairline: some View {
        Rectangle()
            .fill(GruxTheme.iridescentRim.opacity(0.30))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("CHATS")
                .font(GruxTheme.Font.microCaps)
                .kerning(2.0)
                .foregroundStyle(GruxTheme.textTertiary)
            Spacer()
            Button {
                let id = state.newThread()
                renamingId = id
                renameDraft = "New chat"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    renameFieldFocused = true
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(GruxTheme.iridescent)
                    .shadow(color: GruxTheme.violetGlow(), radius: 4)
            }
            .buttonStyle(.plain)
            .help("Start a new chat thread")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(GruxTheme.textTertiary)
            TextField("Filter threads", text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(GruxTheme.textPrimary)
                .tint(GruxTheme.accentPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(
                    query.isEmpty ? GruxTheme.textTertiary.opacity(0.25)
                                  : GruxTheme.accentPrimary.opacity(0.55),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var filtered: [ChatThreadIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.threads }
        return state.threads.filter { entry in
            entry.title.lowercased().contains(q)
                || (entry.preview?.lowercased().contains(q) ?? false)
        }
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filtered) { entry in
                    row(entry)
                        .id(entry.id)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatThreadIndexEntry) -> some View {
        let isActive = state.activeThreadId == entry.id
        let isRenaming = renamingId == entry.id
        Button {
            guard !isRenaming else { return }
            state.switchThread(entry.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                starDot(on: entry.starred)
                VStack(alignment: .leading, spacing: 3) {
                    if isRenaming {
                        TextField("Thread title", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(GruxTheme.textPrimary)
                            .tint(GruxTheme.accentPrimary)
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename(entry.id) }
                            .onExitCommand { cancelRename() }
                    } else {
                        HStack(spacing: 4) {
                            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(isActive ? GruxTheme.textPrimary : GruxTheme.textPrimary.opacity(0.85))
                                .lineLimit(1)
                            if entry.hasSummary {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(GruxTheme.accentPrimaryLight.opacity(0.85))
                                    .help("This thread has a compacted summary")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if let preview = entry.preview, !preview.isEmpty, !isRenaming {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(GruxTheme.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(relativeDate(entry.updatedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(GruxTheme.textTertiary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(GruxTheme.textTertiary)
                        Text("\(entry.messageCount) msg")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(active: isActive))
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .strokeBorder(
                        isActive ? GruxTheme.accentPrimary.opacity(0.55) : Color.white.opacity(0.06),
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                state.toggleThreadStar(entry.id)
            } label: {
                Label(entry.starred ? "Unpin" : "Pin to top",
                      systemImage: entry.starred ? "star.slash" : "star")
            }
            Button {
                renamingId = entry.id
                renameDraft = entry.title
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    renameFieldFocused = true
                }
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                state.deleteThread(entry.id)
            } label: {
                Label("Delete thread", systemImage: "trash")
            }
        }
    }

    private func starDot(on: Bool) -> some View {
        Group {
            if on {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(GruxTheme.warnAmber)
            } else {
                Circle()
                    .fill(GruxTheme.accentPrimary.opacity(0.4))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 12, alignment: .top)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func rowBackground(active: Bool) -> some View {
        if active {
            LinearGradient(
                colors: [
                    GruxTheme.accentPrimary.opacity(0.16),
                    GruxTheme.accentCo.opacity(0.08)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else {
            Color.white.opacity(0.025)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            let hasActive = state.activeThreadId != nil
            let hasEnough = state.chat.count >= 8
            Button {
                runCompact()
            } label: {
                HStack(spacing: 6) {
                    if compacting {
                        ProgressView().controlSize(.small)
                            .scaleEffect(0.65)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.caption2)
                    }
                    Text(compacting ? "Compacting…" : "Compact thread")
                        .font(.caption.weight(.semibold))
                        .kerning(0.4)
                }
                .foregroundStyle(hasEnough ? Color.white : GruxTheme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(
                        hasEnough
                            ? AnyShapeStyle(GruxTheme.iridescent)
                            : AnyShapeStyle(Color.white.opacity(0.05))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        hasEnough ? Color.white.opacity(0.25) : Color.white.opacity(0.10),
                        lineWidth: 0.6
                    )
                )
                .shadow(color: hasEnough ? GruxTheme.violetGlow() : .clear, radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(!hasActive || !hasEnough || compacting)
            .help(hasEnough
                  ? "Fold older messages into a rolling summary and keep the last 10 in view"
                  : "Needs at least 8 messages before compacting is useful")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder private var toastOverlay: some View {
        if let msg = compactToast {
            Text(msg)
                .font(.caption.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(GruxTheme.iridescent)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
                )
                .foregroundStyle(.white)
                .shadow(color: GruxTheme.violetGlow(strong: true), radius: 8)
                .clipShape(Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(GruxTheme.textTertiary)
            Text(query.isEmpty ? "No threads yet." : "No threads match.")
                .font(.caption).foregroundStyle(GruxTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ops

    private func commitRename(_ id: UUID) {
        let t = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            state.renameThread(id, title: t)
        }
        renamingId = nil
        renameDraft = ""
    }

    private func cancelRename() {
        renamingId = nil
        renameDraft = ""
    }

    private func runCompact() {
        guard let _ = state.activeThreadId else { return }
        compacting = true
        Task {
            let ok = await state.compactActiveThread(keepLastN: 10)
            await MainActor.run {
                compacting = false
                showToast(ok ? "Thread compacted" : "Nothing to compact (or API key missing)")
            }
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring()) { compactToast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { compactToast = nil }
            }
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        if secs < 7 * 86_400 { return "\(secs / 86_400)d ago" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: d)
    }
}
