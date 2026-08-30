import Foundation

// Items 32 + 33: whole-app backup + restore.
//
// BackupManager snapshots the entire Grux data tree (Application
// Support/Grux plus ~/Documents/Grux) into a single zip archive with a
// schema-versioned manifest.json at its root, and restores from such an
// archive with a mandatory safety copy of the current state.
//
// Archive layout:
//   manifest.json          : BackupManifest (schema, app version, file list)
//   support/...            : full copy of Application Support/Grux
//   documents/...          : full copy of ~/Documents/Grux (if present)
//
// Restore is staged: the archive is unzipped to a temp dir, the manifest is
// validated, THEN the live trees are moved aside into a timestamped
// .pre-restore safety copy before the staged payload is moved into place.
// Live data is NEVER deleted. The safety copy survives until the user
// removes it. A failed swap rolls the safety copy back automatically.
//
// Transient data deliberately excluded from backups:
//   audio-wal/         : in-flight crash-recovery PCM chunks, replayed at launch
//   .DS_Store          : Finder noise
//   .pre-restore       : never re-archive an old safety copy
//   backups/           : the default destination lives INSIDE documentsRoot;
//                        without this every archive would embed all earlier
//                        ones and sizes would compound run over run
//   grux-backup-*.zip  : same reason, covers custom destinations too

struct BackupManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    struct Entry: Codable, Equatable {
        // "support" or "documents"
        var root: String
        var relativePath: String
        var byteCount: Int64
    }

    var schemaVersion: Int
    var appVersion: String
    var appBuild: String
    var createdAt: Date
    var hostName: String
    // Schema versions of nested serialized formats, so a future build can
    // decide whether it understands the payload before swapping anything.
    var componentSchemaVersions: [String: Int]
    var entries: [Entry]
    var totalFiles: Int
    var totalBytes: Int64

    static func snapshotComponentVersions() -> [String: Int] {
        [
            "manifest": currentSchemaVersion,
            "memory-export": GruxMemoryExport.currentSchemaVersion
        ]
    }
}

enum BackupError: Error, LocalizedError {
    case nothingToBackUp
    case zipFailed(String)
    case unzipFailed(String)
    case manifestMissing
    case manifestUnreadable(String)
    case unsupportedSchema(Int)
    case archiveMissingPayload
    case swapFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToBackUp: return "No Grux data found to back up"
        case .zipFailed(let d): return "zip failed: \(d)"
        case .unzipFailed(let d): return "unzip failed: \(d)"
        case .manifestMissing: return "Archive has no manifest.json, not a Grux backup"
        case .manifestUnreadable(let d): return "Could not decode manifest.json: \(d)"
        case .unsupportedSchema(let v): return "Backup schema v\(v) is newer than this build understands (max \(BackupManifest.currentSchemaVersion))"
        case .archiveMissingPayload: return "Archive contains a manifest but no support/ payload"
        case .swapFailed(let d): return "Restore swap failed (safety copy preserved): \(d)"
        }
    }
}

struct RestoreResult {
    var manifest: BackupManifest
    var safetyCopyPath: String
    var restoredSupport: Bool
    var restoredDocuments: Bool
}

actor BackupManager {
    static let shared = BackupManager()

    // Injectable roots so tests run against temp dirs and NEVER touch the
    // real Application Support / Documents trees.
    let supportRoot: URL
    let documentsRoot: URL
    let safetyRoot: URL

    static var defaultDocumentsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Grux", isDirectory: true)
    }

    // Safety copies live BESIDE the data tree (sibling of Application
    // Support/Grux), so they are never swept into a later backup archive.
    static var defaultSafetyRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Grux-pre-restore", isDirectory: true)
    }

    /// Where backups go, WITHOUT creating anything. Naming a place is not making one.
    ///
    /// BackupScheduler's init reads `d.string(forKey: destination) ?? defaultBackupsDir.path`,
    /// and on a Mac with no defaults domain the left side is nil, so computing the fallback
    /// PATH created two empty folders in the person's Documents during their first launch,
    /// before onboarding finished, for a feature that is off and that would never write into
    /// them until they opted in. With Desktop and Documents iCloud sync on, the empty folder
    /// propagated to their other devices. Nothing removed it if they never enabled backups.
    static var defaultBackupsPath: URL { backupsPath(home: URL(fileURLWithPath: NSHomeDirectory())) }

    /// Home injected so a test can prove the ABSENCE of a side effect, which is the whole
    /// claim here and is otherwise unprovable: on the machine this is developed on
    /// ~/Documents/Grux already exists, so asserting "it was not created" against the real
    /// home passes whether the accessor creates or not. Point it at an empty temp directory
    /// and the assertion means something.
    static func backupsPath(home: URL) -> URL {
        home.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Grux", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// There is deliberately no creating twin of this. `createBackup(to:)` already calls
    /// createDirectory on whatever destination it is handed, so the folder appears the first
    /// time a backup is actually written and not one moment earlier.

    private static let excludedNames: Set<String> = ["audio-wal", ".DS_Store", "backups"]

    // Previous archives anywhere in the tree are never re-archived.
    private static func isBackupArchiveName(_ name: String) -> Bool {
        name.hasPrefix("grux-backup-") && name.hasSuffix(".zip")
    }

    init(supportRoot: URL = Persistence.supportDir,
         documentsRoot: URL = BackupManager.defaultDocumentsRoot,
         safetyRoot: URL = BackupManager.defaultSafetyRoot) {
        self.supportRoot = supportRoot
        self.documentsRoot = documentsRoot
        self.safetyRoot = safetyRoot
    }

    // MARK: - Backup

    // Stages a copy of both data trees, writes manifest.json, zips, and
    // moves the archive into destinationDir. Returns the archive URL.
    func createBackup(to destinationDir: URL,
                      progress: (@Sendable (String) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let staging = fm.temporaryDirectory
            .appendingPathComponent("grux-backup-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var entries: [BackupManifest.Entry] = []

        progress?("Copying Application Support data")
        let supportCount = try copyTree(
            from: supportRoot,
            to: staging.appendingPathComponent("support", isDirectory: true),
            root: "support",
            entries: &entries
        )

        progress?("Copying Documents data")
        let documentsCount = try copyTree(
            from: documentsRoot,
            to: staging.appendingPathComponent("documents", isDirectory: true),
            root: "documents",
            entries: &entries
        )

        guard supportCount + documentsCount > 0 else { throw BackupError.nothingToBackUp }

        progress?("Writing manifest")
        let manifest = BackupManifest(
            schemaVersion: BackupManifest.currentSchemaVersion,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
            appBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev",
            createdAt: Date(),
            hostName: ProcessInfo.processInfo.hostName,
            componentSchemaVersions: BackupManifest.snapshotComponentVersions(),
            entries: entries,
            totalFiles: entries.count,
            totalBytes: entries.reduce(0) { $0 + $1.byteCount }
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        progress?("Zipping archive")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let archiveName = "grux-backup-\(df.string(from: manifest.createdAt)).zip"
        let tmpZip = fm.temporaryDirectory.appendingPathComponent("grux-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmpZip) }

        let zip = try runProcess(
            executable: "/usr/bin/zip",
            arguments: ["-r", "-q", "-X", tmpZip.path, "."],
            currentDirectory: staging
        )
        guard zip.status == 0 else { throw BackupError.zipFailed(zip.output) }

        let final = destinationDir.appendingPathComponent(archiveName)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: tmpZip, to: final)
        progress?("Backup written to \(final.path)")
        return final
    }

    // MARK: - Manifest preview

    // Reads ONLY manifest.json out of an archive (streamed via `unzip -p`),
    // without extracting the payload. Used for the restore preview UI.
    func readManifest(fromArchive url: URL) throws -> BackupManifest {
        let result = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-p", url.path, "manifest.json"],
            currentDirectory: nil
        )
        guard result.status == 0, !result.outputData.isEmpty else { throw BackupError.manifestMissing }
        return try decodeManifest(result.outputData)
    }

    // MARK: - Restore

    // Full restore flow: stage → validate → safety copy → swap.
    // The previous live state is preserved at safetyRoot/<timestamp>/ and
    // its path is returned so the UI can surface it.
    func restore(fromArchive url: URL,
                 progress: (@Sendable (String) -> Void)? = nil) throws -> RestoreResult {
        let fm = FileManager.default

        progress?("Extracting archive to staging")
        let staging = fm.temporaryDirectory
            .appendingPathComponent("grux-restore-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-q", url.path, "-d", staging.path],
            currentDirectory: nil
        )
        guard unzip.status == 0 else { throw BackupError.unzipFailed(unzip.output) }

        progress?("Validating manifest")
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.manifestMissing }
        let manifest = try decodeManifest(try Data(contentsOf: manifestURL))

        let stagedSupport = staging.appendingPathComponent("support", isDirectory: true)
        let stagedDocuments = staging.appendingPathComponent("documents", isDirectory: true)
        guard fm.fileExists(atPath: stagedSupport.path) else { throw BackupError.archiveMissingPayload }

        // Safety copy dir. Current state is MOVED here, never deleted.
        progress?("Preserving current data as a safety copy")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let safety = safetyRoot.appendingPathComponent(df.string(from: Date()), isDirectory: true)
        try fm.createDirectory(at: safety, withIntermediateDirectories: true)

        progress?("Swapping in restored data")
        try swap(live: supportRoot, staged: stagedSupport,
                 safety: safety.appendingPathComponent("support", isDirectory: true))

        var restoredDocuments = false
        if fm.fileExists(atPath: stagedDocuments.path) {
            do {
                try swap(live: documentsRoot, staged: stagedDocuments,
                         safety: safety.appendingPathComponent("documents", isDirectory: true))
                restoredDocuments = true
            } catch {
                // Roll the already-committed support swap back too, so a
                // failed restore never leaves half-old half-new trees from
                // different points in time. The archive's support payload is
                // parked in the safety dir (never deleted) for inspection.
                let safetySupport = safety.appendingPathComponent("support", isDirectory: true)
                let aborted = safety.appendingPathComponent("aborted-restore-support", isDirectory: true)
                try? fm.moveItem(at: supportRoot, to: aborted)
                if fm.fileExists(atPath: safetySupport.path) {
                    try? fm.moveItem(at: safetySupport, to: supportRoot)
                }
                throw error
            }
        }

        progress?("Restore complete. Previous state kept at \(safety.path)")
        return RestoreResult(
            manifest: manifest,
            safetyCopyPath: safety.path,
            restoredSupport: true,
            restoredDocuments: restoredDocuments
        )
    }

    func listBackups(in directory: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("grux-backup-") && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Internals

    private func decodeManifest(_ data: Data) throws -> BackupManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let manifest: BackupManifest
        do { manifest = try dec.decode(BackupManifest.self, from: data) }
        catch { throw BackupError.manifestUnreadable(String(describing: error)) }
        guard manifest.schemaVersion <= BackupManifest.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    // Recursive copy of one tree into the staging area, skipping the
    // exclusion list, collecting manifest entries. Returns file count.
    @discardableResult
    private func copyTree(from source: URL, to destination: URL,
                          root: String, entries: inout [BackupManifest.Entry]) throws -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied = 0
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        for child in children {
            let name = child.lastPathComponent
            if Self.excludedNames.contains(name) || name.hasPrefix(".pre-restore") { continue }
            if Self.isBackupArchiveName(name) { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let target = destination.appendingPathComponent(name, isDirectory: values.isDirectory ?? false)
            if values.isDirectory ?? false {
                copied += try copyTree(from: child, to: target, root: root, entries: &entries)
            } else {
                try fm.copyItem(at: child, to: target)
                let relative = relativePath(of: target, under: root)
                entries.append(BackupManifest.Entry(
                    root: root,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0)
                ))
                copied += 1
            }
        }
        return copied
    }

    private func relativePath(of url: URL, under root: String) -> String {
        let comps = url.pathComponents
        guard let idx = comps.lastIndex(of: root) else { return url.lastPathComponent }
        return comps[(idx + 1)...].joined(separator: "/")
    }

    // Atomic-ish three-step swap: live → safety, staged → live. If step two
    // fails, the safety copy is rolled back so the live tree is never lost.
    private func swap(live: URL, staged: URL, safety: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: safety.deletingLastPathComponent(), withIntermediateDirectories: true)

        let liveExisted = fm.fileExists(atPath: live.path)
        if liveExisted {
            do { try fm.moveItem(at: live, to: safety) }
            catch { throw BackupError.swapFailed("could not set aside \(live.path): \(error.localizedDescription)") }
        }
        do {
            try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staged, to: live)
        } catch {
            // Roll the safety copy back so we never strand the live tree.
            if liveExisted { try? fm.moveItem(at: safety, to: live) }
            throw BackupError.swapFailed("could not move staged data into \(live.path): \(error.localizedDescription)")
        }
    }

    private struct ProcessResult {
        var status: Int32
        var outputData: Data
        var output: String { String(data: outputData, encoding: .utf8) ?? "" }
    }

    private func runProcess(executable: String, arguments: [String],
                            currentDirectory: URL?) throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd = currentDirectory { proc.currentDirectoryURL = cwd }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ProcessResult(status: proc.terminationStatus, outputData: data)
    }
}
