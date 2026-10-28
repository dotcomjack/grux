import XCTest
@testable import Grux

/// WHICH FILES "FILES THAT NAME THEMSELVES" MAY TOUCH.
///
/// Renaming a file a person named is the worst thing this feature can do, so
/// the name table leans to false and is pinned both ways: names a clock, a
/// camera or a server made turn true, and names somebody could have typed stay
/// false. Everything here is pure apart from one xattr on a temporary file.
final class FileNamingRulesTests: XCTestCase {

    // MARK: - Looks machine-made

    func testMachineMadeNamesAreRecognized() {
        let machine = [
            "Screenshot 2026-10-27 at 9.41.03 AM",
            "Screen Shot 2019-01-01 at 10.00.00 AM",
            "document(3)",
            "document (3)",
            "IMG_4471",
            "IMG-20261027-WA0001",
            "PXL_20261027_094103123",
            "Screenshot_20261027-094103",
            "CleanShot 2026-10-27 at 9.41.03 AM",
            "Screen Recording 2026-10-27 at 9.41.03 AM",
            "20261027_094103",
            "1693",
            "C0855-1693",
            "INV-000123",
            "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            "a3f9c2d1e4b5a6f7c8d9",
            "download",
            "file-2",
            "untitled",
            "Untitled 2",
            "scan0001",
            "DSC_0042",
            "invoice",
            "attachment",
            "export_2026",
            "unknown",
            "receipt (1)",
            // Codes by the letter-run rule (review ruling 2026-10-28). The
            // review called these three typed; the ruling keeps them as codes:
            // one letter and a year is a form number, not a word.
            "W2-2025",
            "Q4-2025",
            "W2_2025",
            "1040-2025",
            // "statement" is one of the spec's generic words, followed only by
            // digits and separators, so this is machine-made by that rule, not
            // by the hex rule the review named it under.
            "Statement 20261001-20261031",
        ]
        XCTAssertGreaterThanOrEqual(machine.count, 15)
        for name in machine {
            XCTAssertTrue(FileNamingRules.looksMachineMade(name), "\(name) reads as typed by a person, but a machine made it")
        }
    }

    func testNamesAPersonCouldHaveTypedStayAlone() {
        let human = [
            "Lease renewal 2027",
            "taxes",
            "Q3 deck final",
            "Q3",
            "taxes_2026",
            "Lease_2027",
            "Northwind Studio logo",
            "Acme contract signed",
            "resume",
            "budget 2027 draft",
            "Meeting notes Oct 12",
            "floor plan v2",
            "Invoice for Acme",
            "Passport scan for visa",
            "Recipe for bread",
            "Holiday card",
            "photo of the garden",
            "receipt Acme hardware",
            "Screenshot of the bug",
            "Acme W2",
            "family tree",
            // A word run into a year has no separator, and is plainly typed
            // (review 2026-10-28).
            "taxes2025",
            "resume2024",
            "lease2027",
            "Acme2024",
            "q3deck",
            // A long number inside a worded name is a person's order number,
            // not a hash (review 2026-10-28).
            "Acme order 112-1234567-1234567",
            "Acme tracking 9400111202555842761302",
            // A stamp needs a digit after it (review 2026-10-28).
            "Screen Recording Policy",
            "Screen recording consent form",
        ]
        XCTAssertGreaterThanOrEqual(human.count, 15)
        for name in human {
            XCTAssertFalse(FileNamingRules.looksMachineMade(name), "\(name) would be renamed, and a person may have typed it")
        }
    }

    /// The limits on the digit rule, each with the case it lets through.
    func testTheCodeRuleNeedsLengthAndNoWord() {
        XCTAssertTrue(FileNamingRules.isCodeLike("C0855-1693"))
        XCTAssertTrue(FileNamingRules.isCodeLike("INV-000123"), "three capitals is a code prefix")
        XCTAssertFalse(FileNamingRules.isCodeLike("Q3"), "too short to be a code")
        XCTAssertFalse(FileNamingRules.isCodeLike("taxes_2026"), "holds a word")
        XCTAssertFalse(FileNamingRules.isCodeLike("Acme 12345"), "two tokens is not one code")
        // Letter runs, not separator segments: a word run into a year is a word.
        XCTAssertFalse(FileNamingRules.isCodeLike("taxes2025"), "a word with no separator before its year")
        XCTAssertFalse(FileNamingRules.isCodeLike("resume2024"))
        XCTAssertFalse(FileNamingRules.isCodeLike("lease2027"))
        XCTAssertFalse(FileNamingRules.isCodeLike("inv-000123"), "two or three letters must be capitals")
        XCTAssertFalse(FileNamingRules.isCodeLike("q3deck"), "digits under 40%")
    }

    /// The hash rule reads the whole stem, never a run inside it.
    func testTheHashRuleNeedsTheWholeName() {
        XCTAssertTrue(FileNamingRules.looksMachineMade("a3f9c2d1e4b5a6f7c8d9"))
        XCTAssertTrue(FileNamingRules.looksMachineMade("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        XCTAssertFalse(FileNamingRules.looksMachineMade("Acme order a3f9c2d1e4b5a6f7c8d9"),
                       "a hash inside a worded name is a reference a person kept")
        XCTAssertFalse(FileNamingRules.looksMachineMade("deadbeefcafebabefacade"),
                       "hex letters with no digit are words, not a hash")
    }

    // MARK: - Partial and hidden

    func testPartialAndHiddenFilesAreNotFinishedFiles() {
        for name in ["..Screenshot 2026-10-27 at 9.41.03 AM.png-a1B2", ".Screenshot 2026-10-27 at 9.41.03 AM.png",
                     "report.pdf.crdownload", "report.pdf.download", "report.pdf.part", "report.pdf.partial",
                     "report.pdf.tmp", "report.pdf.opdownload", "REPORT.PDF.CRDOWNLOAD"] {
            XCTAssertTrue(FileNamingRules.isPartialOrHidden(name), name)
        }
        for name in ["report.pdf", "IMG_4471.png", "document (3).pdf"] {
            XCTAssertFalse(FileNamingRules.isPartialOrHidden(name), name)
        }
    }

    // MARK: - Kind

    func testKindComesFromTheExtensionInAnyCase() {
        for ext in ["png", "PNG", "jpg", "jpeg", "JPEG", "heic", "tiff", "gif", "webp"] {
            XCTAssertEqual(FileNamingRules.kind(ofExtension: ext), .image, ext)
        }
        XCTAssertEqual(FileNamingRules.kind(ofExtension: "pdf"), .pdf)
        XCTAssertEqual(FileNamingRules.kind(ofExtension: "PDF"), .pdf)
        for ext in ["mov", "zip", "dmg", "docx", "txt", ""] {
            XCTAssertNil(FileNamingRules.kind(ofExtension: ext), ext)
        }
    }

    // MARK: - Candidacy

    func testCandidacyFollowsTheFolderRule() {
        let shots = FileNamingFolder(url: URL(fileURLWithPath: "/tmp/shots"), screenshots: true, downloads: false)
        let downloads = FileNamingFolder(url: URL(fileURLWithPath: "/tmp/dl"), screenshots: false, downloads: true)

        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Screenshot 2026-10-27 at 9.41.03 AM.png", in: shots,
                                                 isScreenCapture: { true }), .candidate(.image))
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "IMG_4471.png", in: shots, isScreenCapture: { false }),
                       .skip(.humanName), "the screenshot folder renames captures only, whatever the name")
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "document (3).pdf", in: downloads, isScreenCapture: { true }),
                       .candidate(.pdf))
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Lease renewal 2027.pdf", in: downloads, isScreenCapture: { false }),
                       .skip(.humanName))
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "IMG_4471.mov", in: downloads, isScreenCapture: { false }),
                       .skip(.unsupported))
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "credentials.png", in: downloads, isScreenCapture: { false }),
                       .skip(.unsupported), "a name on the deny list is never read")
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "document.pdf.crdownload", in: downloads, isScreenCapture: { false }),
                       .ignore)
    }

    /// The capture mark survives a rename, so in the screenshot folder the
    /// name has to read as a capture too (review 2026-10-28).
    func testACaptureAPersonNamedIsNotACandidate() {
        let shots = FileNamingFolder(url: URL(fileURLWithPath: "/tmp/shots"), screenshots: true, downloads: false)
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Screenshot 2026-10-27 at 9.41.03 AM.png", in: shots,
                                                 isScreenCapture: { true }), .candidate(.image), "control")
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Screen Shot 2019-01-01 at 10.00.00 AM.png", in: shots,
                                                 isScreenCapture: { true }), .candidate(.image))
        for typed in ["Bug repro.png", "Lease photo.png", "Screenshot of the bug.png", "Northwind Studio Invoice.png"] {
            XCTAssertEqual(FileNamingRules.candidacy(fileName: typed, in: shots, isScreenCapture: { true }),
                           .skip(.humanName), "\(typed) carries the capture mark but a person named it")
        }
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "IMG_4471.png", in: shots, isScreenCapture: { true }),
                       .candidate(.image), "a machine-made name with the mark is still a capture")

        var custom = shots
        custom.capturePrefixes = ["Grab"]
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Grab 2026-10-27 at 9.41.03 AM.png", in: custom,
                                                 isScreenCapture: { true }), .candidate(.image))
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Screenshot 2026-10-27 at 9.41.03 AM.png", in: custom,
                                                 isScreenCapture: { true }), .candidate(.image),
                       "a machine-made name still counts when the prefix is custom")
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Grab bag.png", in: custom, isScreenCapture: { true }),
                       .skip(.humanName))
    }

    /// A CAPTURE ON A MAC IN ANOTHER LANGUAGE. Its prefix is localized and
    /// not in the `name` default, so with the English prefixes alone no
    /// capture was ever named there (review 2026-10-28). Every locale's name
    /// carries the date, so any prefix, a space and `YYYY-MM-DD` counts.
    /// The capture prefixes of the languages these tests use, as
    /// `systemCapturePrefixes` reads them from the system's table.
    private let localizedPrefixes = ["Bildschirmfoto", "Capture d\u{2019}\u{E9}cran", "Captura de pantalla", "\u{622A}\u{5C4F}"]

    func testALocalizedCaptureNameIsACandidate() {
        var shots = FileNamingFolder(url: URL(fileURLWithPath: "/tmp/shots"), screenshots: true, downloads: false)
        shots.capturePrefixes = FileNamingRules.capturePrefixes(defaults: [:], system: localizedPrefixes)
        let localized = [
            "Bildschirmfoto 2026-10-28 um 09.41.03.png",
            "Capture d\u{2019}\u{E9}cran 2026-10-28 \u{E0} 09.41.03.png",
            "Captura de pantalla 2026-10-28 a las 9.41.03.png",
            "\u{622A}\u{5C4F}2026-10-28 \u{4E0B}\u{5348}3.41.03.png",
        ]
        for name in localized {
            XCTAssertEqual(FileNamingRules.candidacy(fileName: name, in: shots, isScreenCapture: { true }),
                           .candidate(.image), "\(name) is a capture on a Mac in another language")
            XCTAssertEqual(FileNamingRules.candidacy(fileName: name, in: shots, isScreenCapture: { false }),
                           .skip(.humanName), "control: without the capture mark \(name) is not a capture")
        }
        let english = FileNamingFolder(url: URL(fileURLWithPath: "/tmp/shots"), screenshots: true, downloads: false)
        XCTAssertEqual(FileNamingRules.candidacy(fileName: "Bildschirmfoto 2026-10-28 um 09.41.03.png", in: english,
                                                 isScreenCapture: { true }), .skip(.humanName),
                       "control: without the German prefix in the set, the German name is not known")
        XCTAssertFalse(FileNamingRules.looksLikeCapture("Bildschirmfoto vom Fehler", prefixes: localizedPrefixes),
                       "a localized prefix with no date is a name a person typed")
        XCTAssertFalse(FileNamingRules.looksLikeCapture("Bildschirmfoto 2026", prefixes: localizedPrefixes), "a year is not a date")
        XCTAssertFalse(FileNamingRules.looksLikeCapture("2026-10-28 notes", prefixes: localizedPrefixes), "a date must follow a prefix")
    }

    /// A CAPTURE'S NAME IS A REAL PREFIX AND THE WHOLE STAMP. Any words in
    /// front of a timestamp read a renamed capture's copy, `Login error
    /// 2026-10-28 at 9.41.03 AM copy`, as fresh (review 2026-10-28, twice), so
    /// the prefix is one macOS really writes.
    func testTheLocalizedCaptureShapeIsTheWholeName() {
        let prefixes = FileNamingRules.capturePrefixes(defaults: [:], system: localizedPrefixes)
        let captures = [
            "Bildschirmfoto 2026-10-27 um 09.41.03",
            "Capture d\u{2019}\u{E9}cran 2026-10-27 \u{E0} 09.41.03",
            "\u{622A}\u{5C4F}2026-10-27 09.41.03",
            "Screenshot 2026-10-27 at 9.41.03 AM (2)",
            "Bildschirmfoto 2026-10-27 um 09:41",
        ]
        for name in captures {
            XCTAssertTrue(FileNamingRules.looksLikeCapture(name, prefixes: prefixes), "\(name) is a capture's own name")
        }
        let typed = [
            "Login error 2026-10-28 at 9.41.03 AM",
            "Login error 2026-10-28 at 9.41.03 AM copy",
            "Bug repro 2026-10-28 at 9.41.03 AM copy",
            "Call with Dana 2026-10-28 at 2.15 PM",
            "Expense report 2026-10-28 copy",
            "Standup notes 2026-10-27",
            "Lease 2026-11-01 signed",
            "2026-10-27 09.41.03",
            "Notes 2026-10-27 9.41.03 v2",
        ]
        for name in typed {
            XCTAssertFalse(FileNamingRules.looksLikeCapture(name, prefixes: prefixes),
                           "\(name) reads as a capture, and a person named it")
        }
    }

    /// The system's own table of capture prefixes is read when it is there,
    /// and its absence leaves the name default and the English two.
    func testTheCapturePrefixesComeFromTheSystemTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-naming-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let table: [String: Any] = [
            "de": ["Screenshot": "Bildschirmfoto", "Other": "Andere"],
            "fr": ["Screenshot": "Capture d\u{2019}\u{E9}cran"],
            "en": ["Screenshot": "Screenshot"],
            "LocProvenance": ["de": "1"],
        ]
        let url = dir.appendingPathComponent("Localizable.loctable")
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: url)
        XCTAssertEqual(FileNamingRules.systemCapturePrefixes(table: url),
                       ["Bildschirmfoto", "Capture d\u{2019}\u{E9}cran", "Screenshot"])
        XCTAssertEqual(FileNamingRules.systemCapturePrefixes(table: dir.appendingPathComponent("missing.loctable")), [])
        XCTAssertEqual(FileNamingRules.capturePrefixes(defaults: ["name": "Grab"], system: []), ["Grab", "Screenshot", "Screen Shot"],
                       "with no table, the name default and the English two")
        XCTAssertEqual(FileNamingRules.capturePrefixes(defaults: [:], system: ["Bildschirmfoto", "Screenshot"]),
                       ["Bildschirmfoto", "Screenshot", "Screen Shot"])
    }

    /// A folder that does not exist is kept, so the retry can arm it once it
    /// appears (review 2026-10-28: it was dropped for the whole arm).
    func testAMissingFolderIsStillAFolderToWatch() {
        let home = URL(fileURLWithPath: "/tmp/file-naming-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "control: the home folder exists")
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let folders = FileNamingRules.watchedFolders(defaults: ["location": "~/Desktop/Shots"], home: home, downloads: downloads)
        XCTAssertEqual(folders.map(\.url.path), [home.appendingPathComponent("Desktop/Shots").path, downloads.path])
        XCTAssertEqual(folders.map(\.screenshots), [true, false])
        let merged = FileNamingRules.watchedFolders(defaults: ["location": "~/Downloads"], home: home, downloads: downloads)
        XCTAssertEqual(merged.count, 1, "the screenshot folder and Downloads are one folder")
        XCTAssertEqual(merged.first?.downloads, true)
    }

    func testTheCapturePrefixComesFromTheDefaults() {
        XCTAssertEqual(FileNamingRules.capturePrefixes(defaults: [:]), ["Screenshot", "Screen Shot"])
        XCTAssertEqual(FileNamingRules.capturePrefixes(defaults: ["name": "  "]), ["Screenshot", "Screen Shot"])
        XCTAssertEqual(FileNamingRules.capturePrefixes(defaults: ["name": "Grab"]), ["Grab", "Screenshot", "Screen Shot"])
        XCTAssertTrue(FileNamingRules.looksLikeCapture("Grab 2026-10-27", prefixes: ["Grab"]))
        XCTAssertTrue(FileNamingRules.looksLikeCapture("screenshot 2026-10-27", prefixes: ["Screenshot"]))
        XCTAssertFalse(FileNamingRules.looksLikeCapture("Grabbed 2026", prefixes: ["Grab"]), "a space must follow")
        XCTAssertFalse(FileNamingRules.looksLikeCapture("Screenshot final", prefixes: ["Screenshot"]), "a digit must follow")
        XCTAssertFalse(FileNamingRules.looksLikeCapture("My Screenshot 2026", prefixes: ["Screenshot"]), "at the start only")
    }

    // MARK: - Pairs

    func testAFileWithAPairIsFound() {
        XCTAssertTrue(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471.MOV", "notes.txt"]), "a Live Photo")
        XCTAssertTrue(FileNamingRules.hasPair("IMG_4471.JPG", among: ["img_4471.xmp"]), "a sidecar, any case")
        XCTAssertTrue(FileNamingRules.hasPair("DSC_0042.jpg", among: ["DSC_0042.NEF"]), "a raw and its JPEG")
        XCTAssertFalse(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4472.MOV", "IMG_4471 copy.HEIC"]))
        XCTAssertFalse(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471.heic"]), "the same file, another case")
        XCTAssertFalse(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471"]), "no extension is no pair")
        XCTAssertFalse(FileNamingRules.hasPair("IMG_4471.HEIC", among: []))
        // A partner still downloading, and a sidecar named after the whole
        // file name (review 2026-10-28).
        XCTAssertTrue(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471.MOV.crdownload"]), "a movie still downloading")
        XCTAssertTrue(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471.MOV.download"]), "a Safari download")
        XCTAssertTrue(FileNamingRules.hasPair("IMG_0012.jpg", among: ["IMG_0012.jpg.xmp"]), "a darktable sidecar")
        XCTAssertTrue(FileNamingRules.hasPair("IMG_0012.JPG", among: ["img_0012.jpg.XMP"]), "any case")
        XCTAssertTrue(FileNamingRules.hasPair("IMG_0012.jpg", among: ["IMG_0012.aae"]), "a Photos edit sidecar")
        XCTAssertFalse(FileNamingRules.hasPair("IMG_4471.HEIC", among: ["IMG_4471.HEIC.crdownload"]),
                       "the same file still downloading is not a partner")
        XCTAssertFalse(FileNamingRules.hasPair("IMG_0012.jpg", among: ["IMG_0013.jpg.xmp", "IMG_00121.aae"]))
    }

    // MARK: - The screenshot folder

    private let home = URL(fileURLWithPath: "/tmp/file-naming-home", isDirectory: true)

    func testTheScreenshotLocationIsATildePath() {
        let got = FileNamingRules.screenshotFolder(defaults: ["location": "~/Documents/", "target": "file"], home: home)
        XCTAssertEqual(got?.path, "/tmp/file-naming-home/Documents")
    }

    func testNoLocationMeansTheDesktop() {
        XCTAssertEqual(FileNamingRules.screenshotFolder(defaults: [:], home: home)?.path, "/tmp/file-naming-home/Desktop")
        XCTAssertEqual(FileNamingRules.screenshotFolder(defaults: ["location": "  "], home: home)?.path,
                       "/tmp/file-naming-home/Desktop")
    }

    func testAnAbsoluteLocationIsKept() {
        let got = FileNamingRules.screenshotFolder(defaults: ["location": "/Volumes/Shots/"], home: home)
        XCTAssertEqual(got?.path, "/Volumes/Shots")
    }

    func testTheClipboardTargetWritesNoFile() {
        XCTAssertNil(FileNamingRules.screenshotFolder(defaults: ["location": "~/Documents/", "target": "clipboard"],
                                                      home: home))
    }

    // MARK: - The screen capture mark

    func testTheCaptureMarkIsReadFromTheXattr() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-naming-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("capture.png")
        try Data([1, 2, 3]).write(to: url)
        XCTAssertFalse(FileNamingRules.isScreenCapture(url), "control: a file with no mark reads as a capture")

        func mark(_ value: Bool) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            let rc = data.withUnsafeBytes {
                setxattr(url.path, FileNamingRules.screenCaptureAttribute, $0.baseAddress, data.count, 0, 0)
            }
            XCTAssertEqual(rc, 0, "could not set the xattr")
        }
        try mark(true)
        XCTAssertTrue(FileNamingRules.isScreenCapture(url))
        try mark(false)
        XCTAssertFalse(FileNamingRules.isScreenCapture(url))
    }
}
