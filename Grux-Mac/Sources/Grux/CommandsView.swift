import SwiftUI

// MARK: - Editor-only wrapper

// Each editor row carries a per-instance UUID so SwiftUI's ForEach has
// stable identity across re-renders (two identical steps like two
// `delay(1.0)` entries can coexist), and so drag-and-drop reordering has
// something concrete to target. The UUID lives in memory only - it's
// re-minted every time we load from disk.
private struct EditableStep: Identifiable, Equatable {
    let id: UUID
    var action: MacroAction
    var enabled: Bool
    var waitForCompletion: Bool
    init(_ step: MacroStep, id: UUID = UUID()) {
        self.id = id
        self.action = step.action
        self.enabled = step.enabled
        self.waitForCompletion = step.waitForCompletion
    }
    var asStep: MacroStep { MacroStep(action: action, enabled: enabled, waitForCompletion: waitForCompletion) }
}

private struct MacroDraft: Equatable {
    var originalName: String   // stable id of the row we're editing (empty for new)
    var name: String
    var triggersText: String   // one trigger per line in the UI
    var description: String
    var items: [EditableStep]

    init(_ macro: Macro) {
        self.originalName = macro.name
        self.name = macro.name
        self.triggersText = macro.triggers.joined(separator: "\n")
        self.description = macro.description
        self.items = macro.actions.map { EditableStep($0) }
    }

    func toMacro() -> Macro {
        let triggers = triggersText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Macro(
            name: VoiceMacroRegistry.sanitize(name: name),
            triggers: triggers,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: items.map(\.asStep)
        )
    }
}

// MARK: - Commands tab

struct CommandsView: View {
    @ObservedObject private var registry = VoiceMacroRegistry.shared
    @State private var expandedName: String?       // which row is expanded
    @State private var drafts: [String: MacroDraft] = [:]   // keyed by originalName
    @State private var runStatus: [String: String] = [:]    // keyed by macro name → last run output
    @State private var testRunning: String?
    @State private var lastAutoSaved: [String: Date] = [:]  // per-macro last autosave time
    @State private var dragOverId: UUID?           // row id currently under the drag hover
    @State private var searchText: String = ""
    @State private var showActiveOnly: Bool = false
    // Row name we should scroll to on next render (set after createNew/duplicate
    // so new rows inserted into a big list don't land offscreen and look like
    // nothing happened).
    @State private var pendingScrollTo: String?

    // Case-insensitive substring match across name, triggers, and description.
    // Empty search returns everything. Stable (no re-sort) so row order during
    // typing matches row order with the field empty.
    private var filteredMacros: [Macro] {
        let base = showActiveOnly ? registry.macros.filter(\.enabled) : registry.macros
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { m in
            if m.name.lowercased().contains(q) { return true }
            if m.description.lowercased().contains(q) { return true }
            for t in m.triggers where t.lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        let shown = filteredMacros
                        ForEach(shown) { macro in
                            macroCard(macro).id(macro.name)
                        }
                        if registry.macros.isEmpty {
                            emptyState
                        } else if shown.isEmpty {
                            noMatchesState
                        }
                    }
                    .padding(16)
                }
                .onChange(of: pendingScrollTo) { _, newName in
                    guard let name = newName else { return }
                    // Let the ForEach render the new row, then scroll to it.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(name, anchor: .top)
                        }
                        pendingScrollTo = nil
                    }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Grux Commands").font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                Text("| voice macros")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    createNew()
                } label: {
                    Label("New Command", systemImage: "plus.circle.fill")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            HStack(spacing: 8) {
                let total = registry.macros.count
                let active = registry.macros.filter(\.enabled).count
                chipButton(label: "All (\(total))", selected: !showActiveOnly) {
                    showActiveOnly = false
                }
                chipButton(label: "Active only (\(active))", selected: showActiveOnly) {
                    showActiveOnly = true
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search name, trigger phrase, or description", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                Text("\(filteredMacros.count)/\(registry.macros.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding()
    }

    @ViewBuilder
    private func chipButton(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? GruxTheme.accentPrimary.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(selected ? GruxTheme.accentPrimary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text("No commands match \u{201C}\(searchText)\u{201D}.").font(.headline)
            Button("Clear search") { searchText = "" }
                .buttonStyle(.bordered)
        }
        .padding(32)
    }

    /// The empty stack's copy, static so it can be asserted on.
    ///
    /// The registry ships NO seed macros, deliberately (see VoiceMacros.swift:
    /// a compiled-in default became a file on disk the first time anybody
    /// edited anything). So this is what every install opens on, and it has to
    /// teach the two halves of a macro rather than just say there are none.
    static let emptyCopy = (
        headline: "No commands yet.",
        detail: "Click **New Command** to build your first voice macro. "
            + "Triggers are the spoken phrases Grux listens for; "
            + "actions are the steps Grux runs when you say one."
    )

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text(Self.emptyCopy.headline).font(.headline)
            // EXPLICIT LocalizedStringKey, because the literal that used to sit
            // here got one for free and that is what rendered `**New Command**`
            // bold. Handing `Text` a plain String selects the verbatim overload
            // instead, and the asterisks would have shown up on screen.
            Text(LocalizedStringKey(Self.emptyCopy.detail))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
        .padding(32)
    }

    // MARK: Card

    @ViewBuilder
    private func macroCard(_ macro: Macro) -> some View {
        let isExpanded = expandedName == macro.name
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(macro, isExpanded: isExpanded)
            if isExpanded {
                Divider()
                if let draft = drafts[macro.name] {
                    editor(for: macro, draft: Binding(
                        get: { drafts[macro.name] ?? draft },
                        set: { drafts[macro.name] = $0 }
                    ))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(isExpanded ? 0.18 : 0.08), lineWidth: 1)
        )
    }

    private func cardHeader(_ macro: Macro, isExpanded: Bool) -> some View {
        let dim = macro.enabled ? 1.0 : 0.5
        return HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 12)
                .opacity(dim)
            Toggle("", isOn: Binding(
                get: { macro.enabled },
                set: { newVal in
                    var updated = macro
                    updated.enabled = newVal
                    registry.upsert(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(macro.enabled ? "Macro is ON, Grux will run it" : "Macro is OFF, Grux ignores it")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(macro.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .strikethrough(!macro.enabled)
                    // A BUILT-IN badge used to render here, matched on one
                    // literal macro name. Nothing is compiled in any more, so
                    // that badge could only ever fire on a macro the user wrote
                    // themselves, stamping their own work as ours. Removed
                    // rather than rewired: if built-ins ever return, the honest
                    // signal is a flag on the macro, never a name comparison.
                }
                if !macro.triggers.isEmpty {
                    Text(macro.triggers.map { "“\($0)”" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !macro.description.isEmpty {
                    Text(macro.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .opacity(dim)
            Spacer()
            Text("\(macro.actions.count) step\(macro.actions.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(dim)
            Menu {
                Button("Edit") { expand(macro) }
                Button {
                    Task { await runMacro(macro.name) }
                } label: { Label("Test Run", systemImage: "play.fill") }
                Button("Duplicate") {
                    if let copy = registry.duplicate(name: macro.name) {
                        expand(copy)
                    }
                }
                Divider()
                DestructiveMenuButton(
                    "Delete",
                    question: "Delete this command?",
                    detail: "The command and its steps are removed, and anything scheduled to run "
                        + "it stops working. This cannot be undone.",
                    confirmLabel: "Delete command"
                ) {
                    deleteMacro(macro.name)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .opacity(dim)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { collapse() } else { expand(macro) }
        }
    }

    // MARK: Editor

    private func editor(for macro: Macro, draft: Binding<MacroDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name + sanitize hint
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    let sanitized = VoiceMacroRegistry.sanitize(name: draft.wrappedValue.name)
                    if sanitized != draft.wrappedValue.name {
                        Text("→ saves as `\(sanitized)`").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                TextField("machine_name (snake_case)", text: draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Triggers, one phrase per line").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: draft.triggersText)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What this does (Claude sees this)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("One-line description", text: draft.description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("| drag to reorder, toggle to skip")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Menu {
                        ForEach(MacroAction.Kind.allCases, id: \.self) { kind in
                            Button(kind.label) {
                                draft.wrappedValue.items.append(
                                    EditableStep(MacroStep(action: MacroAction.defaultAction(for: kind)))
                                )
                            }
                        }
                    } label: {
                        Label("Add Action", systemImage: "plus.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }

                if draft.wrappedValue.items.isEmpty {
                    Text("No actions yet. Add one above.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(draft.wrappedValue.items.enumerated()), id: \.element.id) { idx, item in
                            ActionEditorRow(
                                action: Binding(
                                    get: { draft.wrappedValue.items[idx].action },
                                    set: { draft.wrappedValue.items[idx].action = $0 }
                                ),
                                enabled: Binding(
                                    get: { draft.wrappedValue.items[idx].enabled },
                                    set: { draft.wrappedValue.items[idx].enabled = $0 }
                                ),
                                waitForCompletion: Binding(
                                    get: { draft.wrappedValue.items[idx].waitForCompletion },
                                    set: { draft.wrappedValue.items[idx].waitForCompletion = $0 }
                                ),
                                index: idx,
                                isDragTarget: dragOverId == item.id,
                                remove: { draft.wrappedValue.items.remove(at: idx) },
                                duplicate: {
                                    let copy = EditableStep(
                                        MacroStep(action: draft.wrappedValue.items[idx].action,
                                                  enabled: draft.wrappedValue.items[idx].enabled,
                                                  waitForCompletion: draft.wrappedValue.items[idx].waitForCompletion)
                                    )
                                    draft.wrappedValue.items.insert(copy, at: idx + 1)
                                },
                                insertAbove: { kind in
                                    draft.wrappedValue.items.insert(
                                        EditableStep(MacroStep(action: MacroAction.defaultAction(for: kind))),
                                        at: idx
                                    )
                                },
                                insertBelow: { kind in
                                    draft.wrappedValue.items.insert(
                                        EditableStep(MacroStep(action: MacroAction.defaultAction(for: kind))),
                                        at: idx + 1
                                    )
                                }
                            )
                            // Each row is both a drag source (its own id) and
                            // a drop destination. Moving within the same list
                            // is an index swap keyed by UUID, so the editor
                            // doesn't care about pointer identity.
                            .draggable(item.id.uuidString) {
                                DragPreviewPill(text: "\(idx + 1). \(item.action.summary)")
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                guard let raw = ids.first,
                                      let srcUUID = UUID(uuidString: raw),
                                      let srcIdx = draft.wrappedValue.items.firstIndex(where: { $0.id == srcUUID }),
                                      srcIdx != idx else {
                                    dragOverId = nil
                                    return false
                                }
                                let moving = draft.wrappedValue.items.remove(at: srcIdx)
                                let insertAt = srcIdx < idx ? idx : idx
                                draft.wrappedValue.items.insert(moving, at: min(insertAt, draft.wrappedValue.items.count))
                                dragOverId = nil
                                return true
                            } isTargeted: { hovering in
                                dragOverId = hovering ? item.id : (dragOverId == item.id ? nil : dragOverId)
                            }
                        }
                    }
                }
            }

            if let status = runStatus[macro.name] {
                ScrollView {
                    Text(status)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await runMacro(macro.name) }
                } label: {
                    if testRunning == macro.name {
                        ProgressView().controlSize(.small).padding(.trailing, 4)
                        Text("Running…")
                    } else {
                        Label("Test Run", systemImage: "play.fill")
                    }
                }
                .disabled(testRunning != nil)

                autoSaveBadge(for: macro.name)

                Spacer()

                DestructiveMenuButton(
                    "Delete",
                    question: "Delete this command?",
                    detail: "The command and its steps are removed, and anything scheduled to run "
                        + "it stops working. This cannot be undone.",
                    confirmLabel: "Delete command"
                ) {
                    deleteMacro(macro.name)
                }
                Button("Done") { collapse() }
                Button("Save") { save(originalName: macro.name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDraftValid(originalName: macro.name))
            }
        }
        .padding(12)
        // Autosave every meaningful edit (fields or actions) so closing the
        // editor without clicking Save can't lose work. Rename-to-a-new-name
        // still requires Save (because it deletes the old row first).
        .onChange(of: draft.wrappedValue) { _, _ in
            autosave(originalName: macro.name)
        }
    }

    // Show a subtle "saved" indicator for a few seconds after an autosave.
    @ViewBuilder
    private func autoSaveBadge(for name: String) -> some View {
        if let t = lastAutoSaved[name], Date().timeIntervalSince(t) < 3 {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }

    // MARK: Actions

    private func createNew() {
        // Clear any active search so the new row is visible in the filtered
        // list (otherwise clicking "New Command" while filtered would add a
        // row that's immediately hidden - the same "nothing happened" UX bug
        // the big-list-offscreen case caused).
        searchText = ""
        let template = registry.newMacroTemplate()
        registry.upsert(template)
        expand(template)
        // Queue a scroll-to so the new row appears at the top of the viewport
        // instead of tacked on at the bottom of a 83-item scroll.
        pendingScrollTo = template.name
    }

    private func expand(_ macro: Macro) {
        drafts[macro.name] = MacroDraft(macro)
        expandedName = macro.name
        // Scroll to the expanded row so the editor is in view even when the
        // user clicked Edit from the ellipsis menu on a row far down the list.
        pendingScrollTo = macro.name
    }

    private func collapse() {
        expandedName = nil
    }

    private func isDraftValid(originalName: String) -> Bool {
        guard let draft = drafts[originalName] else { return false }
        let sanitized = VoiceMacroRegistry.sanitize(name: draft.name)
        guard !sanitized.isEmpty else { return false }
        // Name collision with a DIFFERENT existing macro blocks save.
        if sanitized != originalName && registry.macros.contains(where: { $0.name == sanitized }) {
            return false
        }
        return true
    }

    private func save(originalName: String) {
        guard let draft = drafts[originalName] else { return }
        let updated = draft.toMacro()
        // If the name changed, delete the old row first so we don't leave a duplicate.
        if originalName != updated.name {
            registry.delete(name: originalName)
        }
        registry.upsert(updated)
        drafts.removeValue(forKey: originalName)
        expandedName = updated.name
        drafts[updated.name] = MacroDraft(updated)   // keep editor open on the renamed row
        lastAutoSaved[updated.name] = Date()
    }

    // Write the current draft to disk in-place (no rename). Rename still
    // requires explicit Save because it would delete the old row. This runs
    // on every field/action change so closing the window mid-edit never
    // loses data - exactly the bug reported in the voice memo.
    private func autosave(originalName: String) {
        guard let draft = drafts[originalName] else { return }
        let updated = draft.toMacro()
        // Skip autosave during a rename - the sanitized new name doesn't match
        // the original row yet, and upsert(updated) with a different name
        // would ORPHAN the old row. User has to hit Save explicitly to
        // commit the rename.
        guard updated.name == originalName else { return }
        guard isDraftValid(originalName: originalName) else { return }
        registry.upsert(updated)
        lastAutoSaved[originalName] = Date()
    }

    private func deleteMacro(_ name: String) {
        registry.delete(name: name)
        drafts.removeValue(forKey: name)
        if expandedName == name { expandedName = nil }
        runStatus.removeValue(forKey: name)
    }

    private func runMacro(_ name: String) async {
        testRunning = name
        runStatus[name] = "running…"
        let result = await VoiceMacroRegistry.shared.run(name: name)
        runStatus[name] = result
        testRunning = nil
    }
}

// MARK: - Per-action editor row

// Small floating pill shown while the user drags an action row. Matches
// the row layout minimally so the drag preview is recognizable.
private struct DragPreviewPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(radius: 4)
    }
}

private struct ActionEditorRow: View {
    @Binding var action: MacroAction
    @Binding var enabled: Bool
    @Binding var waitForCompletion: Bool
    let index: Int
    let isDragTarget: Bool
    let remove: () -> Void
    let duplicate: () -> Void
    let insertAbove: (MacroAction.Kind) -> Void
    let insertBelow: (MacroAction.Kind) -> Void

    // Some kinds are inherently blocking - exposing a "fire and forget"
    // checkbox would just confuse the user.
    private var supportsAsyncRun: Bool {
        switch action {
        case .delay, .awaitSilence, .runShell, .runAppleScript, .speakShellOutput, .openEmpireDashboard:
            return false
        default:
            return true
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Drag handle - the whole row is `.draggable` in the parent, but
            // this explicit grip makes the affordance obvious.
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 7)
                .help("Drag to reorder")

            Text("\(index + 1).")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 6)

            // Per-action enable toggle. Disabled steps stay in the list but
            // are skipped at run time (see VoiceMacroRegistry.run).
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .padding(.top, 4)
                .help(enabled ? "Step is ON, will run" : "Step is OFF, will be skipped")

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: kindBinding) {
                    ForEach(MacroAction.Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                paramFields

                if supportsAsyncRun {
                    HStack(spacing: 6) {
                        Toggle(isOn: $waitForCompletion) {
                            Text("Wait for completion before next step")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        if !waitForCompletion {
                            Image(systemName: "arrow.right.to.line")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Fire-and-forget: next step starts immediately")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(enabled ? 1.0 : 0.45)

            Menu {
                Menu("Insert above") {
                    ForEach(MacroAction.Kind.allCases, id: \.self) { kind in
                        Button(kind.label) { insertAbove(kind) }
                    }
                }
                Menu("Insert below") {
                    ForEach(MacroAction.Kind.allCases, id: \.self) { kind in
                        Button(kind.label) { insertBelow(kind) }
                    }
                }
                Button("Duplicate", action: duplicate)
                Divider()
                DestructiveButton("Delete",
                              question: "Delete this command?",
                              detail: "The command and its steps are removed. This cannot be undone.",
                              confirmLabel: "Delete command", action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .padding(.top, 4)
            .help("Insert above/below, duplicate, or delete this step")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(enabled ? 0.04 : 0.02))
        )
        .overlay(
            // Highlight the row currently under a drag hover so the drop
            // target is unambiguous.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isDragTarget ? GruxTheme.accentPrimary : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var kindBinding: Binding<MacroAction.Kind> {
        Binding(
            get: { action.kindID },
            set: { newKind in
                if newKind != action.kindID {
                    action = MacroAction.defaultAction(for: newKind)
                }
            }
        )
    }

    @ViewBuilder
    private var paramFields: some View {
        switch action {
        case .launchApp:
            TextField("App name (e.g. Safari, Messages)", text: launchAppBinding)
                .textFieldStyle(.roundedBorder)
        case .openURL:
            TextField("https://…", text: openURLBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        case .spawnTerminalsToGrid:
            HStack {
                Stepper(value: rowsBinding, in: 1...4) {
                    Text("Rows: \(currentRows)")
                }
                Stepper(value: colsBinding, in: 1...4) {
                    Text("Cols: \(currentCols)")
                }
            }
        case .enableTerminalFocusOverlay:
            Text("No parameters. Turns the overlay on.")
                .font(.caption).foregroundStyle(.tertiary)
        case .disableTerminalFocusOverlay:
            Text("No parameters. Tears the overlay down; Terminal windows stay.")
                .font(.caption).foregroundStyle(.tertiary)
        case .playMusic:
            SongPicker(
                song: songBinding,
                artist: artistBinding
            )
        case .prepareCleanWorkspace:
            Text("No parameters. Minimizes Terminals, hides other apps.")
                .font(.caption).foregroundStyle(.tertiary)
        case .runShell:
            VStack(alignment: .leading, spacing: 2) {
                TextEditor(text: shellCommandBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text("Runs INVISIBLY in the background via `/bin/zsh -lc`. Output goes to Grux, not the Terminal grid. Must be a real shell command. To type into a Terminal window, use **Run in Terminal grid cell** instead. 30s timeout.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .runInTerminalCell:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Stepper(value: cellRowBinding, in: 0...3) {
                        Text("Row: \(currentCellRow)")
                    }
                    Stepper(value: cellColBinding, in: 0...3) {
                        Text("Col: \(currentCellCol)")
                    }
                }
                TextEditor(text: cellCommandBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text("Types this command into the Terminal window at grid cell (row, col), zero-indexed from top-left. Requires a 'Spawn Terminal grid' step earlier in the macro.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .speakShellOutput:
            SpeakShellEditor(
                setup: setupBinding,
                template: templateBinding
            )
        case .runAppleScript:
            VStack(alignment: .leading, spacing: 2) {
                TextEditor(text: scriptSourceBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text("Runs via NSAppleScript. First run may prompt for Automation permission.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .speak:
            VStack(alignment: .leading, spacing: 2) {
                TextField("What Grux should say out loud", text: speakTextBinding)
                    .textFieldStyle(.roundedBorder)
                Text("The macro waits for Grux to finish this line before running the next step.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .delay:
            HStack {
                Text("Seconds:")
                TextField("", value: delayBinding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("(max 60)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .awaitSilence:
            HStack {
                Text("Milliseconds:")
                TextField("", value: awaitSilenceBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("(0 to 10000) pause after the previous spoken line ends")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .openEmpireDashboard:
            Text("No parameters. Opens the Empire Dashboard window with live stats for the past 24 hours.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // Per-case parameter bindings. Each read extracts the associated value;
    // each write rebuilds the enum with the same kind so SwiftUI sees a
    // legitimate assignment.
    private var launchAppBinding: Binding<String> {
        Binding(
            get: { if case .launchApp(let n) = action { return n } else { return "" } },
            set: { action = .launchApp(name: $0) }
        )
    }
    private var openURLBinding: Binding<String> {
        Binding(
            get: { if case .openURL(let u) = action { return u } else { return "" } },
            set: { action = .openURL(url: $0) }
        )
    }
    private var currentRows: Int {
        if case .spawnTerminalsToGrid(let r, _) = action { return r } else { return 2 }
    }
    private var currentCols: Int {
        if case .spawnTerminalsToGrid(_, let c) = action { return c } else { return 2 }
    }
    private var rowsBinding: Binding<Int> {
        Binding(
            get: { currentRows },
            set: { action = .spawnTerminalsToGrid(rows: $0, cols: currentCols) }
        )
    }
    private var colsBinding: Binding<Int> {
        Binding(
            get: { currentCols },
            set: { action = .spawnTerminalsToGrid(rows: currentRows, cols: $0) }
        )
    }
    private var songBinding: Binding<String> {
        Binding(
            get: { if case .playMusic(let s, _) = action { return s } else { return "" } },
            set: { newVal in
                let artist = { if case .playMusic(_, let a) = action { return a } else { return "" } }()
                action = .playMusic(song: newVal, artist: artist)
            }
        )
    }
    private var artistBinding: Binding<String> {
        Binding(
            get: { if case .playMusic(_, let a) = action { return a } else { return "" } },
            set: { newVal in
                let song = { if case .playMusic(let s, _) = action { return s } else { return "" } }()
                action = .playMusic(song: song, artist: newVal)
            }
        )
    }
    private var shellCommandBinding: Binding<String> {
        Binding(
            get: { if case .runShell(let c) = action { return c } else { return "" } },
            set: { action = .runShell(command: $0) }
        )
    }
    private var currentCellRow: Int {
        if case .runInTerminalCell(let r, _, _) = action { return r } else { return 0 }
    }
    private var currentCellCol: Int {
        if case .runInTerminalCell(_, let c, _) = action { return c } else { return 0 }
    }
    private var currentCellCommand: String {
        if case .runInTerminalCell(_, _, let c) = action { return c } else { return "" }
    }
    private var cellRowBinding: Binding<Int> {
        Binding(
            get: { currentCellRow },
            set: { action = .runInTerminalCell(row: $0, col: currentCellCol, command: currentCellCommand) }
        )
    }
    private var cellColBinding: Binding<Int> {
        Binding(
            get: { currentCellCol },
            set: { action = .runInTerminalCell(row: currentCellRow, col: $0, command: currentCellCommand) }
        )
    }
    private var cellCommandBinding: Binding<String> {
        Binding(
            get: { currentCellCommand },
            set: { action = .runInTerminalCell(row: currentCellRow, col: currentCellCol, command: $0) }
        )
    }
    private var currentSpeakShellSetup: String {
        if case .speakShellOutput(let s, _) = action { return s } else { return "" }
    }
    private var currentSpeakShellTemplate: String {
        if case .speakShellOutput(_, let t) = action { return t } else { return "" }
    }
    private var setupBinding: Binding<String> {
        Binding(
            get: { currentSpeakShellSetup },
            set: { action = .speakShellOutput(setup: $0, template: currentSpeakShellTemplate) }
        )
    }
    private var templateBinding: Binding<String> {
        Binding(
            get: { currentSpeakShellTemplate },
            set: { action = .speakShellOutput(setup: currentSpeakShellSetup, template: $0) }
        )
    }
    private var scriptSourceBinding: Binding<String> {
        Binding(
            get: { if case .runAppleScript(let s) = action { return s } else { return "" } },
            set: { action = .runAppleScript(source: $0) }
        )
    }
    private var speakTextBinding: Binding<String> {
        Binding(
            get: { if case .speak(let t) = action { return t } else { return "" } },
            set: { action = .speak(text: $0) }
        )
    }
    private var delayBinding: Binding<Double> {
        Binding(
            get: { if case .delay(let s) = action { return s } else { return 1.0 } },
            set: { action = .delay(seconds: $0) }
        )
    }
    private var awaitSilenceBinding: Binding<Int> {
        Binding(
            get: { if case .awaitSilence(let ms) = action { return ms } else { return 500 } },
            set: { action = .awaitSilence(milliseconds: max(0, min($0, 10_000))) }
        )
    }
}

// MARK: - Song picker (quick-select dropdown)

// Dropdown of saved songs + free-form title/artist fields + "save current"
// button. Backed by SongLibraryStore so the library persists across macros.
// Picking from the menu writes both fields at once; editing either field
// marks the entry "custom" until the user clicks Save to library.
private struct SongPicker: View {
    @Binding var song: String
    @Binding var artist: String
    @ObservedObject private var library = SongLibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    if library.songs.isEmpty {
                        Text("Library is empty. Type a song and click Save")
                    } else {
                        ForEach(library.songs) { s in
                            Button(s.displayTitle) {
                                song = s.song
                                artist = s.artist
                            }
                        }
                        Divider()
                        Menu("Remove from library") {
                            ForEach(library.songs) { s in
                                Button(s.displayTitle) {
                                    library.delete(id: s.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        library.songs.isEmpty ? "Pick saved…" : "Pick saved (\(library.songs.count))",
                        systemImage: "music.note.list"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    _ = library.add(song: song, artist: artist)
                } label: {
                    Label("Save to library", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .disabled(song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || alreadySaved)
                .help(alreadySaved ? "Already in library" : "Add this song+artist to the dropdown")
            }
            HStack(spacing: 6) {
                TextField("Song title", text: $song)
                    .textFieldStyle(.roundedBorder)
                TextField("Artist (optional)", text: $artist)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var alreadySaved: Bool {
        let s = song.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.songs.contains(where: {
            $0.song.caseInsensitiveCompare(s) == .orderedSame &&
            $0.artist.caseInsensitiveCompare(a) == .orderedSame
        })
    }
}

// MARK: - Speak shell output editor (split: spoken template + optional setup)

// The spoken line is the first-class field. Setup (data-fetching shell) is
// kept secondary so the user doesn't have to scan a wall of curl/jq to find
// the words Grux says. Setup auto-expands when there's content; otherwise
// it's a click away.
private struct SpeakShellEditor: View {
    @Binding var setup: String
    @Binding var template: String
    @State private var setupExpanded: Bool

    init(setup: Binding<String>, template: Binding<String>) {
        self._setup = setup
        self._template = template
        // If the user already has setup content, default to expanded so it's
        // visible. Empty setup = collapsed for a cleaner first-author UX.
        _setupExpanded = State(initialValue: !setup.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What Grux says (uses $vars from setup)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $template)
                    .font(.body)
                    .frame(minHeight: 50, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text("Plain English. Reference shell variables with $NAME, they interpolate from the Setup below. Macro waits for the line to finish before the next step.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $setupExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    TextEditor(text: $setup)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 260)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                    Text("Optional. Runs first: set variables here (e.g. `COUNT=$(curl … | jq …)`). Anything you echo here is also spoken; leave blank for a static line.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text("Setup shell (optional)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}
