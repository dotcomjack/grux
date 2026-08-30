import SwiftUI

// Presets pane: list + editor split, same skeleton as UserCronEditorView.
// Left column lists every preset grouped by kind; right column edits the
// selection (name, kind, model pin, system prompt, tool groups, notes) and
// carries Apply / Duplicate / Delete. Apply only exists for chat presets;
// swarm and cron presets are consumed by their own flows.
struct PresetsView: View {
    @ObservedObject private var store = PresetStore.shared

    @State private var selection: UUID?

    // Local editor state, synced from the selected preset, committed on change.
    @State private var editName = ""
    @State private var editKind: PresetKind = .chat
    @State private var editModelId = ""
    @State private var editTemperature: Double = 0.5
    @State private var editProvider: String = ""
    // Config-state overrides. "" maps to nil (inherit) for the string-backed
    // pickers/fields; the rate slider is only meaningful when the toggle is on.
    @State private var editMode: String = ""              // "" = inherit, else GruxMode rawValue
    @State private var editVoiceId: String = ""
    @State private var editVoiceModelId: String = ""
    @State private var editVoiceRateOn: Bool = false      // false = inherit playback rate
    @State private var editVoiceRate: Double = 1.25
    @State private var editUseElevenLabs: String = ""     // "" = inherit, "on", "off"
    @State private var editSystemPrompt = ""
    @State private var editGroups: Set<PresetToolGroup> = []
    @State private var editNotes = ""
    // Guards against onChange feedback loops while syncing editor state.
    @State private var syncing = false
    @State private var confirmingDelete = false

    private var selected: Preset? { selection.flatMap { store.preset(id: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                // 280 is what the index WANTS, not what it takes. As a hard
                // width it kept its number while the pane narrowed and the
                // editor beside it absorbed every lost point, until the form
                // rows (label column plus field) had nowhere left to go and
                // clipped. Bounded, the HStack still hands the column its full
                // 280 at any ordinary size and shrinks it toward
                // listColumnMin first as the pane approaches its 599pt floor,
                // so the thing being edited degrades last. 280 is
                // GruxLayout.listColumnIdeal exactly, so nothing moves today.
                .frame(minWidth: GruxLayout.listColumnMin,
                       idealWidth: GruxLayout.listColumnIdeal,
                       maxWidth: GruxLayout.listColumnIdeal)
            Divider()
            editorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if selection == nil { selection = store.ordered.first?.id }
            syncEditor()
        }
        .onChange(of: selection) { _, _ in syncEditor() }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Presets")
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                Button(action: newPreset) {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(GruxTheme.accentPrimary)
                .help("New preset")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if store.presets.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24))
                        .foregroundStyle(GruxTheme.textTertiary)
                    Text("No presets yet")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                    Text("Prompt, model, and tool bundles")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(PresetKind.allCases) { kind in
                        let inKind = store.presets(kind: kind)
                        if !inKind.isEmpty {
                            Section(kind.label) {
                                ForEach(inKind) { preset in
                                    presetRow(preset)
                                        .tag(preset.id)
                                        .contextMenu {
                                            if preset.kind == .chat {
                                                if store.activeChatPresetId == preset.id {
                                                    Button("Clear active") { store.setActiveChat(id: nil) }
                                                } else {
                                                    Button("Apply to chat") { store.setActiveChat(id: preset.id) }
                                                }
                                            }
                                            Button("Duplicate") { duplicate(preset.id) }
                                            Button("Delete", role: .destructive) {
                                                selection = preset.id
                                                confirmingDelete = true
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func presetRow(_ preset: Preset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: preset.kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                Text(rowSubtitle(preset))
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if store.activeChatPresetId == preset.id {
                Text("ACTIVE")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.0)
                    .foregroundStyle(GruxTheme.successMint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(GruxTheme.successMint.opacity(0.14)))
            }
        }
        .padding(.vertical, 2)
    }

    private func rowSubtitle(_ preset: Preset) -> String {
        var parts: [String] = []
        if !preset.modelId.isEmpty { parts.append(preset.modelId) }
        let groups = preset.enabledGroups
        parts.append(groups.isEmpty ? "all tools" : "\(groups.count) tool groups")
        return parts.joined(separator: " · ")
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let preset = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorHeader(preset)
                    nameAndKind
                    modelField
                    tempField
                    providerField
                    modeField
                    voiceField
                    promptField
                    toolGroupsField
                    notesField
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28))
                    .foregroundStyle(GruxTheme.textTertiary)
                Text("Select a preset, or create one")
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorHeader(_ preset: Preset) -> some View {
        HStack(spacing: 8) {
            Text(preset.name)
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            if preset.kind == .chat {
                if store.activeChatPresetId == preset.id {
                    GruxChip(title: "ACTIVE, CLEAR", systemImage: "checkmark", style: .success) {
                        store.setActiveChat(id: nil)
                    }
                    .help("This preset shapes every chat turn. Click to go back to stock Grux.")
                } else {
                    GruxChip(title: "APPLY TO CHAT", systemImage: "bolt.fill", style: .primary) {
                        store.setActiveChat(id: preset.id)
                    }
                    .help("Use this preset's prompt, model, and tools for chat turns")
                }
            }
            GruxChip(title: "DUPLICATE", systemImage: "plus.square.on.square", style: .secondary) {
                duplicate(preset.id)
            }
            GruxChip(title: "DELETE", systemImage: "trash", style: .destructive) {
                confirmingDelete = true
            }
            .confirmationDialog(
                "Delete \"\(preset.name)\"?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete preset", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var nameAndKind: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("NAME")
                TextField("Preset name", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                    .onChange(of: editName) { _, _ in commit() }
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("KIND")
                Picker("", selection: $editKind) {
                    ForEach(PresetKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 220)
                .onChange(of: editKind) { _, _ in commit() }
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("MODEL OVERRIDE")
            TextField("Empty = current default model", text: $editModelId)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(GruxTheme.Font.mono)
                .frame(maxWidth: 320)
                .onChange(of: editModelId) { _, _ in commit() }
            Text("A Claude model id, or a local tag when offline mode is on.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var tempField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("TEMPERATURE")
            HStack(spacing: 10) {
                Slider(value: $editTemperature, in: 0.0...1.0, step: 0.05)
                    .frame(maxWidth: 260)
                    .controlSize(.small)
                    .onChange(of: editTemperature) { _, _ in commit() }
                Text(String(format: "%.2f", editTemperature))
                    .font(GruxTheme.Font.mono)
                    .foregroundStyle(GruxTheme.textSecondary)
            }
            Text("Lower = focused and deterministic, higher = creative. Default 0.5.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var providerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("PROVIDER")
            Picker("", selection: $editProvider) {
                Text("Inherit (current default)").tag("")
                Text("Anthropic (Claude, cloud)").tag("anthropic")
                Text("Local (offline model)").tag("local")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 280)
            .controlSize(.small)
            .onChange(of: editProvider) { _, _ in commit() }
            Text("Pin which brain this preset uses. Local needs a discovered local server (Settings, Offline mode).")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var modeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("MODE")
            Picker("", selection: $editMode) {
                Text("Inherit (current mode)").tag("")
                ForEach(GruxMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 280)
            .controlSize(.small)
            .onChange(of: editMode) { _, _ in commit() }
            Text("Switches Grux's mode while this preset is active, then restores it on clear.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var voiceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("VOICE")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ELEVENLABS VOICE ID")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                    TextField("Empty = inherit", text: $editVoiceId)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(GruxTheme.Font.mono)
                        .frame(maxWidth: 220)
                        .onChange(of: editVoiceId) { _, _ in commit() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("VOICE MODEL ID")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                    TextField("Empty = inherit", text: $editVoiceModelId)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(GruxTheme.Font.mono)
                        .frame(maxWidth: 220)
                        .onChange(of: editVoiceModelId) { _, _ in commit() }
                }
            }
            HStack(spacing: 10) {
                Toggle("Pin playback rate", isOn: $editVoiceRateOn)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: editVoiceRateOn) { _, _ in commit() }
                if editVoiceRateOn {
                    Slider(value: $editVoiceRate, in: 0.75...2.0, step: 0.05)
                        .frame(maxWidth: 200)
                        .controlSize(.small)
                        .onChange(of: editVoiceRate) { _, _ in commit() }
                    Text(String(format: "%.2fx", editVoiceRate))
                        .font(GruxTheme.Font.mono)
                        .foregroundStyle(GruxTheme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ELEVENLABS TTS")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                Picker("", selection: $editUseElevenLabs) {
                    Text("Inherit").tag("")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
                .controlSize(.small)
                .onChange(of: editUseElevenLabs) { _, _ in commit() }
            }
            Text("Pins voice settings while active and restores them on clear. Empty / Inherit leaves each as-is.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("SYSTEM PROMPT ADDITION")
            TextEditor(text: $editSystemPrompt)
                .font(GruxTheme.Font.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110, maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .onChange(of: editSystemPrompt) { _, _ in commit() }
            Text("Appended to Grux's persona for the turn. Leave empty for no prompt change.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var toolGroupsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldLabel("TOOL GROUPS")
                Text(editGroups.isEmpty ? "all tools enabled" : "\(editGroups.count) of \(PresetToolGroup.allCases.count) enabled")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                if !editGroups.isEmpty {
                    Button("Reset to all") {
                        editGroups = []
                        commit()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GruxTheme.accentPrimaryLight)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(PresetToolGroup.allCases) { group in
                    groupChip(group)
                }
            }
            Text("Nothing selected means no restriction. Selecting any group hides the rest's tools from chat turns; core tools always stay on.")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private func groupChip(_ group: PresetToolGroup) -> some View {
        let on = editGroups.contains(group)
        return Button {
            if on { editGroups.remove(group) } else { editGroups.insert(group) }
            commit()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .bold))
                Text(group.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? GruxTheme.textPrimary : GruxTheme.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .fill(on ? GruxTheme.accentPrimary.opacity(0.22) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .stroke(on ? GruxTheme.accentPrimary.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("NOTES")
            TextField("What this preset is for", text: $editNotes)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 420)
                .onChange(of: editNotes) { _, _ in commit() }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(GruxTheme.Font.microCaps)
            .kerning(1.2)
            .foregroundStyle(GruxTheme.textTertiary)
    }

    // MARK: - Actions

    private func newPreset() {
        guard let p = store.create(name: "New preset", kind: .chat) else { return }
        selection = p.id
        syncEditor()
    }

    private func duplicate(_ id: UUID) {
        guard let copy = store.duplicate(id: id) else { return }
        selection = copy.id
        syncEditor()
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        _ = store.delete(id: id)
        selection = store.ordered.first?.id
        syncEditor()
    }

    // MARK: - Sync

    private func syncEditor() {
        syncing = true
        defer { syncing = false }
        guard let p = selected else { return }
        editName = p.name
        editKind = p.kind
        editModelId = p.modelId
        editTemperature = p.temperature ?? 0.5
        editProvider = p.providerOverride ?? ""
        editMode = p.mode?.rawValue ?? ""
        editVoiceId = p.voiceId ?? ""
        editVoiceModelId = p.voiceModelId ?? ""
        editVoiceRateOn = p.voicePlaybackRate != nil
        editVoiceRate = p.voicePlaybackRate ?? 1.25
        switch p.useElevenLabs {
        case .some(true): editUseElevenLabs = "on"
        case .some(false): editUseElevenLabs = "off"
        case .none: editUseElevenLabs = ""
        }
        editSystemPrompt = p.systemPrompt
        editGroups = p.enabledGroups
        editNotes = p.notes
    }

    private func commit() {
        guard !syncing, let id = selection else { return }
        // Map editor state to update()'s sentinels: "" clears a string-backed
        // field to inherit; the rate toggle controls whether a rate is pinned;
        // the TTS picker's "" means inherit (nil), "on"/"off" pin the bool.
        let rate: Double?? = editVoiceRateOn ? .some(editVoiceRate) : .some(nil)
        let useEL: Bool??
        switch editUseElevenLabs {
        case "on": useEL = .some(true)
        case "off": useEL = .some(false)
        default: useEL = .some(nil)
        }
        _ = store.update(
            id: id,
            name: editName,
            kind: editKind,
            systemPrompt: editSystemPrompt,
            modelId: editModelId,
            temperature: editTemperature,
            providerOverride: editProvider,
            mode: editMode,
            voiceId: editVoiceId,
            voiceModelId: editVoiceModelId,
            voicePlaybackRate: rate,
            useElevenLabs: useEL,
            enabledToolGroups: editGroups.map { $0.rawValue }.sorted(),
            notes: editNotes
        )
    }
}
