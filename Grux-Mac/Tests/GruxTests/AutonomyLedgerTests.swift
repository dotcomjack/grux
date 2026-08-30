import XCTest
@testable import Grux

// Phase 4 per-brand email-autonomy ledger: default record is OBSERVE with zero
// counts; a clean track record graduates; an edit or a gate block blocks
// graduation; LIVE brands are not "ready" (already graduated); and the record
// survives a fresh read from disk. Tests share the AutonomyLedger singleton and
// touch ~/.grux/jax/autonomy-ledger.json, so each uses its own unique brand key
// and cleans up what it added to stay deterministic.
@MainActor
final class AutonomyLedgerTests: XCTestCase {

    private var brands: [String] = []

    // Register a unique brand key for this test and ensure it starts clean.
    private func freshBrand(_ suffix: String) -> String {
        let brand = "ledgertest-\(suffix)-\(UUID().uuidString.prefix(8))"
        brands.append(brand)
        reset(brand)
        return brand
    }

    private func reset(_ brand: String) {
        AutonomyLedger.shared.reset(brand: brand)
    }

    override func tearDown() {
        for brand in brands { AutonomyLedger.shared.reset(brand: brand) }
        brands.removeAll()
        super.tearDown()
    }

    func testDefaultRecordIsObserveWithZeroCounts() {
        let brand = freshBrand("default")
        let ledger = AutonomyLedger.shared

        let rec = ledger.record(forBrand: brand)
        XCTAssertEqual(rec.brand, brand.lowercased())
        XCTAssertEqual(rec.sentClean, 0)
        XCTAssertEqual(rec.sentEdited, 0)
        XCTAssertEqual(rec.gateBlocks, 0)
        XCTAssertEqual(rec.sent, 0)
        XCTAssertEqual(rec.editRate, 0)
        XCTAssertEqual(rec.mode, .observe)
        XCTAssertEqual(ledger.mode(forBrand: brand), .observe)

        // A pure read must NOT have created an on-disk entry.
        ledger.load()
        XCTAssertNil(ledger.records[brand.lowercased()])
    }

    func testRecordKeyIsLowercased() {
        let brand = freshBrand("Case")
        let ledger = AutonomyLedger.shared
        ledger.recordSent(brand: brand.uppercased(), edited: false)
        // Both casings resolve to the same lowercased record.
        XCTAssertEqual(ledger.record(forBrand: brand).sentClean, 1)
        XCTAssertEqual(ledger.record(forBrand: brand.uppercased()).sentClean, 1)
        XCTAssertNotNil(ledger.records[brand.lowercased()])
    }

    func testTenCleanSendsGraduates() {
        let brand = freshBrand("clean")
        let ledger = AutonomyLedger.shared

        for _ in 0..<AutonomyLedger.minCleanSends {
            ledger.recordSent(brand: brand, edited: false)
        }

        XCTAssertTrue(ledger.graduationReady(forBrand: brand))
        let r = ledger.readiness(forBrand: brand)
        XCTAssertTrue(r.ready)
        XCTAssertEqual(r.cleanSends, AutonomyLedger.minCleanSends)
        XCTAssertEqual(r.needed, 0)
        XCTAssertEqual(r.editRate, 0)
        XCTAssertEqual(r.gateBlocks, 0)
    }

    func testNotEnoughCleanSendsReportsNeeded() {
        let brand = freshBrand("short")
        let ledger = AutonomyLedger.shared

        for _ in 0..<3 { ledger.recordSent(brand: brand, edited: false) }

        XCTAssertFalse(ledger.graduationReady(forBrand: brand))
        let r = ledger.readiness(forBrand: brand)
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.cleanSends, 3)
        XCTAssertEqual(r.needed, AutonomyLedger.minCleanSends - 3)
    }

    func testHighEditRateBlocksGraduation() {
        let brand = freshBrand("edited")
        let ledger = AutonomyLedger.shared

        // 10 clean sends (would graduate), then enough edits to push editRate
        // above the 0.2 cap. 10 clean + 3 edited = 3/13 = 0.23 > 0.2.
        for _ in 0..<AutonomyLedger.minCleanSends {
            ledger.recordSent(brand: brand, edited: false)
        }
        for _ in 0..<3 { ledger.recordSent(brand: brand, edited: true) }

        let rec = ledger.record(forBrand: brand)
        XCTAssertGreaterThan(rec.editRate, AutonomyLedger.maxEditRate)
        XCTAssertFalse(ledger.graduationReady(forBrand: brand))
        XCTAssertFalse(ledger.readiness(forBrand: brand).ready)
    }

    func testGateBlockBlocksGraduation() {
        let brand = freshBrand("gate")
        let ledger = AutonomyLedger.shared

        for _ in 0..<AutonomyLedger.minCleanSends {
            ledger.recordSent(brand: brand, edited: false)
        }
        // Clean record would graduate; one gate block must veto it.
        XCTAssertTrue(ledger.graduationReady(forBrand: brand))
        ledger.recordGateBlock(brand: brand)
        XCTAssertEqual(ledger.record(forBrand: brand).gateBlocks, 1)
        XCTAssertFalse(ledger.graduationReady(forBrand: brand))
        XCTAssertEqual(ledger.readiness(forBrand: brand).gateBlocks, 1)
    }

    func testLiveBrandIsNotReady() {
        let brand = freshBrand("live")
        let ledger = AutonomyLedger.shared

        for _ in 0..<AutonomyLedger.minCleanSends {
            ledger.recordSent(brand: brand, edited: false)
        }
        XCTAssertTrue(ledger.graduationReady(forBrand: brand))

        // Once a human graduates the brand to LIVE, it is no longer "ready":
        // graduation is the OBSERVE -> LIVE transition, already done.
        ledger.setMode(.live, forBrand: brand)
        XCTAssertEqual(ledger.mode(forBrand: brand), .live)
        XCTAssertFalse(ledger.graduationReady(forBrand: brand))
        XCTAssertFalse(ledger.readiness(forBrand: brand).ready)
    }

    // A corrupt ledger file must be backed up (not silently wiped + overwritten).
    // [audit-swarm]
    func testCorruptLedgerFileIsBackedUpNotSilentlyWiped() {
        let ledger = AutonomyLedger.shared
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("jax")
        let fileURL = dir.appendingPathComponent("autonomy-ledger.json")
        // Seed a real record, then corrupt the file on disk behind the store.
        let brand = freshBrand("corrupt")
        ledger.recordSent(brand: brand, edited: false)
        try? "{ this is not valid json ".data(using: .utf8)!.write(to: fileURL)

        ledger.load()   // should detect corruption, back up, and start empty

        XCTAssertTrue(ledger.records.isEmpty, "corrupt file should load as empty")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix("autonomy-ledger.corrupt-") } ?? []
        XCTAssertFalse(backups.isEmpty, "the corrupt bytes should be preserved in a backup")
        // cleanup backups
        for b in backups { try? FileManager.default.removeItem(at: dir.appendingPathComponent(b)) }
    }

    func testPersistenceSurvivesFreshRead() {
        let brand = freshBrand("persist")
        let ledger = AutonomyLedger.shared

        for _ in 0..<5 { ledger.recordSent(brand: brand, edited: false) }
        ledger.recordSent(brand: brand, edited: true)
        ledger.recordGateBlock(brand: brand)
        ledger.setMode(.live, forBrand: brand)

        // Reload the dict from disk and confirm the counts round-tripped.
        ledger.load()
        let rec = ledger.record(forBrand: brand)
        XCTAssertEqual(rec.sentClean, 5)
        XCTAssertEqual(rec.sentEdited, 1)
        XCTAssertEqual(rec.gateBlocks, 1)
        XCTAssertEqual(rec.mode, .live)
    }
}
