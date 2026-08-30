import SwiftUI
import AppKit

// Tabbed conversation detail with a searchable, speaker-colored, time-
// indexed timeline. Replaces the single monolithic scroll Meetings used to
// render so captures with hundreds of utterances stay navigable. The three
// tabs mirror Omi's Summary / Transcript / Action Items split.
struct ConversationDetailView: View {
    let record: MeetingRecord
    let isLive: Bool
    let resummarizing: Bool
    let onResummarize: () -> Void
    let onImportSingle: (String) -> Void
    let onImportAll: () -> Void
    let onToggleStar: () -> Void

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary, transcript, actions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary:    return "Summary"
            case .transcript: return "Transcript"
            case .actions:    return "Actions"
            }
        }
        var systemImage: String {
            switch self {
            case .summary:    return "text.alignleft"
            case .transcript: return "waveform"
            case .actions:    return "checklist"
            }
        }
    }

    @State private var selectedTab: DetailTab = .summary
    @State private var searchQuery: String = ""
    @State private var searchOpen: Bool = false
    @State private var currentMatchIndex: Int = 0
    @State private var speakerFilter: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            tabStrip
            Divider().opacity(0.4)
            if selectedTab == .transcript && searchOpen {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            tabBody
        }
        .animation(.easeOut(duration: 0.18), value: selectedTab)
        .animation(.easeOut(duration: 0.18), value: searchOpen)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(record.displayTitle)
                    .font(.system(size: 22, weight: .heavy, design: .default).width(.condensed))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if isLive { liveBadge }
                Spacer()
                Button(action: onToggleStar) {
                    Image(systemName: "star.fill")
                        .font(.callout)
                        .foregroundStyle(
                            LinearGradient(colors: [.yellow, .orange],
                                           startPoint: .top, endPoint: .bottom).opacity(0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Star this conversation (placeholder)")
                .opacity(0.5)
                Button {
                    copyTranscriptToClipboard()
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.clipboard")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                        .padding(6)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Copy full transcript to clipboard")
            }
            HStack(spacing: 8) {
                Text(longDate(record.startedAt))
                Text("·")
                Text(durationString(record))
                    .font(.caption.monospacedDigit())
                if let app = record.sourceAppName, !app.isEmpty {
                    Text("·")
                    Text(app)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }
                Text("·")
                Text("\(record.utterances.count) utterances")
                    .font(.caption.monospacedDigit())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !record.utterances.isEmpty {
                speakerChips
                speakerEnrollStrip
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
    }

    // One row of "Enroll <label>" buttons for every diarizer cluster in this
    // meeting that hasn't already been matched to an enrolled profile. Pulls
    // centroids from the persisted MeetingRecord so it works for any meeting
    // (live or historical), not just the in-flight session.
    @ViewBuilder
    private var speakerEnrollStrip: some View {
        let unenrolled = (record.speakerClusters ?? []).filter { $0.profileId == nil }
        if !unenrolled.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(unenrolled, id: \.speakerId) { cluster in
                        ClusterEnrollChip(
                            meetingId: record.id,
                            cluster: cluster
                        )
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .overlay(
                    Circle().stroke(Color.red.opacity(0.4), lineWidth: 2)
                        .scaleEffect(1.8)
                )
            Text("LIVE")
                .font(.caption2.weight(.heavy))
                .kerning(1.2)
                .foregroundStyle(.red)
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All speakers", filterValue: nil, isAll: true)
                ForEach(Array(distinctSpeakers.enumerated()), id: \.offset) { _, label in
                    filterChip(label: label, filterValue: label, isAll: false)
                }
            }
        }
    }

    private func filterChip(label: String, filterValue: String?, isAll: Bool) -> some View {
        let isActive = speakerFilter == filterValue
        let hue = isAll ? Color.purple : speakerColor(for: label)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                speakerFilter = isActive ? nil : filterValue
                if !isActive {
                    // Switching to a speaker filter makes most sense on the
                    // transcript tab - auto-jump there.
                    selectedTab = .transcript
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(hue)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .kerning(0.4)
            }
            .foregroundStyle(isActive ? .white : .primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isActive
                    ? AnyShapeStyle(LinearGradient(colors: [hue, hue.opacity(0.6)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(.ultraThinMaterial)
                )
            )
            .overlay(
                Capsule().stroke(
                    isActive ? Color.white.opacity(0.30) : hue.opacity(0.35),
                    lineWidth: 0.8
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 4) {
            // The pills SCROLL rather than compress. At the 840pt window floor
            // this pane is handed about 378pt and the three pills need roughly
            // 371 before the 40pt of padding, so something has to give. What
            // SwiftUI gives up by default is the Text, and it does not truncate
            // it, it WRAPS it: "Transcript" rendered as one character per line
            // and "Summary" broke as "Sum-mary". Scrolling keeps every label
            // whole and every tab reachable at any width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(DetailTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
            }
            if selectedTab == .transcript {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        searchOpen.toggle()
                        if !searchOpen {
                            searchQuery = ""
                            currentMatchIndex = 0
                        }
                    }
                } label: {
                    Image(systemName: searchOpen ? "xmark.circle.fill" : "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(searchOpen ? .purple : .secondary)
                        .padding(6)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help(searchOpen ? "Close search" : "Search transcript")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func tabButton(_ tab: DetailTab) -> some View {
        let isActive = selectedTab == tab
        let count: Int = {
            switch tab {
            case .summary:    return record.summary?.isEmpty == false ? 1 : 0
            case .transcript: return record.utterances.count
            case .actions:    return record.actionItems.count
            }
        }()
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selectedTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.caption.weight(.semibold))
                Text(tab.label)
                    .font(.callout.weight(.semibold))
                    // Belt to the ScrollView's braces: a pill label states its
                    // true width and never wraps, so the strip scrolls instead
                    // of the word breaking.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if count > 0 && tab != .summary {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                isActive ? Color.white.opacity(0.25) : Color.purple.opacity(0.18)
                            )
                        )
                }
            }
            .foregroundStyle(isActive ? .white : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(
                ZStack {
                    if isActive {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.85), Color.indigo.opacity(0.75)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    } else {
                        Color.white.opacity(0.03)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? Color.white.opacity(0.25) : Color.white.opacity(0.06),
                            lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: isActive ? Color.purple.opacity(0.35) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search within transcript", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .onChange(of: searchQuery) { _, _ in currentMatchIndex = 0 }
                .onSubmit {
                    advanceMatch(delta: 1)
                }
            if !searchQuery.isEmpty {
                Text(matchLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { advanceMatch(delta: -1) } label: {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(matchingUtteranceIds.isEmpty)
                Button { advanceMatch(delta: 1) } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(matchingUtteranceIds.isEmpty)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.purple.opacity(0.08))
    }

    private var matchLabel: String {
        let total = matchingUtteranceIds.count
        guard total > 0 else { return "0/0" }
        return "\(currentMatchIndex + 1)/\(total)"
    }

    private func advanceMatch(delta: Int) {
        let total = matchingUtteranceIds.count
        guard total > 0 else { return }
        var next = (currentMatchIndex + delta) % total
        if next < 0 { next += total }
        currentMatchIndex = next
    }

    // MARK: - Body per tab

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .summary:    summaryBody
        case .transcript: transcriptBody
        case .actions:    actionsBody
        }
    }

    private var summaryBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = record.summary, !summary.isEmpty {
                    sectionTitle("NOTES")
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLive {
                    livePlaceholder
                } else {
                    regenerateSummary
                }
                if !record.actionItems.isEmpty {
                    previewActionItems
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var livePlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Notes generate when you stop the meeting.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.08))
        )
    }

    private var regenerateSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NOTES")
            Text(record.utterances.isEmpty
                 ? "No transcript captured for this meeting."
                 : "No summary yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !record.utterances.isEmpty {
                Button(action: onResummarize) {
                    Label(
                        resummarizing ? "Generating…" : "Generate summary",
                        systemImage: "sparkles"
                    )
                }
                .disabled(resummarizing)
            }
        }
    }

    private var previewActionItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("ACTION ITEMS")
                Spacer()
                Button("Open Actions tab") {
                    withAnimation(.easeOut(duration: 0.18)) { selectedTab = .actions }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ForEach(Array(record.actionItems.prefix(3).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(item).font(.callout).foregroundStyle(.primary)
                    Spacer()
                }
            }
            if record.actionItems.count > 3 {
                Text("+ \(record.actionItems.count - 3) more")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Transcript

    private var transcriptBody: some View {
        Group {
            if record.utterances.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No utterances captured yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredUtterances) { u in
                                TranscriptRow(
                                    utterance: u,
                                    color: speakerColor(for: u.speakerLabel ?? channelName(u.speaker)),
                                    highlightedQuery: searchQuery,
                                    isActiveMatch: isActiveMatch(for: u.id)
                                )
                                .id(u.id)
                            }
                        }
                        .padding(.horizontal, 24).padding(.vertical, 16)
                    }
                    .onChange(of: currentMatchIndex) { _, _ in
                        guard let id = activeMatchUtteranceId else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: searchQuery) { _, _ in
                        guard let id = activeMatchUtteranceId else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if record.actionItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No action items in this conversation yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !record.utterances.isEmpty {
                            Button(action: onResummarize) {
                                Label(
                                    resummarizing ? "Regenerating…" : "Regenerate notes + actions",
                                    systemImage: "sparkles"
                                )
                            }
                            .disabled(resummarizing)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    HStack {
                        sectionTitle("ACTION ITEMS")
                        Spacer()
                        Button(action: onImportAll) {
                            Label("Import all as main task", systemImage: "plus.rectangle.on.folder")
                                .font(.caption.weight(.bold))
                        }
                        .help("Create one parent task with every item as a sub-task.")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(record.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "circle")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.top, 3)
                                Text(item)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { onImportSingle(item) } label: {
                                    Label("Import", systemImage: "plus.circle.fill")
                                        .font(.caption.weight(.bold))
                                        .labelStyle(.titleAndIcon)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(
                                            Capsule().fill(
                                                LinearGradient(colors: [.purple, .indigo],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                            )
                                        )
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Helpers

    private var distinctSpeakers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in record.utterances {
            let name = u.speakerLabel.flatMap { $0.isEmpty ? nil : $0 } ?? channelName(u.speaker)
            if !seen.contains(name) {
                seen.insert(name)
                out.append(name)
            }
        }
        return out
    }

    private var filteredUtterances: [MeetingUtterance] {
        record.utterances.filter { u in
            if let filter = speakerFilter {
                let label = u.speakerLabel?.isEmpty == false ? u.speakerLabel! : channelName(u.speaker)
                if label != filter { return false }
            }
            return true
        }
    }

    private var matchingUtteranceIds: [UUID] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return filteredUtterances
            .filter { $0.text.lowercased().contains(q) }
            .map(\.id)
    }

    private var activeMatchUtteranceId: UUID? {
        let ids = matchingUtteranceIds
        guard !ids.isEmpty else { return nil }
        let safeIdx = min(max(currentMatchIndex, 0), ids.count - 1)
        return ids[safeIdx]
    }

    private func isActiveMatch(for id: UUID) -> Bool {
        activeMatchUtteranceId == id
    }

    private func channelName(_ channel: MeetingUtterance.Speaker) -> String {
        switch channel {
        case .me: return "Me"
        case .them: return "Them"
        case .mixed: return "-"
        }
    }

    // Deterministic palette: hash the name into a fixed 8-color wheel so the
    // same speaker always renders in the same hue across reloads.
    private func speakerColor(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255),  // violet
            Color(red: 0x6E/255, green: 0xE0/255, blue: 0xFF/255),  // cyan
            Color(red: 0xFF/255, green: 0xB8/255, blue: 0x6B/255),  // amber
            Color(red: 0x7C/255, green: 0xE3/255, blue: 0xA8/255),  // mint
            Color(red: 0xFF/255, green: 0x6B/255, blue: 0x9E/255),  // rose
            Color(red: 0xB7/255, green: 0x9C/255, blue: 0xFF/255),  // lilac
            Color(red: 0xFF/255, green: 0xD6/255, blue: 0x73/255),  // butter
            Color(red: 0x5E/255, green: 0xD8/255, blue: 0xC3/255),  // teal
        ]
        let hash = name.unicodeScalars.reduce(0) { acc, scalar in
            acc &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    private func copyTranscriptToClipboard() {
        let text = record.flatText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.heavy))
            .kerning(1.8)
            .foregroundStyle(.secondary)
    }

    private func longDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d · h:mm a"
        df.timeZone = .current
        return df.string(from: d)
    }

    private func durationString(_ rec: MeetingRecord) -> String {
        let secs = Int(rec.durationSeconds)
        if secs >= 3600 {
            return String(format: "%dh %dm %ds", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
        return String(format: "%dm %ds", secs / 60, secs % 60)
    }
}

// Single row in the transcript timeline. Renders a [mm:ss] time prefix, a
// left-edge speaker-color rail, a speaker label chip, and the utterance
// text with an optional highlighted search term. The active search match
// gets a subtle purple pulse so the scroll target is visually obvious.
private struct TranscriptRow: View {
    let utterance: MeetingUtterance
    let color: Color
    let highlightedQuery: String
    let isActiveMatch: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTime(utterance.t))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .padding(.top, 3)
            Capsule()
                .fill(color.opacity(0.85))
                .frame(width: 3)
                .frame(minHeight: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text((utterance.speakerLabel?.isEmpty == false ? utterance.speakerLabel! : channelLabel(utterance.speaker)).uppercased())
                        .font(.caption2.weight(.heavy))
                        .kerning(1.0)
                        .foregroundStyle(color)
                    if utterance.speakerProfileId != nil {
                        Image(systemName: "person.crop.circle.fill.badge.checkmark")
                            .font(.caption2)
                            .foregroundStyle(color.opacity(0.7))
                            .help("Matched to an enrolled speaker profile")
                    }
                    Spacer()
                }
                HighlightedText(
                    text: utterance.text,
                    query: highlightedQuery,
                    highlight: color
                )
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isActiveMatch
                    ? Color.purple.opacity(0.18)
                    : Color.white.opacity(0.03)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isActiveMatch
                    ? Color.purple.opacity(0.55)
                    : Color.white.opacity(0.06),
                    lineWidth: isActiveMatch ? 1.2 : 0.5
                )
        )
    }

    private func channelLabel(_ s: MeetingUtterance.Speaker) -> String {
        switch s {
        case .me: return "Me"
        case .them: return "Them"
        case .mixed: return "-"
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let secs = max(0, Int(t))
        let m = secs / 60
        let s = secs % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// Draw text with any case-insensitive matches of `query` rendered in an
// accent-backed highlight. Falls back to a plain Text render when the
// query is empty so the non-search path stays cheap.
private struct HighlightedText: View {
    let text: String
    let query: String
    let highlight: Color

    var body: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            Text(text)
        } else {
            Text(attributed(text: text, query: trimmedQuery, highlight: highlight))
        }
    }

    private func attributed(text: String, query: String, highlight: Color) -> AttributedString {
        var attr = AttributedString(text)
        let needle = query.lowercased()
        let haystack = text.lowercased()
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let range = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            if let attrStart = attr.index(attr.startIndex, offsetByCharacters: start, boundedBy: nil),
               let attrEnd = attr.index(attr.startIndex, offsetByCharacters: end, boundedBy: nil) {
                attr[attrStart..<attrEnd].backgroundColor = highlight.opacity(0.30)
                attr[attrStart..<attrEnd].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = range.upperBound
        }
        return attr
    }
}

// Inline enroll pill: shows cluster label + sample count + a + button that
// opens a sheet seeded with the in-transcript name hint (if any). Distinct
// from SpeakerChip in MeetingsView.swift because that one is gated on the
// live diarizer being the source; this one works from the persisted record
// so a speaker can be enrolled hours later from any saved meeting.
private struct ClusterEnrollChip: View {
    let meetingId: UUID
    let cluster: SpeakerClusterSnapshot

    @State private var showSheet = false
    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.caption2)
            Text("Enroll \(cluster.label)")
                .font(.caption2.bold())
            if let hint = cluster.nameHint {
                Text("· \(hint)?")
                    .font(.caption2.italic())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
        )
        .foregroundStyle(Color.purple)
        .onTapGesture {
            draftName = cluster.nameHint ?? ""
            showSheet = true
        }
        .help("Give \(cluster.label) a name. Future meetings will auto-label this voice.")
        .sheet(isPresented: $showSheet) {
            enrollSheet
        }
    }

    private var enrollSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enroll \(cluster.label)")
                .font(.headline)
            Text("Give this voice a name. Future meetings will auto-label them, and this meeting's transcript will update to show the new name immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = cluster.nameHint {
                Text("Heard self-introduction: \"\(hint)\"")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextField("e.g. Dad, Sarah", text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSheet = false }
                Button("Enroll") { enroll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        // A sheet has no scroll of its own, so anything that outgrows a hard
        // width is lost rather than scrolled to: a long cluster label in the
        // title, a long self-introduction hint, or a larger system text size
        // pushes "Enroll" past the right edge. 340 stays the ideal so the sheet
        // renders exactly as it does today, with a ceiling to grow into. The
        // floor is the current 340 rather than GruxLayout.sheetMin (380)
        // because raising it would rewrap this sheet's copy now, and this pass
        // changes flexibility only.
        .frame(minWidth: 340, idealWidth: 340, maxWidth: GruxLayout.sheetMax)
    }

    private func enroll() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showSheet = false
        Task { @MainActor in
            let profile = SpeakerProfileStore.shared.enroll(
                name: name,
                embedding: cluster.centroid
            )
            _ = MeetingStore.shared.renameCluster(
                meetingId: meetingId,
                speakerId: cluster.speakerId,
                to: profile.name,
                profileId: profile.id
            )
        }
    }
}

private extension AttributedString {
    // Safe-offset helper using character offsets. Returns nil rather than
    // trapping when the offset is out of bounds (e.g. mid-emoji grapheme).
    func index(_ base: AttributedString.Index, offsetByCharacters offset: Int, boundedBy: Int?) -> AttributedString.Index? {
        guard offset >= 0 else { return nil }
        var idx = base
        for _ in 0..<offset {
            guard idx < self.endIndex else { return nil }
            idx = self.index(afterCharacter: idx)
        }
        return idx
    }
}
