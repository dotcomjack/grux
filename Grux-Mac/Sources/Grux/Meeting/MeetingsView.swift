import SwiftUI

// Meetings tab - the full archive UI. Left: scrollable list of every captured
// meeting. Right: selected meeting detail (notes + action items + transcript
// toggle + import-to-tasks buttons). Re-reads MeetingStore on appear and on
// capture-service state changes so the list stays fresh after a live capture.
struct MeetingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var service = MeetingCaptureService.shared
    @ObservedObject private var folderStore: FolderStore = .shared

    @State private var meetings: [MeetingIndexEntry] = []
    @State private var selection: UUID?
    @State private var selectedRecord: MeetingRecord?
    @State private var query: String = ""
    @State private var showTranscript: Bool = false
    @State private var toast: String?
    @State private var resummarizing = false
    @State private var folderSelection: FolderTabSelection = .all
    @State private var folderCounts: [UUID: Int] = [:]
    @State private var unsortedCount: Int = 0
    @State private var creatingFolder: Bool = false
    @State private var classifyingMeeting: UUID?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                // Flexible so the detail pane keeps enough room when the window
                // narrows (a hard 340 left the Summary/Transcript/Actions detail
                // crushed into vertical text at the window floor). The bounds are
                // the shared ones rather than local numbers: a hand-picked 280
                // floor leaves the detail 318pt at the 599pt pane floor, under
                // GruxLayout.detailContentMin, which is the budget the column is
                // supposed to protect. 340 stays the ask so nothing moves.
                .frame(minWidth: GruxLayout.listColumnMin,
                       idealWidth: 340,
                       maxWidth: GruxLayout.listColumnMax)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: refresh)
        .onChange(of: service.isCapturing) { _, _ in refresh() }
        .onChange(of: service.activeMeeting?.utterances.count) { _, _ in
            // Live-capture append → reselect if the active meeting is onscreen
            if let active = service.activeMeeting, selection == active.id {
                selectedRecord = active
            }
        }
        .overlay(alignment: .top) { toastOverlay }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            FolderTabStrip(
                selection: $folderSelection,
                counts: folderCounts,
                allCount: meetings.count,
                unsortedCount: unsortedCount,
                onManage: { state.requestedTab = "folders" },
                onCreate: { creatingFolder = true }
            )
            Divider()
            if filteredMeetings.isEmpty {
                emptyList
            } else {
                List(selection: $selection) {
                    ForEach(dateGroupedMeetings, id: \.key) { bucket in
                        Section {
                            ForEach(bucket.items) { entry in
                                meetingRow(entry)
                                    .tag(entry.id)
                                    .contextMenu { folderContextMenu(for: entry) }
                            }
                        } header: {
                            dateSectionHeader(bucket.label)
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: selection) { _, newId in loadSelection(newId) }
            }
        }
        .background(Color.black.opacity(0.05))
        .sheet(isPresented: $creatingFolder) {
            FolderEditSheet { name, desc, color, icon in
                if let created = folderStore.create(name: name, description: desc, colorHex: color, icon: icon) {
                    folderSelection = .folder(created.id)
                    showToast("Created '\(created.name)'")
                    refresh()
                }
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(for entry: MeetingIndexEntry) -> some View {
        Menu("Move to folder") {
            Button {
                _ = MeetingStore.shared.assign(meetingId: entry.id, folderId: nil)
                refresh()
                showToast("Unsorted")
            } label: {
                Label("(Unsorted)", systemImage: "questionmark.folder")
            }
            Divider()
            ForEach(folderStore.ordered) { folder in
                Button {
                    _ = MeetingStore.shared.assign(meetingId: entry.id, folderId: folder.id)
                    refresh()
                    showToast("Moved to '\(folder.name)'")
                } label: {
                    Label(folder.name, systemImage: folder.icon)
                }
            }
        }
        if !state.anthropicKey.isEmpty {
            Button {
                classifyEntry(entry)
            } label: {
                Label(
                    classifyingMeeting == entry.id ? "Classifying…" : "Auto-file with AI",
                    systemImage: "sparkles"
                )
            }
            .disabled(classifyingMeeting != nil)
        }
    }

    private func classifyEntry(_ entry: MeetingIndexEntry) {
        classifyingMeeting = entry.id
        Task {
            defer { Task { @MainActor in classifyingMeeting = nil } }
            guard let rec = MeetingStore.shared.loadRecord(id: entry.id) else { return }
            guard let assignment = await FolderClassifier.classify(record: rec) else {
                await MainActor.run { showToast("Classifier unavailable.") }
                return
            }
            guard assignment.confidence >= FolderClassifier.minConfidence else {
                await MainActor.run { showToast("Low confidence - left unsorted.") }
                return
            }
            _ = await MainActor.run { MeetingStore.shared.assign(meetingId: entry.id, folderId: assignment.folderId) }
            await MainActor.run {
                let folder = FolderStore.shared.folder(id: assignment.folderId)
                showToast("Filed into '\(folder?.name ?? "folder")'")
                refresh()
            }
        }
    }

    private var listHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Meetings")
                    .font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                if service.isCapturing {
                    liveBadge
                }
                Button {
                    Task {
                        if service.isCapturing {
                            await service.stop()
                        } else if await service.start() == nil {
                            // SAY WHY. A nil return means capture never began,
                            // and this was the one call site that discarded it:
                            // pressing Start while muted did nothing at all,
                            // with no error and (before the fix above) an empty
                            // meeting appearing in the list as the only clue.
                            showToast(service.lastError ?? "Meeting capture could not start.")
                        }
                        refresh()
                    }
                } label: {
                    Label(
                        service.isCapturing ? "Stop" : "Start",
                        systemImage: service.isCapturing ? "stop.circle.fill" : "record.circle"
                    )
                    .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(service.isCapturing ? .red : .purple)
                .controlSize(.small)
                .disabled(service.isInitializing)
            }
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search title, summary, utterances…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onChange(of: query) { _, _ in refresh() }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(service.elapsedDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.red.opacity(0.12))
        .clipShape(Capsule())
    }

    private func meetingRow(_ entry: MeetingIndexEntry) -> some View {
        let isLive = service.isCapturing && service.activeMeeting?.id == entry.id
        let duration: String = {
            guard let ended = entry.endedAt else {
                return isLive ? service.elapsedDisplay : "-"
            }
            let secs = Int(ended.timeIntervalSince(entry.startedAt))
            if secs >= 3600 {
                return String(format: "%dh %dm", secs / 3600, (secs % 3600) / 60)
            }
            return String(format: "%dm %ds", secs / 60, secs % 60)
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isLive {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                }
                Text(entry.title ?? entry.sourceAppName ?? "Meeting")
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer()
                Text(shortDate(entry.startedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if let app = entry.sourceAppName {
                    Text(app)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(duration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(entry.utteranceCount) utt.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let excerpt = entry.summaryExcerpt {
                Text(excerpt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "No meetings captured yet." : "No meetings match '\(query)'.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Start a call and tap ⌘⇧M, or click Start above.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let rec = displayedRecord {
            ConversationDetailView(
                record: rec,
                isLive: service.isCapturing && service.activeMeeting?.id == rec.id,
                resummarizing: resummarizing,
                onResummarize: { resummarize(rec: rec) },
                onImportSingle: { item in importSingle(rec: rec, item: item) },
                onImportAll: { importAllAsParent(rec: rec) },
                onToggleStar: { /* starred-conversation model field is not wired yet */ }
            )
            .id(rec.id)
        } else {
            placeholderDetail
        }
    }

    private var displayedRecord: MeetingRecord? {
        // Prefer the live capture service when viewing the active meeting;
        // its utterances are fresher than anything in the store (which writes
        // on chunk boundaries).
        if let active = service.activeMeeting, active.id == selection {
            return active
        }
        return selectedRecord
    }

    private func detailHeader(rec: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(rec.displayTitle)
                    .font(.title.bold())
                Spacer()
                if service.isCapturing && service.activeMeeting?.id == rec.id {
                    liveBadge
                }
            }
            HStack(spacing: 8) {
                Text(longDate(rec.startedAt))
                if let ended = rec.endedAt {
                    Text("·")
                    Text("ended \(shortTime(ended))")
                }
                Text("·")
                Text(durationString(rec))
                if let appName = rec.sourceAppName {
                    Text("·")
                    Text(appName)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func summarySection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NOTES")
            Text(summary)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var livePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NOTES")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Notes generate when you stop the meeting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func regenerateSummaryPrompt(rec: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NOTES")
            Text(rec.utterances.isEmpty ? "No transcript captured for this meeting." : "No summary yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !rec.utterances.isEmpty {
                Button {
                    resummarize(rec: rec)
                } label: {
                    Label(
                        resummarizing ? "Generating…" : "Generate summary",
                        systemImage: "sparkles"
                    )
                }
                .disabled(resummarizing)
            }
        }
    }

    private func actionItemsSection(rec: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("ACTION ITEMS")
                Spacer()
                Button {
                    importAllAsParent(rec: rec)
                } label: {
                    Label("Import all as main task", systemImage: "plus.rectangle.on.folder")
                        .font(.caption.bold())
                }
                .help("Create one parent task (\"\(rec.displayTitle)\") with every action item as a sub-task.")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rec.actionItems.enumerated()), id: \.offset) { _, item in
                    actionItemRow(rec: rec, item: item)
                }
            }
        }
    }

    private func actionItemRow(rec: MeetingRecord, item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(item)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                importSingle(rec: rec, item: item)
            } label: {
                Label("Import", systemImage: "plus.circle")
                    .font(.caption.bold())
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(Color.purple)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add this as a top-level task.")
        }
        .padding(.vertical, 2)
    }

    private func transcriptSection(rec: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("TRANSCRIPT (\(rec.utterances.count))")
                Spacer()
                Button(showTranscript ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTranscript.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(rec.utterances.isEmpty)
            }
            if showTranscript && !rec.utterances.isEmpty {
                if !rec.distinctSpeakers.isEmpty {
                    speakerLegend(rec: rec)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rec.utterances) { u in
                        HStack(alignment: .top, spacing: 8) {
                            Text(timeString(u.t))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 46, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                if let label = u.speakerLabel, !label.isEmpty {
                                    Text(label)
                                        .font(.caption2.bold())
                                        .kerning(0.4)
                                        .foregroundStyle(u.speakerProfileId != nil ? Color.purple : .secondary)
                                }
                                Text(u.text)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if rec.utterances.isEmpty {
                Text("No utterances captured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Chip strip listing every distinct speaker in the transcript, with an
    // "Enroll" button next to anonymous ones (no matched profile) so the user can
    // turn a "Speaker 2" into "Dad" straight from the transcript when the
    // source meeting is still the current live diarizer session.
    private func speakerLegend(rec: MeetingRecord) -> some View {
        let isLive = service.isCapturing && service.activeMeeting?.id == rec.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(rec.distinctSpeakers.enumerated()), id: \.offset) { _, item in
                    SpeakerChip(
                        label: item.label,
                        isIdentified: item.profileId != nil,
                        canEnroll: isLive && item.profileId == nil
                    )
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var placeholderDetail: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Select a meeting to see notes and action items.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var toastOverlay: some View {
        if let msg = toast {
            Text(msg)
                .font(.caption.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.purple.opacity(0.9))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private func refresh() {
        meetings = MeetingStore.shared.list(limit: 500)
        folderCounts = MeetingStore.shared.folderCounts()
        unsortedCount = MeetingStore.shared.unsortedCount
        // Prepend the in-flight meeting if it's not yet persisted in the index
        // (fresh captures show instantly rather than on the next chunk).
        if let active = service.activeMeeting,
           !meetings.contains(where: { $0.id == active.id }) {
            let liveEntry = MeetingIndexEntry(
                id: active.id,
                startedAt: active.startedAt,
                endedAt: nil,
                title: active.title,
                sourceAppName: active.sourceAppName,
                utteranceCount: active.utterances.count,
                summaryExcerpt: nil,
                folderId: active.folderId
            )
            meetings.insert(liveEntry, at: 0)
        }
        // Maintain selection through refresh: if the selected id is still
        // present, re-load its full record; otherwise default to top.
        if let id = selection, meetings.contains(where: { $0.id == id }) {
            loadSelection(id)
        } else if let first = meetings.first {
            selection = first.id
            loadSelection(first.id)
        } else {
            selection = nil
            selectedRecord = nil
        }
    }

    private func loadSelection(_ id: UUID?) {
        guard let id else { selectedRecord = nil; return }
        if let active = service.activeMeeting, active.id == id {
            selectedRecord = active
            return
        }
        selectedRecord = MeetingStore.shared.loadRecord(id: id)
    }

    // Time-bucketed meetings for the sidebar timeline feed: Today / Yesterday /
    // This week / This month / older-by-month. Bucket order is stable across
    // refreshes so sections don't pop in and out as meetings age into the
    // next category.
    private var dateGroupedMeetings: [(key: String, label: String, items: [MeetingIndexEntry])] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today

        var buckets: [(key: String, label: String, items: [MeetingIndexEntry])] = []
        var byKey: [String: [MeetingIndexEntry]] = [:]
        var orderedKeys: [String] = []

        // Key ordering drives section order top-to-bottom.
        func push(_ key: String, label: String, entry: MeetingIndexEntry) {
            if byKey[key] == nil {
                byKey[key] = []
                orderedKeys.append(key)
                buckets.append((key: key, label: label, items: []))
            }
            byKey[key]?.append(entry)
        }

        for entry in filteredMeetings {
            let ts = entry.startedAt
            if ts >= today {
                push("today", label: "Today", entry: entry)
            } else if ts >= yesterday {
                push("yesterday", label: "Yesterday", entry: entry)
            } else if ts >= weekAgo {
                let df = DateFormatter()
                df.dateFormat = "EEEE"
                push("weekday-\(cal.component(.day, from: ts))",
                     label: df.string(from: ts), entry: entry)
            } else if ts >= monthStart {
                push("thismonth", label: "Earlier this month", entry: entry)
            } else {
                let df = DateFormatter()
                df.dateFormat = "MMMM yyyy"
                let key = df.string(from: ts)
                push("mo-\(key)", label: key, entry: entry)
            }
        }

        return buckets.compactMap { b in
            guard let items = byKey[b.key], !items.isEmpty else { return nil }
            return (key: b.key, label: b.label, items: items)
        }
    }

    private func dateSectionHeader(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.heavy))
                .kerning(1.8)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.25), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var filteredMeetings: [MeetingIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return meetings.filter { entry in
            switch folderSelection {
            case .all: break
            case .unsorted: if entry.folderId != nil { return false }
            case .folder(let id): if entry.folderId != id { return false }
            }
            guard !q.isEmpty else { return true }
            return (entry.title?.lowercased().contains(q) ?? false)
                || (entry.summaryExcerpt?.lowercased().contains(q) ?? false)
                || (entry.sourceAppName?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Import flows

    private func importSingle(rec: MeetingRecord, item: String) {
        guard let task = state.addTask(item, project: rec.displayTitle, priority: .next) else { return }
        showToast("Imported '\(item.prefix(40))…' as task")
        NotificationCenter.default.post(name: .gruxActiveTaskChanged, object: task.id)
    }

    private func importAllAsParent(rec: MeetingRecord) {
        let parentTitle = "Action items from \(rec.displayTitle)"
        guard let parent = state.addTask(
            parentTitle,
            project: rec.displayTitle,
            priority: .next
        ) else { return }
        var count = 0
        for item in rec.actionItems {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if state.addSubtask(parentId: parent.id, title: trimmed) != nil {
                count += 1
            }
        }
        showToast("Imported \(count) sub-tasks under '\(parentTitle.prefix(50))…'")
        state.requestedTab = "tasks"
    }

    private func resummarize(rec: MeetingRecord) {
        resummarizing = true
        Task {
            if let summary = await MeetingSummarizer.summarize(rec) {
                var updated = rec
                updated.summary = summary.tldr
                updated.actionItems = summary.actionItems
                MeetingStore.shared.finalize(updated)
                selectedRecord = updated
                showToast("Summary generated")
            } else {
                showToast("Summary failed - check API key")
            }
            resummarizing = false
            refresh()
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring()) { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { toast = nil }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption.bold())
            .kerning(1.5)
            .foregroundStyle(.secondary)
    }

    private func durationString(_ rec: MeetingRecord) -> String {
        let secs = Int(rec.durationSeconds)
        if secs >= 3600 {
            return String(format: "%dh %dm %ds", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
        return String(format: "%dm %ds", secs / 60, secs % 60)
    }

    private func shortDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d · h:mma"
        df.timeZone = .current
        return df.string(from: d).lowercased()
    }

    private func longDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d · h:mm a"
        df.timeZone = .current
        return df.string(from: d)
    }

    private func shortTime(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        df.timeZone = .current
        return df.string(from: d)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// Compact pill shown in the transcript header for each distinct speaker.
// Purple fill when the label resolves to an enrolled SpeakerProfile; muted
// gray with an inline "Enroll" affordance when the cluster is still
// anonymous AND the source meeting is the live diarizer session (so the
// centroid is still in memory to save).
private struct SpeakerChip: View {
    let label: String
    let isIdentified: Bool
    let canEnroll: Bool

    @State private var showEnrollSheet = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isIdentified ? "person.fill" : "person.crop.circle")
                .font(.caption2)
            Text(label)
                .font(.caption2.bold())
            if canEnroll {
                Button {
                    draftName = ""
                    showEnrollSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .help("Enroll this speaker")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isIdentified ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.12))
        )
        .foregroundStyle(isIdentified ? Color.purple : .secondary)
        .sheet(isPresented: $showEnrollSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enroll \(label)")
                    .font(.headline)
                Text("Give this voice a name. Future meetings will auto-label them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Dad, Sarah", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showEnrollSheet = false }
                    Button("Enroll") {
                        enrollAction()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            // A sheet has no scroll of its own, so anything that outgrows a
            // hard width is lost, not scrolled to: a long speaker label in the
            // title, or a larger system text size, pushes "Enroll" past the
            // right edge and the sheet becomes unusable. 320 stays the ideal so
            // the sheet renders exactly as it does today, with a ceiling to
            // grow into. The floor is the current 320 rather than
            // GruxLayout.sheetMin (380) because raising it would rewrap this
            // sheet's copy now, and this pass changes flexibility only.
            .frame(minWidth: 320, idealWidth: 320, maxWidth: GruxLayout.sheetMax)
        }
    }

    private func enrollAction() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showEnrollSheet = false
        Task { @MainActor in
            guard let list = MeetingCaptureService.shared.currentDiarizerCentroids,
                  let hit = list.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
                return
            }
            _ = SpeakerProfileStore.shared.enroll(name: name, embedding: hit.centroid)
        }
    }
}
