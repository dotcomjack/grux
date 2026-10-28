import XCTest
@testable import Grux

/// A RENAME MUST NEVER LOSE, MOVE OR OVERWRITE A FILE, AND EVERY ONE CAN BE
/// UNDONE. All of it runs in a temporary folder of the test's own.
final class FileRenamerTests: XCTestCase {

    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = fm.temporaryDirectory.appendingPathComponent("file-renamer-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func file(_ name: String, _ bytes: String = "contents") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - Unique names

    func testUniqueNamesCountUpAndKeepTheExtensionCase() throws {
        let renamer = FileRenamer(fileManager: fm)
        XCTAssertEqual(renamer.uniqueName(base: "Northwind Invoice", ext: "PNG", in: dir), "Northwind Invoice.PNG")
        try file("Northwind Invoice.PNG")
        XCTAssertEqual(renamer.uniqueName(base: "Northwind Invoice", ext: "PNG", in: dir), "Northwind Invoice 2.PNG")
        try file("Northwind Invoice 2.PNG")
        XCTAssertEqual(renamer.uniqueName(base: "Northwind Invoice", ext: "PNG", in: dir), "Northwind Invoice 3.PNG")
    }

    // MARK: - Rename

    func testARenameKeepsTheExtensionAndTheFolder() throws {
        let original = try file("IMG_4471.jpeg", "the picture")
        let stamp = try XCTUnwrap(FileFingerprint.of(original, fileManager: fm))
        let renamed = try FileRenamer(fileManager: fm).rename(original, to: "Acme Receipt Oct 2026", expecting: stamp)
        XCTAssertEqual(renamed.lastPathComponent, "Acme Receipt Oct 2026.jpeg")
        XCTAssertEqual(renamed.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertFalse(exists("IMG_4471.jpeg"))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "the picture", "the bytes changed")
    }

    func testARenameNeverOverwrites() throws {
        let original = try file("IMG_4471.png", "new")
        try file("Acme Receipt.png", "already here")
        let renamed = try FileRenamer(fileManager: fm).rename(original, to: "Acme Receipt", expecting: nil)
        XCTAssertEqual(renamed.lastPathComponent, "Acme Receipt 2.png")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Acme Receipt.png"), encoding: .utf8),
                       "already here")
    }

    func testAFileChangedMeanwhileIsSkipped() throws {
        let original = try file("document (3).pdf", "first")
        let stamp = try XCTUnwrap(FileFingerprint.of(original, fileManager: fm))
        try Data("first and then some more".utf8).write(to: original)
        XCTAssertThrowsError(try FileRenamer(fileManager: fm).rename(original, to: "Acme Lease", expecting: stamp)) {
            XCTAssertEqual($0 as? FileRenameError, .changedMeanwhile)
        }
        XCTAssertTrue(exists("document (3).pdf"), "a file that changed was renamed anyway")
    }

    func testAFileMovedAwayMeanwhileIsSkipped() throws {
        let original = try file("document (3).pdf")
        let stamp = try XCTUnwrap(FileFingerprint.of(original, fileManager: fm))
        try fm.moveItem(at: original, to: dir.appendingPathComponent("Lease renewal 2027.pdf"))
        XCTAssertThrowsError(try FileRenamer(fileManager: fm).rename(original, to: "Acme Lease", expecting: stamp)) {
            XCTAssertEqual($0 as? FileRenameError, .changedMeanwhile)
        }
        XCTAssertTrue(exists("Lease renewal 2027.pdf"), "the name a person gave was touched")
    }

    func testANameThatWouldHideOrLeaveTheFolderIsRefused() throws {
        let original = try file("IMG_4471.png")
        for bad in ["", "  ", ".hidden", "a/b", "a:b"] {
            XCTAssertThrowsError(try FileRenamer(fileManager: fm).rename(original, to: bad, expecting: nil), bad)
        }
        XCTAssertTrue(exists("IMG_4471.png"))
    }

    // MARK: - Ledger and undo

    private func ledger() -> FileRenameLedger {
        FileRenameLedger(url: dir.appendingPathComponent("ledger/ledger.json"), fileManager: fm)
    }

    /// Renames `old` to `new` on disk and records it, the way the service does,
    /// file number included.
    private func renamed(_ old: String, to base: String, in ledger: FileRenameLedger) throws -> FileRename {
        let url = try file(old)
        let stamp = try XCTUnwrap(FileFingerprint.of(url, fileManager: fm))
        let to = try FileRenamer(fileManager: fm).rename(url, to: base, expecting: stamp)
        let entry = FileRename(id: UUID(), folder: dir.path, oldName: old, newName: to.lastPathComponent,
                               at: Date(), undoneAt: nil, fileID: stamp.fileNumber)
        ledger.append(entry)
        return entry
    }

    func testUndoRestoresTheName() throws {
        let book = ledger()
        let entry = try renamed("IMG_4471.png", to: "Acme Receipt", in: book)
        XCTAssertEqual(book.undo(id: entry.id), .restored)
        XCTAssertTrue(exists("IMG_4471.png"))
        XCTAssertFalse(exists("Acme Receipt.png"))
        XCTAssertNotNil(book.entry(id: entry.id)?.undoneAt)
        XCTAssertEqual(book.undo(id: entry.id), .nothingToUndo, "the same rename was undone twice")
        XCTAssertEqual(book.undo(id: UUID()), .nothingToUndo)
    }

    func testUndoRefusesWhenTheOldNameIsTaken() throws {
        let book = ledger()
        let entry = try renamed("IMG_4471.png", to: "Acme Receipt", in: book)
        try file("IMG_4471.png", "somebody else's file")
        XCTAssertEqual(book.undo(id: entry.id), .oldNameTaken)
        XCTAssertTrue(exists("Acme Receipt.png"), "a refused undo changed something")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("IMG_4471.png"), encoding: .utf8),
                       "somebody else's file")
        XCTAssertNil(book.entry(id: entry.id)?.undoneAt)
    }

    func testUndoRefusesWhenTheRenamedFileIsGone() throws {
        let book = ledger()
        let entry = try renamed("IMG_4471.png", to: "Acme Receipt", in: book)
        try fm.removeItem(at: dir.appendingPathComponent("Acme Receipt.png"))
        XCTAssertEqual(book.undo(id: entry.id), .newNameGone)
        XCTAssertFalse(exists("IMG_4471.png"))
    }

    /// UNDO MOVES GRUX'S FILE OR NOTHING. The person deleted the renamed file
    /// and later saved their own under the same name; an undo by name alone
    /// renamed theirs (review 2026-10-28).
    func testUndoRefusesAFileThatIsNotTheOneGruxRenamed() throws {
        let book = ledger()
        let entry = try renamed("IMG_4471.png", to: "Acme Receipt", in: book)
        XCTAssertNotNil(entry.fileID, "control: the rename recorded no file number")
        try fm.removeItem(at: dir.appendingPathComponent("Acme Receipt.png"))
        try file("Acme Receipt.png", "a file the person saved later")
        let theirs = try XCTUnwrap(FileFingerprint.of(dir.appendingPathComponent("Acme Receipt.png"), fileManager: fm))
        XCTAssertNotEqual(theirs.fileNumber, entry.fileID, "control: the new file reused the old number")

        XCTAssertEqual(book.undo(id: entry.id), .fileChanged,
                       "a file under the new name that is not Grux's reads as changed, not as gone")
        XCTAssertTrue(exists("Acme Receipt.png"), "the person's file was renamed")
        XCTAssertFalse(exists("IMG_4471.png"))
        XCTAssertNil(book.entry(id: entry.id)?.undoneAt)
    }

    /// A FILE SAVED OVER AFTER THE RENAME IS LEFT ALONE, AND SAID SO. An app's
    /// safe save (Preview, TextEdit) writes a new file over the old one: same
    /// name, new number. Undo said the file had been moved, which it had not
    /// (review 2026-10-28).
    func testUndoOfAFileSavedOverSaysItChanged() throws {
        let book = ledger()
        let entry = try renamed("IMG_4471.png", to: "Acme Receipt", in: book)
        let saved = dir.appendingPathComponent("saved-copy.tmp")
        try Data("marked up".utf8).write(to: saved)
        _ = try fm.replaceItemAt(dir.appendingPathComponent("Acme Receipt.png"), withItemAt: saved)
        let now = try XCTUnwrap(FileFingerprint.of(dir.appendingPathComponent("Acme Receipt.png"), fileManager: fm))
        XCTAssertNotEqual(now.fileNumber, entry.fileID, "control: the save kept the file number, so this proves nothing")

        XCTAssertEqual(book.undo(id: entry.id), .fileChanged)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Acme Receipt.png"), encoding: .utf8), "marked up",
                       "a changed file was moved")
        XCTAssertFalse(exists("IMG_4471.png"))
        XCTAssertEqual(FileRenameLedger.restore(entry, fileManager: fm), .fileChanged, "the disk half says the same")
    }

    /// A ledger written before file numbers were kept still loads, and its
    /// entries undo by name as they did.
    func testALedgerWithoutFileNumbersStillLoadsAndUndoes() throws {
        try file("Acme Receipt.png", "the picture")
        let id = UUID()
        let json = #"[{"at":0,"folder":"\#(dir.path)","id":"\#(id.uuidString)","newName":"Acme Receipt.png","oldName":"IMG_4471.png"}]"#
        let url = dir.appendingPathComponent("ledger/ledger.json")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let book = ledger()
        let entry = try XCTUnwrap(book.entry(id: id), "an old ledger no longer loads")
        XCTAssertNil(entry.fileID)
        XCTAssertEqual(book.undo(id: id), .restored)
        XCTAssertTrue(exists("IMG_4471.png"))
        XCTAssertFalse(exists("Acme Receipt.png"))
    }

    func testUndoLastTakesTheNewestNotYetUndone() throws {
        let book = ledger()
        let first = try renamed("IMG_0001.png", to: "Acme First", in: book)
        let second = try renamed("IMG_0002.png", to: "Acme Second", in: book)
        XCTAssertEqual(book.undoLast(), .restored)
        XCTAssertNotNil(book.entry(id: second.id)?.undoneAt)
        XCTAssertNil(book.entry(id: first.id)?.undoneAt)
        XCTAssertEqual(book.undoLast(), .restored)
        XCTAssertNotNil(book.entry(id: first.id)?.undoneAt)
        XCTAssertEqual(book.undoLast(), .nothingToUndo)
        XCTAssertTrue(exists("IMG_0001.png") && exists("IMG_0002.png"))
    }

    func testTheLedgerIsCappedAt200AndSurvivesARelaunch() throws {
        let book = ledger()
        var ids: [UUID] = []
        for i in 0..<205 {
            let entry = FileRename(id: UUID(), folder: dir.path, oldName: "IMG_\(i).png", newName: "Acme \(i).png",
                                   at: Date(), undoneAt: nil)
            ids.append(entry.id)
            book.append(entry)
        }
        XCTAssertEqual(book.entries.count, FileRenameLedger.cap)
        XCTAssertEqual(FileRenameLedger.cap, 200)
        XCTAssertEqual(book.entries.first?.id, ids[5], "the oldest were not the ones dropped")
        let reread = ledger()
        XCTAssertEqual(reread.entries.map(\.id), book.entries.map(\.id), "the ledger on disk is not the ledger in memory")
        XCTAssertEqual(reread.entries.last?.newName, "Acme 204.png")
        XCTAssertEqual(reread.recent(10).count, 10)
        XCTAssertEqual(reread.recent(10).first?.id, ids[204], "recent is not newest first")
    }
}
