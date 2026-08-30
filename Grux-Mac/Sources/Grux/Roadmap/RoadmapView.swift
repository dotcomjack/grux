import SwiftUI

// Grux Roadmap tab. Four tiers (S/A/B/C) of whatever the user is building,
// each row toggleable through not-started → in-progress → done by clicking
// the status glyph. Subtitles hold the one-liner rationale; expanded rows
// reveal a free-form notes editor so the user can jot context as they build.
// Context menu lets them move items across tiers, change status explicitly,
// or delete. "Add" button per-section appends new items.
//
// The board starts EMPTY and stays empty until the user types something. It
// used to arrive pre-filled from a compiled-in seed, so this tab is one of the
// surfaces where empty has to be a first-class state rather than a gap: four
// tier headings over four "No items." lines is all chrome and no explanation,
// so a genuinely empty board gets the one empty state instead, which says what
// the tiers mean and offers the first add.

struct RoadmapView: View {
    @ObservedObject private var store = RoadmapStore.shared
    @State private var expanded: Set<UUID> = []
    @State private var addingToTier: RoadmapTier? = nil
    @State private var newTitle: String = ""
    @State private var newSubtitle: String = ""

    // Empty means empty AND not mid-add: the add form lives inside a tier
    // section, so opening it has to flip back to the tier layout or the form
    // the user just asked for would have nowhere to render.
    private var isEmptyBoard: Bool { store.items.isEmpty && addingToTier == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEmptyBoard {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(RoadmapTier.allCases) { tier in
                            tierSection(tier)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .onAppear { store.load() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        GruxEmptyState(
            icon: "map",
            line: "Your roadmap is empty",
            detail: "This is your build plan: what you intend to ship, grouped by when. Tier S is this month, A is next, B is after that, and C is whenever you feel like it. Add an item and pick the tier it belongs in.",
            ctaTitle: "Add your first item",
            ctaAction: {
                addingToTier = .S
                newTitle = ""
                newSubtitle = ""
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        let overall = store.progress()
        let pct = overall.total == 0 ? 0 : Double(overall.done) / Double(overall.total)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Roadmap").font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                Text("What you are building, grouped by when you plan to ship it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // A 0 / 0 bar at 0% reads as a stalled project rather than an
            // empty one, so the readout waits until there is something to
            // measure. The empty state carries the explanation instead.
            if overall.total > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(overall.done) / \(overall.total) done")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if overall.inProgress > 0 {
                            Text("· \(overall.inProgress) in progress")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }
                    ProgressView(value: pct)
                        .progressViewStyle(.linear)
                        .tint(.purple)
                        .frame(width: 220)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tier section

    @ViewBuilder
    private func tierSection(_ tier: RoadmapTier) -> some View {
        let items = store.items(in: tier)
        let prog = store.progress(in: tier)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(tier.shortLabel)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(tierColor(tier))
                Text("·").foregroundStyle(.tertiary)
                Text(tier.horizonLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(prog.done)/\(prog.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tierColor(tier).opacity(0.15), in: Capsule())

                Button {
                    if addingToTier == tier {
                        addingToTier = nil
                    } else {
                        addingToTier = tier
                        newTitle = ""
                        newSubtitle = ""
                    }
                } label: {
                    Image(systemName: addingToTier == tier ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add item to \(tier.shortLabel)")
            }

            if addingToTier == tier {
                addRow(for: tier)
            }

            if items.isEmpty && addingToTier != tier {
                Text("No items.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        RoadmapRow(
                            item: item,
                            tierColor: tierColor(tier),
                            isExpanded: expanded.contains(item.id),
                            toggleExpand: { toggle(item.id) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addRow(for tier: RoadmapTier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Item title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitAdd(tier))
            TextField("Subtitle / rationale (optional)", text: $newSubtitle)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { addingToTier = nil }
                    .buttonStyle(.bordered)
                Button("Add") { submitAdd(tier)() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(tierColor(tier).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tierColor(tier).opacity(0.35), lineWidth: 1)
        )
    }

    private func submitAdd(_ tier: RoadmapTier) -> () -> Void {
        return {
            let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            store.add(tier: tier, title: t, subtitle: newSubtitle)
            newTitle = ""
            newSubtitle = ""
            addingToTier = nil
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func tierColor(_ tier: RoadmapTier) -> Color {
        switch tier {
        case .S: return .purple
        case .A: return .blue
        case .B: return .teal
        case .C: return .gray
        }
    }
}

// MARK: - Row

private struct RoadmapRow: View {
    @ObservedObject var store: RoadmapStore = .shared
    let item: RoadmapItem
    let tierColor: Color
    let isExpanded: Bool
    let toggleExpand: () -> Void

    @State private var editingNotes = false
    @State private var draftNotes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button { store.cycleStatus(id: item.id) } label: {
                    Image(systemName: item.status.systemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(statusColor)
                }
                .buttonStyle(.plain)
                .help("Click to cycle status: \(item.status.label) → \(item.status.next().label)")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .strikethrough(item.status == .done)
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                statusPill

                Button(action: toggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                Divider().padding(.vertical, 2)
                notesBlock
                metaLine
            }
        }
        .padding(12)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tierColor.opacity(item.status == .done ? 0.15 : 0.3), lineWidth: 1)
        )
        .contextMenu {
            Menu("Move to tier") {
                ForEach(RoadmapTier.allCases) { t in
                    Button {
                        store.move(id: item.id, to: t)
                    } label: {
                        Text("\(t.shortLabel) | \(t.horizonLabel)")
                    }
                    .disabled(t == item.tier)
                }
            }
            Menu("Set status") {
                ForEach(RoadmapStatus.allCases, id: \.self) { s in
                    Button(s.label) { store.setStatus(id: item.id, s) }
                        .disabled(s == item.status)
                }
            }
            Divider()
            Button(role: .destructive) {
                store.delete(id: item.id)
            } label: {
                Text("Delete item")
            }
        }
    }

    private var statusPill: some View {
        Text(item.status.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.15), in: Capsule())
    }

    private var rowBackground: Color {
        switch item.status {
        case .done:       return Color.green.opacity(0.08)
        case .inProgress: return Color.blue.opacity(0.10)
        case .notStarted: return Color.black.opacity(0.18)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done:       return .green
        case .inProgress: return .blue
        case .notStarted: return .secondary
        }
    }

    @ViewBuilder
    private var notesBlock: some View {
        if editingNotes {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftNotes)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Cancel") { editingNotes = false }
                        .buttonStyle(.bordered)
                    Button("Save notes") {
                        store.updateNotes(id: item.id, notes: draftNotes)
                        editingNotes = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(item.notes.isEmpty ? "Add notes" : "Edit") {
                        draftNotes = item.notes
                        editingNotes = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                if item.notes.isEmpty {
                    Text("No notes yet. Use this space to jot progress, blockers, links, decisions as we build.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(item.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 10) {
            Label {
                Text("Added \(item.addedAt, format: .dateTime.month().day().year())")
            } icon: {
                Image(systemName: "calendar.badge.plus")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let done = item.completedAt, item.status == .done {
                Label {
                    Text("Done \(done, format: .dateTime.month().day()) (\(done, format: .relative(presentation: .named)))")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                }
                .font(.caption2)
                .foregroundStyle(.green.opacity(0.8))
            }

            Spacer()
        }
    }
}
