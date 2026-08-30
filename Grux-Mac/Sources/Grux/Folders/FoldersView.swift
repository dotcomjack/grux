import SwiftUI

// Horizontal folder tab strip. Renders above the meetings list so the user can
// pivot captures by folder without opening a menu. Omi-style: pseudo-tabs
// ("All", "Unsorted") sit alongside user folders. Taps flip the binding the
// parent view uses to filter its meeting list.
struct FolderTabStrip: View {
    @ObservedObject var store: FolderStore = .shared
    @Binding var selection: FolderTabSelection
    let counts: [UUID: Int]
    let allCount: Int
    let unsortedCount: Int
    var onManage: () -> Void = {}
    var onCreate: () -> Void = {}

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pseudoChip(
                    title: "All",
                    icon: "tray.full.fill",
                    count: allCount,
                    tint: Color.secondary,
                    isSelected: selection == .all
                ) { selection = .all }

                if unsortedCount > 0 {
                    pseudoChip(
                        title: "Unsorted",
                        icon: "questionmark.folder.fill",
                        count: unsortedCount,
                        tint: Color.orange,
                        isSelected: selection == .unsorted
                    ) { selection = .unsorted }
                }

                ForEach(store.ordered) { f in
                    folderChip(
                        folder: f,
                        count: counts[f.id] ?? 0,
                        isSelected: selection == .folder(f.id)
                    ) {
                        selection = .folder(f.id)
                    }
                }

                Button {
                    onCreate()
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                        .background(
                            Capsule().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onManage) {
                    Image(systemName: "gearshape.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Manage folders")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
        .background(Color.black.opacity(0.03))
    }

    private func folderChip(folder: Folder, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: folder.icon)
                    .font(.caption)
                    .foregroundStyle(folder.color)
                Text(folder.name)
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? folder.color : .primary)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? folder.color.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? folder.color.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(folder.description.isEmpty ? folder.name : "\(folder.name): \(folder.description)")
    }

    private func pseudoChip(title: String, icon: String, count: Int, tint: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption.bold())
                    .foregroundStyle(isSelected ? tint : .primary)
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? tint.opacity(0.18) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.6) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

enum FolderTabSelection: Equatable, Hashable {
    case all
    case unsorted
    case folder(UUID)

    var folderId: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

// Create / edit sheet. One form for both because the fields are identical.
// Color preset row + SF Symbol string input keeps parity with Omi's
// "emoji + hex" affordance without pulling in an emoji picker dependency.
struct FolderEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Folder?
    var onSave: (String, String, String, String) -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var colorHex: String = "#8B5CF6"
    @State private var icon: String = "folder.fill"

    private let colorPalette: [String] = [
        "#8B5CF6", "#3B82F6", "#10B981", "#F59E0B",
        "#EF4444", "#EC4899", "#14B8A6", "#6366F1",
        "#6B7280", "#84CC16", "#F97316", "#06B6D4"
    ]

    private let iconPalette: [String] = [
        "folder.fill", "briefcase.fill", "person.crop.circle.fill",
        "square.stack.3d.up.fill", "heart.fill", "music.note",
        "gamecontroller.fill", "book.fill", "dollarsign.circle.fill",
        "hammer.fill", "star.fill", "bolt.fill",
        "cart.fill", "graduationcap.fill", "airplane",
        "paintpalette.fill", "camera.fill", "tray.full.fill"
    ]

    init(existing: Folder? = nil, onSave: @escaping (String, String, String, String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        if let existing {
            _name = State(initialValue: existing.name)
            _description = State(initialValue: existing.description)
            _colorHex = State(initialValue: existing.colorHex)
            _icon = State(initialValue: existing.icon)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            nameField
            descriptionField
            iconPicker
            colorPicker
            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 460, maxWidth: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(resolvedColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(resolvedColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New folder" : "Edit folder")
                    .font(.title3.bold())
                Text(existing?.isSystem == true ? "System folder, some fields are fixed" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.caption.bold()).foregroundStyle(.secondary)
            TextField("e.g. Work, Family, Side project", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Classifier prompt").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Tell Grux what belongs here. This is how the AI decides where to auto-file new captures.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextEditor(text: $description)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Icon").font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(iconPalette, id: \.self) { ic in
                        Button {
                            icon = ic
                        } label: {
                            Image(systemName: ic)
                                .font(.body)
                                .foregroundStyle(ic == icon ? Color.white : resolvedColor)
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle().fill(ic == icon ? resolvedColor : resolvedColor.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Color").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(colorPalette, id: \.self) { hex in
                    Button {
                        colorHex = hex
                    } label: {
                        Circle()
                            .fill(colorFor(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(
                                    hex == colorHex ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Create" : "Save") {
                onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                       description.trimmingCharacters(in: .whitespacesAndNewlines),
                       colorHex,
                       icon)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(resolvedColor)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var resolvedColor: Color { colorFor(hex: colorHex) }

    private func colorFor(hex: String) -> Color {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard clean.count == 6, let rgb = UInt32(clean, radix: 16) else { return .purple }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// Full-screen management view. Lists every folder with member counts and
// inline actions (rename / set-default / delete). Also surfaces the AI
// auto-file button per folder so the user can retro-classify the unsorted
// bucket with one click.
struct FoldersManagementView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store: FolderStore = .shared
    @ObservedObject private var meetingService = MeetingCaptureService.shared
    @State private var counts: [UUID: Int] = [:]
    @State private var unsorted: Int = 0
    @State private var editing: Folder?
    @State private var creating: Bool = false
    @State private var deletingFolder: Folder?
    @State private var reassignTarget: UUID?
    @State private var toast: String?
    @State private var classifyInFlight: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .onAppear(perform: refresh)
        .sheet(item: $editing) { folder in
            FolderEditSheet(existing: folder) { name, desc, color, icon in
                _ = store.update(id: folder.id, name: name, description: desc, colorHex: color, icon: icon)
                refresh()
                showToast("Updated '\(name)'")
            }
        }
        .sheet(isPresented: $creating) {
            FolderEditSheet { name, desc, color, icon in
                if let created = store.create(name: name, description: desc, colorHex: color, icon: icon) {
                    showToast("Created '\(created.name)'")
                } else {
                    showToast("Couldn't create folder - name may be taken.")
                }
                refresh()
            }
        }
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg)
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.purple.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            deletingFolder.map { "Delete '\($0.name)'?" } ?? "Delete folder?",
            isPresented: Binding(
                get: { deletingFolder != nil },
                set: { if !$0 { deletingFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete & move contents to default", role: .destructive) {
                if let folder = deletingFolder {
                    if let r = store.delete(id: folder.id) {
                        showToast("Moved \(counts[folder.id] ?? 0) meetings to '\(r.newHome.name)'")
                    }
                    deletingFolder = nil
                    refresh()
                }
            }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: {
            Text("This folder's meetings will move to the default folder. System folders can't be deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folders").font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                Text("Organize meetings and memories. The description steers Grux's AI auto-filer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                classifyAllUnsorted()
            } label: {
                Label(
                    classifyInFlight ? "Classifying…" : "Auto-file unsorted (\(unsorted))",
                    systemImage: "sparkles"
                )
                .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .disabled(unsorted == 0 || classifyInFlight || state.anthropicKey.isEmpty)
            .help(state.anthropicKey.isEmpty ? "Add an Anthropic key in Settings to enable auto-classify." : "Ask Grux to file every unsorted meeting into the best-matching folder.")

            Button {
                creating = true
            } label: {
                Label("New folder", systemImage: "plus")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(16)
    }

    private var list: some View {
        List {
            if unsorted > 0 {
                unsortedRow
            }
            ForEach(store.ordered) { folder in
                folderRow(folder)
            }
        }
        .listStyle(.inset)
    }

    private var unsortedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder.fill")
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Unsorted").font(.callout.bold())
                Text("Meetings Grux hasn't filed yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(unsorted)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: folder.icon)
                .foregroundStyle(folder.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(folder.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder.name).font(.callout.bold())
                    if folder.isDefault {
                        Text("DEFAULT")
                            .font(.caption2.bold())
                            .foregroundStyle(folder.color)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(folder.color.opacity(0.15)))
                    }
                    if folder.isSystem {
                        Text("SYSTEM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                if !folder.description.isEmpty {
                    Text(folder.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text("\(counts[folder.id] ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Button("Edit") { editing = folder }
                Button("Make default") { store.setDefault(id: folder.id); refresh() }
                    .disabled(folder.isDefault)
                Divider()
                Button("Delete", role: .destructive) { deletingFolder = folder }
                    .disabled(folder.isSystem)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func refresh() {
        counts = MeetingStore.shared.folderCounts()
        unsorted = MeetingStore.shared.unsortedCount
    }

    private func classifyAllUnsorted() {
        guard !classifyInFlight else { return }
        classifyInFlight = true
        Task {
            let rows = MeetingStore.shared.list(limit: 500, folderId: nil)
            let toClassify = rows.filter { $0.folderId == nil }
            var filed = 0
            for row in toClassify.prefix(25) {
                guard let rec = MeetingStore.shared.loadRecord(id: row.id) else { continue }
                guard let assignment = await FolderClassifier.classify(record: rec) else { continue }
                guard assignment.confidence >= FolderClassifier.minConfidence else { continue }
                _ = MeetingStore.shared.assign(meetingId: rec.id, folderId: assignment.folderId)
                filed += 1
            }
            classifyInFlight = false
            refresh()
            showToast(filed == 0
                      ? "No confident matches - left unsorted."
                      : "Filed \(filed) meeting\(filed == 1 ? "" : "s").")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }
}
