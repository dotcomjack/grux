import SwiftUI
import AppKit

// PolishedGlass floating HUD - the face of Grux Focus Ambient.
// Dark vibrancy blur, gradient rim, soft purple glow, live transcript ticker,
// extracted commitments + facts, proposed actions with promote/dismiss,
// coach history, quick controls. Draggable by the header.

struct AmbientHUDRoot: View {
    @ObservedObject var ambient = AmbientState.shared
    @ObservedObject var appState = AppState.shared
    @ObservedObject var speech = SpeechEngine.shared
    // Item 24: shell bus fills the idle gap with canonical moments.
    @ObservedObject private var shellBus = ShellStateBus.shared

    @State private var editingMemoryId: UUID?
    @State private var editingText: String = ""
    @State private var editingProject: String = ""
    @State private var isFlushingTurn = false
    @State private var expandTranscript = false
    @State private var expandMemory = false
    @State private var expandActions = false

    // Preview caps before the section collapses to scroll mode
    private let transcriptPreviewCount = 3
    private let memoryPreviewCount = 4
    private let actionsPreviewCount = 3

    // Max scroll height when a section is expanded - keeps the HUD sized
    // reasonably even with hundreds of items.
    private let expandedScrollMaxHeight: CGFloat = 260

    var body: some View {
        GlassShell {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                header
                doneTalkingButton
                coachBanner
                transcriptTicker
                memoriesSection
                actionsSection
                footerControls
            }
            // HUD-specific gutter: a touch wider than the PIM detail-pane l
            // (16) so the floating panel breathes against its glass rim.
            .padding(18)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Project names known to the app: union of current task projects and
    // existing memory projects, deduped + sorted. Used to populate the
    // project Menu in inline memory edit.
    private var knownProjects: [String] {
        var set = Set<String>()
        for t in appState.tasks { if !t.project.isEmpty { set.insert(t.project) } }
        for m in ambient.memories { if let p = m.project, !p.isEmpty { set.insert(p) } }
        for a in ambient.detectedActions { if !a.project.isEmpty { set.insert(a.project) } }
        return set.sorted()
    }

    // MARK: - Header (orb + title + capture pill)

    private var orbState: GruxOrbState {
        // Muted wins - keeps the ambient HUD orb in sync with the sidebar orb.
        if appState.micMuted { return .muted }
        if ambient.coachIsSpeaking || speech.isSpeaking || speech.isBuffering { return .speaking }
        if ambient.isExtracting { return .thinking }
        if ambient.isTranscribing { return .thinking }
        if ambient.isCapturing { return .listening }
        // Item 24: shell bus fills the idle gap with canonical moments.
        return shellBus.current.mode.orbState
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            HStack(spacing: GruxSpacing.m) {
                // Tapping the ambient HUD orb toggles the mic, same as the
                // main-window sidebar orb. Both observe `AppState.micMuted`
                // so they stay visually in sync across surfaces.
                Button {
                    MicController.toggle()
                } label: {
                    OrbView(state: orbState, level: ambient.liveLevel)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help(appState.micMuted ? "Mic muted, tap to resume" : "Tap to mute the mic")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("GRUX OS")
                            .font(.system(size: 13, weight: .black, design: .default))
                            .kerning(2.5)
                        Text("· AMBIENT")
                            .font(.system(size: 11, weight: .bold, design: .default))
                            .kerning(1.8)
                            .foregroundStyle(LinearGradient(
                                colors: [.purple.opacity(0.95), .cyan.opacity(0.8)],
                                startPoint: .leading, endPoint: .trailing))
                    }
                    statusRow
                }
                Spacer()
                capturePill
            }
            modeSelector
        }
        .background(DragHandle())
    }

    // Wake vs Focus mode toggle - a two-button segmented-style pill.
    // Wake: requires "Hey Grux" to engage (with armed follow-up).
    // Focus: every meaningful utterance is sent to chat.
    private var modeSelector: some View {
        HStack(spacing: 6) {
            modeButton(mode: .wake, icon: "ear.badge.waveform")
            modeButton(mode: .focus, icon: "bolt.horizontal.fill")
            Spacer()
            Text(appState.config.ambientMode.shortHelp)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func modeButton(mode: AmbientMode, icon: String) -> some View {
        let isSelected = appState.config.ambientMode == mode
        return Button {
            // Route through AmbientState so live listener topology updates -
            // switching wake↔focus starts/stops the ambient engine and wake
            // listener as needed instead of just flipping the config flag.
            Task { @MainActor in
                await AmbientState.shared.setMode(mode)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(mode.label)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(1.4)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isSelected
                    ? AnyShapeStyle(LinearGradient(
                        colors: mode == .focus ? [.cyan, .blue] : [.purple, .indigo],
                        startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.white.opacity(0.05))
                )
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.10),
                    lineWidth: 0.8
                )
            )
            .shadow(color: isSelected ? (mode == .focus ? .cyan.opacity(0.5) : .purple.opacity(0.5)) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .help(mode.shortHelp)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ambient.isCapturing ? Color.mint : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
                .shadow(color: ambient.isCapturing ? .mint.opacity(0.8) : .clear, radius: 4)
            Text(ambient.status)
                .font(GruxType.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var capturePill: some View {
        // Three visual states - kept explicit so the ambient HUD always
        // tells the same story as the orb: ON (listening), OFF (user turned
        // ambient off), or MUTED (global mic mute via orb tap). Tapping
        // while MUTED unmutes rather than toggling ambient, so the single
        // "turn Grux back on" gesture works from every surface.
        Button {
            Task { @MainActor in
                if appState.micMuted {
                    MicController.unmute()
                } else if ambient.isEnabled {
                    ambient.disable()
                } else {
                    await ambient.enable()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: capturePillIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(capturePillLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .kerning(1.2)
            }
            .foregroundStyle(appState.micMuted || !ambient.isEnabled ? Color.secondary : Color.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(capturePillFill)
            )
            .overlay(
                Capsule().stroke(
                    ambient.isEnabled && !appState.micMuted ? Color.white.opacity(0.25) : Color.white.opacity(0.08),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: ambient.isEnabled && !appState.micMuted ? .purple.opacity(0.5) : .clear,
                radius: 8
            )
        }
        .buttonStyle(.plain)
        .help(appState.micMuted ? "Mic muted, tap to unmute" : (ambient.isEnabled ? "Tap to pause ambient capture" : "Tap to enable ambient capture"))
    }

    private var capturePillIcon: String {
        if appState.micMuted { return "mic.slash.fill" }
        return ambient.isEnabled ? "waveform.circle.fill" : "waveform.slash"
    }

    private var capturePillLabel: String {
        if appState.micMuted { return "MUTED" }
        return ambient.isEnabled ? "ON" : "OFF"
    }

    private var capturePillFill: AnyShapeStyle {
        if appState.micMuted {
            return AnyShapeStyle(LinearGradient(
                colors: [.gray.opacity(0.35), .gray.opacity(0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if ambient.isEnabled {
            return AnyShapeStyle(LinearGradient(
                colors: [.purple.opacity(0.85), .indigo.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [.secondary.opacity(0.2), .secondary.opacity(0.12)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    // MARK: - Done talking

    // Prominent "end of turn" control. Tells ambient to drain its rolling
    // buffer right now, transcribe whatever's in flight, and force-run the
    // Claude extractor without waiting for the 25-second debounce. Lets the
    // user explicitly signal "I'm done talking, go process" instead of waiting
    // for the silence timer.
    private var doneTalkingButton: some View {
        Button {
            WakeLog.shared.log("hud: DONE TALKING tapped")
            guard !isFlushingTurn else { return }
            isFlushingTurn = true
            Task { @MainActor in
                await AmbientListener.shared.flushNow()
                isFlushingTurn = false
                // In WAKE mode, "I'm done talking" also ends the conversation -
                // ambient stops, wake listener resumes, music stops getting
                // nerfed. Focus mode stays continuous (that's the whole point).
                if appState.config.ambientMode == .wake,
                   AmbientState.shared.conversationActive {
                    AmbientState.shared.exitConversation(reason: "done talking tap")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isFlushingTurn ? "hourglass" : "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.pulse, options: .repeating, isActive: isFlushingTurn)
                Text(isFlushingTurn ? "PROCESSING…" : "I'M DONE TALKING")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .kerning(1.8)
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: isFlushingTurn
                            ? [Color.indigo.opacity(0.65), Color.purple.opacity(0.55)]
                            : [Color.purple.opacity(0.95), Color.indigo.opacity(0.85), Color.cyan.opacity(0.7)],
                        startPoint: .leading, endPoint: .trailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            )
            .shadow(color: .purple.opacity(0.55), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!ambient.isCapturing)
        .opacity(ambient.isCapturing ? 1.0 : 0.4)
        .help("End your speech turn: flush the buffer and run extraction now.")
    }

    // MARK: - Coach banner

    private var coachBanner: some View {
        Group {
            if let nudge = ambient.nudges.first,
               Date().timeIntervalSince(nudge.timestamp) < 300 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ambient.coachIsSpeaking ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 20)
                        .symbolEffect(.variableColor.iterative, isActive: ambient.coachIsSpeaking)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("COACH")
                            .font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundStyle(.cyan)
                        MarkdownText(content: nudge.text)
                            .markdownFont(.system(size: 12.5, weight: .medium))
                            .markdownForegroundColor(.primary)
                            .markdownBlockSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { SpeechEngine.shared.speak(nudge.text) } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.cyan.opacity(0.14), .purple.opacity(0.10)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.cyan.opacity(0.35), lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - Transcript ticker

    private var transcriptTicker: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            sectionHeader(
                label: "HEARING",
                countBadge: ambient.recentChunks.count,
                isExpandable: ambient.recentChunks.count > transcriptPreviewCount,
                isExpanded: expandTranscript,
                toggle: { expandTranscript.toggle() }
            )
            if ambient.recentChunks.isEmpty {
                GlassRow {
                    Text(ambient.isCapturing ? "Waiting for voice…" : "Flip the switch to start listening.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if expandTranscript {
                // Full history: newest first, scrolls.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let all = Array(ambient.recentChunks.reversed())
                        ForEach(Array(all.enumerated()), id: \.element.id) { idx, chunk in
                            chunkRow(chunk: chunk, index: min(idx, 0)) // full opacity in expanded mode
                        }
                    }
                }
                .frame(maxHeight: expandedScrollMaxHeight)
            } else {
                // Preview: last N only, with fading opacity.
                VStack(alignment: .leading, spacing: 6) {
                    let recent = Array(ambient.recentChunks.suffix(transcriptPreviewCount).reversed())
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, chunk in
                        chunkRow(chunk: chunk, index: idx)
                    }
                }
            }
        }
    }

    private func chunkRow(chunk: AmbientChunk, index: Int) -> some View {
        let age = Int(Date().timeIntervalSince(chunk.timestamp))
        let ageStr: String = age < 60 ? "\(age)s" : "\(age/60)m"
        let opacity = index == 0 ? 1.0 : (index == 1 ? 0.72 : 0.45)
        return HStack(alignment: .top, spacing: 8) {
            Text(ageStr)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(chunk.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(opacity)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: - Memories

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            sectionHeader(
                label: "MEMORY",
                countBadge: ambient.memories.count,
                isExpandable: ambient.memories.count > memoryPreviewCount,
                isExpanded: expandMemory,
                toggle: { expandMemory.toggle() }
            )
            if ambient.memories.isEmpty {
                GlassRow {
                    Text("Commitments and facts appear here once you talk.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if expandMemory {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(ambient.memories) { memoryRow(memory: $0) }
                    }
                }
                .frame(maxHeight: expandedScrollMaxHeight)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ambient.memories.prefix(memoryPreviewCount)) { memoryRow(memory: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func memoryRow(memory: AmbientMemory) -> some View {
        if editingMemoryId == memory.id {
            memoryEditRow(memory: memory)
        } else {
            memoryDisplayRow(memory: memory)
        }
    }

    private func memoryDisplayRow(memory: AmbientMemory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            memoryKindBadge(kind: memory.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(memory.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let project = memory.project, !project.isEmpty {
                    Text(project)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                editingMemoryId = memory.id
                editingText = memory.text
                editingProject = memory.project ?? ""
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Edit")
            Button { ambient.deleteMemory(memory.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }.buttonStyle(.plain).help("Delete")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.028))
        )
    }

    private func memoryEditRow(memory: AmbientMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                memoryKindBadge(kind: memory.kind)
                TextField("Title", text: $editingText, onCommit: { saveMemoryEdit(memory) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.purple.opacity(0.45), lineWidth: 0.8)
                    )
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Project picker: existing projects + free-text entry.
                Menu {
                    ForEach(knownProjects, id: \.self) { proj in
                        Button(proj) { editingProject = proj }
                    }
                    if !knownProjects.isEmpty { Divider() }
                    Button("(no project)") { editingProject = "" }
                } label: {
                    HStack(spacing: 4) {
                        Text(editingProject.isEmpty ? "choose…" : editingProject)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(editingProject.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                }.menuStyle(.borderlessButton).fixedSize()
                TextField("or type a project", text: $editingProject, onCommit: { saveMemoryEdit(memory) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Spacer(minLength: 0)
                Button {
                    editingMemoryId = nil
                    editingText = ""
                    editingProject = ""
                } label: {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Button { saveMemoryEdit(memory) } label: {
                    Text("Save")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [.purple, .indigo],
                                startPoint: .leading, endPoint: .trailing))
                        )
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.purple.opacity(0.4), lineWidth: 0.8)
        )
    }

    private func saveMemoryEdit(_ memory: AmbientMemory) {
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ambient.updateMemory(memory.id, text: text, project: editingProject)
        editingMemoryId = nil
        editingText = ""
        editingProject = ""
    }

    private func memoryKindBadge(kind: AmbientMemoryKind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .intent: return ("INT", .purple)
            case .commitment: return ("COM", .mint)
            case .fact: return ("FACT", .orange)
            case .reminder: return ("REM", .pink)
            }
        }()
        return Text(label)
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .kerning(0.8)
            .foregroundStyle(color)
            .frame(width: 34, height: 16)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.45), lineWidth: 0.6)
            )
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            sectionHeader(
                label: "PROPOSED ACTIONS",
                countBadge: ambient.activeActions.count,
                isExpandable: ambient.activeActions.count > actionsPreviewCount,
                isExpanded: expandActions,
                toggle: { expandActions.toggle() }
            )
            if ambient.activeActions.isEmpty {
                GlassRow {
                    Text(appState.config.ambientAutoPromoteActions
                         ? "Auto-promoting detected actions into your task stack."
                         : "Action items from your speech show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if expandActions {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(ambient.activeActions) { a in actionRow(action: a) }
                    }
                }
                .frame(maxHeight: expandedScrollMaxHeight)
            } else {
                VStack(spacing: 6) {
                    ForEach(ambient.activeActions.prefix(actionsPreviewCount)) { a in actionRow(action: a) }
                }
            }
        }
    }

    private func actionRow(action: AmbientDetectedAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            priorityBadge(action.priority)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !action.project.isEmpty || !action.rationale.isEmpty {
                    Text([action.project, action.rationale].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button { ambient.dismissAction(action.id) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Button { ambient.promoteAction(action.id) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(LinearGradient(
                        colors: [.purple, .indigo],
                        startPoint: .top, endPoint: .bottom))
                    .shadow(color: .purple.opacity(0.5), radius: 5)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.05), Color.white.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.purple.opacity(0.22), lineWidth: 0.6)
        )
    }

    private func priorityBadge(_ p: TaskPriority) -> some View {
        let color: Color = {
            switch p {
            case .now: return .pink
            case .next: return .orange
            case .later: return .secondary
            }
        }()
        return Text(p.label)
            .font(.system(size: 8.5, weight: .black, design: .monospaced))
            .kerning(0.8)
            .foregroundStyle(color)
            .frame(width: 36, height: 16)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.6))
    }

    // MARK: - Footer

    private var footerControls: some View {
        HStack(spacing: GruxSpacing.s) {
            pill(systemImage: "bolt.heart", label: "Nudge") {
                Task { @MainActor in await AmbientCoach.shared.nudgeNow() }
            }
            pill(systemImage: "sparkles", label: "Extract now") {
                Task { @MainActor in await AmbientMemoryExtractor.shared.runExtraction() }
            }
            exportAudioPill
            Spacer()
            Menu {
                Toggle("Auto-promote actions", isOn: Binding(
                    get: { appState.config.ambientAutoPromoteActions },
                    set: { v in
                        appState.config.ambientAutoPromoteActions = v
                        appState.saveConfig()
                    }
                ))
                Toggle("Voice coach", isOn: Binding(
                    get: { appState.config.ambientCoachEnabled },
                    set: { v in
                        appState.config.ambientCoachEnabled = v
                        appState.saveConfig()
                    }
                ))
                Divider()
                DestructiveButton(
                    "Clear all ambient data",
                    question: "Delete everything ambient mode has captured?",
                    detail: "Every stored frame, transcript and observation from ambient sessions "
                        + "is removed from this Mac. This cannot be undone.",
                    confirmLabel: "Delete ambient data"
                ) {
                    ambient.clearAll()
                }
                Divider()
                Button("Hide HUD") { ambient.toggleHUD() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.top, GruxSpacing.xs)
    }

    // Dedicated pill that exports the newest N minutes of ambient audio to
    // a WAV in `audio-exports/` and reveals in Finder. Shows a 1-second
    // "saved" confirmation inline so the user gets instant feedback without a
    // dialog. Disabled (and dimmed) when the ring buffer is empty, e.g.
    // ambient was just enabled or they cleared it.
    private var exportAudioPill: some View {
        let ring = AmbientAudioRing.shared
        let available = ring.availableSeconds
        let hasAudio = available > 1.0
        let minutes = max(1, Int((available / 60.0).rounded()))
        return Menu {
            // Common presets. The "Save last N" items all export min(N, available).
            Button("Save last 1 min")  { performExport(seconds: 60) }
            Button("Save last 5 min")  { performExport(seconds: 300) }
            Button("Save last 15 min") { performExport(seconds: 900) }
            Divider()
            Button("Save all available (~\(minutes) min)") {
                performExport(seconds: ring.availableSeconds + 1)
            }
            Divider()
            Button("Reveal exports folder") {
                NSWorkspace.shared.activateFileViewerSelecting([AudioExportStore.exportsDir])
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle").font(.system(size: 10, weight: .bold))
                Text(exportPillLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .kerning(0.5)
            }
            .foregroundStyle(hasAudio ? .secondary : .tertiary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.white.opacity(hasAudio ? 0.05 : 0.02))
            )
            .overlay(Capsule().stroke(Color.white.opacity(hasAudio ? 0.12 : 0.06), lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!hasAudio)
        .help(hasAudio
              ? "Save captured ambient audio as a WAV (local only, never uploaded)."
              : "No ambient audio captured yet.")
    }

    @State private var exportFeedback: String? = nil

    private var exportPillLabel: String {
        if let f = exportFeedback { return f }
        return "Save WAV"
    }

    private func performExport(seconds: Double) {
        WakeLog.shared.log("hud: export audio seconds=\(Int(seconds))")
        // Ring + writer are safe to call from main; keep on-thread so the
        // "Saved" label appears immediately.
        if let url = AudioExportStore.exportAmbientTail(seconds: seconds) {
            AudioExportStore.reveal(url)
            exportFeedback = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if exportFeedback == "Saved ✓" { exportFeedback = nil }
            }
        } else {
            exportFeedback = "No audio"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if exportFeedback == "No audio" { exportFeedback = nil }
            }
        }
    }

    private func pill(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).kerning(0.5)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.white.opacity(0.05))
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        }.buttonStyle(.plain)
    }

    private func sectionHeader(
        label: String,
        countBadge: Int?,
        isExpandable: Bool = false,
        isExpanded: Bool = false,
        toggle: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(spacing: 6) {
            Text(label)
                .font(GruxType.microCaps)
                .kerning(2)
                .foregroundStyle(.secondary)
            if let c = countBadge, c > 0 {
                Text("\(c)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isExpanded ? .white : .secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        Capsule().fill(isExpanded
                                       ? Color.purple.opacity(0.55)
                                       : Color.white.opacity(0.08))
                    )
            }
            Spacer()
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(MotionTokens.gated(MotionTokens.easeOutBase), value: isExpanded)
            }
        }
        .contentShape(Rectangle())

        return Group {
            if let toggle, isExpandable {
                Button(action: {
                    WakeLog.shared.log("hud: section '\(label)' toggle tapped → expanded=\(!isExpanded)")
                    toggle()
                }) { content }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand to see all")
            } else {
                content
            }
        }
    }
}

// MARK: - Glass shell

private struct GlassShell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            // Base vibrancy blur
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
            // Subtle gradient overlay for depth
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        Color.purple.opacity(0.035),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.purple.opacity(0.55),
                            Color.indigo.opacity(0.30),
                            Color.cyan.opacity(0.25),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .purple.opacity(0.30), radius: 28, x: 0, y: 14)
        .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 6)
    }
}

private struct GlassRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
    }
}

// NSVisualEffectView wrapped for SwiftUI - gives true macOS vibrancy behind
// the HUD (real blur, not tinted translucency).
struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Makes the header a drag region so the HUD panel can be moved around.
// NSPanel with .nonactivatingPanel doesn't get the auto drag bar, so we add
// one ourselves via an NSView that forwards mouseDown to performDrag.
struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = DragView()
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { true }
}
