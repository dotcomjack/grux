import SwiftUI

// Roster UI for enrolled voice profiles. Left: sortable list. Right: selected
// profile detail with rename, delete, and cross-meeting stats (how many
// meetings Grux has heard them in, last-heard timestamp). Lives under its own
// sidebar tab; no equivalent existed before - speakers could only be managed
// via Claude tool calls.
struct SpeakersView: View {
    @ObservedObject private var store = SpeakerProfileStore.shared
    @State private var selection: UUID?
    @State private var renameDraft: String = ""
    @State private var isRenaming: Bool = false
    @State private var stats: [UUID: SpeakerUsage] = [:]
    @State private var toast: String?

    struct SpeakerUsage {
        var meetings: Int
        var utterances: Int
        var lastHeard: Date?
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                // 320 is the roster's ask, not a demand. Held hard it kept its
                // full width while the window narrowed and the profile detail
                // absorbed every lost point: 279pt at the 599pt pane floor,
                // under GruxLayout.detailContentMin, which folds the avatar,
                // rename row and stats into a crushed column. As a range the
                // roster shrinks toward listColumnMin first and the detail
                // stays readable. Same shape GruxListDetailScaffold applies,
                // including no minWidth on the detail half: a minimum on both
                // halves is what makes the pair demand more than the window
                // floor can hand them.
                .frame(minWidth: GruxLayout.listColumnMin,
                       idealWidth: 320,
                       maxWidth: 320)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { refreshStats() }
        .overlay(alignment: .top) {
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
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.profiles.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(sortedProfiles) { profile in
                        speakerRow(profile)
                            .tag(profile.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: selection) { _, newId in
                    guard let newId, let p = store.get(id: newId) else {
                        isRenaming = false
                        return
                    }
                    renameDraft = p.name
                    isRenaming = false
                }
            }
        }
        .background(Color.black.opacity(0.05))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speakers")
                    .font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                Text("\(store.profiles.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text("Enrolled voices Grux recognizes across meetings. Enroll new speakers from the Meetings tab: pick a cluster chip and give it a name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No speakers enrolled yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Record a meeting, then tap a speaker chip in its transcript to give that voice a name.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sortedProfiles: [SpeakerProfile] {
        store.profiles.sorted { a, b in
            let ma = stats[a.id]?.meetings ?? 0
            let mb = stats[b.id]?.meetings ?? 0
            if ma != mb { return ma > mb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func speakerRow(_ profile: SpeakerProfile) -> some View {
        let usage = stats[profile.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(color(for: profile.name))
                Text(profile.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer()
                Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if let usage {
                    Text("\(usage.meetings) meeting\(usage.meetings == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(usage.utterances) utt.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("updated \(relative(profile.updatedAt))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let sel = selection, let profile = store.get(id: sel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(profile: profile)
                    Divider()
                    detailStats(profile: profile)
                    Divider()
                    detailActions(profile: profile)
                    Spacer(minLength: 20)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            placeholder
        }
    }

    private func detailHeader(profile: SpeakerProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color(for: profile.name).opacity(0.25))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initials(profile.name))
                        .font(.title2.bold())
                        .foregroundStyle(color(for: profile.name))
                )
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { commitRename(profile: profile) }
                    HStack(spacing: 8) {
                        Button("Save") { commitRename(profile: profile) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            renameDraft = profile.name
                            isRenaming = false
                        }
                    }
                } else {
                    Text(profile.name)
                        .font(.title.bold())
                    Text("enrolled \(mediumDate(profile.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func detailStats(profile: SpeakerProfile) -> some View {
        let u = stats[profile.id] ?? SpeakerUsage(meetings: 0, utterances: 0, lastHeard: nil)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("USAGE")
            HStack(spacing: 16) {
                statChip("Meetings", "\(u.meetings)")
                statChip("Utterances", "\(u.utterances)")
                statChip("Samples merged", "\(profile.sampleCount)")
            }
            if let last = u.lastHeard {
                Text("Last heard \(mediumDate(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet heard in any stored meeting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detailActions(profile: SpeakerProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ACTIONS")
            HStack(spacing: 10) {
                Button {
                    renameDraft = profile.name
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(isRenaming)
                Button(role: .destructive) {
                    deleteProfile(profile)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
            }
            Text("Deleting a profile forgets that voice. Future meetings will label that person as anonymous 'Speaker N' again until you re-enroll them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a speaker to see their stats and actions.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func commitRename(profile: SpeakerProfile) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != profile.name else {
            isRenaming = false
            return
        }
        _ = store.rename(id: profile.id, to: trimmed)
        isRenaming = false
        showToast("Renamed to \(trimmed)")
    }

    private func deleteProfile(_ profile: SpeakerProfile) {
        _ = store.delete(id: profile.id)
        selection = nil
        refreshStats()
        showToast("Deleted \(profile.name)")
    }

    private func refreshStats() {
        var out: [UUID: SpeakerUsage] = [:]
        for p in store.profiles {
            out[p.id] = SpeakerUsage(meetings: 0, utterances: 0, lastHeard: nil)
        }
        for entry in MeetingStore.shared.index {
            guard let rec = MeetingStore.shared.loadRecord(id: entry.id) else { continue }
            var seen: Set<UUID> = []
            for u in rec.utterances {
                guard let pid = u.speakerProfileId else { continue }
                guard out[pid] != nil else { continue }
                var slot = out[pid]!
                slot.utterances += 1
                if !seen.contains(pid) {
                    seen.insert(pid)
                    slot.meetings += 1
                    let at = rec.startedAt
                    if let prev = slot.lastHeard {
                        slot.lastHeard = max(prev, at)
                    } else {
                        slot.lastHeard = at
                    }
                }
                out[pid] = slot
            }
        }
        stats = out
    }

    // MARK: - Helpers

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
            .font(.caption.weight(.heavy))
            .kerning(1.8)
            .foregroundStyle(.secondary)
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    private func color(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255),
            Color(red: 0x6E/255, green: 0xE0/255, blue: 0xFF/255),
            Color(red: 0xFF/255, green: 0xB8/255, blue: 0x6B/255),
            Color(red: 0x7C/255, green: 0xE3/255, blue: 0xA8/255),
            Color(red: 0xFF/255, green: 0x6B/255, blue: 0x9E/255),
            Color(red: 0xB7/255, green: 0x9C/255, blue: 0xFF/255),
            Color(red: 0xFF/255, green: 0xD6/255, blue: 0x73/255),
            Color(red: 0x5E/255, green: 0xD8/255, blue: 0xC3/255)
        ]
        let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private func relative(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    private func mediumDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy h:mm a"
        df.timeZone = .current
        return df.string(from: d)
    }
}
