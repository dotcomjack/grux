import SwiftUI
import GruxAgentCore

// AgentsView - sidebar tab showing all agent jobs + per-job worker grid +
// live step timeline. Read-only for v1; cancel buttons available per job.

struct AgentsView: View {
    @ObservedObject private var svc = AgentService.shared
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String? = nil
    @State private var resumeSheetJobId: String? = nil
    // Banner toast shown after right-click context menu actions that would
    // otherwise be silent (Copy, Open in Finder, Retry…). Cleared by a fire-
    // and-forget Task after ~2s. Avoids the user wondering whether their
    // click actually did anything.
    @State private var ctxToast: String? = nil

    var body: some View {
        HSplitView {
            jobList
                .frame(minWidth: 240, idealWidth: 280)
            jobDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) { ctxToastOverlay }
        // No .navigationTitle here, deliberately. On macOS it renames the
        // WINDOW, and Agents was the only tab of 36 that set one, so opening it
        // once renamed the window to "Agents" and every tab visited afterwards
        // kept that title: Usage, Settings and the rest all showed "Agents" in
        // the title bar. A stale name is worse than the app name, the sidebar
        // already shows which tab is active, and "Grux OS" in the title bar is
        // the standard single-window macOS pattern. If per-tab titles are ever
        // wanted, all 36 have to set one, not just this one.
        .task {
            await svc.refreshJobs()
            if selection == nil { selection = svc.jobs.first?.id }
            consumePendingResume()
        }
        .onChange(of: appState.pendingResumeJobId) { _, _ in
            consumePendingResume()
        }
        .sheet(isPresented: Binding(
            get: { resumeSheetJobId != nil },
            set: { if !$0 { resumeSheetJobId = nil } }
        )) {
            if let jobId = resumeSheetJobId,
               let job = svc.jobs.first(where: { $0.id == jobId }) {
                ResumeJobSheet(job: job, dismiss: { resumeSheetJobId = nil })
            } else {
                Text("Job not found").padding()
            }
        }
    }

    private func consumePendingResume() {
        guard let jobId = appState.pendingResumeJobId else { return }
        appState.pendingResumeJobId = nil
        if svc.jobs.contains(where: { $0.id == jobId }) {
            selection = jobId
            resumeSheetJobId = jobId
        }
    }

    // MARK: - Right-click context menu
    //
    // State-aware menu: items render conditionally so the user only sees
    // actions that apply to this job's current status. The full set is:
    //   • Expand          (always)
    //   • Chat about this (always)
    //   • Resume…         (only when waiting + authLimitHit)
    //   • Cancel          (only when !isTerminal)
    //   • Retry failed    (only when failed worker count > 0)
    //   • Open in Finder ▸ Job folder | Project root
    //   • Copy ▸ Job ID | Goal | Cost summary
    //   • Delete          (only when isTerminal)
    @ViewBuilder
    private func jobContextMenu(for job: AgentJob) -> some View {
        let failedCount = job.workers.filter { $0.status == .failed }.count
        let canResume = (job.status == .waiting && job.pausedReason == .authLimitHit)

        Button {
            openWindow(id: "agent-job", value: job.id)
        } label: {
            Label("Expand in new window", systemImage: "rectangle.expand.vertical")
        }

        Button {
            chatAboutJob(job)
        } label: {
            Label("Chat about this job", systemImage: "bubble.left.and.text.bubble.right")
        }

        Divider()

        if canResume {
            Button {
                appState.pendingResumeJobId = job.id
            } label: {
                Label("Resume…", systemImage: "play.circle")
            }
        }
        if !job.isTerminal {
            Button(role: .destructive) {
                Task { await svc.cancel(jobId: job.id) }
            } label: {
                Label("Cancel job", systemImage: "stop.circle")
            }
        }
        if failedCount > 0 {
            Button {
                Task {
                    await svc.retryFailedWorkers(jobId: job.id)
                    showCtxToast("Retrying \(failedCount) failed worker\(failedCount == 1 ? "" : "s")")
                }
            } label: {
                Label("Retry \(failedCount) failed worker\(failedCount == 1 ? "" : "s")",
                      systemImage: "arrow.clockwise.circle")
            }
        }

        Divider()

        Menu {
            Button {
                svc.revealJobFolderInFinder(jobId: job.id)
            } label: {
                Label("Job folder", systemImage: "folder")
            }
            Button {
                Task { await svc.revealProjectRootInFinder(jobId: job.id) }
            } label: {
                Label("Project root", systemImage: "folder.badge.gearshape")
            }
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }

        Menu {
            Button {
                copyToClipboard(job.id)
                showCtxToast("Copied job ID")
            } label: {
                Label("Job ID", systemImage: "number")
            }
            Button {
                copyToClipboard(job.goal)
                showCtxToast("Copied goal")
            } label: {
                Label("Goal", systemImage: "text.alignleft")
            }
            Button {
                copyToClipboard(costSummary(job))
                showCtxToast("Copied cost summary")
            } label: {
                Label("Cost summary", systemImage: "dollarsign.circle")
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if job.isTerminal {
            Divider()
            Button(role: .destructive) {
                Task {
                    await svc.deleteJob(job.id)
                    if selection == job.id { selection = nil }
                }
            } label: {
                Label("Delete job", systemImage: "trash")
            }
        }
    }

    // MARK: - Action helpers

    // Seed a fresh chat thread with a markdown context briefing, then switch
    // to the chat tab. The briefing is appended as an `.assistant` turn so
    // it shows up in the conversation transcript AND is part of history when
    // the user fires their first follow-up - the model treats it as its own
    // prior turn (a context briefing it just delivered), which is the most
    // robust framing across model versions.
    private func chatAboutJob(_ job: AgentJob) {
        let title = "Job: \(job.title)"
        _ = appState.newThread(title: title)
        let briefing = ChatMessage(
            role: .assistant,
            content: jobContextMarkdown(job)
        )
        appState.appendChat(briefing)
        appState.requestedTab = "chat"
        WindowOpener.openChat()
    }

    private func jobContextMarkdown(_ job: AgentJob) -> String {
        let done = job.workers.filter { $0.status == .done }.count
        let failed = job.workers.filter { $0.status == .failed }.count
        let running = job.workers.filter { $0.status == .running }.count
        let paused = job.workers.filter { $0.status == .pausedForAuth }.count
        var lines: [String] = []
        lines.append("📋 **Loaded context for Grux job:** \(job.title)")
        lines.append("")
        lines.append("**Status:** `\(job.status.rawValue)`")
        if let reason = job.pausedReason {
            lines.append("**Paused reason:** `\(reason.rawValue)`")
        }
        lines.append("**Workers:** \(done)/\(job.workers.count) done"
                     + (failed > 0 ? " · \(failed) failed" : "")
                     + (running > 0 ? " · \(running) running" : "")
                     + (paused > 0 ? " · \(paused) paused-for-auth" : ""))
        lines.append("**Cost:** $\(String(format: "%.4f", job.spentUSD)) of $\(String(format: "%.2f", job.budgetUSD)) budget")
        lines.append("**Root dir:** `\(job.rootDir)`")
        lines.append("**Job ID:** `\(job.id)`")
        lines.append("")
        lines.append("**Goal:**")
        lines.append("> " + job.goal.replacingOccurrences(of: "\n", with: "\n> "))
        if !job.workers.isEmpty {
            lines.append("")
            lines.append("**Worker roster:**")
            for w in job.workers {
                var line = "- `\(w.label)` (\(w.role.rawValue)) - \(w.status.rawValue), $\(String(format: "%.4f", w.spentUSD))"
                if let err = w.errorMessage, !err.isEmpty {
                    line += " - ⚠️ \(err.prefix(120))"
                }
                lines.append(line)
            }
        }
        if let err = job.errorMessage, !err.isEmpty {
            lines.append("")
            lines.append("**Job-level error:** \(err)")
        }
        lines.append("")
        lines.append("Ask me anything about this job - I can explain what each worker is doing, why something failed, what to do next, or summarize the timeline so far.")
        return lines.joined(separator: "\n")
    }

    private func costSummary(_ job: AgentJob) -> String {
        let done = job.workers.filter { $0.status == .done }.count
        let failed = job.workers.filter { $0.status == .failed }.count
        var s = "Job: \(job.title)\n"
        s += "Status: \(job.status.rawValue)\n"
        s += "Workers: \(done)/\(job.workers.count) done\(failed > 0 ? " · \(failed) failed" : "")\n"
        s += "Spent: $\(String(format: "%.4f", job.spentUSD)) of $\(String(format: "%.2f", job.budgetUSD))\n"
        s += "ID: \(job.id)\n"
        return s
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func showCtxToast(_ msg: String) {
        withAnimation(.spring(response: 0.3)) { ctxToast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { ctxToast = nil }
            }
        }
    }

    @ViewBuilder
    private var ctxToastOverlay: some View {
        if let msg = ctxToast {
            Text(msg)
                .font(.caption.bold())
                .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [.purple.opacity(0.95), .indigo.opacity(0.95)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .foregroundStyle(.white)
                .shadow(color: .purple.opacity(0.4), radius: 8, y: 2)
                .padding(.top, GruxSpacing.m)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Jobs")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                Button {
                    Task { await svc.refreshJobs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if svc.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 32))
                    Text("No agent jobs yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Jobs appear here when you send work to a coding agent, from Chat, a command, or the Foundry. Each one shows its cost and what it changed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                    Text("Tell Grux to start a swarm.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(svc.jobs) { job in
                        JobRow(job: job)
                            .tag(Optional(job.id))
                            .contextMenu { jobContextMenu(for: job) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var jobDetail: some View {
        if let id = selection, let job = svc.jobs.first(where: { $0.id == id }) {
            JobDetailView(job: job)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.play.fill").font(.system(size: 40))
                Text("Pick a job to inspect").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct JobRow: View {
    let job: AgentJob
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                statusDot(job.status)
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                let done = job.workers.filter { $0.status == .done }.count
                let failed = job.workers.filter { $0.status == .failed }.count
                let paused = job.workers.filter { $0.status == .pausedForAuth }.count
                Text("\(done)/\(job.workers.count) done")
                if failed > 0 { Text("· \(failed) failed").foregroundStyle(.red) }
                if paused > 0 { Text("· \(paused) paused").foregroundStyle(.yellow) }
                Text("· $\(String(format: "%.4f", job.spentUSD))").foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if job.status == .waiting && job.pausedReason == .authLimitHit {
                Text("Waiting for account switch")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusDot(_ s: AgentJob.Status) -> some View {
        let color: Color = {
            switch s {
            case .running:   return .blue
            case .done:      return .green
            case .failed:    return .red
            case .cancelled: return .orange
            case .paused:    return .yellow
            case .waiting:   return .yellow
            case .queued:    return .gray
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct JobDetailView: View {
    let job: AgentJob
    @ObservedObject private var svc = AgentService.shared
    @ObservedObject private var appState = AppState.shared
    @State private var steps: [AgentStep] = []
    @State private var refreshTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            workerGrid
            Divider()
            stepLog
        }
        .onAppear { startStreamingSteps() }
        .onDisappear { stopStreamingSteps() }
        .onChange(of: job.id) { _, _ in
            steps = []
            startStreamingSteps()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            HStack {
                Text(job.title).font(GruxType.title)
                Spacer()
                if job.status == .waiting && job.pausedReason == .authLimitHit {
                    Button("Resume…") {
                        appState.pendingResumeJobId = job.id
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                }
                if !job.isTerminal {
                    Button("Cancel", role: .destructive) {
                        Task { await svc.cancel(jobId: job.id) }
                    }
                }
            }
            HStack(spacing: GruxSpacing.m) {
                Label(job.status.rawValue, systemImage: "circle.fill")
                    .foregroundStyle(statusColor(job.status))
                Text("$\(String(format: "%.4f", job.spentUSD)) of $\(String(format: "%.2f", job.budgetUSD))")
                    .foregroundStyle(.secondary)
                Text(job.id.prefix(8)).font(.caption).monospaced().foregroundStyle(.tertiary)
            }
            .font(.caption)
            Text(job.goal).font(.body).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(GruxSpacing.m)
    }

    private var workerGrid: some View {
        ScrollView(.horizontal) {
            HStack(spacing: GruxSpacing.s) {
                ForEach(job.workers) { w in
                    workerCard(w)
                }
            }
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.s)
        }
    }

    private func workerCard(_ w: SwarmWorkerSpec) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            HStack(spacing: GruxSpacing.xs + 2) {
                Circle().fill(statusColor(w.status)).frame(width: 8, height: 8)
                Text(w.label).font(.headline).lineLimit(1)
            }
            Text(w.role.rawValue).font(.caption).foregroundStyle(.secondary)
            Text("$\(String(format: "%.4f", w.spentUSD))").font(.caption2).foregroundStyle(.tertiary)
            if let err = w.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(GruxSpacing.s)
        .frame(width: 160, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var stepLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    ForEach(steps) { step in
                        stepRow(step)
                            .id(step.id)
                    }
                }
                .padding(GruxSpacing.m)
            }
            .onChange(of: steps.count) { _, _ in
                if let last = steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func stepRow(_ s: AgentStep) -> some View {
        HStack(alignment: .top, spacing: GruxSpacing.s) {
            Text(prefix(for: s.kind)).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                if let wid = s.workerId, let w = job.workers.first(where: { $0.id == wid }) {
                    Text(w.label).font(.caption2.bold()).foregroundStyle(.secondary)
                }
                Text(s.text).font(.system(.body, design: .monospaced)).lineLimit(4)
            }
        }
    }

    private func prefix(for k: AgentStep.Kind) -> String {
        switch k {
        case .workerStart:        return "▶"
        case .workerEnd:          return "■"
        case .assistantText:      return "💬"
        case .toolUse:            return "🔧"
        case .toolResult:         return "✓"
        case .usage:              return "$"
        case .error:              return "❌"
        case .orchestrator:       return "🎼"
        case .approvalRequested:  return "⏸"
        case .approvalGranted:    return "▶▶"
        case .info:               return "·"
        case .authLimitDetected:  return "🔒"
        case .accountSwitched:    return "🔄"
        case .workerResumed:      return "▶▶"
        }
    }

    private func statusColor(_ s: AgentJob.Status) -> Color {
        switch s {
        case .running:   return .blue
        case .done:      return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .paused:    return .yellow
        case .waiting:   return .yellow
        case .queued:    return .gray
        }
    }
    private func statusColor(_ s: SwarmWorkerSpec.Status) -> Color {
        switch s {
        case .running:        return .blue
        case .done:           return .green
        case .failed:         return .red
        case .cancelled:      return .orange
        case .skipped:        return .gray
        case .queued:         return .gray
        case .pausedForAuth:  return .yellow
        }
    }

    private func startStreamingSteps() {
        Task {
            steps = await svc.loadSteps(jobId: job.id, limit: 200)
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                let fresh = await AgentService.shared.loadSteps(jobId: job.id, limit: 200)
                if fresh.count != steps.count { steps = fresh }
            }
        }
    }

    private func stopStreamingSteps() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Standalone job window (right-click → Expand)
//
// Renders JobDetailView at full window size, subscribed to AgentService so it
// live-updates if the orchestrator advances while the window is open. Resolved
// from a jobId because SwiftUI's WindowGroup(for:) requires a Codable value
// type - passing the AgentJob struct directly would lock the window to a
// snapshot.
struct AgentJobWindow: View {
    let jobId: String?
    @ObservedObject private var svc = AgentService.shared

    var body: some View {
        Group {
            if let id = jobId, let job = svc.jobs.first(where: { $0.id == id }) {
                // Same reason as above: this renamed the window to the selected
                // job's title, which then persisted across every later tab.
                JobDetailView(job: job)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Job not found")
                        .foregroundStyle(.secondary)
                    if let id = jobId {
                        Text(id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .task {
            await svc.refreshJobs()
        }
    }
}

// MARK: - Resume sheet
//
// Shown when a job's status is .waiting / .authLimitHit. The user picks an
// account from the registered set, hits Resume, and Grux:
//   1. Logs out of the current claude account (silent)
//   2. Pops a Terminal window with `claude auth login --email <addr>` so the
//      user finishes Anthropic OAuth in their browser
//   3. Polls `claude auth status --json` until the active orgId matches
//   4. Re-spawns the paused workers via SwarmOrchestrator.resumeJob()
//
// "Snooze 1h" defers the resume by an hour on the same account (the limit
// window may roll). "Cancel job" hard-stops the orchestrator.
struct ResumeJobSheet: View {
    let job: AgentJob
    let dismiss: () -> Void

    @ObservedObject private var svc = AgentService.shared
    @ObservedObject private var switcher = AccountSwitcher.shared
    @State private var selectedAccountId: String? = nil
    @State private var inFlightAccountId: String? = nil
    @State private var resumingHere: Bool = false
    @State private var lastError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text("Anthropic monthly limit hit")
                .font(.title2.bold())
            if let activeLabel = activeAccountLabel {
                Text("\(activeLabel) is rate-limited.")
                    .foregroundStyle(.secondary)
            }
            Text("Job: \(job.title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Text("Switch to:")
                .font(.headline)

            if switcher.state.accounts.isEmpty {
                Text("No additional accounts paired yet. Run `claude auth login` once for each account, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                    ForEach(switcher.state.accounts) { acct in
                        accountRow(acct)
                    }
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, GruxSpacing.xs)
                // The switch logs out the prior account FIRST, then pops a
                // Terminal for OAuth. A timeout (closed window, abandoned
                // OAuth) leaves the user signed out of everything with the job
                // still paused - a worse state. Offer a one-tap re-open of the
                // SAME login Terminal (no re-logout) so the flow can resume.
                HStack(spacing: GruxSpacing.s) {
                    Button("Re-open login Terminal") {
                        switcher.reopenLoginTerminal()
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.top, GruxSpacing.xs - 2)
            }

            if switcher.isSignedOutOfEverything {
                Label(
                    "Signed out of all accounts. Finish the login in the Terminal window to restore access.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, GruxSpacing.xs)
            }

            Divider()

            // Resume-in-place on the current account, NO logout/OAuth swap.
            // This is the path for "I re-signed into the same account" or "the
            // limit window rolled over": just re-engage the paused worker from
            // its last checkpoint. Distinct from the account-switch Resume.
            Button {
                Task { await runResumeHere() }
            } label: {
                if resumingHere {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Resume on this account")
                }
            }
            .disabled(resumingHere || inFlightAccountId != nil)

            HStack(spacing: GruxSpacing.s) {
                Button("Snooze 1h") {
                    Task {
                        await svc.snoozeJob(jobId: job.id, minutes: 60)
                        dismiss()
                    }
                }
                Button("Cancel job", role: .destructive) {
                    Task {
                        await svc.cancel(jobId: job.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let id = selectedAccountId else { return }
                    Task { await runSwitch(targetId: id) }
                } label: {
                    if inFlightAccountId != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Resume")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAccountId == nil || inFlightAccountId != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(GruxSpacing.xl)
        // A sheet cannot be wider than the window it hangs off, and 480 as a
        // hard width was a demand rather than a preference: SwiftUI centres an
        // oversized child, so on a narrow window this lost the account labels
        // off the left edge and the Resume button off the right at the same
        // time. 480 stays the ideal and only the bounds are new, so it renders
        // exactly as it does today and shrinks toward sheetMin instead.
        // No height ceiling here on purpose: the account list is a plain
        // ForEach with no scroll, so a cap would squeeze rows that have
        // nowhere to go rather than buy anything back. That one wants a
        // ScrollView around the list first.
        .frame(minWidth: GruxLayout.sheetMin,
               idealWidth: 480,
               maxWidth: GruxLayout.sheetMax)
        .task {
            await switcher.refreshActiveStatus()
            // Pre-select the first account that's NOT the currently rate-
            // limited one. This is the "pick the obvious other account"
            // shortcut for users with two accounts.
            let activeId = switcher.state.activeAccountId
            selectedAccountId = switcher.state.accounts.first(where: { $0.id != activeId })?.id
                ?? switcher.state.accounts.first?.id
        }
    }

    private var activeAccountLabel: String? {
        let id = switcher.state.activeAccountId
        return switcher.state.accounts.first(where: { $0.id == id })?.label
    }

    @ViewBuilder
    private func accountRow(_ acct: ClaudeAuthAccount) -> some View {
        let isActive = (acct.id == switcher.state.activeAccountId)
        let lastHit = switcher.state.perAccount[acct.id]?.lastLimitHitAt
        HStack(alignment: .top, spacing: GruxSpacing.s) {
            Image(systemName: selectedAccountId == acct.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GruxSpacing.xs + 2) {
                    Text(acct.label).font(.body.weight(.semibold))
                    if isActive {
                        Text("(rate-limited)")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let email = acct.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                if let last = lastHit {
                    Text("last limit hit \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(GruxSpacing.s)
        .background(selectedAccountId == acct.id ? GruxTheme.accentPrimary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAccountId = acct.id
        }
    }

    private func runResumeHere() async {
        resumingHere = true
        lastError = nil
        let ok = await svc.resumeOnCurrentAccount(jobId: job.id)
        resumingHere = false
        if ok {
            dismiss()
        } else {
            lastError = "Nothing to resume - the job has no paused workers."
        }
    }

    private func runSwitch(targetId: String) async {
        inFlightAccountId = targetId
        lastError = nil
        let result = await svc.resumeWithAccountSwitch(jobId: job.id, targetAccountId: targetId)
        inFlightAccountId = nil
        switch result {
        case .switched, .alreadyActive:
            dismiss()
        case .failed(let msg):
            lastError = msg
        }
    }
}
