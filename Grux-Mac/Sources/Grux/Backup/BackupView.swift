import SwiftUI
import AppKit

// Items 32 + 33: Backup tab inside Settings.
//
// Backup Now (with live progress), restore picker with manifest preview +
// confirm dialog, daily auto-backup toggle + destination, plus selective
// memory export/import (MemoryPortability) and CommandsV2 user-command
// export/import seams.
struct BackupView: View {
    @ObservedObject private var scheduler = BackupScheduler.shared

    @State private var restoreCandidate: URL?
    @State private var restoreManifest: BackupManifest?
    @State private var restoreError: String?
    @State private var showRestoreConfirm = false
    @State private var restoreResult: RestoreResult?
    @State private var restoreInFlight = false
    @State private var selectiveStatus: String?

    var body: some View {
        Form {

                // MARK: Backup now
                Section("Backup") {
                    Text("Snapshots everything under Application Support/Grux and ~/Documents/Grux into one zip with a versioned manifest. Chats, agents, meetings, workday logs, memory, documents, commands.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(scheduler.backupInFlight ? "Backing up..." : "Backup now") {
                            scheduler.backupNow(trigger: "manual")
                        }
                        .disabled(scheduler.backupInFlight)
                        Button("Reveal backups folder") {
                            NSWorkspace.shared.open(scheduler.destinationURL)
                        }.buttonStyle(.borderless).font(.caption)
                    }
                    if let result = scheduler.lastResult {
                        Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let last = scheduler.lastSuccessAt {
                        Text("Last successful backup: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }


                // MARK: Auto-backup
                Section("Daily auto-backup") {
                    Toggle("Back up automatically once a day", isOn: $scheduler.autoBackupEnabled)
                    HStack(spacing: 8) {
                        Text("Destination").font(.caption).frame(width: 80, alignment: .leading)
                        Text(scheduler.destinationPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Change...") { pickDestination() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    Text("Off by default. When on, Grux checks every 30 minutes and writes a fresh archive if the last one is over 24h old.")
                        .font(.caption).foregroundStyle(.secondary)
                }


                // MARK: Restore
                Section("Restore") {
                    Text("Pick a grux-backup-*.zip. Grux validates its manifest, sets your current data aside as a safety copy, then swaps the backup in. Nothing is deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Choose backup...") { pickRestoreArchive() }
                            .disabled(restoreInFlight)
                        if restoreInFlight { ProgressView().controlSize(.small) }
                    }

                    if let m = restoreManifest, let candidate = restoreCandidate {
                        manifestPreview(m, archive: candidate)
                    }
                    if let err = restoreError {
                        Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let result = restoreResult {
                        // Normally never seen: performRestore relaunches the
                        // app immediately on success. Kept as the escape
                        // hatch if something cancels the terminate.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restored. Restarting Grux to load the restored data...")
                                .font(.caption).bold()
                            Text("Previous state preserved at \(result.safetyCopyPath)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Restart Grux now") { relaunchGrux() }
                        }
                    }
                }


                // MARK: Selective export / import
                Section("Selective export") {
                    Text("Smaller, portable JSON exports for moving specific data between Macs without a full restore.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Export memory") { exportMemory() }
                        Button("Import memory...") { importMemory() }
                        Button("Export commands") { exportCommands() }
                        Button("Import commands...") { importCommands() }
                    }
                    if let s = selectiveStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

        }
        // GROUPED, to match every other Settings pane. This view was a bare
        // ScrollView with its own .padding(20) and hand-rolled title/Divider
        // section headers, so Data & Security rendered at a different left
        // inset and a different content width from the other four tabs.
        // Measured on the Mini 2026-08-30: content started 73pt left of where
        // General started and ran 80pt wider.
        .formStyle(.grouped)
        .confirmationDialog(
            "Restore this backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore (current data kept as safety copy)", role: .destructive) { performRestore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let m = restoreManifest {
                Text("From \(m.hostName), \(m.createdAt.formatted(date: .abbreviated, time: .shortened)). \(m.totalFiles) files. Your current data is moved to a .pre-restore safety copy first, never deleted.")
            }
        }
    }

    private func manifestPreview(_ m: BackupManifest, archive: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(archive.lastPathComponent).font(.caption.bold())
            Text("Created \(m.createdAt.formatted(date: .abbreviated, time: .shortened)) on \(m.hostName) (Grux \(m.appVersion))")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(m.totalFiles) files, \(ByteCountFormatter.string(fromByteCount: m.totalBytes, countStyle: .file)), manifest schema v\(m.schemaVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore this backup") { showRestoreConfirm = true }
                .disabled(restoreInFlight)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Actions

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            scheduler.destinationPath = url.path
        }
    }

    private func pickRestoreArchive() {
        restoreError = nil
        restoreResult = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = scheduler.destinationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreCandidate = url
        restoreManifest = nil
        Task {
            do {
                let manifest = try await BackupManager.shared.readManifest(fromArchive: url)
                await MainActor.run { restoreManifest = manifest }
            } catch {
                await MainActor.run { restoreError = error.localizedDescription }
            }
        }
    }

    private func performRestore() {
        guard let url = restoreCandidate else { return }
        restoreInFlight = true
        restoreError = nil
        // Suspend every Persistence.save BEFORE the on-disk swap: the live
        // stores and schedulers keep pre-restore state in memory, and any
        // debounced save or timer tick after the swap would silently
        // overwrite the restored files with stale data.
        Persistence.writesSuspended = true
        Task {
            do {
                let result = try await BackupManager.shared.restore(fromArchive: url)
                await MainActor.run {
                    restoreInFlight = false
                    restoreResult = result
                    restoreManifest = nil
                    restoreCandidate = nil
                    // Relaunch IMMEDIATELY: while writes are suspended every
                    // guarded save silently drops its payload, so anything
                    // the user does between restore and relaunch (notes,
                    // chats, skills, memories) would be confirmed in-UI and
                    // then vanish. No passive click-through window.
                    relaunchGrux()
                }
            } catch {
                await MainActor.run {
                    // Nothing was swapped (or it was fully rolled back), so
                    // normal saves are safe again.
                    Persistence.writesSuspended = false
                    // Suspension DROPS debounced saves rather than deferring
                    // them: a save timer that fired during unzip/staging was
                    // consumed with its store believing it saved. Rewrite
                    // current in-memory state so a failed restore cannot
                    // silently lose a pre-restore edit or memory.
                    NotesStore.shared.flush()
                    SkillStore.shared.flush()
                    ResearchStore.shared.flush()
                    SemanticMemory.shared.flush()
                    restoreInFlight = false
                    restoreError = error.localizedDescription
                }
            }
        }
    }

    // Re-exec the app so a fresh process loads the restored trees. Writes
    // stay suspended in this process until it exits, so nothing stale can
    // touch the restored data even during teardown.
    private func relaunchGrux() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func exportMemory() {
        do {
            let url = try MemoryPortability.exportAll()
            selectiveStatus = "Memory exported to \(url.path)"
        } catch {
            selectiveStatus = "Memory export failed: \(error.localizedDescription)"
        }
    }

    private func importMemory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = MemoryPortability.exportsDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try MemoryPortability.importAll(from: url)
            selectiveStatus = "Memory imported: \(summary.description)"
        } catch {
            selectiveStatus = "Memory import failed: \(error.localizedDescription)"
        }
    }

    private func exportCommands() {
        do {
            let url = try CommandsPortability.exportUserCommands()
            selectiveStatus = "Commands exported to \(url.path)"
        } catch {
            selectiveStatus = "Commands export failed: \(error.localizedDescription)"
        }
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = MemoryPortability.exportsDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try CommandsPortability.importUserCommands(from: url)
            selectiveStatus = "Commands imported: +\(added) new (existing titles skipped)"
        } catch {
            selectiveStatus = "Commands import failed: \(error.localizedDescription)"
        }
    }
}

// CommandsV2 definition export seam. User-authored scheduled commands
// (UserCronStore) are the only user-defined CommandsV2 data on disk; the
// built-in definitions are code. Export copies the JSON to the shared
// exports dir; import merges by title (never overwrites existing jobs).
@MainActor
enum CommandsPortability {

    static func exportUserCommands(to directory: URL = MemoryPortability.exportsDir) throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let dest = directory.appendingPathComponent("grux-commands-\(df.string(from: Date())).json")
        let jobs = UserCronStore.shared.jobs
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(jobs).write(to: dest, options: .atomic)
        return dest
    }

    static func importUserCommands(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let imported = try dec.decode([UserCronJob].self, from: data)
        let existingTitles = Set(UserCronStore.shared.jobs.map { $0.title.lowercased() })
        var added = 0
        for job in imported where !existingTitles.contains(job.title.lowercased()) {
            UserCronStore.shared.create(
                title: job.title,
                weekdays: job.weekdays,
                hour: job.hour,
                minute: job.minute,
                action: job.action,
                notifyOnFire: job.notifyOnFire
            )
            added += 1
        }
        return added
    }
}
