import Foundation

// Item 32: optional daily auto-backup. OFF by default, the user opts in from
// the Backup tab in Settings. Settings persist in UserDefaults (deliberately
// not in config.json so this lands without touching Models.swift).
//
// The scheduler checks every 30 minutes whether 24h have elapsed since the
// last successful backup; if so it runs BackupManager.createBackup against
// the chosen destination folder. Failures surface in `lastResult` and retry
// on the next tick.
@MainActor
final class BackupScheduler: ObservableObject {
    static let shared = BackupScheduler()

    enum Keys {
        static let enabled = "grux.backup.autoEnabled"
        static let destination = "grux.backup.destinationPath"
        static let lastSuccessAt = "grux.backup.lastSuccessAt"
    }

    @Published var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: Keys.enabled) }
    }
    @Published var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Keys.destination) }
    }
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var lastResult: String?
    @Published private(set) var backupInFlight = false

    private var timer: Timer?
    private static let interval: TimeInterval = 30 * 60
    private static let cadence: TimeInterval = 24 * 60 * 60

    private init() {
        let d = UserDefaults.standard
        autoBackupEnabled = d.bool(forKey: Keys.enabled)
        // defaultBackupsPath, not the accessor that creates. See BackupManager for why:
        // asking where backups WOULD go used to make the folder.
        destinationPath = d.string(forKey: Keys.destination) ?? BackupManager.defaultBackupsPath.path
        lastSuccessAt = d.object(forKey: Keys.lastSuccessAt) as? Date
    }

    var destinationURL: URL { URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath, isDirectory: true) }

    // Idempotent. Call once at app launch.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in BackupScheduler.shared.tick() }
        }
        // Also evaluate shortly after launch so a Mac that sleeps through the
        // tick window still gets its daily backup.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            self.tick()
        }
    }

    // Called when a backup succeeded outside the scheduler's own flow
    // (e.g. the backup_now Claude tool), so the daily cadence resets.
    func noteExternalSuccess(at date: Date = Date()) {
        lastSuccessAt = date
        UserDefaults.standard.set(date, forKey: Keys.lastSuccessAt)
        lastResult = "Backed up (tool) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    func tick() {
        guard autoBackupEnabled, !backupInFlight else { return }
        if let last = lastSuccessAt, Date().timeIntervalSince(last) < Self.cadence { return }
        backupNow(trigger: "auto")
    }

    // Shared by the tick, the Backup Now button, and the backup_now tool.
    func backupNow(trigger: String, completion: (@Sendable (Result<URL, Error>) -> Void)? = nil) {
        guard !backupInFlight else {
            completion?(.failure(BackupError.zipFailed("a backup is already running")))
            return
        }
        backupInFlight = true
        lastResult = "Backing up..."
        let dest = destinationURL
        Task {
            do {
                let url = try await BackupManager.shared.createBackup(to: dest) { msg in
                    Task { @MainActor in BackupScheduler.shared.lastResult = msg }
                }
                await MainActor.run {
                    self.backupInFlight = false
                    self.lastSuccessAt = Date()
                    UserDefaults.standard.set(self.lastSuccessAt, forKey: Keys.lastSuccessAt)
                    self.lastResult = "Backed up (\(trigger)) to \(url.lastPathComponent)"
                }
                completion?(.success(url))
            } catch {
                await MainActor.run {
                    self.backupInFlight = false
                    self.lastResult = "Backup failed: \(error.localizedDescription)"
                }
                completion?(.failure(error))
            }
        }
    }
}
