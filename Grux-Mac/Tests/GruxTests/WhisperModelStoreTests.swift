import XCTest
@testable import Grux

/// Whisper models live in Grux's own folder, never in `~/Documents`.
///
/// WhisperKit falls back to `~/Documents/huggingface` when a config names no
/// `downloadBase`, and Documents is guarded per app and emptied by iCloud (measured
/// 2026-09-27: `grux transcribe` could not load a model that was on disk). This scans
/// every source file so a loader added later cannot leave the argument out.
final class WhisperModelStoreTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_everyWhisperKitConfigNamesGruxsModelFolder() throws {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var sites = 0
        var offenders: [String] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("WhisperKitConfig(") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                sites += 1
                // The call spans a few lines; the argument must be inside it.
                let call = lines[i..<min(i + 10, lines.count)].joined(separator: "\n")
                if !call.contains("downloadBase: WhisperModelStore.downloadBase") {
                    offenders.append("\(rel):\(i + 1)")
                }
                if !call.contains("download: WhisperModelStore.mayDownload") {
                    offenders.append("\(rel):\(i + 1) downloads under test")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(sites, 3, "the scan found fewer loaders than Grux has, so it proves nothing")
        XCTAssertEqual(offenders, [], "these WhisperKit loaders fall back to ~/Documents: \(offenders)")
    }

    func test_modelFolderIsInsideGruxSupportAndNotDocuments() {
        let base = WhisperModelStore.downloadBase.standardizedFileURL.path
        XCTAssertTrue(base.hasPrefix(Persistence.supportDir.standardizedFileURL.path), base)
        XCTAssertFalse(base.contains("/Documents/"), base)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: base, isDirectory: &isDir) && isDir.boolValue)
    }

    /// THE SUITE NEVER FETCHES A MODEL. Measured 2026-09-27: once the model folder moved
    /// under `Persistence.supportDir`, every suite run touched `VoiceInput.shared`, found no
    /// model in its fresh sandbox and downloaded large-v3-turbo (1.5 to 2.5 GB) into it; 24
    /// runs filled this Mini's disk until codesign failed.
    func test_theSuiteNeverDownloadsAModel() {
        XCTAssertTrue(Persistence.isUnderTest)
        XCTAssertFalse(WhisperModelStore.mayDownload)
    }
}
