import Foundation
import Combine

// Phase 4 per-brand email-autonomy ledger. For each configured brand it
// tracks the support-reply track record (clean sends, edited
// sends, output-gate blocks) and the per-brand autonomy mode, then computes
// whether the brand is READY to graduate from OBSERVE to LIVE.
//
// Nothing here auto-flips. graduationReady is surfaced in the UI; a human
// deliberately calls setMode(.live). Graduation requires the brand to still be
// in OBSERVE, to have enough clean sends, a low edit rate, and zero gate
// blocks. Persisted to ~/.grux/jax/autonomy-ledger.json so the record survives
// relaunch and is greppable from the CLI. House style mirrors FilteredMailStore
// and GoalPursuitEngine: @MainActor singleton, dir-create-before-write, zero
// em/en dashes.
struct BrandAutonomyRecord: Codable, Equatable {
    var brand: String          // brand-voice key, e.g. "support" / "personal"
    var sentClean: Int         // sent with NO human edit
    var sentEdited: Int        // sent after a human edit
    var gateBlocks: Int        // output-gate blocks
    var mode: AutonomyMode     // per-brand email autonomy; default .observe

    var sent: Int { sentClean + sentEdited }
    var editRate: Double { sent == 0 ? 0 : Double(sentEdited) / Double(sent) }
}

@MainActor
final class AutonomyLedger: ObservableObject {
    static let shared = AutonomyLedger()

    // Keyed by lowercased brand.
    @Published private(set) var records: [String: BrandAutonomyRecord]

    // Graduation thresholds.
    static let minCleanSends = 10
    static let maxEditRate = 0.2

    static var rootDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("jax")
    }
    private static var fileURL: URL { rootDir.appendingPathComponent("autonomy-ledger.json") }

    private init() {
        records = Self.loadRecords()
    }

    // Reload from disk. Used by tests and any UI refresh.
    func load() {
        records = Self.loadRecords()
    }

    // Load the ledger, distinguishing "file missing" (legitimately empty) from
    // "file present but corrupt". A corrupt file is BACKED UP before we fall back
    // to empty, so a truncated write never silently wipes the brand track record
    // and is then clobbered by the next save. The preserved bytes allow recovery.
    private static func loadRecords() -> [String: BrandAutonomyRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }   // missing = empty
        if let decoded = try? JSONDecoder().decode([String: BrandAutonomyRecord].self, from: data) {
            return decoded
        }
        let backup = rootDir.appendingPathComponent("autonomy-ledger.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        WakeLog.shared.log("autonomyLedger: corrupt ledger file backed up to \(backup.lastPathComponent); starting fresh")
        return [:]
    }

    private static func key(_ brand: String) -> String {
        brand.lowercased()
    }

    // Returns the stored record, or a fresh default .observe record when absent.
    // A pure read: it does NOT mutate the store.
    func record(forBrand brand: String) -> BrandAutonomyRecord {
        let k = Self.key(brand)
        if let existing = records[k] { return existing }
        return BrandAutonomyRecord(brand: k, sentClean: 0, sentEdited: 0, gateBlocks: 0, mode: .observe)
    }

    func mode(forBrand brand: String) -> AutonomyMode {
        record(forBrand: brand).mode
    }

    func setMode(_ mode: AutonomyMode, forBrand brand: String) {
        var rec = record(forBrand: brand)
        rec.mode = mode
        records[Self.key(brand)] = rec
        persist()
    }

    // Increments sentClean when the draft went out untouched, sentEdited when a
    // human edited before sending.
    func recordSent(brand: String, edited: Bool) {
        var rec = record(forBrand: brand)
        if edited { rec.sentEdited += 1 } else { rec.sentClean += 1 }
        records[Self.key(brand)] = rec
        persist()
    }

    func recordGateBlock(brand: String) {
        var rec = record(forBrand: brand)
        rec.gateBlocks += 1
        records[Self.key(brand)] = rec
        persist()
    }

    // Drop a brand's record entirely (back to the default OBSERVE, zero counts).
    // Used by the graduation smoke test to leave the real ledger untouched.
    func reset(brand: String) {
        records.removeValue(forKey: Self.key(brand))
        persist()
    }

    // Ready to graduate to LIVE: still in OBSERVE, enough clean sends, low edit
    // rate, zero gate blocks. Never flips on its own; a human acts on this.
    func graduationReady(forBrand brand: String) -> Bool {
        let rec = record(forBrand: brand)
        return rec.mode == .observe
            && rec.sentClean >= Self.minCleanSends
            && rec.editRate <= Self.maxEditRate
            && rec.gateBlocks == 0
    }

    // For the UI: the readiness checklist for one brand.
    func readiness(forBrand brand: String) -> (ready: Bool, cleanSends: Int, needed: Int, editRate: Double, gateBlocks: Int) {
        let rec = record(forBrand: brand)
        let needed = max(0, Self.minCleanSends - rec.sentClean)
        return (graduationReady(forBrand: brand), rec.sentClean, needed, rec.editRate, rec.gateBlocks)
    }

    private func persist() {
        // Ensure ~/.grux/jax exists before writing: on a fresh machine no
        // sibling store may have created it yet, and Persistence.save swallows
        // the write error, which would silently drop the ledger.
        try? FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        Persistence.save(records, to: Self.fileURL)
    }
}
