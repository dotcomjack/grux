import SwiftUI

// Schedules tab: list + editor split for user-authored cron jobs. The user picks
// weekdays + a time, then either a registered CommandsV2 workflow or a
// free-text agent prompt. Persists through UserCronStore; the standalone
// UserCronScheduler picks changes up on its next tick (no rearm dance).
struct UserCronEditorView: View {
    @ObservedObject private var store = UserCronStore.shared
    @ObservedObject private var engine = CommandV2Engine.shared

    @State private var selection: UUID?

    // Local editor state, synced from the selected job, committed on change.
    @State private var editTitle = ""
    @State private var editWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var editTime = Date()
    @State private var editActionKind: ActionKind = .runCommand
    @State private var editDefinitionId = ""
    @State private var editPrompt = ""
    @State private var editEnabled = true
    @State private var editNotify = true
    // Guards against onChange feedback loops while syncing editor state.
    @State private var syncing = false

    private enum ActionKind: String, CaseIterable, Identifiable {
        case runCommand, agentPrompt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .runCommand: return "Run workflow"
            case .agentPrompt: return "Agent prompt"
            }
        }
    }

    private static let dayLabels: [(Int, String)] = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")
    ]

    private var selected: UserCronJob? { selection.flatMap { store.job(id: $0) } }

    var body: some View {
        GruxListDetailScaffold {
            listColumn
        } detail: {
            editorColumn
        }
        .onAppear {
            engine.load()
            if selection == nil { selection = store.jobs.first?.id }
            syncEditor()
        }
        .onChange(of: selection) { _, _ in syncEditor() }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            GruxToolbar("Schedules") {
                Spacer()
                GruxToolbarButton(title: "New", systemImage: "plus",
                                  prominent: true, helpText: "New schedule", action: newJob)
            }

            if store.jobs.isEmpty {
                // Empty list: the single create CTA empty state lives in the
                // detail pane (see editorColumn). The list column stays quiet so
                // we don't shout the same instruction twice side by side. The
                // "New" toolbar button above still offers the action here.
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(store.jobs) { job in
                        jobRow(job)
                            .tag(job.id)
                            .contextMenu {
                                Button(job.enabled ? "Disable" : "Enable") {
                                    _ = store.setEnabled(id: job.id, !job.enabled)
                                    syncEditor()
                                }
                                DestructiveMenuButton(
                                        "Delete",
                                        question: "Delete this schedule?",
                                        detail: "It stops running and its definition is removed. "
                                            + "This cannot be undone.",
                                        confirmLabel: "Delete schedule"
                                    ) {
                                    deleteJob(job.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func jobRow(_ job: UserCronJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: GruxSpacing.xs + 1) {
                Circle()
                    .fill(job.enabled ? GruxTheme.successMint : GruxTheme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(job.title.isEmpty ? "Untitled schedule" : job.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
            }
            Text(job.scheduleSummary)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
            Text(job.action.summary)
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.accentCo.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.vertical, GruxSpacing.xs - 2)
        .opacity(job.enabled ? 1 : 0.55)
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let job = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: GruxSpacing.l) {
                    HStack(spacing: GruxSpacing.s) {
                        TextField("Schedule name", text: $editTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(GruxTheme.textPrimary)
                        Toggle("", isOn: $editEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .help(editEnabled ? "Enabled" : "Disabled")
                        Button {
                            deleteJob(job.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(GruxTheme.destructiveRose.opacity(0.85))
                                .padding(4)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Delete schedule")
                    }

                    sectionLabel("WHEN")
                    HStack(spacing: GruxSpacing.s - 2) {
                        ForEach(Self.dayLabels, id: \.0) { (day, label) in
                            dayChip(day: day, label: label)
                        }
                        Spacer()
                        DatePicker("", selection: $editTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .frame(width: 90)
                    }
                    HStack(spacing: GruxSpacing.s) {
                        presetChip("Weekdays", days: [2, 3, 4, 5, 6])
                        presetChip("Every day", days: Set(1...7))
                        presetChip("Weekends", days: [1, 7])
                    }

                    sectionLabel("ACTION")
                    Picker("", selection: $editActionKind) {
                        ForEach(ActionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Ceiling, not a demand. A segmented picker fills whatever
                    // it is handed, so 260 is here to stop the two segments
                    // stretching the width of the pane; as a max it still
                    // renders 260 and gives width back instead of overflowing.
                    // The margin is thinner than it looks: at the 599pt pane
                    // floor this editor column is 318 wide, and 16pt of padding
                    // per side leaves 286.
                    .frame(maxWidth: 260)

                    switch editActionKind {
                    case .runCommand:
                        if engine.definitions.isEmpty {
                            // "registered yet" described an action the user does
                            // not have: workflows are BUILT IN, seeded by
                            // registerBuiltinDefinitions() inside load(), and
                            // there is no register-a-workflow surface anywhere.
                            // So the old copy told a stranger to go and do
                            // something impossible.
                            //
                            // This branch is also close to unreachable, which is
                            // why it went unnoticed: load() is called in this
                            // view's own onAppear and seeds the builtins
                            // synchronously, so by first render the list is
                            // non-empty. It stays as an honest fallback rather
                            // than being deleted, because "unreachable today"
                            // stops being true the moment loading turns async.
                            Text("No workflows loaded yet. Grux ships these built in, so close and reopen this sheet.")
                                .font(GruxTheme.Font.caption)
                                .foregroundStyle(GruxTheme.textSecondary)
                        } else {
                            Picker("Workflow", selection: $editDefinitionId) {
                                ForEach(engine.definitions, id: \.id) { def in
                                    Text(def.displayName).tag(def.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    case .agentPrompt:
                        TextEditor(text: $editPrompt)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80, maxHeight: 160)
                            .padding(GruxSpacing.s)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        Text("Spawns one Claude agent with this prompt when the schedule fires.")
                            .font(GruxTheme.Font.microCaps)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }

                    Toggle("Notify when it fires", isOn: $editNotify)
                        .toggleStyle(.checkbox)
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(GruxTheme.textSecondary)

                    sectionLabel("NEXT FIRE")
                    Text(nextFirePreview(job))
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(editEnabled ? GruxTheme.successMint : GruxTheme.textTertiary)
                }
                .padding(GruxSpacing.l)
            }
            .onChange(of: editTitle) { _, _ in commit() }
            .onChange(of: editWeekdays) { _, _ in commit() }
            .onChange(of: editTime) { _, _ in commit() }
            .onChange(of: editActionKind) { _, _ in commit() }
            .onChange(of: editDefinitionId) { _, _ in commit() }
            .onChange(of: editPrompt) { _, _ in commit() }
            .onChange(of: editEnabled) { _, _ in commit() }
            .onChange(of: editNotify) { _, _ in commit() }
        } else if store.jobs.isEmpty {
            // Zero schedules: the one empty state for this situation. Carries the
            // create CTA and the voice hint (the list column stays quiet so the
            // instruction is not duplicated).
            GruxEmptyState(
                icon: "clock.badge.checkmark",
                line: "No schedules yet",
                detail: "Recurring workflows and agent prompts",
                ctaTitle: "New schedule",
                ctaAction: newJob,
                voiceHint: "Grux, every weekday at 9..."
            )
        } else {
            // Schedules exist but none is selected: prompt to pick one.
            GruxEmptyState(
                icon: "calendar.badge.clock",
                line: "Select a schedule or create one",
                ctaTitle: "New schedule",
                ctaAction: newJob
            )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        GruxSectionLabel(text)
    }

    private func dayChip(day: Int, label: String) -> some View {
        let on = editWeekdays.contains(day)
        return Button {
            if on { editWeekdays.remove(day) } else { editWeekdays.insert(day) }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? Color.white : GruxTheme.textSecondary)
                .background(
                    Circle().fill(on ? GruxTheme.accentPrimary : Color.white.opacity(0.06))
                )
                .overlay(
                    Circle().stroke(on ? Color.white.opacity(0.25) : Color.white.opacity(0.10), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private func presetChip(_ title: String, days: Set<Int>) -> some View {
        Button {
            editWeekdays = days
        } label: {
            Text(title)
                .font(GruxTheme.Font.microCaps)
                .kerning(1.0)
                .padding(.horizontal, GruxSpacing.m - 2)
                .padding(.vertical, GruxSpacing.xs + 1)
                .foregroundStyle(editWeekdays == days ? Color.white : GruxTheme.textSecondary)
                .background(
                    Capsule().fill(editWeekdays == days ? GruxTheme.accentPrimary.opacity(0.7) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func nextFirePreview(_ job: UserCronJob) -> String {
        guard editEnabled else { return "Disabled" }
        guard !editWeekdays.isEmpty else { return "Pick at least one day" }
        let (h, m) = Self.hourMinute(from: editTime)
        guard let next = CronSchedule.nextFireDate(after: Date(), weekdays: editWeekdays, hour: h, minute: m) else {
            return "Invalid schedule"
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d 'at' h:mm a"
        df.timeZone = .current
        return df.string(from: next)
    }

    // MARK: - Actions

    private func newJob() {
        let job = store.create(
            title: "New schedule",
            action: .agentPrompt("")
        )
        selection = job.id
        syncEditor()
    }

    private func deleteJob(_ id: UUID) {
        store.delete(id: id)
        if selection == id {
            selection = store.jobs.first?.id
            syncEditor()
        }
    }

    private func syncEditor() {
        syncing = true
        defer { syncing = false }
        guard let job = selected else { return }
        editTitle = job.title
        editWeekdays = job.weekdays
        editTime = Self.date(hour: job.hour, minute: job.minute)
        editEnabled = job.enabled
        editNotify = job.notifyOnFire
        switch job.action {
        case .runCommand(let id):
            editActionKind = .runCommand
            editDefinitionId = id.isEmpty ? (engine.definitions.first?.id ?? "") : id
            editPrompt = ""
        case .agentPrompt(let p):
            editActionKind = .agentPrompt
            editPrompt = p
            editDefinitionId = engine.definitions.first?.id ?? ""
        }
    }

    private func commit() {
        guard !syncing, var job = selected else { return }
        job.title = editTitle
        job.weekdays = editWeekdays
        let (h, m) = Self.hourMinute(from: editTime)
        job.hour = h
        job.minute = m
        job.enabled = editEnabled
        job.notifyOnFire = editNotify
        switch editActionKind {
        case .runCommand:
            let id = editDefinitionId.isEmpty ? (engine.definitions.first?.id ?? "") : editDefinitionId
            job.action = .runCommand(definitionId: id)
        case .agentPrompt:
            job.action = .agentPrompt(editPrompt)
        }
        _ = store.update(job)
    }

    // MARK: - Time helpers

    static func hourMinute(from date: Date) -> (Int, Int) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 9, comps.minute ?? 0)
    }

    static func date(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? Date()
    }
}
