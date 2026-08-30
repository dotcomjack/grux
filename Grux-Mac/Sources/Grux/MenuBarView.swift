import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var wake = WakeWordListener.shared
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var ambient = AmbientState.shared
    @ObservedObject private var terminalFocus = TerminalFocusState.shared
    @ObservedObject private var meeting = MeetingCaptureService.shared
    @ObservedObject private var v2Engine = CommandV2Engine.shared
    @ObservedObject private var supportDrafts = SupportDraftStore.shared
    @State private var newTaskText = ""
    @State private var newTaskProject = ""
    @State private var newTaskPriority: TaskPriority = .next
    @State private var showCompleted = false
    @State private var showEvents = false

    // Item 24: shell bus fills the idle gap with canonical moments
    // (focus verdicts, workflow runs, agent jobs).
    @ObservedObject private var shellBus = ShellStateBus.shared

    private var orbState: GruxOrbState {
        // Muted wins - keeps the menu bar dropdown orb in sync with the
        // sidebar orb and the ambient HUD orb (all read micMuted).
        if state.micMuted { return .muted }
        if speech.isSpeaking || speech.isBuffering { return .speaking }
        if wake.isListening && state.isThinking { return .thinking }
        if state.isThinking { return .thinking }
        if wake.isListening { return .listening }
        return shellBus.current.mode.orbState
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Phase ribbon - only renders when there's at least one active V2
            // run. Collapses cleanly otherwise so the menu bar dropdown doesn't
            // grow vertical chrome for users who never run workflows.
            if let summary = activePhaseSummary {
                phaseRibbon(summary)
                Divider()
            }
            currentFocus
            Divider()
            ambientRow
            Divider()
            meetingRow
            Divider()
            addTaskRow
            Divider()
            taskList
            Divider()
            inboxRow
            Divider()
            footer
        }
        .frame(width: 440)
        .padding(.vertical, GruxSpacing.s)
        .background(.ultraThinMaterial)
    }

    // MARK: - V2 Phase Ribbon

    private struct ActivePhaseSummary {
        let runId: UUID
        let displayName: String
        let phaseIndex: Int      // 1-based
        let totalPhases: Int
        let phaseDisplayName: String
    }

    /// Pick the most recently started active V2 run (if any) and resolve its
    /// current phase to a 1-based index. Returns nil when there are no live
    /// runs OR when the live run's definition can't be resolved (e.g. a
    /// definition was renamed and the persisted run hasn't been migrated).
    private var activePhaseSummary: ActivePhaseSummary? {
        guard let run = v2Engine.activeRuns.first(where: {
            $0.status == .running || $0.status == .waitingForApproval ||
            $0.status == .waitingScheduled || $0.status == .waitingForActiveUser
        }) else {
            return nil
        }
        guard let def = v2Engine.definition(id: run.definitionId),
              let idx = def.phases.firstIndex(where: { $0.id == run.currentPhaseId }) else {
            return nil
        }
        let phase = def.phases[idx]
        return ActivePhaseSummary(
            runId: run.id,
            displayName: run.displayName,
            phaseIndex: idx + 1,
            totalPhases: def.phases.count,
            phaseDisplayName: phase.displayName
        )
    }

    private func phaseRibbon(_ summary: ActivePhaseSummary) -> some View {
        Button {
            // Deep-link the user to the Workflows tab. CommandsV2View shows
            // active runs at the top, so a single click lands them on the run.
            WindowOpener.openWorkflows()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(GruxTheme.accentPrimary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WORKFLOW")
                        .font(.caption.bold())
                        .kerning(1.5)
                        .foregroundStyle(.secondary)
                    Text("\(summary.displayName) · Phase \(summary.phaseIndex)/\(summary.totalPhases): \(summary.phaseDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
        }
        .buttonStyle(.plain)
    }

    private var ambientRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.micMuted ? "mic.slash.fill" : (ambient.isEnabled ? "waveform.circle.fill" : "waveform.slash"))
                .font(.system(size: 14))
                .foregroundStyle(state.micMuted
                                 ? LinearGradient(colors: [.gray, .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                 : (ambient.isEnabled
                                    ? LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom)
                                    : LinearGradient(colors: [.secondary, .secondary], startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("AMBIENT")
                        .font(.caption.bold())
                        .kerning(1.5)
                    if state.micMuted {
                        Text("· muted")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if ambient.isEnabled {
                        Text("· passive listening")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(ambientStatusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if ambient.isEnabled && !state.micMuted {
                Button { ambient.toggleHUD() } label: {
                    Image(systemName: ambient.hudVisible ? "macwindow" : "macwindow.badge.plus")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(ambient.hudVisible ? "Hide HUD" : "Show HUD")
            }
            // While muted, the toggle acts as the single "turn Grux back on"
            // gesture - flipping it unmutes (which restarts ambient if
            // ambient was the configured listener). Otherwise it toggles
            // ambient as before.
            Toggle("", isOn: Binding(
                get: { ambient.isEnabled && !state.micMuted },
                set: { on in
                    Task { @MainActor in
                        if state.micMuted {
                            if on { MicController.unmute() }
                        } else {
                            if on { await ambient.enable() } else { ambient.disable() }
                        }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
    }

    private var ambientStatusLine: String {
        if state.micMuted {
            return "Muted - tap the orb or flip the switch to resume."
        }
        return ambient.isEnabled ? ambient.status : "Off - enable to capture spoken memory, actions, and coach nudges."
    }

    // MARK: - Meeting capture row

    private var meetingRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(meeting.isCapturing ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 14, height: 14)
                if meeting.isCapturing {
                    Circle()
                        .strokeBorder(Color.red.opacity(0.5), lineWidth: 2)
                        .frame(width: 22, height: 22)
                        .scaleEffect(1.2)
                        .opacity(0.6)
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("MEETING")
                        .font(.caption.bold())
                        .kerning(1.5)
                    if meeting.isCapturing {
                        Text("· capturing")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if meeting.autoCaptureOffered, let offer = meeting.pendingOffer {
                        Text("· \(offer.name) detected")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    } else if !meeting.isSystemAudioSupported {
                        Text("· requires macOS 14+")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(meetingStatusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer()
            Button { MeetingPanelController.shared.toggle() } label: {
                Image(systemName: MeetingPanelController.shared.isShowing ? "macwindow" : "macwindow.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(MeetingPanelController.shared.isShowing ? "Hide meeting HUD" : "Show meeting HUD")

            Button {
                Task {
                    if meeting.isCapturing {
                        await meeting.stop()
                    } else {
                        _ = await meeting.start()
                    }
                }
            } label: {
                if meeting.isInitializing {
                    ProgressView().controlSize(.small)
                } else if meeting.isCapturing {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.bold())
                        .padding(.vertical, 3).padding(.horizontal, 10)
                        .background(Color.red.opacity(0.2))
                        .foregroundStyle(Color.red)
                        .clipShape(Capsule())
                } else {
                    Label("Start", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.bold())
                        .padding(.vertical, 3).padding(.horizontal, 10)
                        .background(Color.purple.opacity(0.18))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(!meeting.isSystemAudioSupported || meeting.isInitializing)
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
    }

    private var meetingStatusLine: String {
        if meeting.isCapturing {
            let app = meeting.activeMeeting?.sourceAppName ?? "meeting"
            return "\(meeting.elapsedDisplay) · \(app) · \(meeting.liveUtterances.count) utterances"
        }
        if let err = meeting.lastError, !err.isEmpty {
            return "error: \(err)"
        }
        if meeting.autoCaptureOffered, let offer = meeting.pendingOffer {
            return "Tap Start to record \(offer.name)."
        }
        return "Off - ⌘⇧M to record calls, meetings, FaceTime locally."
    }

    private var header: some View {
        HStack(spacing: 10) {
            OrbView(state: orbState, level: speech.outputLevel)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("GRUX OS").font(.headline.weight(.heavy)).kerning(2)
                OrbStatusPill(state: orbState).scaleEffect(0.85, anchor: .leading)
            }
            Spacer()
            if state.isThinking {
                ProgressView().controlSize(.small)
            }
            Button(action: { state.watching ? FocusWatcher.shared.stop() : FocusWatcher.shared.start() }) {
                Label(state.watching ? "Watching" : "Paused",
                      systemImage: state.watching ? "eye.fill" : "eye.slash.fill")
                    .font(.caption)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(state.watching ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }.buttonStyle(.plain)
            Menu {
                Button("Open Chat") { WindowOpener.openChat() }
                Button("Settings…") { WindowOpener.openSettings() }
                Button("Focus Log") { showEvents.toggle() }
                Divider()
                Button(FocusOverlayState.shared.isVisible ? "Hide Focus Overlay" : "Show Focus Overlay") {
                    FocusOverlayController.shared.toggle()
                }
                Button(OrbAnywhereState.shared.isVisible ? "Hide Floating Orb" : "Show Floating Orb") {
                    let next = !OrbAnywhereState.shared.isVisible
                    state.config.orbAnywhereEnabled = next
                    state.saveConfig()
                    OrbAnywhereController.shared.toggle()
                }
                // Separate from the glass Focus Overlay - controls the Terminal
                // Focus overlay's user-dismiss flag, which keybindings the × button
                // and the "overlay on"/"overlay off" voice macros.
                Button(terminalFocus.userHidden ? "Show Terminal Focus Overlay" : "Hide Terminal Focus Overlay") {
                    terminalFocus.toggleOverlay()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Run Check Now") { FocusWatcher.shared.runOnceNow() }
                Button("Run Daily Recap Now") {
                    Task { @MainActor in await DailyRecapScheduler.shared.fireRecapNow() }
                }
                Divider()
                Button("Workday Log…") {
                    WorkdayLogPanelController.shared.present()
                }
                Button("Generate Today's Workday Log Now") {
                    Task { @MainActor in
                        let dk = WorkdayLogScheduler.currentDayKey()
                        _ = await WorkdayLogScheduler.shared.generateWorkdayLogNow(forDayKey: dk)
                        WorkdayLogPanelController.shared.present()
                    }
                }
                Button("Snooze 15m") { state.snooze(minutes: state.config.snoozeMinutes) }
                if state.snoozedUntil != nil { Button("Clear Snooze") { state.snoozedUntil = nil } }
                Divider()
                Button("Quit Grux") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, GruxSpacing.m)
    }

    private var currentFocus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CURRENT FOCUS").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let snoozedUntil = state.snoozedUntil, snoozedUntil > Date() {
                    Label("Snoozed", systemImage: "moon.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
            if let t = state.currentTask {
                HStack(spacing: 8) {
                    Circle().fill(Color.purple).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.headline).lineLimit(2)
                        if !t.project.isEmpty {
                            Text(t.project).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { state.completeTask(t.id) } label: {
                        Image(systemName: "checkmark.circle")
                    }.buttonStyle(.plain)
                }
            } else {
                Text("No current task. Add one below.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                verdictPill
                Text(state.lastActiveApp.isEmpty ? "-" : state.lastActiveApp)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let tick = state.lastTick {
                    Text(tick, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
    }

    private var verdictPill: some View {
        let (label, color): (String, Color) = {
            switch state.lastVerdict {
            case .onTask: return ("on task", .green)
            case .drifting: return ("drifting", .yellow)
            case .offTask: return ("off task", .red)
            case .ambiguous: return ("ambiguous", .gray)
            case .none: return ("-", .gray)
            }
        }()
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var addTaskRow: some View {
        VStack(spacing: GruxSpacing.s) {
            HStack {
                TextField("Add task…", text: $newTaskText, onCommit: submitTask)
                    .textFieldStyle(.plain)
                    .padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(6)
                Picker("", selection: $newTaskPriority) {
                    ForEach(TaskPriority.allCases) { p in Text(p.label).tag(p) }
                }.frame(width: 80)
                Button { submitTask() } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.purple)
                }.buttonStyle(.plain).disabled(newTaskText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Project (optional)", text: $newTaskProject)
                .textFieldStyle(.plain).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.06)).cornerRadius(6)
        }.padding(.horizontal, GruxSpacing.m)
    }

    private func submitTask() {
        let t = newTaskText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.addTask(t, project: newTaskProject.trimmingCharacters(in: .whitespaces), priority: newTaskPriority)
        newTaskText = ""; newTaskProject = ""
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let grouped = groupTasks()
                ForEach(TaskPriority.allCases) { pri in
                    if let items = grouped[pri], !items.isEmpty {
                        Text(pri.label)
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                            .padding(.horizontal, GruxSpacing.m).padding(.top, GruxSpacing.s).padding(.bottom, GruxSpacing.xs)
                        ForEach(items) { task in
                            TaskRow(task: task)
                                .environmentObject(state)
                        }
                    }
                }
                if showCompleted && !state.completedTasks.isEmpty {
                    Text("COMPLETED")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                        .padding(.horizontal, GruxSpacing.m).padding(.top, GruxSpacing.s).padding(.bottom, GruxSpacing.xs)
                    ForEach(state.completedTasks.prefix(10)) { t in
                        TaskRow(task: t).environmentObject(state)
                    }
                }
                HStack {
                    Button(showCompleted ? "Hide completed" : "Show completed (\(state.completedTasks.count))") {
                        showCompleted.toggle()
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
            }
        }.frame(maxHeight: 240)
    }

    private func groupTasks() -> [TaskPriority: [FocusTask]] {
        var out: [TaskPriority: [FocusTask]] = [:]
        for t in state.activeTasks {
            out[t.priority, default: []].append(t)
        }
        return out
    }

    // Email surfaces: review staged support replies, or compose cold outreach.
    private var inboxRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 14))
                .foregroundStyle(LinearGradient(colors: [.teal, .blue], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text("EMAIL").font(.caption.bold()).kerning(1.5)
                Text(supportDrafts.stagedCount > 0
                     ? "\(supportDrafts.stagedCount) support draft\(supportDrafts.stagedCount == 1 ? "" : "s") waiting"
                     : "No drafts waiting")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { WindowOpener.composeOutreach() } label: {
                Label("Compose", systemImage: "square.and.pencil")
                    .font(.caption.bold())
                    .padding(.vertical, 3).padding(.horizontal, 10)
                    .background(Color.teal.opacity(0.18))
                    .foregroundStyle(Color.teal)
                    .clipShape(Capsule())
            }.buttonStyle(.plain)
            Button { WindowOpener.openSupportDrafts() } label: {
                HStack(spacing: 5) {
                    Text("Drafts")
                    if supportDrafts.stagedCount > 0 {
                        Text("\(supportDrafts.stagedCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .font(.caption.bold())
                .padding(.vertical, 3).padding(.horizontal, 10)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
    }

    private var footer: some View {
        HStack {
            Button { WindowOpener.openChat() } label: {
                Label("Chat", systemImage: "bubble.left.fill")
            }.buttonStyle(.borderless)
            Spacer()
            if !state.screenPermissionGranted {
                Button { _ = ScreenCapturer.shared.requestPermission() } label: {
                    Label("Grant screen access", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                }.buttonStyle(.borderless)
            }
            Spacer()
            Button { WindowOpener.openSettings() } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }.buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, GruxSpacing.m).padding(.top, GruxSpacing.s)
    }
}

struct TaskRow: View {
    @EnvironmentObject var state: AppState
    let task: FocusTask
    // When true, render a NOW/NEXT/LATER pill beside the title. TasksDetailView
    // now sections by project, so priority has to surface per-row. The menu
    // bar still groups by priority and leaves this off to avoid duplication.
    var showsPriorityPill: Bool = false
    @State private var hovering = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editProject = ""
    @FocusState private var focusedField: EditField?

    private enum EditField: Hashable { case title, project }

    var body: some View {
        HStack(spacing: 8) {
            Button { task.completed ? state.uncompleteTask(task.id) : state.completeTask(task.id) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.completed ? Color.secondary : (state.currentTaskId == task.id ? Color.purple : Color.primary))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Task title", text: $editTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .focused($focusedField, equals: .title)
                        .onSubmit(commitEdit)
                        .onExitCommand(perform: cancelEdit)
                    TextField("Project (optional)", text: $editProject)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .focused($focusedField, equals: .project)
                        .onSubmit(commitEdit)
                        .onExitCommand(perform: cancelEdit)
                    HStack(spacing: 6) {
                        Button("Save", action: commitEdit)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                        Button("Cancel", action: cancelEdit)
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .strikethrough(task.completed, color: .secondary)
                            .foregroundStyle(task.completed ? .secondary : .primary)
                            .lineLimit(2)
                        if showsPriorityPill && !task.completed {
                            priorityPill
                        }
                    }
                    if !task.project.isEmpty {
                        Text(task.project).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if !isEditing && hovering && !task.completed {
                Menu {
                    Button("Rename…") { beginEdit() }
                    Button("Focus (promote to NOW)") { state.focus(on: task.id) }
                    Divider()
                    ForEach(TaskPriority.allCases) { p in
                        Button("Move to \(p.label)") { state.setPriority(task.id, p) }
                    }
                    Divider()
                    DestructiveMenuButton("Delete",
                                          question: "Delete this task?",
                                          detail: "The task and its notes are removed. This cannot be undone.",
                                          confirmLabel: "Delete task") { state.deleteTask(task.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if !isEditing && state.currentTaskId == task.id {
                Text("●").foregroundStyle(.purple)
            }
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.xs + 2)
        .background(state.currentTaskId == task.id ? Color.purple.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { beginEdit() }
            if !task.completed {
                Button("Focus (promote to NOW)") { state.focus(on: task.id) }
                Divider()
                ForEach(TaskPriority.allCases) { p in
                    Button("Move to \(p.label)") { state.setPriority(task.id, p) }
                }
            }
            Divider()
            DestructiveMenuButton("Delete",
                                          question: "Delete this task?",
                                          detail: "The task and its notes are removed. This cannot be undone.",
                                          confirmLabel: "Delete task") { state.deleteTask(task.id) }
        }
        .onTapGesture(count: 2) {
            beginEdit()
        }
        .onTapGesture {
            if !isEditing && !task.completed { state.focus(on: task.id) }
        }
    }

    private func beginEdit() {
        editTitle = task.title
        editProject = task.project
        isEditing = true
        DispatchQueue.main.async { focusedField = .title }
    }

    private func commitEdit() {
        let newTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { cancelEdit(); return }
        state.renameTask(task.id, title: newTitle, project: editProject)
        isEditing = false
        focusedField = nil
    }

    private func cancelEdit() {
        isEditing = false
        focusedField = nil
    }

    private var priorityPill: some View {
        let color: Color = {
            switch task.priority {
            case .now: return .purple
            case .next: return .blue
            case .later: return .secondary
            }
        }()
        return Text(task.priority.label)
            .font(.caption2.weight(.bold))
            .kerning(0.6)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
