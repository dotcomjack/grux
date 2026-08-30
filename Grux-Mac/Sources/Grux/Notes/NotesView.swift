import SwiftUI

// Quick Notes tab: list + editor split. Left column is searchable with
// pinned notes floated to the top; right column is a markdown editor with
// title, tags, and pin controls. Edits autosave through NotesStore's
// debounced scheduleSave.
struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared

    @State private var selection: UUID?
    @State private var search = ""

    // Local editor state, synced from the selected note. Writing back goes
    // through store.update so updatedAt + debounced save stay correct.
    //
    // No "syncing" flag here: SwiftUI delivers onChange AFTER the synchronous
    // scope that set the value, so a set-flag/defer-reset guard is always
    // already false by the time the handler runs. Instead each onChange
    // compares the incoming value against the note's stored value and skips
    // when they match, so programmatic loads (syncEditor) never re-enter the
    // save path and selection changes never re-timestamp notes.
    @State private var editTitle = ""
    @State private var editBody = ""
    @State private var editTags = ""

    private var filtered: [GruxNote] { store.search(search) }
    private var selected: GruxNote? { selection.flatMap { store.note(id: $0) } }

    /// The editor column's copy when nothing is selected, static so it can be
    /// asserted on.
    ///
    /// It read "Select a note or create one" whatever the store held, INCLUDING
    /// on a first run where there is nothing to select. Half an instruction that
    /// cannot be followed is the same defect as a suggestion chip that cannot
    /// work: the reader tries the first half, finds nothing to try it on, and
    /// stops trusting the second half too.
    /// THREE states share this pane and none of them may share a sentence,
    /// which is the DocumentLibraryView.emptyCopy(unfiltered:) rule. Keying
    /// on the UNFILTERED store collapsed two of them: with notes on disk and
    /// a search matching none, the list column was empty and this column
    /// still said "Select a note", which is the half-instruction-that-cannot
    /// -be-followed defect the copy was rewritten to remove.
    static func emptyDetailCopy(hasNotes: Bool, hasMatches: Bool) -> String {
        if !hasNotes { return "No notes yet. Create one and it saves as you type." }
        if !hasMatches { return "Nothing matched the search. Clear it to see your notes." }
        return "Select a note, or create a new one"
    }

    var body: some View {
        GruxListDetailScaffold {
            listColumn
        } detail: {
            editorColumn
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
            GruxToolbar("Notes") {
                Spacer()
                GruxToolbarButton(title: "New", systemImage: "square.and.pencil",
                                  prominent: true, helpText: "New note", action: newNote)
            }

            GruxSearchField(placeholder: "Search notes", text: $search)
                .padding(.horizontal, GruxSpacing.m)
                .padding(.bottom, GruxSpacing.s)

            if filtered.isEmpty {
                GruxEmptyState(
                    icon: "note.text",
                    line: search.isEmpty ? "No notes yet" : "No matches",
                    voiceHint: search.isEmpty ? "Grux, note that..." : nil,
                    compact: true
                )
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { note in
                        noteRow(note)
                            .tag(note.id)
                            .contextMenu {
                                Button(note.pinned ? "Unpin" : "Pin") {
                                    _ = store.togglePin(id: note.id)
                                }
                                DestructiveMenuButton(
                                        "Delete",
                                        question: "Delete this note?",
                                        detail: "The note and everything written in it are removed. "
                                            + "This cannot be undone.",
                                        confirmLabel: "Delete note"
                                    ) {
                                    deleteNote(note.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func noteRow(_ note: GruxNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: GruxSpacing.xs + 1) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                Text(note.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
            }
            if !note.previewLine.isEmpty {
                Text(note.previewLine)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: GruxSpacing.xs) {
                Text(Self.relativeStamp(note.updatedAt))
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                ForEach(note.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.accentCo.opacity(0.85))
                }
            }
        }
        .padding(.vertical, GruxSpacing.xs - 2)
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let note = selected {
            VStack(alignment: .leading, spacing: GruxSpacing.m - 2) {
                HStack(spacing: GruxSpacing.s) {
                    TextField("Title", text: $editTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .onChange(of: editTitle) { _, new in
                            guard let current = store.note(id: note.id),
                                  new != current.title else { return }
                            _ = store.update(id: note.id, title: new)
                        }
                    Button {
                        _ = store.togglePin(id: note.id)
                    } label: {
                        Image(systemName: note.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 13))
                            .foregroundStyle(note.pinned ? GruxTheme.warnAmber : GruxTheme.textTertiary)
                            .padding(4)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(note.pinned ? "Unpin" : "Pin to top")

                    Button {
                        deleteNote(note.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(GruxTheme.destructiveRose.opacity(0.85))
                            .padding(4)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                }

                HStack(spacing: GruxSpacing.s - 2) {
                    Image(systemName: "tag")
                        .font(.system(size: 10))
                        .foregroundStyle(GruxTheme.textTertiary)
                    TextField("tags, comma separated", text: $editTags)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(GruxTheme.accentCo)
                        .onChange(of: editTags) { _, new in
                            // Compare the raw field string against the exact
                            // string syncEditor loads, not the parsed tags:
                            // parsing is lossy for tags that contain commas,
                            // so a parse-then-compare would treat a mere
                            // selection load as an edit and rewrite the note.
                            guard let current = store.note(id: note.id),
                                  new != current.tags.joined(separator: ", ") else { return }
                            _ = store.update(id: note.id, tags: Self.parseTags(new))
                        }
                }
                .padding(.horizontal, GruxSpacing.m - 2)
                .padding(.vertical, GruxSpacing.s - 2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.04))
                )

                TextEditor(text: $editBody)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(GruxSpacing.m - 2)
                    .background(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .onChange(of: editBody) { _, new in
                        guard let current = store.note(id: note.id),
                              new != current.body else { return }
                        _ = store.update(id: note.id, body: new)
                    }

                HStack {
                    Text("Created \(Self.relativeStamp(note.createdAt))")
                    Text("·")
                    Text("Updated \(Self.relativeStamp(note.updatedAt))")
                }
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(GruxSpacing.l)
        } else {
            GruxEmptyState(
                icon: "note.text.badge.plus",
                line: Self.emptyDetailCopy(hasNotes: !store.ordered.isEmpty,
                                           hasMatches: !store.search(search).isEmpty),
                ctaTitle: "New note",
                ctaAction: newNote,
                voiceHint: "Grux, note that..."
            )
        }
    }

    // MARK: - Actions

    private func newNote() {
        let note = store.create()
        selection = note.id
        syncEditor()
    }

    private func deleteNote(_ id: UUID) {
        store.delete(id: id)
        if selection == id {
            selection = store.ordered.first?.id
            syncEditor()
        }
    }

    private func syncEditor() {
        guard let note = selected else {
            editTitle = ""; editBody = ""; editTags = ""
            return
        }
        editTitle = note.title
        editBody = note.body
        editTags = note.tags.joined(separator: ", ")
    }

    // Comma-separated tags field -> tag list. Static so tests can pin the
    // round-trip behavior the editTags onChange guard depends on.
    static func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func relativeStamp(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
