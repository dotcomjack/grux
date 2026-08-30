import XCTest
@testable import Grux

// Coverage for the two competitor importers. Fixtures are built on disk in temp
// dirs; the ZIP importer's archive is created in-test with /usr/bin/zip.
final class ImporterTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-importer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Claude Design ZIP importer

    func testImportArchiveMapsWebFilesAndAssets() throws {
        // Build a source web bundle.
        let source = tmp.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "<html><body><h1>Imported</h1></body></html>".write(to: source.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body { margin: 0; }".write(to: source.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        try Data([0x1, 0x2, 0x3]).write(to: source.appendingPathComponent("secret.bin")) // unknown type

        // Zip it.
        let zipURL = tmp.appendingPathComponent("bundle.zip")
        try runZip(cwd: source, zipURL: zipURL)

        let designRoot = tmp.appendingPathComponent("design", isDirectory: true)
        let result = try ClaudeDesignImporter.importArchive(at: zipURL, into: designRoot, title: "My Landing")

        XCTAssertEqual(result.slug, "my-landing")
        let site = result.projectDir.appendingPathComponent("site")
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appendingPathComponent("index.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appendingPathComponent("styles.css").path))
        // Unknown files land under site/assets/.
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appendingPathComponent("assets/secret.bin").path),
                      "unknown file types must be preserved under site/assets/")
        // project.json written and decodable.
        let projectData = try Data(contentsOf: result.projectDir.appendingPathComponent("project.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(DesignProject.self, from: projectData)
        XCTAssertEqual(project.slug, "my-landing")
        XCTAssertTrue(project.tags.contains("imported"))
    }

    func testImportArchiveRejectsBundleWithNoHTML() throws {
        let source = tmp.appendingPathComponent("noHTML", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "just text".write(to: source.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let zipURL = tmp.appendingPathComponent("noHTML.zip")
        try runZip(cwd: source, zipURL: zipURL)

        XCTAssertThrowsError(try ClaudeDesignImporter.importArchive(at: zipURL, into: tmp.appendingPathComponent("design2"))) { error in
            guard case ClaudeDesignImporter.ImportError.noHTMLFound = error else {
                return XCTFail("expected noHTMLFound, got \(error)")
            }
        }
    }

    // MARK: - Open Design directory importer

    func testImportProjectStagesDesignSystemsAndSkipsMetadata() throws {
        // A project directory: a DESIGN.md, an HTML artifact folder, and an
        // opaque metadata db that must NOT be imported.
        let source = tmp.appendingPathComponent("od-project", isDirectory: true)
        let systemDir = source.appendingPathComponent("system", isDirectory: true)
        let artifactDir = source.appendingPathComponent("artifact", isDirectory: true)
        try FileManager.default.createDirectory(at: systemDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        try "# Design System\nTokens here.".write(to: systemDir.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Artifact</h1></body></html>".write(to: artifactDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log('x')".write(to: artifactDir.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
        try Data([0xDE, 0xAD]).write(to: source.appendingPathComponent("project.db")) // opaque metadata

        let designRoot = tmp.appendingPathComponent("design", isDirectory: true)
        let designSystemsRoot = tmp.appendingPathComponent("design-systems", isDirectory: true)
        let result = try ODProjectImporter.importProject(
            at: source,
            into: designRoot,
            designSystemsRoot: designSystemsRoot,
            title: "OD Import"
        )

        // DESIGN.md staged into incoming/.
        XCTAssertEqual(result.designSystemFiles.count, 1)
        let staged = try XCTUnwrap(result.designSystemFiles.first)
        XCTAssertTrue(staged.path.contains("/incoming/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        // Project created with the HTML artifact + co-located asset.
        let slug = try XCTUnwrap(result.slug)
        XCTAssertEqual(slug, "od-import")
        let site = try XCTUnwrap(result.projectDir).appendingPathComponent("site")
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appendingPathComponent("index.html").path))

        // The opaque .db metadata must NOT have been copied anywhere in site/.
        let siteFiles = FileManager.default.enumerator(at: site, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(siteFiles.contains("project.db"), "opaque metadata must not be imported into the site")
    }

    func testImportProjectWithNoHTMLStillStagesDesignSystems() throws {
        let source = tmp.appendingPathComponent("od-systems-only", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "# DS".write(to: source.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)

        let result = try ODProjectImporter.importProject(
            at: source,
            into: tmp.appendingPathComponent("design3"),
            designSystemsRoot: tmp.appendingPathComponent("design-systems3")
        )
        XCTAssertNil(result.slug, "no HTML means no renderable project")
        XCTAssertEqual(result.designSystemFiles.count, 1)
    }

    // MARK: - Helpers

    private func runZip(cwd: URL, zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = cwd
        process.arguments = ["-r", "-q", zipURL.path, "."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip fixture creation must succeed")
    }
}
